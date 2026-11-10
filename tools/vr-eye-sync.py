# Estimate the temporal offset between split stereo eye files (_L/_R).
# Compares one L frame at time t against R frames in a window around t,
# allowing horizontal x-shift compensation for stereo disparity.
# Prints the best-matching R offset per sample; a consistent value across
# samples is the eye desync (negative = R leads L).
#
# Usage: vr-eye-sync.py <left.mp4> <right.mp4> [t1,t2,...] [window_sec]
import subprocess
import sys

import numpy as np

FPS = 60000 / 1001
W = 160


def grab(path, t0, n=1):
    cmd = ["ffmpeg", "-v", "error", "-ss", f"{t0:.4f}", "-i", path,
           "-frames:v", str(n), "-vf", f"scale={W}:{W},format=gray",
           "-f", "rawvideo", "-"]
    d = subprocess.run(cmd, capture_output=True).stdout
    return np.frombuffer(d, np.uint8).reshape(-1, W, W).astype(np.float32)


def mse_x(a, b):
    # min MSE of a vs b over horizontal shifts; stereo eyes differ mostly
    # by horizontal disparity, so content matches across a small x range
    best = 1e18
    for dx in range(-40, 41, 4):
        if dx >= 0:
            d = ((a[:, dx:] - b[:, :W - dx]) ** 2).mean()
        else:
            d = ((a[:, :W + dx] - b[:, -dx:]) ** 2).mean()
        best = min(best, d)
    return best


def main():
    left, right = sys.argv[1], sys.argv[2]
    times = [float(v) for v in sys.argv[3].split(",")] if len(sys.argv) > 3 else [5, 15, 30, 45]
    win = float(sys.argv[4]) if len(sys.argv) > 4 else 1.5
    n = int(win * 2 * FPS)
    for t in times:
        lf = grab(left, t)[0]
        rf = grab(right, t - win, n)
        errs = [mse_x(lf, f) for f in rf]
        i = int(np.argmin(errs))
        off = (t - win + i / FPS) - t
        print(f"t={t:>5.1f}s  best R offset {off * 1000:+6.0f} ms "
              f"(mse {errs[i]:.0f} vs same-time {errs[int(win * FPS)]:.0f})")


if __name__ == "__main__":
    main()
