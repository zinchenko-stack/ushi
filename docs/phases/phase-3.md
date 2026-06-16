# Phase 3 — External-папки и FileMover

**Перед началом:** прочитай `docs/projects-brief.md`, особенно §5 (физический слой), §7.4 (Move to), §7.6 (degraded state), §10 Phase 3 (без sandbox).

## Что нужно сделать

Разрешить создание Проектов с привязкой к произвольной папке на диске (Documents, Desktop, любое место). Сделать робастный FileMover для переноса записей между Проектами на разных томах. Обработать degraded state, когда внешняя папка пропала.

## Контекст

После Phase 2 все Проекты — `.managed`. Bookmark-инфра уже есть в `ushi-next` (из Phase 5 текущего Ushi, файл должен называться примерно `BookmarkResolver.swift` или похожее — найди в коде через grep по `URLBookmarkResolutionWithSecurityScope` или `bookmarkData`). Переиспользуй её.

Приложение **не sandboxed** — можно работать с произвольными путями без entitlement-танцев. Bookmarks всё равно используем: переживают переименование и перемещение папки.

## Задачи

1. **Создание Проекта с external-папкой.** В модалке создания (§6.5 брифа) активируй радио «Использовать существующую папку».
   - При выборе — открывается `NSOpenPanel(canChooseDirectories: true, canChooseFiles: false)`.
   - Имя Проекта по умолчанию = `url.lastPathComponent`, юзер может изменить.
   - Создаётся `Project` с `storage = .external(bookmark: bookmarkData, displayPath: url.path)`.
   - Если внутри нет подпапки `recordings/` — создать.
2. **BookmarkResolver для Проектов.** Используй существующий или экстракти из текущего кода. На каждом запуске приложения резолвь bookmarks всех external-Проектов. Логика:
   - Резолв успешный, путь не изменился → `displayPath` без изменений.
   - Резолв успешный, путь изменился (папку переименовали/перенесли) → обновить `displayPath` в БД.
   - Резолв failed (папка удалена, диск отключён, доступ потерян) → пометить Проект как `degraded`. Не падать.
3. **Degraded state в sidebar.** Проект в `degraded` показывается:
   - С иконкой ⚠ слева от имени.
   - Имя приглушённым цветом.
   - Кнопка ⏺ disabled.
   - Контекстное меню: добавь пункт «Подключить заново…» — открывает NSOpenPanel, новая папка заменяет bookmark.
4. **FileMover — отдельный сервис.** `FileMover.swift`. Методы:
   - `move(_ recording: Recording, to project: Project?) async throws` — основной API.
   - Внутри:
     - Резолвь source URL (если Recording был в external — startAccessingSecurityScopedResource).
     - Резолвь destination URL (аналогично).
     - Если оба на одном томе (`FileManager.attributesOfItem` → `systemNumber` совпадает) → `moveItem`, мгновенно.
     - Если разные тома → `copyItem` с прогрессом, после успешной копии — удалить оригинал. Прогресс через `Progress` или callback.
     - При ошибке — НЕ удалять оригинал. Запись остаётся на месте, throw наверх.
   - stopAccessing в `defer`.
5. **UI прогресса при cross-volume move.** Если предполагается копирование (> 50 МБ или другой том) — показать sheet с progress bar и кнопкой Cancel. При Cancel — прервать копирование, удалить частичную копию, оригинал не трогать.
6. **Запись в external-Проект.** Когда стартует запись в external-Проект — пишем сразу в `{externalPath}/recordings/` (через security-scoped доступ). Если в момент старта bookmark stale → показать алерт «Папка проекта недоступна», предложить «Подключить заново».
7. **Edge cases для тестов:**
   - Создать external-Проект, удалить папку в Finder, перезапустить → degraded state в sidebar.
   - Переименовать external-папку в Finder, перезапустить → bookmark резолвится, displayPath обновляется.
   - Move запись с managed на external (другой том) → копирование с прогрессом.
   - Move с external на external (тот же том) → мгновенно.
   - Cancel при копировании → оригинал на месте, частичная копия удалена.

## Готово когда

- При создании Проекта работает «Использовать существующую папку».
- Папку можно потерять (удалить, переименовать) — приложение не падает, показывает degraded.
- «Подключить заново» восстанавливает Проект.
- Move работает между всеми комбинациями managed/external/orphan на одном и разных томах.
- При cross-volume copy показывается прогресс, можно отменить.
- Юнит-тесты FileMover (минимум: same-volume move, cross-volume copy, error rollback).

## Не делай

- Не добавляй UI выбора пути для managed-Проектов — managed всегда в `Application Support/UshiNext/Projects/{id}/`, юзер путь не видит и не выбирает.
- Не делай авто-имя — Phase 4.
- Не трогай menu bar — Phase 5.
- Не делай sync/iCloud-фичи — это не в роадмапе.

## Отчёт

Какие edge cases протестированы вручную, какие через юниты. Лог одного cross-volume переноса с прогрессом.
