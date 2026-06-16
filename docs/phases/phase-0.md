# Phase 0 — Параллельная сборка UshiNext

**Перед началом:** прочитай `docs/projects-brief.md` целиком, особенно §0 (параметры UshiNext) и §13 (зафиксированные решения). Не пересматривай решения брифа.

## Что нужно сделать

Создать вторую сборку приложения рядом с существующим Ushi. После Phase 0 должны быть установлены **обе версии**, запускаться независимо, не делить данные.

## Контекст

В репо есть текущий рабочий Ushi (`ushi/`, `ushi.xcodeproj`). Юзер пользуется им ежедневно, **трогать нельзя**. Все будущие фазы (1-6) делаются в новой папке `ushi-next/`.

## Задачи

1. **Дубликат папки.** `cp -R ushi/ ushi-next/`. Сохрани новую папку рядом с исходной.
2. **Дубликат Xcode-проекта.** Внутри `ushi-next/` переименуй `ushi.xcodeproj` → `ushinext.xcodeproj`. Открой в Xcode, поменяй в настройках target:
   - Product Name: `UshiNext`
   - Bundle Identifier: `com.icemac.UshiNext`
   - Display Name (Info.plist `CFBundleDisplayName`): `Ushi Next`
3. **Application Support.** Найди в коде все упоминания пути к Application Support (вероятно в `RecordingsStore`, `ModelManager`, `AppSettings`). Введи константу `AppContainer.name = "UshiNext"` в одном месте, прокинь её во все нужные пути. Проверь, что Ushi-старый продолжает писать в `~/Library/Application Support/ushi/`, а UshiNext — в `~/Library/Application Support/UshiNext/`.
4. **UserDefaults suite.** Если используется (`UserDefaults(suiteName:)`) — сменить на `com.icemac.UshiNext`. Если `UserDefaults.standard` — оставить (он сам разделяется по bundle id).
5. **Иконка menu bar.** Скопируй `MenuBarWaveform.imageset` → `MenuBarWaveformNext.imageset`. К существующему PDF/SVG добавь маленькую цветную точку в правом верхнем углу (любого яркого цвета — синего/оранжевого, чтобы отличалась). Подключи новый asset в коде вместо старого.
6. **Иконка приложения (опционально, но желательно).** Если есть AppIcon — дублируй и добавь визуальный маркер `next` (можно текстом или цветной полосой), чтобы в Dock/Spotlight отличалось.

## Готово когда

- Обе сборки можно собрать и запустить из Xcode без конфликтов.
- В `/Applications` (или `~/Applications`) лежат две разные `.app`-бандла, обе запускаются.
- У каждой свой menu bar icon (визуально отличимы).
- Запись в UshiNext попадает в `~/Library/Application Support/UshiNext/`, в старом Ushi — в `~/Library/Application Support/ushi/`. Базы не пересекаются, можно проверить через Finder.
- Старый Ushi работает как раньше, без регрессий.

## Не делай

- Не меняй ничего в исходной папке `ushi/`. Все правки — только в `ushi-next/`.
- Не начинай Phase 1 (модель Проектов). Phase 0 только про инфраструктуру дубль-сборки.
- Не делай миграцию данных из старого Ushi сейчас — это Phase 6.

## Отчёт

В конце — короткий отчёт: какие файлы тронуты в `ushi-next/`, какие пути меняли, чем отличается иконка. Подтверди, что обе сборки независимо запустились на твоей машине (или, если запуск невозможен, что собралось без ошибок).
