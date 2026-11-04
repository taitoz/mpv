@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem VR sharpening A/B test. Run in cmd.exe, not PowerShell 5.1.
rem Base for all variants: FSRCNNX_x2_16-0-4-1_enhance at 4800x2400, QP 18.
rem Only the sharpening stage differs; output suffix names the variant.
set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
set "OUTBASE=T&A VR180_SBS_LR"
set "START=80"
set "END=380"
set "QP=18"
set "OUTW=4800"
set "OUTH=2400"
if not "%~2"=="" set /a "END=START+%~2"
set /a "DUR=END-START"
set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"
set "RENDER=--brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16"
set "FSENH=~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl"
set "CONVERT=scale=out_color_matrix=bt709:out_range=tv:threads=0,format=nv12"

set "ONLY=%~1"
if /i "%ONLY%"=="all" set "ONLY="
if defined ONLY echo %ONLY%| findstr /r /x "[1-3]" >nul || goto :usage

rem 1: adaptive-sharpen in mpv, halved curve (curve_height is a #define, so a
rem separate shader copy is used; glsl-shader-opts cannot override it).
call :variant 1 adaptive-half "%FSENH%;~~/shaders/adaptive-sharpen-half.glsl" "" "%CONVERT%"
if errorlevel 1 goto :fail
rem 2: no mpv sharpen; CAS in FFmpeg (contrast-adaptive, gentler than unsharp).
call :variant 2 cas "%FSENH%" "" "%CONVERT%,cas=0.5"
if errorlevel 1 goto :fail
rem 3: no mpv sharpen; mild unsharp in FFmpeg.
call :variant 3 unsharp "%FSENH%" "" "%CONVERT%,unsharp=5:5:0.6:5:5:0.0"
if errorlevel 1 goto :fail
echo === Done.
exit /b 0

:variant
rem %1=index %2=name %3=shader list %4=extra mpv opts %5=ffmpeg filter
if defined ONLY if not "%ONLY%"=="%~1" exit /b 0
set "NAME=sharp-%~2"
echo === [%~1/3] %~2
"%MPV%" --load-auto-profiles=no --no-audio --start=%START% --end=%END% %RENDER% --vf=gpu=w=%OUTW%:h=%OUTH% --glsl-shaders-clr --glsl-shaders="%~3" %~4 --o=- --of=nut --ovc=rawvideo "%SRC%" 2>"%OUTDIR%\mpv-%NAME%.log" | "%FFMPEG%" -y -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "%~5" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -c:a copy "%OUTDIR%\%OUTBASE%_%NAME%.mp4" 2>"%OUTDIR%\ffmpeg-%NAME%.log"
set "RESULT=%errorlevel%"
if "%RESULT%"=="0" echo Wrote "%OUTDIR%\%OUTBASE%_%NAME%.mp4"
exit /b %RESULT%

:usage
echo Usage: vr-ab-test.bat [1-3^|all] [seconds]
echo   1 adaptive-sharpen curve_height=0.5  2 FFmpeg cas=0.5  3 FFmpeg unsharp 0.6
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED. Check mpv-sharp-*.log and ffmpeg-sharp-*.log in the output directory.
exit /b %RESULT%
