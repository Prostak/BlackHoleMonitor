# Bhm_12 — BlackHole Monitor for macOS 12 (Intel)

Копия проекта для работы на **MacBook Air Early 2015 / macOS 12.7.6** в Cursor.

Продукт: **`Bhm_12.app`** · Bundle ID: `com.local.Bhm12` · Deployment: **macOS 12.0+** · Universal **arm64 + x86_64**.

Исходная ветка разработки: `macos-12-bhm12` (репозиторий BlackHoleMonitor на основном Mac).

---

## Открыть в Cursor на Air

1. Открой папку проекта как workspace:  
   `/Volumes/MikeShared/Mike/Projects/Bhm_12`  
   (или локальную копию, если шару смонтировал в другое место).
2. Главный Xcode-проект: `BlackHoleMonitor.xcodeproj`  
   (имя target/scheme всё ещё `BlackHoleMonitor`, но **PRODUCT_NAME = Bhm_12**).
3. Готовый билд (если положен): `dist/Bhm_12.app` и `dist/Bhm_12.zip`.

### Сборка на этом Mac (если есть Xcode)

```bash
cd "/Volumes/MikeShared/Mike/Projects/Bhm_12"   # или куда скопировал
chmod +x scripts/install.sh
./scripts/install.sh
open ~/Applications/Bhm_12.app
```

На Air **без свежего Xcode** проще запускать уже собранный `dist/Bhm_12.app`  
(ПКМ → Open из‑за Gatekeeper). После каждой переустановки заново выдай:

- Microphone  
- Accessibility  
- Screen Recording (нужен для Battle / OCR)

---

## Карта файлов

```
Bhm_12/
├── README.md                          ← этот файл
├── BlackHoleMonitor.xcodeproj/        ← открой в Xcode / собирай отсюда
├── scripts/install.sh                 ← Release → ~/Applications/Bhm_12.app
├── dist/                              ← готовый .app / .zip (если есть)
├── BlackHoleMonitor/                  ← исходники приложения
│   ├── BlackHoleMonitorApp.swift      ← @main, меню
│   ├── ContentView.swift              ← UI (Activity Fishing/Battle, кнопки)
│   ├── AudioLevelMonitor.swift        ← аудио RMS, режимы, serial/keepalive
│   ├── AutobattleController.swift     ← state machine Battle (poll ~1s)
│   ├── AutobattleDetector.swift       ← захват окна SS + OCR + lock ROI
│   ├── ScreenSharingAutomation.swift  ← фокус SS + CGEvent (` / A)
│   ├── CompatSleep.swift              ← Task.sleep для macOS 12
│   ├── SerialPort.swift               ← /dev/cu.… → Pico
│   ├── AudioPassThrough.swift
│   ├── AudioDeviceHelper.swift
│   ├── LevelGraphView.swift
│   ├── ThresholdStore.swift
│   ├── TriggerBeep.swift / TriggerLog.swift
│   ├── Info.plist
│   └── BlackHoleMonitor.entitlements
└── SerialKeyboardBridge/              ← отдельная утилита (не Bhm_12)
```

Скриншоты в этой папке (`Screen Shot …png`) — артефакты с Air, не часть сборки.

---

## Режимы

| Activity | Поведение |
|----------|-----------|
| **Fishing** | Порог RMS → `` ` `` (Screen Sharing или serial). Keepalive `` ` `` ~30 с. |
| **Battle** | OCR кнопки Autobattle в окне Screen Sharing → `A`. Fishing-cast/keepalive выключены. |

**Key output:** Screen Sharing / serial (Pico) / local beep (только fishing).

### Battle / OCR (важно для производительности на Air 2015)

1. Пока кнопка **не найдена** — широкий ROI (низ окна ~40–60% × 84–93%), OCR `.accurate`.
2. После **первого нахождения** — **lock**: снимается и OCR’ится только прямоугольник кнопки (не всё окно). В статусе: `search` / `locked`.
3. Lock сбрасывается: Stop, пропало окно SS, сменился размер окна, или ~4 OCR-промаха подряд.

---

## Известные фиксы уже в этом дереве

- **macOS 12:** `CompatSleep` вместо `Task.sleep(for:)` (13+).
- **Screen Sharing path:** не хардкодить только `/System/Applications/Utilities/…` — на Monterey путь другой; резолв по bundle id + кандидаты (иначе диалог «The file can't be found»).
- **UI на Monterey:** не ставить глобальный `.foregroundStyle(.white)` — кнопки светлые, текст пропадал. Сейчас `.preferredColorScheme(.dark)` + `.bordered` / явные цвета.
- Default Activity: **Battle**.

---

## Разрешения после переустановки

Каждый новый бинарник macOS считает «другим приложением»:

1. System Preferences → Security & Privacy → Privacy → **Accessibility** — удалить Bhm_12, добавить снова.  
2. То же для **Screen Recording**.  
3. Microphone обычно остаётся.

На Monterey: **System Preferences**, не System Settings.

---

## Что править дальше (если продолжишь в Cursor на Air)

Типичные точки:

- ROI / lock / OCR: `BlackHoleMonitor/AutobattleDetector.swift`
- Тайминги poll / 2s delay: `AutobattleController.swift` (`pollIntervalSeconds`, `redWithoutGrayDelaySeconds`)
- UI: `ContentView.swift`
- Клавиши / фокус SS: `ScreenSharingAutomation.swift`
- Deployment / имя продукта: `BlackHoleMonitor.xcodeproj/project.pbxproj` (`MACOSX_DEPLOYMENT_TARGET`, `PRODUCT_NAME`, `ARCHS`)

Не нужно трогать `SerialKeyboardBridge/` для обычной работы Bhm_12.

---

## Связь с основным Mac

Основной репозиторий: `~/Projects/BlackHoleMonitor`, ветка **`macos-12-bhm12`**.  
Эта папка на MikeShared — **рабочая копия для Air**, чтобы Cursor там видел те же исходники.  
После правок на Air имеет смысл скопировать изменённые `.swift` обратно на основной Mac / в git.
