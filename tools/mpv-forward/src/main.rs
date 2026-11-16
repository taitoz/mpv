// Copyright (c) 2026 taitoz
// SPDX-License-Identifier: GPL-3.0-or-later
//
// mpv-forward: single-instance launcher shim for mpv on Windows.
//
// If an mpv instance is already listening on the IPC named pipe
// (`input-ipc-server`, default \\.\pipe\mpvsocket), file/URL arguments are
// forwarded to it via `loadfile` and this process exits — no second mpv is
// ever spawned, so there is no window flash. Otherwise mpv.exe located next
// to this executable is launched with the original arguments.
//
// Shim flags (consumed here, never passed to mpv):
//   --mpv-forward-pipe=<name>   IPC pipe name (env: MPV_FORWARD_PIPE)
//   --mpv-forward-mpv=<path>    path to mpv.exe (env: MPV_FORWARD_MPV)

#![cfg_attr(not(test), windows_subsystem = "windows")]

use std::env;
use std::ffi::{OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread::sleep;
use std::time::{Duration, Instant};

const DEFAULT_PIPE: &str = r"\\.\pipe\mpvsocket";
const LOG_FILE: &str = "mpv-forward.log";
const PIPE_RETRY_TIMEOUT: Duration = Duration::from_millis(500);
const PIPE_RETRY_DELAY: Duration = Duration::from_millis(50);
const ERROR_FILE_NOT_FOUND: i32 = 2;

fn main() {
    std::process::exit(run());
}

fn run() -> i32 {
    let mut pipe = env::var("MPV_FORWARD_PIPE").unwrap_or_else(|_| DEFAULT_PIPE.into());
    let mut mpv_exe = env::var_os("MPV_FORWARD_MPV").map(PathBuf::from);
    let mut mpv_args: Vec<OsString> = Vec::new();
    let mut has_options = false;

    for arg in env::args_os().skip(1) {
        let s = arg.to_string_lossy();
        if let Some(rest) = s.strip_prefix("--mpv-forward-") {
            if let Some(v) = rest.strip_prefix("pipe=") {
                pipe = v.to_string();
            } else if let Some(v) = rest.strip_prefix("mpv=") {
                mpv_exe = Some(PathBuf::from(v));
            }
            continue;
        }
        if s.starts_with('-') {
            has_options = true;
        }
        mpv_args.push(arg);
    }

    let mpv_exe = mpv_exe.unwrap_or_else(|| {
        env::current_exe()
            .ok()
            .and_then(|p| p.parent().map(|d| d.join("mpv.exe")))
            .unwrap_or_else(|| PathBuf::from("mpv.exe"))
    });

    // Only forward pure file/URL lists. Any mpv option (or no arguments at
    // all) means the caller wants a real new instance.
    if has_options || mpv_args.is_empty() {
        return spawn_mpv(&mpv_exe, &mpv_args);
    }

    match connect_pipe(&pipe) {
        Some(mut f) => {
            for (i, arg) in mpv_args.iter().enumerate() {
                let target = absolutize_or_url(arg);
                let mode = if i == 0 { "replace" } else { "append-play" };
                let cmd = format!(
                    "{{\"command\":[\"loadfile\",\"{}\",\"{}\"]}}\n",
                    json_escape(&target),
                    mode
                );
                if f.write_all(cmd.as_bytes()).is_err() {
                    return spawn_mpv(&mpv_exe, &mpv_args);
                }
            }
            let _ = f.flush();
            0
        }
        None => spawn_mpv(&mpv_exe, &mpv_args),
    }
}

// Opens the IPC pipe for writing. Returns None when no instance is listening
// (fast exit on ERROR_FILE_NOT_FOUND) or when the pipe stays busy.
fn connect_pipe(pipe: &str) -> Option<File> {
    let deadline = Instant::now() + PIPE_RETRY_TIMEOUT;
    loop {
        match OpenOptions::new().write(true).open(pipe) {
            Ok(f) => return Some(f),
            Err(e) => {
                if e.raw_os_error() == Some(ERROR_FILE_NOT_FOUND) || Instant::now() >= deadline {
                    return None;
                }
                sleep(PIPE_RETRY_DELAY);
            }
        }
    }
}

// Local paths are made absolute so the running instance resolves them
// identically; URLs and UNC paths are passed through unchanged.
fn absolutize_or_url(arg: &OsStr) -> String {
    let s = arg.to_string_lossy();
    if s.contains("://") || s.starts_with(r"\\") {
        return s.into_owned();
    }
    match std::path::absolute(Path::new(arg)) {
        Ok(abs) => abs.to_string_lossy().into_owned(),
        Err(_) => s.into_owned(),
    }
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn spawn_mpv(exe: &Path, args: &[OsString]) -> i32 {
    match Command::new(exe).args(args).spawn() {
        Ok(_) => 0,
        Err(e) => {
            let msg = format!("failed to launch {}: {}", exe.display(), e);
            log_error(&msg);
            show_message_box(&format!("mpv-forward\n\n{}", msg));
            1
        }
    }
}

fn log_error(msg: &str) {
    let Some(dir) = env::current_exe().ok().and_then(|p| p.parent().map(PathBuf::from)) else {
        return;
    };
    let mut line = msg.to_string();
    line.push('\n');
    let _ = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(LOG_FILE))
        .and_then(|mut f| f.write_all(line.as_bytes()));
}

#[cfg(windows)]
fn show_message_box(msg: &str) {
    use std::os::windows::ffi::OsStrExt;
    const MB_ICONERROR: u32 = 0x10;
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            hwnd: *mut std::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            utype: u32,
        ) -> i32;
    }
    fn wide(s: &str) -> Vec<u16> {
        OsStr::new(s).encode_wide().chain(Some(0)).collect()
    }
    let text = wide(msg);
    let caption = wide("mpv-forward");
    unsafe {
        MessageBoxW(std::ptr::null_mut(), text.as_ptr(), caption.as_ptr(), MB_ICONERROR);
    }
}

#[cfg(not(windows))]
fn show_message_box(_: &str) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_json() {
        assert_eq!(json_escape(r#"C:\a"b.mp4"#), r#"C:\\a\"b.mp4"#);
        assert_eq!(json_escape("a\nb"), "a\\nb");
        assert_eq!(json_escape("кириллица"), "кириллица");
    }

    #[test]
    fn urls_pass_through() {
        assert_eq!(
            absolutize_or_url(OsStr::new("https://host/a b.mp4")),
            "https://host/a b.mp4"
        );
        assert_eq!(
            absolutize_or_url(OsStr::new(r"\\server\share\f.mp4")),
            r"\\server\share\f.mp4"
        );
    }

    #[test]
    fn relative_paths_become_absolute() {
        let abs = absolutize_or_url(OsStr::new("file.mp4"));
        assert!(Path::new(&abs).is_absolute(), "got: {}", abs);
    }
}
