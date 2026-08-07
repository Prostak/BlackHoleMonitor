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

## Сборка и установка (рекомендуется)

Чтобы **Accessibility** не сбрасывался при каждой пересборке, установите постоянную копию в `~/Applications`:

```bash
cd ~/Projects/BlackHoleMonitor
chmod +x scripts/install.sh
./scripts/install.sh
open ~/Applications/BlackHoleMonitor.app
```

Один раз выдайте разрешения для **этой** копии:
- **Microphone** — при первом запуске
- **Accessibility** — System Settings → Privacy & Security → Accessibility → **BlackHoleMonitor**

Дальше запускайте только `~/Applications/BlackHoleMonitor.app`, а не ⌘R в Xcode. После изменений в коде снова запустите `./scripts/install.sh`.

## Разработка в Xcode

```bash
cd ~/Projects/BlackHoleMonitor
open BlackHoleMonitor.xcodeproj
```

⌘R удобен для отладки, но путь к `.app` в DerivedData меняется — macOS может снова спрашивать Accessibility.

## Использование

1. Направьте звук в BlackHole 2ch (через Audio MIDI Setup или Multi-Output Device).
2. Запустите BlackHole Monitor.
3. Разрешите доступ к микрофону, если система спросит.
4. Приложение автоматически подключится к «BlackHole 2ch» и покажет уровень.

Кнопки **Старт** / **Стоп** — перезапуск и остановка мониторинга.

## Если нет доступа

Системные настройки → Конфиденциальность и безопасность → Микрофон → включите **BlackHole Monitor**.
