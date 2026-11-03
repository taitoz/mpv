@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem VR restoration A/B test. Run in cmd.exe, not PowerShell 5.1.
rem Segment: 01:20 - 06:20. Heights identify variants in DeoVR/XBVR.
set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
set "OUTBASE=T&A VR180_SBS_LR"
set "START=80"
set "END=380"
set "QP=18"
rem FSRCNNX WHEN: output >1.4x source in both dims (3400x1700 -> above 4760x2380).
rem 2048 height disables it; native 1700 = no upscale.
set "OUTW=4800"
set "OUTH=2400"
if not "%~2"=="" set /a "END=START+%~2"
set /a "DUR=END-START"
set /a "H1=OUTH"
set /a "H2=OUTH+2"
set /a "H3=OUTH+4"
set /a "H4=OUTH+6"
set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"
set "RENDER=--brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16"

if "%~1"=="" goto :run1
if /i "%~1"=="1" goto :run1
if /i "%~1"=="2" goto :run2
if /i "%~1"=="3" goto :run3
if /i "%~1"=="nl" goto :runnl
goto :usage

:run1
echo === [1/3] baseline scale-only
"%FFMPEG%" -y -hwaccel cuda -hwaccel_output_format cuda -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 0:a? -vf "scale_cuda=%OUTW%:%H1%:interp_algo=lanczos" -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -c:a copy "%OUTDIR%\%OUTBASE%_%H1%.mp4" 2>"%OUTDIR%\ffmpeg-v1-baseline.log"
if errorlevel 1 goto :fail
echo Wrote "%OUTDIR%\%OUTBASE%_%H1%.mp4"
if /i "%~1"=="1" goto :done

:run2
echo === [2/3] FSRCNNX
call :pipe v2-fsrcnnx %H2% "~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl"
if errorlevel 1 goto :fail
if /i "%~1"=="2" goto :done

:run3
echo === [3/3] full chain
rem SSimDownscaler dropped: only runs on downscale, inactive in this upscale chain.
call :pipe v3-full %H3% "~~/shaders/nlmeans.glsl;~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl;~~/shaders/adaptive-sharpen.glsl"
if errorlevel 1 goto :fail
goto :done

:runnl
echo === nlmeans-only diagnostic
call :pipe v4-nlmeans %H4% "~~/shaders/nlmeans.glsl"
if errorlevel 1 goto :fail
goto :done

:pipe
rem %1=log-name %2=height %3=shader list
"%MPV%" --load-auto-profiles=no --no-audio --start=%START% --end=%END% %RENDER% --vf=gpu=w=%OUTW%:h=%~2 --glsl-shaders-clr --glsl-shaders="%~3" --o=- --of=nut --ovc=rawvideo "%SRC%" 2>"%OUTDIR%\mpv-%~1.log" | "%FFMPEG%" -y -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "scale=out_color_matrix=bt709:out_range=tv:threads=0,format=nv12" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -c:a copy "%OUTDIR%\%OUTBASE%_%~2.mp4" 2>"%OUTDIR%\ffmpeg-%~1.log"
if not errorlevel 1 echo Wrote "%OUTDIR%\%OUTBASE%_%~2.mp4"
exit /b %errorlevel%

:done
echo === Done.
exit /b 0

:usage
echo Usage: vr-ab-test.bat [1^|2^|3^|nl] [seconds]
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED. Check mpv-v*.log and ffmpeg-v*.log in the output directory.
exit /b %RESULT%
