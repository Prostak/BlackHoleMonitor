# BlackHole Monitor

macOS-приложение для мониторинга уровня аудио с входа **BlackHole 2ch** в реальном времени.

## Возможности

- Захват аудио с устройства «BlackHole 2ch»
- Отображение текущего уровня (dB) и пика
- Полоска-индикатор и прокручивающийся график
- Запрос разрешения на доступ к микрофону/аудио входу

## Требования

- macOS 13+
- Xcode 15+
- Установленный [BlackHole 2ch](https://existential.audio/blackhole/)

## Сборка и запуск

```bash
cd ~/Projects/BlackHoleMonitor
open BlackHoleMonitor.xcodeproj
```

В Xcode нажмите **Run** (⌘R). При первом запуске macOS попросит разрешить доступ к микрофону — это нужно для мониторинга аудио входа (BlackHole считается входным устройством).

Или из терминала:

```bash
xcodebuild -project BlackHoleMonitor.xcodeproj -scheme BlackHoleMonitor -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/BlackHoleMonitor-*/Build/Products/Debug/BlackHoleMonitor.app
```

## Использование

1. Направьте звук в BlackHole 2ch (через Audio MIDI Setup или Multi-Output Device).
2. Запустите BlackHole Monitor.
3. Разрешите доступ к микрофону, если система спросит.
4. Приложение автоматически подключится к «BlackHole 2ch» и покажет уровень.

Кнопки **Старт** / **Стоп** — перезапуск и остановка мониторинга.

## Если нет доступа

Системные настройки → Конфиденциальность и безопасность → Микрофон → включите **BlackHole Monitor**.
