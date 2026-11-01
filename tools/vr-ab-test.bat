@echo off
setlocal
rem ==================================================================
rem VR restoration A/B test: 3 sequential encode runs of the same clip
rem Run in cmd.exe ONLY (PowerShell corrupts the binary pipe).
rem
rem Segment: 01:20 - 06:20
rem   *_2400  baseline: scale_cuda upscale only
rem   *_2402  baseline + FSRCNNX glsl shader
rem   *_2404  full restoration chain
rem Height +2 per variant to tell files apart quickly in DeoVR/XBVR.
rem ==================================================================

set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
set "OUTBASE=T&A VR180_SBS_LR"
set "START=80"
set "END=380"
set "WIDTH=4800"
set "QP=18"
rem GLSL shaders only reach the mpv encode output via --vf=gpu.
rem Its output must exceed ~1.2x the source or FSRCNNX stays inactive.
rem 4800x2400 = 1.41x source; rgb0 pipe ~2GB/s. 6800x3400 was ~4GB/s and stalled.
set "SHW=4800"
set "SHH=2400"
set /a "DUR=END-START"

set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"

echo === [1/3] baseline scale-only
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" 2>"%OUTDIR%\mpv-v1-baseline.log" | %FFMPEG% -y -init_hw_device cuda=cuda:0 -filter_hw_device cuda -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v -map 1:a? -vf "hwupload,scale_cuda=%WIDTH%:2400:format=nv12" -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -c:a copy "%OUTDIR%\%OUTBASE%_2400.mp4"
if errorlevel 1 goto :fail

echo === [2/3] FSRCNNX
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16 --vf=gpu=w=%SHW%:h=%SHH% --glsl-shaders-clr --glsl-shaders="~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl" --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" 2>"%OUTDIR%\mpv-v2-fsrcnnx.log" | %FFMPEG% -y -init_hw_device cuda=cuda:0 -filter_hw_device cuda -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v -map 1:a? -vf "hwupload,scale_cuda=%WIDTH%:2402:format=nv12" -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -c:a copy "%OUTDIR%\%OUTBASE%_2402.mp4"
if errorlevel 1 goto :fail

echo === [3/3] full chain
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16 --vf=gpu=w=%SHW%:h=%SHH% --glsl-shaders-clr --glsl-shaders="~~/shaders/nlmeans.glsl;~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl;~~/shaders/adaptive-sharpen.glsl;~~/shaders/SSim/SSimDownscaler.glsl" --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" 2>"%OUTDIR%\mpv-v3-full.log" | %FFMPEG% -y -init_hw_device cuda=cuda:0 -filter_hw_device cuda -i pipe:0 -ss %START% -t %DUR% -i "%SRC%" -map 0:v -map 1:a? -vf "hwupload,scale_cuda=%WIDTH%:2404:format=nv12" -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -c:a copy "%OUTDIR%\%OUTBASE%_2404.mp4"
if errorlevel 1 goto :fail

echo === Done. Compare:
echo     "%OUTDIR%\%OUTBASE%_2400.mp4"  baseline
echo     "%OUTDIR%\%OUTBASE%_2402.mp4"  FSRCNNX
echo     "%OUTDIR%\%OUTBASE%_2404.mp4"  full chain
echo.
echo Pixel-diff check whether shaders reached the export:
echo     ffmpeg -i "%OUTDIR%\%OUTBASE%_2400.mp4" -i "%OUTDIR%\%OUTBASE%_2402.mp4" -filter_complex "[0:v][1:v]blend=difference" -f null -
exit /b 0

:fail
echo === FAILED (errorlevel %errorlevel%)
exit /b %errorlevel%
