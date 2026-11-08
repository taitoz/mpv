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

DEFAULT_VENC = "-c:v hevc_nvenc -preset p4 -tune hq -rc vbr -b:v 45M -maxrate:v 60M -bufsize:v 80M -tag:v hvc1"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("--src", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--start", type=float, default=0.0)
    p.add_argument("--duration", type=float, help="seconds; default: to the end")
    p.add_argument("--width", type=int, required=True, help="full output frame width")
    p.add_argument("--height", type=int, required=True, help="full output frame height")
    p.add_argument("--layout", choices=["sbs", "tb", "mono"], default="sbs")
    p.add_argument("--model", default="", help="path to .pth/.safetensors SR weights, or a raw TensorRT .engine with --engine")
    p.add_argument("--resize-only", action="store_true",
                   help="no model: plain GPU bicubic+antialias downscale to --width/--height with --sharpen")
    p.add_argument("--engine", action="store_true",
                   help="load --model as a raw TensorRT engine (.engine/.plan) via tensorrt runtime")
    p.add_argument("--model-scale", type=int, default=0,
                   help="required with --engine: model upscale factor (e.g. 4 for Nomos8k)")
    p.add_argument("--engine-input", type=int, default=0,
                   help="required with --engine: fixed input tile size incl. padding (e.g. 532)")
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


def _kr_kb(matrix):
    return (0.299, 0.114) if matrix == "bt601" else (0.2126, 0.0722)


def nv12_to_rgb(buf, w, h, matrix, rng):
    """NV12 byte buffer -> (3, h, w) float cuda tensor, 0..1 full range."""
    frame = torch.frombuffer(buf, dtype=torch.uint8).view(h * 3 // 2, w).cuda()
    y8, uv8 = frame[:h].float(), frame[h:].view(h // 2, w // 2, 2).float()
    if rng == "pc":
        yn = y8.div(255.0)
        un = uv8[..., 0].sub(128).div(255.0)
        vn = uv8[..., 1].sub(128).div(255.0)
    else:
        yn = y8.sub(16).div(219)
        un = uv8[..., 0].sub(128).div(224)
        vn = uv8[..., 1].sub(128).div(224)
    un = F.interpolate(un[None, None], size=(h, w), mode="bilinear", align_corners=False)[0, 0]
    vn = F.interpolate(vn[None, None], size=(h, w), mode="bilinear", align_corners=False)[0, 0]
    kr, kb = _kr_kb(matrix)
    r = yn + vn * (2 * (1 - kr))
    b = yn + un * (2 * (1 - kb))
    g = (yn - kr * r - kb * b) / (1 - kr - kb)
    return torch.stack([r, g, b]).clamp_(0.0, 1.0)


def rgb_to_nv12(x):
    """(3, h, w) float 0..1 -> NV12 uint8 tensor, always BT.709 limited (matches
    the output tagging). Chroma is decimated with a 2x2 average."""
    kr, kb = 0.2126, 0.0722
    r, g, b = x[0], x[1], x[2]
    yp = kr * r + (1 - kr - kb) * g + kb * b
    un = (b - yp) / (2 * (1 - kb))
    vn = (r - yp) / (2 * (1 - kr))
    y8 = yp * 219.0 + 16
    u8 = F.avg_pool2d((un * 224.0 + 128)[None], 2)[0]
    v8 = F.avg_pool2d((vn * 224.0 + 128)[None], 2)[0]
    uv = torch.stack([u8, v8], dim=2).view(x.shape[1] // 2, x.shape[2])
    return torch.cat([y8, uv]).add(0.5).clamp(0, 255).to(torch.uint8)


class ResizeOnly:
    """No model — GPU resize of each eye's luma (with unsharp) and chroma
    directly in NV12 planes; the RGB roundtrip is skipped entirely."""

    scale, batch = 1, "-"

    def __init__(self, sharpen, ow, oh, layout):
        self.target, self.sharpen, self.layout = (oh, ow), sharpen, layout

    def _rs(self, plane, oh, ow, sharpen):
        # plane: (H, W, C) float -> (oh, ow, C)
        out = F.interpolate(plane.permute(2, 0, 1)[None].float(), size=(oh, ow),
                            mode="bicubic", antialias=True, align_corners=False)[0]
        if sharpen:
            blur = F.avg_pool2d(out, kernel_size=3, stride=1, padding=1)
            out = (out + sharpen * (out - blur)).clamp_(0.0, 255.0)
        return out.permute(1, 2, 0)

    def __call__(self, frame):
        # frame: (h*3/2, w) uint8 nv12 on cuda -> (oh*3/2, ow) uint8 nv12.
        # Luma is resized per eye with unsharp; chroma is handled as (U,V)
        # pairs so adjacent pairs never bleed into each other.
        (oh, ow), layout = self.target, self.layout
        h, w = frame.shape[0] * 2 // 3, frame.shape[1]
        y = frame[:h]
        uv = frame[h:].view(h // 2, w // 2, 2)  # (h/2, w/2, 2) interleaved pairs
        if layout == "sbs":
            y_eyes = [y[..., None] for y in (y[:, :w // 2], y[:, w // 2:])]
            uv_eyes = [uv[:, :w // 4], uv[:, w // 4:]]
            t = (oh, ow // 2)
            cat_y, cat_uv = 1, 1
        elif layout == "tb":
            y_eyes = [y[..., None] for y in (y[:h // 2], y[h // 2:])]
            uv_eyes = [uv[:h // 4], uv[h // 4:]]
            t = (oh // 2, ow)
            cat_y, cat_uv = 0, 0
        else:
            y_eyes, uv_eyes, t, cat_y, cat_uv = [y[..., None]], [uv], (oh, ow), 0, 0
        y_out = torch.cat([self._rs(p, t[0], t[1], self.sharpen)[..., 0] for p in y_eyes], dim=cat_y)
        uv_out = torch.cat([self._rs(p, t[0] // 2, t[1] // 2, 0) for p in uv_eyes], dim=cat_uv)
        return torch.cat([y_out, uv_out.reshape(oh // 2, ow)]).add(0.5).clamp(0, 255).to(torch.uint8)


class TiledSr:
    """One spandrel SR model, applied to an eye frame with padded tiling.

    Each input tile of `tile`x`tile` is padded by `pad` pixels, upscaled by the
    model scale factor S, and only the central S*tile region is written to the
    output. Model output is then downscaled to the exact target size
    (bicubic, or Lanczos via torchvision), with an optional unsharp pass.
    """

    def __init__(self, model_path, tile, pad, tile_batch, fp32, compile_model,
                 downscale, sharpen, ow, oh, engine=False, model_scale=0, engine_input=0):
        if engine:
            if not model_scale or not engine_input:
                sys.exit("--engine needs --model-scale and --engine-input")
            import tensorrt as trt
            eng = trt.Runtime(trt.Logger(trt.Logger.WARNING)).deserialize_cuda_engine(
                Path(model_path).read_bytes())
            ctx = eng.create_execution_context()
            in_name = next(eng.get_tensor_name(i) for i in range(eng.num_io_tensors)
                           if eng.get_tensor_mode(eng.get_tensor_name(i)) == trt.TensorIOMode.INPUT)
            out_name = next(eng.get_tensor_name(i) for i in range(eng.num_io_tensors)
                            if eng.get_tensor_mode(eng.get_tensor_name(i)) == trt.TensorIOMode.OUTPUT)
            io_dtype = torch.float16 if eng.get_tensor_dtype(in_name) == trt.DataType.HALF else torch.float32
            in_shape = tuple(eng.get_tensor_shape(in_name))
            if in_shape[2] != engine_input:
                sys.exit(f"engine expects input {in_shape}, got --engine-input {engine_input}")
            # fixed-batch engines report dim N>0; dynamic ones report -1 and
            # are then bounded only by the build profile (our builds: 1..4)
            max_batch = in_shape[0] if in_shape[0] > 0 else tile_batch

            def run_trt(batch):
                x = batch.to(io_dtype).contiguous()
                ctx.set_input_shape(in_name, tuple(x.shape))
                y = torch.empty(tuple(ctx.get_tensor_shape(out_name)), device=x.device, dtype=io_dtype)
                ctx.set_tensor_address(in_name, x.data_ptr())
                ctx.set_tensor_address(out_name, y.data_ptr())
                ctx.execute_async_v3(torch.cuda.current_stream().cuda_stream)
                return y

            self.model = run_trt
            self.scale = model_scale
            # engine input == engine_input; pad is the border; batch is per engine profile
            self.tile, self.pad, self.batch = engine_input - 2 * pad, pad, max(1, min(tile_batch, max_batch))
            self.dtype = io_dtype
            self.cl = False
        else:
            from spandrel import ModelLoader
            self.model = ModelLoader().load_from_file(model_path).cuda().eval()
            if float(self.model.scale) != int(self.model.scale):
                sys.exit(f"model scale {self.model.scale} is non-integer, unsupported")
            self.scale = int(self.model.scale)
            self.tile, self.pad, self.batch = tile, pad, max(1, tile_batch)
            self.dtype = torch.float32 if fp32 else torch.float16
            self.model = self.model.to(dtype=self.dtype)
            # channels_last is measurably faster for conv SR models in fp16 (~25%)
            try:
                self.model.model.to(memory_format=torch.channels_last)
                self.cl = True
            except AttributeError:
                self.cl = False
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
            batch = torch.cat(tiles[i0:i0 + self.batch])
            if self.cl:
                batch = batch.to(memory_format=torch.channels_last)
            up = self.model(batch)
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
    out = Path(args.out)
    trim = ["-ss", str(args.start)] + (["-t", str(args.duration)] if args.duration else [])

    if args.resize_only:
        # pure-ffmpeg path: scale_cuda (lanczos) on GPU -> NVENC; the CPU
        # --post chain (e.g. unsharp) needs a hwdownload first. The pipe
        # version of this was ~6x slower — raw pipes cap around 500 MB/s.
        vf = f"scale_cuda={args.width}:{args.height}:interp_algo=lanczos"
        if args.post:
            vf += ",hwdownload,format=nv12," + args.post
        cmd = ([args.ffmpeg, "-hide_banner", "-y", "-hwaccel", "cuda",
                "-hwaccel_output_format", "cuda"] + trim
               + ["-i", args.src, "-map", "0:v:0", "-map", "0:a?", "-vf", vf]
               + shlex.split(args.venc)
               + ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                  "-color_range", "tv", "-c:a", "copy", str(out)])
        print(f"resize-only scale_cuda lanczos -> {args.width}x{args.height}"
              + (f" + {args.post}" if args.post else ""))
        with open(out.with_suffix(".enc.log"), "wb") as enc_log:
            rc = subprocess.call(cmd, stderr=enc_log)
        if rc:
            sys.exit(f"failed: encoder rc={rc}; see {out.stem}.enc.log")
        print(f"done -> {out}")
        return
    else:
        if not args.model:
            sys.exit("--model is required (or use --resize-only)")
        sr = TiledSr(args.model, args.tile, args.pad, args.tile_batch, args.fp32, args.compile,
                     args.downscale, args.sharpen, ow, oh,
                     engine=args.engine, model_scale=args.model_scale, engine_input=args.engine_input)
        print(f"sr x{sr.scale} ({'fp32' if args.fp32 else 'fp16'}), {args.layout}, "
              f"per eye: {iw}x{ih} tiled {args.tile}+{args.pad} x{sr.batch} -> {ow}x{oh}")

    dec_cmd = ([args.ffmpeg, "-hide_banner", "-loglevel", "error"]
               + ([] if args.no_hwdec else ["-hwaccel", "cuda"])
               + trim + ["-i", args.src, "-map", "0:v:0",
                         "-vf", "format=nv12", "-f", "rawvideo", "-"])
    enc_cmd = ([args.ffmpeg, "-hide_banner", "-y", "-f", "rawvideo", "-pix_fmt", "nv12",
                "-s", f"{args.width}x{args.height}", "-framerate", info["r_frame_rate"], "-i", "-"]
               + trim + ["-i", args.src, "-map", "0:v:0", "-map", "1:a?"]
               + (["-vf", args.post] if args.post else [])
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
        pin_bufs = [torch.empty(args.height * args.width * 3 // 2, dtype=torch.uint8,
                                pin_memory=True) for _ in range(PIN)]
        pin_views = [memoryview(b.numpy()) for b in pin_bufs]
        pin_ev = [torch.cuda.Event() for _ in range(PIN)]
        pin_done = [threading.Event() for _ in range(PIN)]
        for e in pin_done:
            e.set()
        reader = threading.Thread(target=read_frames, args=(dec.stdout, w * h * 3 // 2, q_in), daemon=True)
        writer = threading.Thread(target=write_frames, args=(enc.stdin, q_out, pin_views, pin_ev, pin_done), daemon=True)
        reader.start()
        writer.start()

        frames, t0 = 0, time.time()
        try:
            with torch.inference_mode():
                while (buf := q_in.get()) is not None:
                    if args.resize_only:
                        frame = torch.frombuffer(buf, dtype=torch.uint8).view(h * 3 // 2, w).cuda()
                        nv = sr(frame)
                    else:
                        x = nv12_to_rgb(buf, w, h, matrix, rng)
                        y = join_eyes([sr(e) for e in split_eyes(x, args.layout)], args.layout)
                        nv = rgb_to_nv12(y.clamp_(0.0, 1.0))
                    i = frames % PIN
                    pin_done[i].wait()
                    pin_bufs[i].copy_(nv.flatten(), non_blocking=True)
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
