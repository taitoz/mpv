@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem VR upscaler A/B test. Run in cmd.exe, not PowerShell 5.1.
rem Only the luma upscaler changes; render options, QP and segment are identical.
rem Output height OUTH+0/2/4/... identifies the variant in DeoVR/XBVR.
set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
set "OUTBASE=T&A VR180_SBS_LR"
set "START=80"
set "END=140"
set "QP=18"
rem 3400x1700 source: FSRCNNX enhance needs >1.4x (h>2380), plain FSRCNNX >1.3x,
rem NNEDI3 needs h>2404.2 (1.414x), so it runs last at 2408. RAVU-zoom: any upscale.
set "OUTW=4800"
set "OUTH=2400"
if not "%~2"=="" set /a "END=START+%~2"
set /a "DUR=END-START"
set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"
set "RENDER=--brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16"
set "CONVERT=scale=out_color_matrix=bt709:out_range=tv:threads=0,format=nv12"

set "ONLY=%~1"
if /i "%ONLY%"=="all" set "ONLY="
if defined ONLY echo %ONLY%| findstr /r /x "[1-6]" >nul || goto :usage

call :variant 1 none ""
if errorlevel 1 goto :fail
call :variant 2 fsrcnnx16-enhance "~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl"
if errorlevel 1 goto :fail
call :variant 3 fsrcnnx16 "~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1.glsl"
if errorlevel 1 goto :fail
call :variant 4 ravu-zoom-ar-r3 "~~/shaders/RAVU/RAVU Zoom Antiringing/ravu-zoom-ar-r3.hook"
if errorlevel 1 goto :fail
call :variant 5 nnedi3-nns64 "~~/shaders/NNEDI3/nnedi3-nns64-win8x4.hook"
if errorlevel 1 goto :fail
call :variant 6 fsrcnnx8 "~~/shaders/FSRCNNX/FSRCNNX_x2_8-0-4-1.glsl"
if errorlevel 1 goto :fail
echo === Done.
exit /b 0

:variant
rem %1=index %2=name %3=shader list (empty = render options only)
if defined ONLY if not "%ONLY%"=="%~1" exit /b 0
set /a "H=OUTH+2*(%~1-1)"
set "NAME=%H%_%~2"
echo === [%~1/6] %~2 at %OUTW%x%H%
"%MPV%" --load-auto-profiles=no --no-audio --start=%START% --end=%END% %RENDER% --vf=gpu=w=%OUTW%:h=%H% --glsl-shaders-clr --glsl-shaders="%~3" --o=- --of=nut --ovc=rawvideo "%SRC%" 2>"%OUTDIR%\mpv-up-%NAME%.log" | "%FFMPEG%" -y -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "%CONVERT%" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -c:a copy "%OUTDIR%\%OUTBASE%_%NAME%.mp4" 2>"%OUTDIR%\ffmpeg-up-%NAME%.log"
set "RESULT=%errorlevel%"
if "%RESULT%"=="0" echo Wrote "%OUTDIR%\%OUTBASE%_%NAME%.mp4"
exit /b %RESULT%

:usage
echo Usage: vr-ab-shaders-test.bat [1-6^|all] [seconds]
echo   1 none  2 fsrcnnx16-enhance  3 fsrcnnx16  4 ravu-zoom-ar-r3  5 nnedi3-nns64  6 fsrcnnx8
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED. Check mpv-up-*.log and ffmpeg-up-*.log in the output directory.
exit /b %RESULT%
