# Инструкция по тестированию и запуску VR-SR моделей на RTX 3070 (8 GB)

Документ содержит план бенчмаркинга скрипта `vr-sr.py` с использованием оптимизаций (батчинг тайлов, динамический размер тайла и `torch.compile`), а также прямые указания по выбору и запуску моделей с **OpenModelDB**.

> Note: this file is still in Russian and must be translated before public release (project rule: English only). New sections below are written in English.

## 0. Environment (Windows, home PC)

`vr-sr.py` reuses the venv created for `vr-vsr.py`, plus `spandrel` for model loading:

```cmd
"G:\mpv-vfx\Scripts\python.exe" -m pip install spandrel safetensors
"G:\mpv-vfx\Scripts\python.exe" -c "import torch, spandrel; print(torch.cuda.get_device_name(0))"
```

**Fix: `python.exe` keeps disappearing from the venv.** If Python was installed from the Microsoft Store, `venv` puts a tiny app-execution-alias redirector in `Scripts\` instead of a real interpreter, and Windows updates/AV scans can break or delete it. Recreate the venv with `--copies` so the real `python.exe` is copied in:

```cmd
py -3.12 -m venv --copies "G:\mpv-vfx"
"G:\mpv-vfx\Scripts\python.exe" -m pip install torch==2.14.1 numpy --index-url https://download.pytorch.org/whl/cu126
"G:\mpv-vfx\Scripts\python.exe" -m pip install nvidia-vfx==0.2.0.0 spandrel safetensors --extra-index-url https://pypi.nvidia.com
```

If it still vanishes after `--copies`, check Windows Defender → Protection history — the venv dir may need an exclusion (never disable protection globally for this).

All commands below assume `PY="%USERPROFILE%\mpv-vfx\Scripts\python.exe"` and are run from `portable_config\tools`. Models are user-downloaded from OpenModelDB and are **not** bundled — check each model's license before any redistribution.

Optional: `--downscale lanczos` needs `torchvision` (same cu126 index: `pip install torchvision --index-url https://download.pytorch.org/whl/cu126`). The default `bicubic` path has no extra dependency. `--sharpen N` (default 0.3) applies an unsharp mask only when the model output is shrunk to the target size; `--sharpen 0` disables it.

---

## 1. Подготовка и загрузка моделей с OpenModelDB

https://openmodeldb.info/?q=SPAN_BSRGAN&t=restoration
Скачайте целевые веса (`.pth` или `.safetensors`) и поместите их в локальную папку `models/`:

1. **`SPAN_BSRGAN` (Архитектура SPAN)**
   * **Назначение:** Агрессивный подавитель артефактов сжатия (убирает макроблоки FFmpeg и шум) при высочайшей скорости вычислений.
   * **Поиск на OpenModelDB:** Запрос `SPAN BSRGAN` или фильтр `Architecture: SPAN`.

2. **`4x_NMKD_Superscale_Compact` (Архитектура ESRGAN Compact)**
   * **Назначение:** Классический баланс для видео. Дает высокую четкость без гадких овершутов и перешарпа на лицах.
   * **Поиск на OpenModelDB:** Запрос `NMKD Superscale Compact` или фильтр `Architecture: Compact`.

3. **`SAFMN_RealWorld` (Архитектура SAFMN / OmniSR)**
   * **Назначение:** Сверхлегкий современный трансформер (2023–2025). Восстанавливает тонкие детали на заднем плане без выедания VRAM.
   * **Поиск на OpenModelDB:** Запрос `SAFMN RealWorld` или фильтр `Architecture: SAFMN`.

**Важно про множитель модели (scale):** глаз нашего исходника — 1700×1700, цель — 2400 на глаз (1.41×). Модель **×4** рендерит 6800×6800 на глаз, которые потом сжимаются до 2400 — это в ~4 раза больше работы, чем у **×2** (3400→2400). ×4 часто даёт чуть лучшее качество после даунскейла, но для скорости ×2 (например `2x_NMKD-*`) или даже ×1 (чистый ремонт артефактов, без апскейла) обычно разумнее. Скрипт сам доводит выход до `--width/--height`; фактический scale виден в первой строке вывода (`sr x4`/`sr x2`).

