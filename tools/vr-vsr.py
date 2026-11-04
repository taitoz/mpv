# Copyright (c) 2026 taitoz
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline stereo VR export through NVIDIA VFX VideoSuperRes (nvidia-vfx).

ffmpeg decode -> RGB pipe -> per-eye VideoSuperRes on GPU -> RGB pipe ->
ffmpeg BT.709 NV12 -> encoder. Each eye has its own effect instance so the
model never mixes the two views or their temporal state.
"""
import argparse
import json
import math
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
    p.add_argument("--backend", choices=["vsr", "bicubic"], default="vsr",
                   help="bicubic = same pipeline without VSR, for A/B and testing")
    p.add_argument("--quality", default="HIGH", help="VideoSuperRes.QualityLevel name, e.g. LOW/MEDIUM/HIGH/ULTRA")
    p.add_argument("--strength", type=float, default=1.0)
    p.add_argument("--venc", default=DEFAULT_VENC, help="ffmpeg video encoder arguments")
    p.add_argument("--ffmpeg", default="ffmpeg")
    p.add_argument("--ffprobe", default="ffprobe")
    p.add_argument("--no-hwdec", action="store_true", help="decode on CPU instead of -hwaccel cuda")
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


class Bicubic:
    def __init__(self, ow, oh):
        self.size = (oh, ow)

    def __call__(self, x):
        return F.interpolate(x[None], size=self.size, mode="bicubic", align_corners=False)[0]

    def close(self):
        pass


class Vsr:
    """VideoSuperRes for one eye. If the driver rejects the exact output size,
    upscale by the next integer factor and downscale to the target on the GPU."""

    def __init__(self, iw, ih, ow, oh, quality, strength, device):
        from nvvfx import VideoSuperRes
        self.stream_ptr = torch.cuda.current_stream().cuda_stream
        self.target = (oh, ow)
        self.post = None
        self.sr = VideoSuperRes(quality=VideoSuperRes.QualityLevel[quality], strength=strength, device=device)
        self.sr.input_width, self.sr.input_height = iw, ih
        probe_frame = torch.zeros(3, ih, iw, device="cuda")
        try:
            self._load(ow, oh)
            self._run(probe_frame)
            self.mode = f"exact {iw}x{ih} -> {ow}x{oh}"
        except Exception as exc:
            k = max(2, math.ceil(max(ow / iw, oh / ih)))
            print(f"VSR rejected {ow}x{oh} ({exc}); using x{k} + bicubic downscale", file=sys.stderr)
            self.sr.close()
            self.sr = VideoSuperRes(quality=VideoSuperRes.QualityLevel[quality], strength=strength, device=device)
            self.sr.input_width, self.sr.input_height = iw, ih
            self._load(iw * k, ih * k)
            self._run(probe_frame)
            self.post = self.target
            self.mode = f"x{k} {iw}x{ih} -> {iw * k}x{ih * k} -> bicubic {ow}x{oh}"

    def _load(self, w, h):
        self.sr.output_width, self.sr.output_height = w, h
        self.sr.load()

    def _run(self, x):
        return torch.from_dlpack(self.sr.run(x, stream_ptr=self.stream_ptr).image).clone()

    def __call__(self, x):
        y = self._run(x)
        if self.post:
            y = F.interpolate(y[None], size=self.post, mode="bicubic", antialias=True, align_corners=False)[0]
        return y

    def close(self):
        self.sr.close()


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
    info = probe(args)
    w, h = int(info["width"]), int(info["height"])
    if info.get("pix_fmt", "").endswith(("10le", "10be", "12le")):
        print(f"warning: {info['pix_fmt']} source is processed as 8-bit RGB", file=sys.stderr)
    matrix, rng = color_args(info)
    iw, ih, ow, oh = eye_geometry(args.layout, w, h, args.width, args.height)

    cuda = torch.cuda.is_available()
    if args.backend == "vsr" and not cuda:
        sys.exit("VSR backend needs a CUDA GPU")
    device = "cuda" if cuda else "cpu"
    eyes = 1 if args.layout == "mono" else 2
    if args.backend == "vsr":
        upscalers = [Vsr(iw, ih, ow, oh, args.quality, args.strength, 0) for _ in range(eyes)]
        mode = upscalers[0].mode
    else:
        upscalers = [Bicubic(ow, oh) for _ in range(eyes)]
        mode = f"bicubic {iw}x{ih} -> {ow}x{oh}"
    print(f"{args.backend} ({args.quality if args.backend == 'vsr' else '-'}), {args.layout}, per eye: {mode}")

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
                         "-vf", "scale=out_color_matrix=bt709:out_range=tv:threads=0,format=nv12"]
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
                    x = torch.frombuffer(buf, dtype=torch.uint8).view(h, w, 3).to(device)
                    x = x.permute(2, 0, 1).float().div_(255.0)
                    y = join_eyes([u(e) for u, e in zip(upscalers, split_eyes(x, args.layout))], args.layout)
                    y = y.clamp_(0.0, 1.0).mul_(255.0).add_(0.5).to(torch.uint8).permute(1, 2, 0).contiguous()
                    q_out.put(y.cpu().numpy().tobytes())
                    frames += 1
                    if frames % 100 == 0:
                        print(f"{frames} frames, {frames / (time.time() - t0):.2f} fps", flush=True)
        finally:
            q_out.put(None)
            writer.join()
            for u in upscalers:
                u.close()
        rc_dec, rc_enc = dec.wait(), enc.wait()

    elapsed = time.time() - t0
    print(f"done: {frames} frames in {elapsed:.1f}s ({frames / elapsed if elapsed else 0:.2f} fps) -> {out}")
    if rc_dec or rc_enc or not frames:
        sys.exit(f"failed: decoder rc={rc_dec}, encoder rc={rc_enc}, frames={frames}; see {out.stem}.dec.log/.enc.log")


if __name__ == "__main__":
    main()
