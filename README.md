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

Чтобы путь к `.app` был стабильным (`~/Applications`), используйте установку через скрипт:

```bash
cd ~/Projects/BlackHoleMonitor
chmod +x scripts/install.sh
./scripts/install.sh
open ~/Applications/BlackHoleMonitor.app
```

Один раз выдайте разрешения для **этой** копии:
- **Microphone** — при первом запуске
- **Accessibility** — см. раздел ниже (нужно обновлять после каждой переустановки)

Дальше запускайте только `~/Applications/BlackHoleMonitor.app`, а не ⌘R в Xcode. После изменений в коде снова запустите `./scripts/install.sh`.

### Accessibility permissions (English)

Each time you **rebuild and reinstall** the app (`./scripts/install.sh`), macOS treats it as a new binary. You must **remove BlackHoleMonitor from the Accessibility list and add it again**:

1. Open **System Settings → Privacy & Security → Accessibility**
2. Select **BlackHoleMonitor** and click **−** to remove it
3. Run the newly installed app from `~/Applications/BlackHoleMonitor.app`
4. When prompted, allow control of your computer — or click **+** and add `~/Applications/BlackHoleMonitor.app` manually

Microphone permission usually survives reinstalls; Accessibility does not.

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
