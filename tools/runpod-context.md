# Devin Cloud agent context — RunPod GPU export runs

Give this file to a Devin Cloud session when GPU exports (`vr-sr.py`, `vr-vsr.py`)
should run on rented hardware instead of the home RTX 3070. The agent operates
everything through the RunPod API/CLI and SSH — there is no browser workflow.

## Goal

Run `tools/vr-sr.py` (PyTorch SR via spandrel) or `tools/vr-vsr.py` (NVIDIA VFX)
on a rented RTX 3090/4090 pod, produce encoded mp4 output, upload the result
back to Hugging Face, then **terminate the pod**. Minimize billed time.

## Secrets (request via Devin secrets, never write to files/logs/commits)

Ask the user to store both in Devin Cloud secrets (the `upload-secrets`
flow or app.devin.ai secrets UI) — the session reads them as env vars:

- `RUNPOD_API_KEY` — RunPod account API key (RunPod console → Settings →
  API Keys; the user has already created one).
- `HF_TOKEN` — Hugging Face token for the private `taitoz/video_source1`
  dataset. Doubles as the 7-Zip archive password.
- `HF_TOKEN` — files are uploaded from the home PC via `tools/hf-upload.bat`,
  which AES-256 encrypts them with 7-Zip (`-mhe=on`, headers encrypted,
  password = `HF_TOKEN`) — the remote name gains a `.7z` suffix. Inside the
  pod download with `huggingface-cli download taitoz/video_source1
  <name>.7z --repo-type dataset` (env `HF_TOKEN`) or
  `wget --header="Authorization: Bearer $HF_TOKEN" -O <name>.7z
   "https://huggingface.co/datasets/taitoz/video_source1/resolve/main/<name>.7z"`,
  then decrypt: `7z x -p"$HF_TOKEN" <name>.7z` (install `p7zip-full` via apt
  if `7z` is missing).
- **Model weights are uploaded UNENCRYPTED** (`set PLAIN=1` before
  `hf-upload.bat`) — OpenModelDB weights are public anyway. Downloaded
  straight into the pod; they never pass through the Devin Cloud VM, which
  only orchestrates the pod (its own disk is ephemeral and holds just
  `vr-sr.py` and the SSH key).
- Names of the source video and model files in that HF repo — confirm with user.

**No per-GPU engine build is needed.** spandrel loads `.pth`/`.safetensors`
weights directly under PyTorch (already in the RunPod template);
`nvidia-vfx` ships its models inside the wheel. The only warmup cost is
`--compile` (torch.compile on the first frame, seconds — and the warmup
repeats on every fresh pod, which is fine). Resume/continue of a cloud
session does NOT rebuild anything on the pod side.

## runpodctl setup (once per session)

```bash
# binary: https://github.com/runpod/runpodctl/releases (linux amd64)
runpodctl config --apiKey "$RUNPOD_API_KEY"
runpodctl get pods            # sanity check: lists pods / empty list
```

Pod lifecycle via runpodctl: `create pod`, `get pod`, `stop pod`,
`remove pod` — check `runpodctl <cmd> --help` for the current flag names
(they change between releases). The alternative is the GraphQL API at
`https://api.runpod.io/graphql` with the same key.

## SSH access to the pod

- Generate a session keypair: `ssh-keygen -t ed25519 -f ~/.ssh/runpod -N ""`.
- Pass the PUBLIC key at pod creation — RunPod images accept the env var
  `PUBLIC_KEY` (contents of `runpod.pub`) and authorize it for root.
- After the pod is Running, `runpodctl get pod <id>` shows the public IP
  and the SSH port mapping (usually `22 -> <random high port>`).
  Connect: `ssh -i ~/.ssh/runpod -p <port> root@<ip>` — add
  `-o StrictHostKeyChecking=accept-new` for non-interactive use, and use
  `scp`/`rsync` for `vr-sr.py` if not fetching it from GitHub raw.

## Cost rules (hard requirements)

- Prefer a **network volume** (e.g. 100 GB) attached to the pod: data survives
  `stop`, and the pod can be killed at any moment without losing output.
  Container-disk data dies with the pod — upload results BEFORE terminating.
- Billing is per-second while the pod is `Running`. Sequence strictly:
  create → wait Running → install/download → short smoke run → full run →
  upload result → terminate. No idle waiting with the pod up.
- Track elapsed pod time; if a full export is projected to exceed the agreed
  budget (default: 2 h), stop, upload partial progress if any, and ask.
- On ANY unrecoverable error: still terminate (or `stop`) the pod and report —
  never leave it running for the user to find on the bill.
