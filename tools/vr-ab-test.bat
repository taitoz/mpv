@echo off
setlocal
rem VR restoration A/B test. Run in cmd.exe, not PowerShell 5.1.
rem Segment: 01:20 - 06:20. Heights identify variants in DeoVR/XBVR.
set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
set "OUTBASE=T&A VR180_SBS_LR"
set "START=80"
set "END=380"
set "WIDTH=4800"
set "QP=18"
rem vf=gpu output: >1.2x source keeps FSRCNNX active.
rem 4096x2048 cuts pipe/CPU-conversion load vs 4800x2400;
rem final 4800x24xx comes from scale_cuda.
set "SHW=4096"
set "SHH=2048"
set /a "DUR=END-START"
set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"
set "RENDER=--brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16"

if /i "%~1"=="1" goto :run1
if /i "%~1"=="2" goto :run2
if /i "%~1"=="3" goto :run3

:run1
echo === [1/3] baseline scale-only
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --glsl-shaders-clr --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" 2>"%OUTDIR%\mpv-v1-baseline.log" | "%FFMPEG%" -y -init_hw_device cuda=cuda:0 -filter_hw_device cuda -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "format=nv12,hwupload,scale_cuda=%WIDTH%:2400" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -c:a copy "%OUTDIR%\%OUTBASE%_2400.mp4" 2>"%OUTDIR%\ffmpeg-v1-baseline.log"
if errorlevel 1 goto :fail
if /i "%~1"=="1" goto :done

:run2
echo === [2/3] FSRCNNX
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% %RENDER% --vf=gpu=w=%SHW%:h=%SHH% --glsl-shaders-clr --glsl-shaders="~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl" --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" 2>"%OUTDIR%\mpv-v2-fsrcnnx.log" | "%FFMPEG%" -y -init_hw_device cuda=cuda:0 -filter_hw_device cuda -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "format=nv12,hwupload,scale_cuda=%WIDTH%:2402" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -c:a copy "%OUTDIR%\%OUTBASE%_2402.mp4" 2>"%OUTDIR%\ffmpeg-v2-fsrcnnx.log"
if errorlevel 1 goto :fail
if /i "%~1"=="2" goto :done

:run3
echo === [3/3] full chain
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% %RENDER% --vf=gpu=w=%SHW%:h=%SHH% --glsl-shaders-clr --glsl-shaders="~~/shaders/nlmeans.glsl;~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl;~~/shaders/adaptive-sharpen.glsl;~~/shaders/SSim/SSimDownscaler.glsl" --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" 2>"%OUTDIR%\mpv-v3-full.log" | "%FFMPEG%" -y -init_hw_device cuda=cuda:0 -filter_hw_device cuda -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v:0 -map 1:a? -vf "format=nv12,hwupload,scale_cuda=%WIDTH%:2404" -t %DUR% -fps_mode passthrough -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -tag:v hvc1 -c:a copy "%OUTDIR%\%OUTBASE%_2404.mp4" 2>"%OUTDIR%\ffmpeg-v3-full.log"
if errorlevel 1 goto :fail

:done
echo === Done. Outputs:
echo "%OUTDIR%\%OUTBASE%_2400.mp4"
echo "%OUTDIR%\%OUTBASE%_2402.mp4"
echo "%OUTDIR%\%OUTBASE%_2404.mp4"
exit /b 0

:fail
set "RESULT=%errorlevel%"
echo === FAILED. Check mpv-v*.log and ffmpeg-v*.log in the output directory.
exit /b %RESULT%
