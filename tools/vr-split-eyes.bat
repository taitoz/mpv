@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem Split a stereo VR video (SBS or TB) into separate left/right eye files.
rem Output: <src>_L.mp4 (keeps audio) and <src>_R.mp4 (video only), next to src.
rem Crop runs in YUV via ffmpeg expressions (iw/ih), so no resolution needed.
rem Run in cmd.exe, not PowerShell.
set "FFMPEG=ffmpeg"
if not defined QP set "QP=12"
rem Near-transparent QP 12 intermediates by default; override via `set QP=18` before running.

if "%~1"=="" goto :usage
set "SRC=%~1"
set "START=%~2"
set "DUR=%~3"
set "LAYOUT=%~4"
if not defined START set "START=0"
if defined LAYOUT if /i not "%LAYOUT%"=="tb" if /i not "%LAYOUT%"=="sbs" goto :usage

set "TRIM=-ss %START%"
if defined DUR set "TRIM=%TRIM% -t %DUR%"
set "ENC=-c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1"

if /i "%LAYOUT%"=="tb" (
    set "LCROP=crop=iw:ih/2:0:0"
    set "RCROP=crop=iw:ih/2:0:ih/2"
) else (
    set "LCROP=crop=iw/2:ih:0:0"
    set "RCROP=crop=iw/2:ih:iw/2:0"
)

echo === Left  -^> "%~dpn1_L.mp4"
"%FFMPEG%" -hide_banner -y %TRIM% -i "%SRC%" -map 0:v:0 -map 0:a? -vf "%LCROP%" %ENC% -c:a copy "%~dpn1_L.mp4" || goto :fail
echo === Right -^> "%~dpn1_R.mp4"
"%FFMPEG%" -hide_banner -y %TRIM% -i "%SRC%" -map 0:v:0 -an -vf "%RCROP%" %ENC% "%~dpn1_R.mp4" || goto :fail
echo === Done.
exit /b 0

:usage
echo Usage: vr-split-eyes.bat ^<src.mp4^> [start_s] [dur_s] [sbs^|tb]
echo   writes ^<src^>_L.mp4 (left eye + audio) and ^<src^>_R.mp4 (right eye)
echo   sbs (default): left = left half, right = right half; tb: left = top
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED rc=%RESULT%
exit /b %RESULT%