---

## 2. Методология пошагового бенчмаркинга (Дома)

Чтобы точно определить, какой параметр даёт наибольший прирост FPS и где начинается OOM на 8 ГБ VRAM, тестируйте строго **по одному изменению за раз** на коротком отрезке видео. Для сравнимости с `vr-ab-shaders-test.bat` используйте тот же вход и `--start 80`; для итераций достаточно `--duration 5` (~300 кадров — первый FPS-принт появится после 25 кадров).

```cmd
set "PY=%USERPROFILE%\mpv-vfx\Scripts\python.exe"
set "SRC=X:\$XVR_Lib\Main\Romi Rain\T&A 1700p_VR180_SBS_LR.mp4"
set "OUTDIR=X:\$XVR_Lib\Main\Romi Rain"
```

### Шаг 1: Базовый замер (Baseline)
* **Параметры:** Тайл `512`, без батчинга, без компиляции.
```cmd
"%PY%" vr-sr.py --src "%SRC%" --out "%OUTDIR%\sr_base.mp4" --model models/4x_NMKD_Superscale_Compact.pth ^
  --width 4800 --height 2400 --layout sbs --start 80 --duration 5 --tile 512 --tile-batch 1
```
*Зафиксируйте FPS в логах.*

### Шаг 2: Включение батчинга тайлов (`--tile-batch 4`)
* **Цель:** Проверить утилизацию Tensor Cores при параллельном прогоне 4 тайлов.
```cmd
"%PY%" vr-sr.py --src "%SRC%" --out "%OUTDIR%\sr_batch4.mp4" --model models/4x_NMKD_Superscale_Compact.pth ^
  --width 4800 --height 2400 --layout sbs --start 80 --duration 5 --tile 512 --tile-batch 4
```

### Шаг 3: Увеличение размера тайла (`--tile 1024 --tile-batch 2`)
* **Цель:** Сократить число прогонов на глаз с 16 до 4, избавившись от kernel-launch overhead.
```cmd
"%PY%" vr-sr.py --src "%SRC%" --out "%OUTDIR%\sr_tile1024.mp4" --model models/4x_NMKD_Superscale_Compact.pth ^
  --width 4800 --height 2400 --layout sbs --start 80 --duration 5 --tile 1024 --tile-batch 2
```

### Шаг 4: Включение `torch.compile` (`--compile`)
* **Цель:** Проверить Kernel Fusion на фиксированных формах тайлов.
* *Примечание:* Первый кадр будет компилироваться 15–40 секунд — это нормально. Оценивайте скорость по последующим кадрам.
```cmd
"%PY%" vr-sr.py --src "%SRC%" --out "%OUTDIR%\sr_compile.mp4" --model models/4x_NMKD_Superscale_Compact.pth ^
  --width 4800 --height 2400 --layout sbs --start 80 --duration 5 --tile 1024 --tile-batch 2 --compile
```

---

## 3. Готовые команды для полного запуска боевых видео

После того как оптимальный пресет найден, используйте готовые команды для полного апскейла.

### А. Для максимальной скорости и подавления артефактов (`SPAN_BSRGAN`)
```cmd
"%PY%" vr-sr.py ^
  --src "%SRC%" ^
  --out "%OUTDIR%\T&A VR180_SBS_LR_SPAN_BSRGAN.mp4" ^
  --model "models/SPAN_BSRGAN.pth" ^
  --width 4800 --height 2400 ^
  --layout sbs --start 80 --duration 60 ^
  --tile 1024 --tile-batch 4 --torch-mem 0.75 ^
  --venc "-c:v hevc_nvenc -rc constqp -qp 18 -preset p6 -tag:v hvc1"
```

