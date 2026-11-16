# mpv-forward

Single-instance launcher shim for mpv on Windows.

## Behavior

- **mpv is already running** (listening on the IPC pipe): positional file/URL
  arguments are forwarded to the running instance via `loadfile` commands
  (first file `replace`, the rest `append-play`), and this process exits.
  No second mpv process is started, so there is no window flash.
- **No instance / any mpv option is passed / no arguments**: `mpv.exe` located
  next to this executable is launched with the original arguments.

Point file associations, shortcuts or `launch.cmd` at `mpv-forward.exe`
instead of `mpv.exe` to get single-instance behavior. `mpv-forward.exe` must
sit next to `mpv.exe`.

## Configuration

| Flag                    | Env var            | Default                     |
|-------------------------|--------------------|-----------------------------|
| `--mpv-forward-pipe=`   | `MPV_FORWARD_PIPE` | `\\.\pipe\mpvsocket`        |
| `--mpv-forward-mpv=`    | `MPV_FORWARD_MPV`  | `mpv.exe` next to the shim  |

`--mpv-forward-*` flags are consumed by the shim and never reach mpv.
The pipe name must match `input-ipc-server` in `mpv.conf`.

Errors (e.g. `mpv.exe` missing) are written to `mpv-forward.log` next to the
executable and shown in a message box.

## Build

Requires a Rust toolchain (`rustup`) with the MSVC toolchain and Visual
Studio Build Tools:

```powershell
cd tools/mpv-forward
cargo build --release
copy target\release\mpv-forward.exe ..\..\..\mpv.exe-dir\
```

## File associations (Windows 11)

`Register-MpvForward.ps1` registers `mpv-forward.exe` as a handler for all
video extensions in HKCU (no admin needed): per-extension ProgIds with an
open verb, `SupportedTypes`/`Capabilities`/`RegisteredApplications` so the app
appears in Settings > Default apps and "Open with", plus an
"Open with mpv-forward" context-menu verb per extension.

```powershell
.\Register-MpvForward.ps1                  # register all video types
.\Register-MpvForward.ps1 -WhatIf          # dry run
.\Register-MpvForward.ps1 -Unregister      # remove everything
.\Register-MpvForward.ps1 -ExePath D:\mpv\mpv-forward.exe
.\Register-MpvForward.ps1 -Extensions mp4,mkv
```

Windows 11 caveat: extensions that already have a user-chosen default
(`FileExts\<ext>\UserChoice`, hash-protected) cannot be claimed
programmatically — those must be finished in Settings > Apps > Default apps >
mpv-forward, which the script opens automatically (`-NoSettingsPrompt` to
skip).

## Manual test matrix

- [ ] No instance: `mpv-forward file.mp4` launches mpv normally.
- [ ] Instance idle: file is forwarded and starts playing, no new window.
- [ ] Instance playing: file replaces the current entry (`replace`).
- [ ] Multiple files: first `replace`, rest `append-play`.
- [ ] Paths with spaces / Cyrillic / UNC / URLs (`https://`, `ytdl://`).
- [ ] `mpv-forward --profile=x file.mp4` spawns a fresh instance (options are
      never forwarded).
- [ ] Two shims launched simultaneously (pipe-busy retry path).
