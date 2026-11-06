# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline stereo VR export through a PyTorch super-resolution model (.pth/.safetensors).

Same pipeline as vr-vsr.py: ffmpeg decode -> RGB pipe -> per-eye SR on GPU
(tiled, for low VRAM) -> optional downscale to target -> RGB pipe -> ffmpeg
BT.709 NV12 -> encoder. Each eye is upscaled separately so the model never
mixes the two views. Model loading uses `spandrel`, which detects the
architecture (SPAN/ESRGAN/SwinIR/...) from the weights file.
"""
import argparse
import json
import queue
import shlex
import subprocess
import sys
import threading
import time
from pathlib import Path

import torch
import torch.nn.functional as F

DEFAULT_VENC = "-c:v hevc_nvenc -rc constqp -qp 18 -b:v 0 -tag:v hvc1"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--start", type=float, default=0.0)
    p.add_argument("--duration", type=float, help="seconds; default: to the end")
    p.add_argument("--width", type=int, required=True, help="full output frame width")
    p.add_argument("--height", type=int, required=True, help="full output frame height")
    p.add_argument("--layout", choices=["sbs", "tb", "mono"], default="sbs")
    p.add_argument("--model", required=True, help="path to .pth/.safetensors SR weights")
    p.add_argument("--tile", type=int, default=512,
                   help="input tile size in pixels; larger (768/1024) means fewer model calls if VRAM allows")
    p.add_argument("--tile-batch", type=int, default=4,
                   help="tiles per model call; lowers kernel-launch overhead, uses more VRAM")
    p.add_argument("--pad", type=int, default=16, help="tile overlap padding (input pixels)")
    p.add_argument("--downscale", choices=["bicubic", "lanczos"], default="bicubic",
                   help="filter for shrinking model output to the target size; lanczos needs torchvision")
    p.add_argument("--sharpen", type=float, default=0.3,
                   help="unsharp amount applied only when model output is shrunk (0 disables)")
    p.add_argument("--fp32", action="store_true", help="run model in fp32 instead of fp16")
    p.add_argument("--compile", action="store_true",
                   help="torch.compile(mode='reduce-overhead') the SR model; long warmup on first frame")
    p.add_argument("--venc", default=DEFAULT_VENC, help="ffmpeg video encoder arguments")
    p.add_argument("--post", default="", help="extra ffmpeg filters after NV12 conversion, e.g. unsharp=5:5:0.6")
    p.add_argument("--ffmpeg", default="ffmpeg")
    p.add_argument("--ffprobe", default="ffprobe")
    p.add_argument("--no-hwdec", action="store_true", help="decode on CPU instead of -hwaccel cuda")
    p.add_argument("--torch-mem", type=float, default=0.0,
                   help="cap torch VRAM to this fraction of total (e.g. 0.7 leaves room for NVENC)")
    return p.parse_args()


def probe(args):
    out = subprocess.run(
        [args.ffprobe, "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,pix_fmt,r_frame_rate,color_space,color_range", "-of", "json", args.src],
        capture_output=True, text=True, check=True)
    return json.loads(out.stdout)["streams"][0]


def color_args(info):
    matrix = "bt601" if info.get("color_space") in ("bt470bg", "smpte170m") else "bt709"
    rng = "pc" if info.get("color_range") == "pc" else "tv"
    return matrix, rng


def eye_geometry(layout, w, h, ow, oh):
    if layout == "sbs":
        return w // 2, h, ow // 2, oh
    if layout == "tb":
        return w, h // 2, ow, oh // 2
    return w, h, ow, oh


def split_eyes(x, layout):
    if layout == "sbs":
        half = x.shape[2] // 2
        return [x[:, :, :half].contiguous(), x[:, :, half:].contiguous()]
    if layout == "tb":
        half = x.shape[1] // 2
        return [x[:, :half, :].contiguous(), x[:, half:, :].contiguous()]
    return [x]


def join_eyes(eyes, layout):
    if layout == "mono":
        return eyes[0]
    return torch.cat(eyes, dim=2 if layout == "sbs" else 1)


class TiledSr:
    """One spandrel SR model, applied to an eye frame with padded tiling.

    Each input tile of `tile`x`tile` is padded by `pad` pixels, upscaled by the
    model scale factor S, and only the central S*tile region is written to the
    output. Model output is then downscaled to the exact target size
    (bicubic, or Lanczos via torchvision), with an optional unsharp pass.
    """

    def __init__(self, model_path, tile, pad, tile_batch, fp32, compile_model,
                 downscale, sharpen, ow, oh):
        from spandrel import ModelLoader
        self.model = ModelLoader().load_from_file(model_path).cuda().eval()
        if float(self.model.scale) != int(self.model.scale):
            sys.exit(f"model scale {self.model.scale} is non-integer, unsupported")
        self.scale = int(self.model.scale)
        self.tile, self.pad, self.batch = tile, pad, max(1, tile_batch)
        self.dtype = torch.float32 if fp32 else torch.float16
        self.model = self.model.to(dtype=self.dtype)
        if compile_model:
            self.model = torch.compile(self.model, mode="reduce-overhead")
        self.target = (oh, ow)
        self.downscale, self.sharpen = downscale, sharpen

    def __call__(self, x):
        # x: (3, ih, iw) float on cuda, 0..1 — one eye per call
        _, ih, iw = x.shape
        s, t, p = self.scale, self.tile, self.pad
        out = torch.zeros(3, ih * s, iw * s, device=x.device, dtype=self.dtype)
        x = x.to(self.dtype)
        tiles, coords = [], []
        for y in range(0, ih, t):
            for xx in range(0, iw, t):
                y1, x1 = min(y + t, ih), min(xx + t, iw)
                # clip the context to the image, then replicate-pad the tile to
                # a constant (t+2p) shape: every model call gets the same input
                # size, which lets the caching allocator reuse blocks and is a
                # prerequisite for torch.compile CUDA graphs and tile batching
                py0, px0 = max(0, y - p), max(0, xx - p)
                py1, px1 = min(ih, y1 + p), min(iw, x1 + p)
                tile_in = x[None, :, py0:py1, px0:px1]
                pl, pt = px0 - (xx - p), py0 - (y - p)
                pr = t + 2 * p - (px1 - px0) - pl
                pb = t + 2 * p - (py1 - py0) - pt
                if pl or pt or pr or pb:
                    tile_in = F.pad(tile_in, (pl, pr, pt, pb), mode="replicate")
                tiles.append(tile_in)
                coords.append((y, y1, xx, x1))
        for i0 in range(0, len(tiles), self.batch):
            up = self.model(torch.cat(tiles[i0:i0 + self.batch]))
            for j, (y, y1, xx, x1) in enumerate(coords[i0:i0 + self.batch]):
                # image row/col y/xx always sits at padded index p
                out[:, y * s:y1 * s, xx * s:x1 * s] = up[j, :, p * s:p * s + (y1 - y) * s, p * s:p * s + (x1 - xx) * s]
        if (out.shape[1], out.shape[2]) != self.target:
            shrinking = out.shape[1] > self.target[0] or out.shape[2] > self.target[1]
            if self.downscale == "lanczos":
                from torchvision.transforms.functional import InterpolationMode, resize
                out = resize(out.float(), list(self.target),
                             interpolation=InterpolationMode.LANCZOS, antialias=True)
            else:
                out = F.interpolate(out[None].float(), size=self.target, mode="bicubic",
                                    antialias=True, align_corners=False)[0]
            if shrinking and self.sharpen:
                # mild unsharp mask compensates the softening any downscale adds
                blur = F.avg_pool2d(out[None], kernel_size=3, stride=1, padding=1)[0]
                out = (out + self.sharpen * (out - blur)).clamp_(0.0, 1.0)
        return out.float()


def read_frames(stream, frame_bytes, q):
    try:
        while True:
            buf = bytearray(frame_bytes)
            view, got = memoryview(buf), 0
            while got < frame_bytes:
                n = stream.readinto(view[got:])
                if not n:
                    return
                got += n
            q.put(buf)
    finally:
        q.put(None)


def write_frames(stream, q, views, events, done):
    try:
        while (i := q.get()) is not None:
            events[i].synchronize()
            stream.write(views[i])
            done[i].set()
    finally:
        stream.close()


def main():
    args = parse_args()
    if not torch.cuda.is_available():
        sys.exit("needs a CUDA GPU")
    if args.torch_mem:
        torch.cuda.set_per_process_memory_fraction(args.torch_mem)
    info = probe(args)
    w, h = int(info["width"]), int(info["height"])
    if info.get("pix_fmt", "").endswith(("10le", "10be", "12le")):
        print(f"warning: {info['pix_fmt']} source is processed as 8-bit RGB", file=sys.stderr)
    matrix, rng = color_args(info)
    iw, ih, ow, oh = eye_geometry(args.layout, w, h, args.width, args.height)

    sr = TiledSr(args.model, args.tile, args.pad, args.tile_batch, args.fp32, args.compile,
                 args.downscale, args.sharpen, ow, oh)
    print(f"sr x{sr.scale} ({'fp32' if args.fp32 else 'fp16'}), {args.layout}, "
          f"per eye: {iw}x{ih} tiled {args.tile}+{args.pad} x{sr.batch} -> {ow}x{oh}")

    out = Path(args.out)
    trim = ["-ss", str(args.start)] + (["-t", str(args.duration)] if args.duration else [])
    dec_cmd = ([args.ffmpeg, "-hide_banner", "-loglevel", "error"]
               + ([] if args.no_hwdec else ["-hwaccel", "cuda"])
               + trim + ["-i", args.src, "-map", "0:v:0",
                         "-vf", f"scale=in_color_matrix={matrix}:in_range={rng}:threads=0,format=rgb24",
                         "-f", "rawvideo", "-"])
    enc_cmd = ([args.ffmpeg, "-hide_banner", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
                "-s", f"{args.width}x{args.height}", "-framerate", info["r_frame_rate"], "-i", "-"]
               + trim + ["-i", args.src, "-map", "0:v:0", "-map", "1:a?",
                         "-vf", "scale=out_color_matrix=bt709:out_range=tv:threads=0,format=nv12"
                         + (("," + args.post) if args.post else "")]
               + shlex.split(args.venc)
               + ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                  "-color_range", "tv", "-c:a", "copy", str(out)])

    with open(out.with_suffix(".dec.log"), "wb") as dec_log, open(out.with_suffix(".enc.log"), "wb") as enc_log:
        dec = subprocess.Popen(dec_cmd, stdout=subprocess.PIPE, stderr=dec_log)
        enc = subprocess.Popen(enc_cmd, stdin=subprocess.PIPE, stderr=enc_log)
        q_in, q_out = queue.Queue(maxsize=4), queue.Queue(maxsize=4)
        # pool of pinned output buffers: D2H copy runs async on the CUDA stream
        # and the pipe writer overlaps it with the next frame's compute
        PIN = 3
        pin_bufs = [torch.empty(args.height * args.width * 3, dtype=torch.uint8,
                                pin_memory=True) for _ in range(PIN)]
        pin_views = [memoryview(b.view(args.height, args.width, 3).numpy()) for b in pin_bufs]
        pin_ev = [torch.cuda.Event() for _ in range(PIN)]
        pin_done = [threading.Event() for _ in range(PIN)]
        for e in pin_done:
            e.set()
        reader = threading.Thread(target=read_frames, args=(dec.stdout, w * h * 3, q_in), daemon=True)
        writer = threading.Thread(target=write_frames, args=(enc.stdin, q_out, pin_views, pin_ev, pin_done), daemon=True)
        reader.start()
        writer.start()

        frames, t0 = 0, time.time()
        try:
            with torch.inference_mode():
                while (buf := q_in.get()) is not None:
                    x = torch.frombuffer(buf, dtype=torch.uint8).view(h, w, 3).cuda()
                    x = x.permute(2, 0, 1).float().div_(255.0)
                    y = join_eyes([sr(e) for e in split_eyes(x, args.layout)], args.layout)
                    y = y.clamp_(0.0, 1.0).mul_(255.0).add_(0.5).to(torch.uint8).permute(1, 2, 0)
                    i = frames % PIN
                    pin_done[i].wait()
                    pin_bufs[i].view(args.height, args.width, 3).copy_(y, non_blocking=True)
                    pin_ev[i].record()
                    q_out.put(i)
                    frames += 1
                    if frames % 25 == 0:
                        print(f"{frames} frames, {frames / (time.time() - t0):.2f} fps", flush=True)
        finally:
            q_out.put(None)
            writer.join()
        rc_dec, rc_enc = dec.wait(), enc.wait()

    elapsed = time.time() - t0
    print(f"done: {frames} frames in {elapsed:.1f}s ({frames / elapsed if elapsed else 0:.2f} fps) -> {out}")
    if rc_dec or rc_enc or not frames:
        sys.exit(f"failed: decoder rc={rc_dec}, encoder rc={rc_enc}, frames={frames}; see {out.stem}.dec.log/.enc.log")


if __name__ == "__main__":
    main()