- `stop` preserves a network volume (still billed per GB/mo, cheap);
  `terminate` deletes the pod and its container disk. Default: terminate,
  keep the volume.

## Procedure

1. **Preflight (local, free):** verify `runpodctl` or REST access works
   (`api.runpod.io/graphql` with the API key). Confirm the source file and
   model weights are reachable. **For a first/trial run do NOT ship the 20 GB
   source** — have the user cut a segment at home
   (`ffmpeg -ss 80 -t 60 -i src.mp4 -c copy -tag:v hvc1 src_seg.mp4`,
   ~150–300 MB) and upload it via `tools\hf-upload.bat` to
   `taitoz/video_source1`, or to Pixeldrain (direct links work with wget). Avoid MEGA (free tier has a
   ~5 GB transfer quota and needs megacmd) and serving from the user's home
   uplink via XBVR/DuckDNS (pod-side download runs at the home upload speed
   and bills pod minutes).
2. **Create pod:** GPUs are frequently out of stock on RunPod. Only TWO
   models are acceptable — **RTX A5000** ($0.27/h, 24 GB, default) and
   **RTX 4000 Ada** ($0.28/h, 20 GB, fallback). If neither is in stock,
   retry the availability check every ~60 s for up to 30 min (waiting
   costs nothing — no pod exists yet, and an idle Devin session sleeps
   without consuming usage). Do NOT substitute other GPUs (no A40 — no
   NVENC; no 3090/4090/PRO — bad $/perf) and do not ask; if still out of
   stock after 30 min, report and stop.
   Official PyTorch template,
   container disk ≥ 60 GB or attached network volume ≥ 100 GB, SSH public key
   injected (generate an ed25519 keypair in the session). On-demand, not spot —
   spot can be interrupted mid-encode.
3. **Inside the pod (SSH):**
   - `nvidia-smi` → confirm the GPU.
   - `ffmpeg -encoders | grep nvenc` → confirm `hevc_nvenc`. If absent, fall
     back to `--venc "-c:v libx265 -preset medium -crf 16"` (CPU, slower —
     warn the user about runtime) rather than installing random ffmpeg builds.
   - `pip install spandrel safetensors` (PyTorch template already has torch).
   - Copy `tools/vr-sr.py` from this repo (raw GitHub URL or scp).
   - `HF_HUB_ENABLE_HF_TRANSFER=1 huggingface-cli download <repo> <file>
     --repo-type dataset` for source + model into `/workspace`.
4. **Smoke run first:** `--start 80 --duration 5` — verify the pipeline end
   to end (frame count, output size, `sr xN` line). ~30 s of pod time.
5. **Full run:** the agreed preset, e.g.
   `python vr-sr.py --src in.mp4 --out out.mp4 --model m.pth --width 4800
   --height 2400 --layout sbs --start 80 --duration 60 --tile 1024
   --tile-batch 4` — log fps lines; watch `nvidia-smi`.
6. **Verify output:** `ffprobe` → 4800x2400, expected frame count, audio
   stream present (copied from source), `bt709`/`tv` tags if the encoder kept
   them. Extract one frame to PNG and check both eyes present / not swapped.
7. **Upload:** encrypt the result the same way before pushing —
   `7z a -t7z -mx=0 -mhe=on -p"$HF_TOKEN" out.mp4.7z out.mp4` — then
   `huggingface-cli upload taitoz/video_source1 out.mp4.7z --repo-type
   dataset`. The user decrypts at home with 7-Zip using the HF token.
   Confirm the upload completed — this is the ONLY accepted result
   delivery path (HF, not a random file host).
8. **Terminate the pod immediately after a verified upload** (network
   volume may stay). Report: model used,
   scale, flags, fps, elapsed pod seconds, output path on HF, anomalies.

## Notes / known failure modes

- `vr-sr.py` is platform-neutral Python; the Windows-only parts are the .bat
  wrappers, which are NOT needed on the pod.
- `--downscale lanczos` additionally needs `pip install torchvision`.
- OOM on 24 GB is unlikely; if hit, follow `vr_sr.md` §4 fallback order.
- NVIDIA VFX (`nvidia-vfx`) also installs on Linux pip; its license still
  applies — the pod is a processing rental, nothing gets bundled.
- If the source was split into `_L`/`_R` files first (`vr-split-eyes.bat`),
  run the model per eye with `--layout mono` on each file and re-join on the
  home PC with `vr-join-eyes.bat` — this avoids shipping the full 20 GB SBS.