### Б. Для сбалансированной четкости (`4x_NMKD_Superscale_Compact`)
```cmd
"%PY%" vr-sr.py ^
  --src "%SRC%" ^
  --out "%OUTDIR%\T&A VR180_SBS_LR_NMKD_Compact.mp4" ^
  --model "models/4x_NMKD_Superscale_Compact.pth" ^
  --width 4800 --height 2400 ^
  --layout sbs --start 80 --duration 60 ^
  --tile 1024 --tile-batch 2 --torch-mem 0.75 ^
  --venc "-c:v hevc_nvenc -rc constqp -qp 18 -preset p6 -tag:v hvc1"
```

### В. Для восстановления отдаленных деталей (`SAFMN_RealWorld`)
```cmd
"%PY%" vr-sr.py ^
  --src "%SRC%" ^
  --out "%OUTDIR%\T&A VR180_SBS_LR_SAFMN.mp4" ^
  --model "models/SAFMN_RealWorld.pth" ^
  --width 4800 --height 2400 ^
  --layout sbs --start 80 --duration 60 ^
  --tile 768 --tile-batch 2 --torch-mem 0.7 ^
  --venc "-c:v hevc_nvenc -rc constqp -qp 18 -preset p6 -tag:v hvc1"
```

---

## 4. Защита от OOM (Out Of Memory) на RTX 3070

Если при запуске скрипт выдает `CUDA out of memory`:

1. Уменьшите `--tile-batch` с `4` до `2` (или `1`).
2. Ограничьте выделение VRAM под PyTorch через `--torch-mem 0.7` (оставит 30% VRAM под кэш NVENC и интерфейс системы).
3. Снизьте размер тайла с `1024` до `768` или `512`.

---

## 5. Instructions for Devin (home PC)

Goal: find the fastest safe `vr-sr.py` preset per model on the RTX 3070, then produce comparable A/B exports.

**Constraints**

- This is the home machine — heavy GPU runs are allowed here (the development PC is NOT; it bugcheck-rebooted under GPU export load).
- Work in `cmd.exe` (batch syntax above), cwd = `portable_config\tools`. Long exports run in background; poll `get_output`, do not busy-wait.
- Never interrupt a running encode except on error; partial mp4 files are fine to delete.
- Watch VRAM via `nvidia-smi --query-gpu=memory.used --format=csv -l 5` in a second shell if OOM is suspected.

**Procedure**

1. **Preflight**: run the two env commands in §0; confirm `NVIDIA RTX 3070` prints. Confirm `models/` contains the downloaded weights; list filenames and report which architecture/scale spandrel detected (`sr xN` in the first output line). If a model fails to load, report the spandrel error verbatim — do not rename or convert weights.
2. **Benchmark matrix** (per model): run §2 steps 1→4 in order, exactly one change at a time. Record for each run: final `done: N frames in Ts (F fps)` line, peak `nvidia-smi` memory, whether OOM occurred. On OOM, step back per §4 and continue. `--compile` fps must be read *after* the warmup frame.
3. **Report a table**: model | scale | tile | batch | compile | fps | peak VRAM | verdict. Mark the best fps and the best fps-per-quality guess.
4. **Full 60 s exports**: run §3 presets that survive, plus the winner config applied to each model. Output names must carry the model name (already in §3).
5. **Verify each output** with ffprobe: `width=4800 height=2400`, `color_space=bt709`, `color_range=tv`, audio stream present, duration ≈ requested.
6. **Sanity-check one frame**: extract frame ~150 (`ffmpeg -ss ~2.5 -i out.mp4 -frames:v 1 frame.png`) and check left/right eyes are not swapped, no tiling seams at eye borders, no color shift vs the shader-test outputs (`..._2402.mp4` etc. from `vr-ab-shaders-test.bat`).
7. **Report to the user**: table + file list + any anomalies. The user does the Quest 2/DeoVR comparison; do not judge visual quality from numbers.

**Known issues to escalate, not fix silently**: spandrel "unsupported architecture" (model not in registry — report name), persistent OOM even at `--tile 256 --tile-batch 1 --torch-mem 0.5`, ffmpeg `hevc_nvenc` missing, fps < 0.1 for >5 min (likely CPU fallback — check `.dec.log`), `No module named 'torchvision'` when `--downscale lanczos` is used (install per §0 or drop the flag).