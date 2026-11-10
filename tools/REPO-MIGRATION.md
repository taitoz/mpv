# Migration plan: VR pipeline tools -> dedicated repository

Work will continue in the new repo and in Devin Cloud session.



The VR export/SR tooling has outgrown the mpv-config repo. This plan moves it
to a new repo (suggested name: `vr-sr-pipeline`, private) while keeping the
mpv repo focused on playback configuration. Execute in order; each phase is
verifiable before the next.

## Phase 0 — Decisions (user)

- Repo name and visibility. Recommend **private** (it references adult
  library paths and is a personal workflow tool).
- Where it lives: GitHub `taitoz/<name>`. Visibility can flip to public later;
  private-first is safer while paths/names are embedded.
- Move with or without git history? The tools are young; a fresh initial
  commit is acceptable. If history matters, use `git filter-repo` to extract
  `tools/` paths — optional, adds complexity.

## Phase 1 — Inventory

**Move to the new repo (standalone VR pipeline):**

- `tools/vr-sr.py` — PyTorch SR export (the core)
- `tools/vr-vsr.py` — NVIDIA VFX VSR export
- `tools/vr-ab-test.bat`, `tools/vr-ab-shaders-test.bat` — A/B harnesses
- `tools/vr-split-eyes.bat`, `tools/vr-join-eyes.bat` — stereo split/join
- `tools/hf-upload.bat` — encrypted HF upload
- `tools/runpod-context.md`, `tools/runpod-prompt.md`, `tools/vr_sr.md`,
  this file

**Leave in the mpv repo (playback config):**

- `mpv.conf`, `profiles.conf`, `vr_profiles.conf`, `vr_rst.conf`,
  `vr_vsr.conf`, `input.conf`, `scripts/`, `shaders/` (all of them),
  `tools/bootstrap*.ps1`, installer work

**Never move / never commit anywhere:**

- `%USERPROFILE%\mpv-vfx` venv (torch + nvidia-vfx) — recreate per machine,
  it is documented in `vr_sr.md` §0 and needs no migration.
- `models/` weights (OpenModelDB) — per-model licenses vary; keep local,
  gitignored, download script instead of committing.
- Source videos and outputs — `X:\` paths stay local; HF dataset holds them.
- `HF_TOKEN` / `RUNPOD_API_KEY` — Devin Cloud secrets, not files.
- `tools/hardware_and_system_configuration_guide.md` — already being
  deleted; its PSU note lives in AGENTS.md.

## Phase 2 — De-couple from portable_config (before the move)

Current scripts assume they live inside `portable_config\tools`:

1. `vr-ab-test.bat` / `vr-ab-shaders-test.bat` use `set "MPV=%~dp0..\..\mpv.exe"`
   — change to `if not defined MPV set "MPV=mpv"` (env override, PATH
   fallback) and make the shader list a variable:
   `if not defined SHADERS_DIR set "SHADERS_DIR=<mpv portable_config path>"`,
   then `~~/shaders` stays valid only if mpv is told the config dir; simpler:
   pass absolute `glsl-shaders` paths via a `SHADER_PREFIX` env var. TODO at
   migration time, not now.
2. `SRC`/`OUTDIR`/`OUTBASE` are already top-of-file variables — keep that
   convention in the new repo.
3. `vr-sr.py`/`vr-vsr.py` are already portable (all paths are CLI args).

## Phase 3 — New repo skeleton

```
vr-sr-pipeline/
  tools/            # the .bat/.py files, unchanged layout
  docs/             # runpod-context.md, runpod-prompt.md, vr_sr.md, REPO-MIGRATION.md
  models/           # gitignored — OpenModelDB downloads go here
  .gitignore        # models/, *.7z, *.mp4, *.log, __pycache__/
  LICENSE           # GPL-3.0-or-later (same as source files' SPDX headers)
  README.md         # English, short: what it does, venv setup, quickstart
  AGENTS.md         # English: pipeline rules, test matrix, RunPod context pointer
```

Steps:

```bash
mkdir vr-sr-pipeline && cd vr-sr-pipeline && git init
# copy the files per Phase 1
git add -A && git commit -m "Initial import of VR SR pipeline tools"
gh repo create taitoz/<name> --private --source . --push
```

Then in Devin Cloud connect the new repo (app.devin.ai workspace repos), and
update `tools/runpod-prompt.md` + `runpod-context.md` to reference the new
repo name (they currently mention `taitoz/mpv`).

## Phase 4 — Home PC side

- Clone the new repo to e.g. `C:\Users\kon.pak\Documents\_Repo\vr-sr-pipeline`.
- venv stays at `%USERPROFILE%\mpv-vfx` — nothing to reinstall.
- Models land in `<repo>\models\` (gitignored); re-download from OpenModelDB
  per `vr_sr.md` §1 rather than copying by hand — or copy the folder, it's
  just weights.
- First-run verification: `tools\vr-ab-shaders-test.bat 1 5` — must produce
  a 2400-height file; that proves mpv + shaders + ffmpeg still resolve.
- Fix `SRC`/`OUTDIR` top-of-file vars in the bat files to the home `X:\`
  paths after cloning (they are per-machine config, keep them in the
  scripts but treat local edits as uncommitted overrides).

## Phase 5 — Old repo cleanup (after the new repo works)

- Delete the moved `tools/` files from the mpv repo; keep only bootstrap
  and mpv-relevant tooling.
- Leave a one-line pointer in mpv `AGENTS.md`: "VR export pipeline moved to
  `<new repo>`; this repo covers playback config only."
- The cloud agent session started via `/handoff` should be re-pointed to the
  new repo (new `/repo` pick or a fresh session with updated prompt).

## Open items to resolve during migration

- Shader dependency: A/B scripts need FSRCNNX/RAVU/NNEDI3 shaders. Two
  options: (a) keep pointing at the mpv portable_config shaders dir via env
  var (no duplication), or (b) copy the needed subset into the new repo —
  only after checking `THIRD_PARTY.md` licensing for each file.
- `vr_sr.md` is Russian — translate to English as part of the move (it is
  already flagged pending translation).
