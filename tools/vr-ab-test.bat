@echo off
rem Copyright (c) 2026 taitoz
rem SPDX-License-Identifier: GPL-3.0-or-later
setlocal
rem VR restoration A/B test. Run in cmd.exe, not PowerShell 5.1.
rem Segment: 01:20 - 06:20. Both variants use identical output dimensions.
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
set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"
rem Python with torch CUDA + nvidia-vfx for variant 3 (see README, VSR export).
if not defined PY set "PY=%USERPROFILE%\mpv-vfx\Scripts\python.exe"
set "RENDER=--brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16"
set "SHADERS=~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl;~~/shaders/adaptive-sharpen.glsl"
set "CONVERT=scale=out_color_matrix=bt709:out_range=tv:threads=0,format=nv12"

if "%~1"=="" goto :run1
if "%~1"=="1" goto :run1
if "%~1"=="2" goto :run2
if "%~1"=="3" goto :run3
goto :usage

:run1
echo === [1/2] FSRCNNX + adaptive-sharpen
set "FILTER=%CONVERT%"
call :pipe v1-fsrcnnx-adaptive
if errorlevel 1 goto :fail
if "%~1"=="1" goto :done

:run2
echo === [2/2] Same shaders + bilateral CUDA + CPU unsharp
set "FILTER=%CONVERT%,hwupload_cuda,bilateral_cuda=sigmaS=3:sigmaR=0.12:window_size=7,hwdownload,format=nv12,unsharp=5:5:1.6:5:5:0.0"
call :pipe v2-fsrcnnx-adaptive-restored
if errorlevel 1 goto :fail
goto :done

:run3
rem Explicit only: needs the nvidia-vfx Python env. No mpv render options/shaders here.
echo === [3] NVIDIA VFX VideoSuperRes, per eye
"%PY%" "%~dp0vr-vsr.py" --src "%SRC%" --out "%OUTDIR%\%OUTBASE%_v3-vsr.mp4" --start %START% --duration %DUR% --width %OUTW% --height %OUTH% --layout sbs --quality HIGH --ffmpeg "%FFMPEG%" --venc "-c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1"
if errorlevel 1 goto :fail
echo Wrote "%OUTDIR%\%OUTBASE%_v3-vsr.mp4"
goto :done

:pipe
rem %1=log-name; shader render size matches the final size (no second resize).
"%MPV%" --load-auto-profiles=no --no-audio --start=%START% --end=%END% %RENDER% --vf=gpu=w=%OUTW%:h=%OUTH% --glsl-shaders-clr --glsl-shaders="%SHADERS%" --o=- --of=nut --ovc=rawvideo "%SRC%" 2>"%OUTDIR%\mpv-%~1.log" | "%FFMPEG%" -y -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "%FILTER%" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv -c:a copy "%OUTDIR%\%OUTBASE%_%~1.mp4" 2>"%OUTDIR%\ffmpeg-%~1.log"
set "RESULT=%errorlevel%"
if "%RESULT%"=="0" echo Wrote "%OUTDIR%\%OUTBASE%_%~1.mp4"
exit /b %RESULT%

:done
echo === Done.
exit /b 0

:usage
echo Usage: vr-ab-test.bat [1^|2^|3] [seconds]   (no argument = 1 then 2; 3 = VSR)
exit /b 2

:fail
set "RESULT=%errorlevel%"
echo === FAILED. Check mpv-v*.log and ffmpeg-v*.log in the output directory.
exit /b %RESULT%
