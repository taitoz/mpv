# Copy-paste prompt for a Devin Cloud session (run at home)

Paste everything below the line into a new Devin Cloud session. Attach the
`taitoz/mpv` repo if it is pushed (the agent can then read
`tools/runpod-context.md` for the full version); the inline text alone is
enough to work.

---

Run a GPU super-resolution export on a rented RunPod GPU. Goal: upscale a
VR180 SBS video segment with `vr-sr.py` (PyTorch SR via spandrel) and upload
the encrypted result back to Hugging Face. Minimize billed pod time.

Secrets already in org secrets: `RUNPOD_API_KEY`, `HF_TOKEN`. The HF token is
also the 7-Zip password. Never write either to files, logs or commits.

Setup once: install `runpodctl` (github.com/runpod/runpodctl releases, linux
amd64), `runpodctl config --apiKey "$RUNPOD_API_KEY"`, `runpodctl get pods`.
Generate `ssh-keygen -t ed25519 -f ~/.ssh/runpod -N ""` and pass its public
key as env `PUBLIC_KEY` when creating the pod.

Source: private HF dataset `taitoz/video_source1` (repo_type=dataset). Files
are AES-256 7-Zip archives (`-mhe=on`, `.7z` suffix). Download with
`huggingface-cli download taitoz/video_source1 <name>.7z --repo-type
dataset` (env HF_TOKEN) or wget with `Authorization: Bearer $HF_TOKEN` on
`.../resolve/main/<name>.7z`, then `7z x -p"$HF_TOKEN" <name>.7z`
(`apt install p7zip-full` if needed). Confirm the exact file names with me
before starting.

Pod: only RTX A5000 ($0.27) or RTX 4000 Ada ($0.28) are acceptable. If
neither is in stock, re-check every ~60 s for up to 30 min (waiting is
free — no pod exists). Do not substitute other GPUs and do not ask me;
if still out of stock after 30 min, report and stop.
Official PyTorch template, container disk ≥60 GB or a ≥100 GB network
volume, on-demand (not spot). After Running:
get IP/port via `runpodctl get pod <id>`, then
`ssh -i ~/.ssh/runpod -p <port> root@<ip>`.

Inside the pod: `nvidia-smi`; `ffmpeg -encoders | grep nvenc` — if
`hevc_nvenc` is missing, use `--venc "-c:v libx265 -preset medium -crf 16"`;
`pip install spandrel safetensors` (+ `torchvision` only if
`--downscale lanczos`). Fetch `vr-sr.py` from the repo or ask me for it.

Runs (cwd anywhere writable):
1. Smoke test first: `--start 80 --duration 5` — verify fps output and a
   valid mp4 before the long run.
2. Full run, e.g.:
   `python vr-sr.py --src src.mp4 --out out.mp4 --model <m>.pth
    --width 4800 --height 2400 --layout sbs --start 80 --duration 60
    --tile 1024 --tile-batch 4`
   Model weights live in the same dataset UNENCRYPTED (no .7z) — just
   download them to the pod. No TensorRT/engine build is needed; spandrel
   loads .pth/.safetensors directly. If a model file is not in the dataset
   yet, ask me to upload it — do not pick a different model silently.

Verify output with ffprobe: 4800x2400, frame count ≈ 30*duration, audio
stream present, bt709/tv tags if kept. Extract one PNG frame and check both
eyes are present and not swapped.

Upload: `7z a -t7z -mx=0 -mhe=on -p"$HF_TOKEN" out.mp4.7z out.mp4`, then
`huggingface-cli upload taitoz/video_source1 out.mp4.7z --repo-type
dataset`. Then TERMINATE the pod immediately (`runpodctl remove pod` or
`stop` if a network volume should persist).

Hard rules: billing is per-second — no idle pod; on any fatal error still
terminate/stop the pod and report; if projected runtime exceeds 2 h, stop
and ask first; never print secrets; never leave a pod running after the
final upload.

Report back: model+scale, flags used, fps, pod seconds elapsed, output name
on HF, any anomalies.
