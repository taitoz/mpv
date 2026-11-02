# Конфигурация системы: Стабилизация питания, память и медиапрофили

## 1. Спецификация железа
* **CPU:** Intel Core i5-11400F
* **GPU:** EVGA GeForce RTX 3070 FTW3 ULTRA GAMING
* **Motherboard:** Gigabyte Z590 Aorus Elite AX
* **PSU:** Seasonic Prime GX-1000 (1000W, 80+ Gold)
* **RAM:** DDR4 3600 MHz (работает в режиме 3200 MHz Gear 1)

---

## 2. Настройки BIOS (Gigabyte Z590 UEFI)

### Вкладка Tweaker / Advanced CPU Settings
* **C-States Control:** `Auto` *(возвращено в Auto: отключение ломало таймеры Windows и запуск Forza Horizon 6)*
* **AES-NI (Intel AES Instructions):** `Enabled` *(обязательно включено для корректной работы защиты игр)*
* **CPU Vcore Loadline Calibration (LLC):** `Standard` *(предотвращает просадки и выбросы напряжения)*
* **Re-Size BAR Support:** `Enabled`

### Настройки памяти (RAM)
* **Частота памяти:** `3200 MHz` *(снижено с 3600/3466 МГц для устранения BSOD и нестабильности Gear 1)*
* **Memory Mode:** `Gear 1`
* **DRAM Voltage:** `1.350V - 1.400V`
* **CPU System Agent Voltage (VCCSA):** `1.200V` *(зафиксировано вручную для стабильного стриминга текстур)*

### Лимиты мощности (Turbo Power Limits)
* **Turbo Power Limits:** `Enabled`
  * **Package Power Limit 1 (PL1 - TDP):** `65` Watts
  * **Package Power Limit 2 (PL2):** `125` Watts *(обеспечивает турбо-буст на ~28-56 секунд)*
  * **Package Power Limit Time (Tau):** `Auto`

---

## 3. Настройки операционной системы (Windows 11)

* **Тестовый режим (Test Mode):** `Disabled` (`bcdedit /set testsigning off` — критично для запуска Forza Horizon 6)
* **Re-Size BAR в системе:** `Включен` в NVIDIA Control Panel
* **TdrDelay:** ранее установлен `10` в `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers`. Это запись о текущей настройке, а не требование mpv или VSR. Изменение таймаута не исправляет причину аппаратных рестартов; для проекта повышать его не требуется.

---

## 4. Настройки видеокарты (EVGA Precision X1)

* **Target Power Limit:** `75% - 80%` *(снижает пиковые микроскачки тока / transient spikes без существенной потери FPS)*
* **Применение:** Нажать `Apply` и сохранить в профиль с автозагрузкой при старте Windows.

---

## 5. Настройки блока питания (Seasonic Prime GX-1000)

* **Режим вентилятора (Hybrid Button):** `Normal` *(кнопка выжата, вентилятор вращается постоянно на минимальных оборотах для охлаждения элементов защиты)*
* **Кабели PCIe:** 2 отдельных штатных 8-pin кабеля без использования разветвителей (daisy-chain).

---

## 6. RTX VSR и текущий проект

Инструкции MPC-HC/LAV/MPC Video Renderer к portable mpv не относятся. RTX VSR в этом проекте пока не подключён и не проверен. FSRCNNX — отдельный GLSL-апскейлер, не RTX VSR; включение VSR в панели NVIDIA не подтверждает его работу в mpv или экспортируемом файле.

## 7. VR-предпросмотр и экспорт в mpv

Актуальные настройки находятся в `../vr_profiles.conf`, `../scripts/vr-detect.lua` и `../shaders/vr-flat.glsl`: `vo=gpu-next`, `gpu-api=d3d11`, `hwdec=d3d11va`, GPU-репроекция без CPU-фильтра `v360`. Предпросмотр одного глаза не следует путать с экспортом полного стереокадра SBS/TB.

`vr-ab-test.bat` экспортирует полный кадр через `vf=gpu` → rawvideo/NUT pipe → FFmpeg: преобразование RGB в NV12 на CPU → CUDA scale → HEVC NVENC. В проверенной сборке offscreen-фильтр создаёт Vulkan-контекст даже с глобальным `--gpu-api=d3d11`; это не API обычного VR-предпросмотра.

## 8. Результат проверки стабильности

После настройки системы пользователь сообщил о 30 минутах OCCT Power без ошибок (скриншот). Изменено несколько параметров, поэтому конкретная причина прежних рестартов и вклад каждого изменения не установлены. Это не гарантия стабильности экспорта; следующий шаг — повторный A/B-прогон с отдельными логами mpv и FFmpeg.