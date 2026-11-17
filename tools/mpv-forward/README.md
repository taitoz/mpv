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

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\Register-MpvForward.ps1
```

All options:

```powershell
.\Register-MpvForward.ps1                  # register + force all video defaults
.\Register-MpvForward.ps1 -NoForce         # register without claiming defaults
.\Register-MpvForward.ps1 -WhatIf          # dry run
.\Register-MpvForward.ps1 -Unregister      # remove everything
.\Register-MpvForward.ps1 -ExePath D:\mpv\mpv-forward.exe
.\Register-MpvForward.ps1 -Extensions mp4,mkv
```

By default the script also claims extensions already owned by other apps:
`SetUserFTA.exe` (third-party, **personal-use only**) computes the
protected `UserChoice` hash. It is looked up next to this script or next to
`mpv.exe` and auto-downloaded from setuserfta.com (v1.8.3) when absent;
override with `-SetUserFta <path>`, opt out with `-NoForce`. Verified on
Windows 11; this is an unsupported technique that Microsoft can break with
an update. Note that `UserChoice` entries are ACL-protected and cannot be
removed by `-Unregister` — reset them manually in Default apps if ever
needed.

With `-NoForce`, extensions that already have a user-chosen default
(`FileExts\<ext>\UserChoice`, hash-protected) cannot be claimed — on stock
Windows 11 most video types belong to Media Player, so finishing in
Settings > Apps > Default apps > mpv-forward is expected. The script
registers in every location the pickers read
(`Classes\.ext\OpenWithProgids`, `FileExts\.ext\OpenWithProgids`,
`SystemFileAssociations\video` covering all PerceivedType=video files,
app Capabilities), so mpv-forward should appear in all lists; if entries
look stale, sign out and back in to refresh the association cache.

## Removing stock players

`RemoveStockPlayers.ps1` uninstalls the built-in Windows players so they
stop competing for associations: Media Player (`Microsoft.ZuneMusic`),
Movies & TV (`Microsoft.ZuneVideo`), and Windows Media Player Legacy
(WMP12, disabled as an optional feature / removed as a capability).
`-IncludePhotos` also removes Photos. Per-user AppX removal works without
admin; provisioned-package and WMP removal need an elevated shell — without
admin those steps are skipped with a warning. Unless `-NoRegister` is
passed it then re-runs `Register-MpvForward.ps1` to re-claim the orphaned
associations:

```powershell
powershell -ExecutionPolicy Bypass -File .\RemoveStockPlayers.ps1
```

## Icon

`Copy-MpvIcon.ps1` copies the icon resources from `mpv.exe` into
`mpv-forward.exe` (pure Win32 resource APIs, no external tools), so the
shim shares mpv's icon in Explorer, the taskbar and file associations.
Run it after building/copying a fresh `mpv-forward.exe`:

```powershell
powershell -ExecutionPolicy Bypass -File .\Copy-MpvIcon.ps1                        # patches ..\..\..\mpv-forward.exe
powershell -ExecutionPolicy Bypass -File .\Copy-MpvIcon.ps1 -Target .\bin\mpv-forward.exe
```

## Manual test matrix

- [ ] No instance: `mpv-forward file.mp4` launches mpv normally.
- [ ] Instance idle: file is forwarded and starts playing, no new window.
- [ ] Instance playing: file replaces the current entry (`replace`).
- [ ] Multiple files: first `replace`, rest `append-play`.
- [ ] Paths with spaces / Cyrillic / UNC / URLs (`https://`, `ytdl://`).
- [ ] `mpv-forward --profile=x file.mp4` spawns a fresh instance (options are
      never forwarded).
- [ ] Two shims launched simultaneously (pipe-busy retry path).
