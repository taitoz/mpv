@echo off
setlocal
rem ==================================================================
rem VR restoration A/B test: 3 sequential encode runs of the same clip
rem Run in cmd.exe ONLY (PowerShell corrupts the binary pipe).
rem
rem Variants (same input segment, encoder and QP):
rem   *_2400  baseline: scale_cuda upscale only
rem   *_2402  baseline + FSRCNNX glsl shader
rem   *_2404  full restoration chain
rem Height differs by +2 to tell files apart quickly in DeoVR/XBVR.
rem ==================================================================

rem --- User settings -------------------------------------------------
set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
set "OUTBASE=T&A VR180_LR"
set "START=80"
set "END=380"
set "WIDTH=4800"
set "QP=18"
rem -------------------------------------------------------------------

set "MPV=%~dp0..\..\mpv.exe"
set "FFMPEG=ffmpeg"
set "FF=-init_hw_device cuda=cuda:0 -filter_hw_device cuda"

echo === [1/3] baseline scale-only ^> "%OUTBASE%_2400.mp4"
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" | %FFMPEG% -y %FF% -i pipe:0 -i "%SRC%" -map 0:v -map 1:a? -vf "hwupload,scale_cuda=%WIDTH%:2400" -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -c:a copy "%OUTDIR%\%OUTBASE%_2400.mp4"
if errorlevel 1 goto :fail

echo === [2/3] FSRCNNX ^> "%OUTBASE%_2402.mp4"
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16 --glsl-shaders-clr --glsl-shaders="~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl" --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" | %FFMPEG% -y %FF% -i pipe:0 -i "%SRC%" -map 0:v -map 1:a? -vf "hwupload,scale_cuda=%WIDTH%:2402" -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -c:a copy "%OUTDIR%\%OUTBASE%_2402.mp4"
if errorlevel 1 goto :fail

echo === [3/3] full chain ^> "%OUTBASE%_2404.mp4"
"%MPV%" --load-auto-profiles=no --start=%START% --end=%END% --brightness=0 --contrast=0 --saturation=-10 --gamma=7 --hue=3 --scale=ewa_lanczos --scale-antiring=0.3 --cscale=ewa_lanczos --cscale-antiring=0.3 --dscale=mitchell --correct-downscaling=yes --linear-downscaling=no --deband=yes --deband-iterations=3 --deband-threshold=32 --deband-range=16 --deband-grain=16 --glsl-shaders-clr --glsl-shaders="~~/shaders/nlmeans.glsl;~~/shaders/FSRCNNX/FSRCNNX_x2_16-0-4-1_enhance.glsl;~~/shaders/adaptive-sharpen.glsl;~~/shaders/SSim/SSimDownscaler.glsl" --o=- --of=nut --ovc=rawvideo --oac=pcm_s16le "%SRC%" | %FFMPEG% -y %FF% -i pipe:0 -i "%SRC%" -map 0:v -map 1:a? -vf "hwupload,scale_cuda=%WIDTH%:2404" -c:v hevc_nvenc -rc constqp -qp %QP% -b:v 0 -c:a copy "%OUTDIR%\%OUTBASE%_2404.mp4"
if errorlevel 1 goto :fail

echo === Done. Compare:
echo     "%OUTDIR%\%OUTBASE%_2400.mp4"  (baseline)
echo     "%OUTDIR%\%OUTBASE%_2402.mp4"  (FSRCNNX)
echo     "%OUTDIR%\%OUTBASE%_2404.mp4"  (full chain)
echo.
echo Quick pixel-diff check whether shaders reached the export:
echo     ffmpeg -i "%OUTDIR%\%OUTBASE%_2400.mp4" -i "%OUTDIR%\%OUTBASE%_2402.mp4" -filter_complex "[0:v][1:v]blend=difference" -f null -
exit /b 0

:fail
echo === FAILED (errorlevel %errorlevel%)
exit /b %errorlevel%
