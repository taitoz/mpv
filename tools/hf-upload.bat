@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem Upload one file to the private HF dataset repo (for RunPod source delivery).
rem The payload is AES-256 encrypted with 7-Zip (encrypted headers, stored
rem uncompressed - video does not compress anyway); password = HF_TOKEN, so no
rem extra secret is needed. Set PLAIN=1 to upload unencrypted.
rem Requires: HF_TOKEN env var (write token), huggingface_hub in the venv:
rem   "%USERPROFILE%\mpv-vfx\Scripts\python.exe" -m pip install huggingface_hub
rem Run in cmd.exe, not PowerShell.
if not defined PY set "PY=%USERPROFILE%\mpv-vfx\Scripts\python.exe"
if not defined HF_REPO set "HF_REPO=taitoz/video_source1"
set "SEVENZIP=7z"
where 7z >nul 2>nul
if errorlevel 1 if exist "%ProgramFiles%\7-Zip\7z.exe" set "SEVENZIP=%ProgramFiles%\7-Zip\7z.exe"

if "%~1"=="" goto :usage
if not defined HF_TOKEN (echo Set HF_TOKEN first: set HF_TOKEN=hf_... & exit /b 1)
set "NAME=%~2"
if not defined NAME set "NAME=%~nx1"
set "UPFILE=%~f1"

if defined PLAIN goto :upload
set "UPFILE=%TEMP%\%~nx1.7z"
set "NAME=%NAME%.7z"
echo === Encrypt -^> "%UPFILE%"
"%SEVENZIP%" a -t7z -mx=0 -mhe=on "-p%HF_TOKEN%" "%UPFILE%" "%~f1" >nul || goto :fail

:upload
echo === Upload -^> hf.co/datasets/%HF_REPO%/%NAME%
"%PY%" -c "from huggingface_hub import upload_file; upload_file(path_or_fileobj=r'%UPFILE%', path_in_repo=r'%NAME%', repo_id=r'%HF_REPO%', repo_type='dataset'); print('done')"
set "RESULT=%errorlevel%"
if not defined PLAIN del "%UPFILE%" >nul 2>nul
if not "%RESULT%"=="0" goto :fail
echo === Pod download URL (private - needs HF_TOKEN header):
echo https://huggingface.co/datasets/%HF_REPO%/resolve/main/%NAME%
if not defined PLAIN echo === Decrypt inside pod: 7z x -p"$HF_TOKEN" %NAME%
exit /b 0

:usage
echo Usage: hf-upload.bat ^<file^> [remote_name]
echo   env: HF_TOKEN (required, also the archive password), HF_REPO
echo        (default taitoz/video_source1), PY, PLAIN=1 to skip encryption
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED rc=%RESULT%
exit /b %RESULT%
