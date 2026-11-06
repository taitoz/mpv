@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem Join per-eye files back into a stereo VR frame (SBS default, tb optional).
rem Pass the BASE name: inputs <base>_L.mp4 + <base>_R.mp4 -> <base>_joined.mp4.
rem Audio is taken from the LEFT input only. Inputs must share fps/geometry.
rem Stack runs in YUV via ffmpeg hstack/vstack. Run in cmd.exe, not PowerShell.
set "FFMPEG=ffmpeg"
if not defined QP set "QP=12"
rem Near-transparent QP 12 output by default; override via `set QP=18` before running.

if "%~1"=="" goto :usage
set "LAYOUT=%~2"
if defined LAYOUT if /i not "%LAYOUT%"=="tb" if /i not "%LAYOUT%"=="sbs" goto :usage
if /i "%LAYOUT%"=="tb" (set "STACK=vstack") else (set "STACK=hstack")

set "LEFT=%~dpn1_L.mp4"
set "RIGHT=%~dpn1_R.mp4"
set "OUT=%~dpn1_joined.mp4"
if not exist "%LEFT%" (echo Missing "%LEFT%" & exit /b 1)
if not exist "%RIGHT%" (echo Missing "%RIGHT%" & exit /b 1)

echo === Join -^> "%OUT%"
"%FFMPEG%" -hide_banner -y -i "%LEFT%" -i "%RIGHT%" -filter_complex "[0:v][1:v]%STACK%=inputs=2[v]" -map "[v]" -map 0:a? -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -c:a copy "%OUT%" || goto :fail
echo === Done.
exit /b 0

:usage
echo Usage: vr-join-eyes.bat ^<base.mp4^> [sbs^|tb]
echo   reads ^<base^>_L.mp4 + ^<base^>_R.mp4, writes ^<base^>_joined.mp4
echo   sbs (default): left eye on the left; tb: left eye on top
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED rc=%RESULT%
exit /b %RESULT%
