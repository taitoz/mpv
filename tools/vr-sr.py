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
    p.add_argument("--tile", type=int, default=512, help="input tile size in pixels")
    p.add_argument("--pad", type=int, default=16, help="tile overlap padding (input pixels)")
    p.add_argument("--fp32", action="store_true", help="run model in fp32 instead of fp16")
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
    output. Model output is then bicubic-downscaled to the exact target size.
    """

    def __init__(self, model_path, tile, pad, fp32, ow, oh):
        from spandrel import ModelLoader
        self.model = ModelLoader().load_from_file(model_path).cuda().eval()
        if float(self.model.scale) != int(self.model.scale):
            sys.exit(f"model scale {self.model.scale} is non-integer, unsupported")
        self.scale = int(self.model.scale)
        self.tile, self.pad = tile, pad
        self.dtype = torch.float32 if fp32 else torch.float16
        self.model = self.model.to(dtype=self.dtype)
        self.target = (oh, ow)

    def __call__(self, x):
        # x: (3, ih, iw) float on cuda, 0..1 — one eye per call
        _, ih, iw = x.shape
        s, t, p = self.scale, self.tile, self.pad
        out = torch.zeros(3, ih * s, iw * s, device=x.device, dtype=self.dtype)
        x = x.to(self.dtype)
        for y in range(0, ih, t):
            for xx in range(0, iw, t):
                y1, x1 = min(y + t, ih), min(xx + t, iw)
                py0, px0 = max(0, y - p), max(0, xx - p)
                py1, px1 = min(ih, y1 + p), min(iw, x1 + p)
                up = self.model(x[None, :, py0:py1, px0:px1])[0]
                # crop the padded border from the upscaled tile
                cy0, cx0 = (y - py0) * s, (xx - px0) * s
                out[:, y * s:y1 * s, xx * s:x1 * s] = up[:, cy0:cy0 + (y1 - y) * s, cx0:cx0 + (x1 - xx) * s]
        if (out.shape[1], out.shape[2]) != self.target:
            out = F.interpolate(out[None].float(), size=self.target, mode="bicubic",
                                antialias=True, align_corners=False)[0]
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


def write_frames(stream, q):
    try:
        while (data := q.get()) is not None:
            stream.write(data)
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

    sr = TiledSr(args.model, args.tile, args.pad, args.fp32, ow, oh)
    print(f"sr x{sr.scale} ({'fp32' if args.fp32 else 'fp16'}), {args.layout}, "
          f"per eye: {iw}x{ih} tiled {args.tile}+{args.pad} -> {ow}x{oh}")

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
        reader = threading.Thread(target=read_frames, args=(dec.stdout, w * h * 3, q_in), daemon=True)
        writer = threading.Thread(target=write_frames, args=(enc.stdin, q_out), daemon=True)
        reader.start()
        writer.start()

        frames, t0 = 0, time.time()
        try:
            with torch.inference_mode():
                while (buf := q_in.get()) is not None:
                    x = torch.frombuffer(buf, dtype=torch.uint8).view(h, w, 3).cuda()
                    x = x.permute(2, 0, 1).float().div_(255.0)
                    y = join_eyes([sr(e) for e in split_eyes(x, args.layout)], args.layout)
                    y = y.clamp_(0.0, 1.0).mul_(255.0).add_(0.5).to(torch.uint8).permute(1, 2, 0).contiguous()
                    q_out.put(y.cpu().numpy().tobytes())
                    del x, y
                    torch.cuda.empty_cache()
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
