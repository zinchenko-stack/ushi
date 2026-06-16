# Phase 1 — Модель данных и Store

**Перед началом:** прочитай `docs/projects-brief.md`, особенно §4 (модель данных), §7.2 (поведение пресета), §8 (архитектура слоёв), §13 (GRDB зафиксирован).

## Что нужно сделать

Ввести в UshiNext модель `Project` и расширить `Recording` под новую схему. Всё на GRDB. Текущие записи мигрируют в orphan-сегмент (`projectId = nil`). UI ещё не трогаем — это Phase 2.

## Контекст

После Phase 0 у нас есть `ushi-next/` — дубль с независимым Application Support. Внутри уже есть рабочий `RecordingsStore` (на чём он сейчас — Codable+JSON, скорее всего, или просто массив в памяти; проверь). Задача: переехать на SQLite через GRDB и добавить таблицу проектов.

## Задачи

1. **Подключить GRDB.** Через SPM (`https://github.com/groue/GRDB.swift`). Версия 6.x или 7.x — текущая стабильная.
2. **Схема БД.** Создай `~/Library/Application Support/UshiNext/store.sqlite`. Таблицы:
   - `project` (id TEXT PK, name TEXT, icon TEXT?, color_hex TEXT?, storage_kind TEXT, bookmark_data BLOB?, display_path TEXT?, last_used_preset TEXT, is_pinned INTEGER, created_at REAL, updated_at REAL)
   - `recording` (id TEXT PK, project_id TEXT? FK→project.id ON DELETE SET NULL, title TEXT, file_url TEXT, file_size INTEGER, duration REAL, created_at REAL, preset_snapshot TEXT, has_microphone INTEGER, has_system_audio INTEGER, has_screen INTEGER, title_source TEXT, transcript_status TEXT)
   - `app_state` (key TEXT PK, value TEXT) — для `lastUsedPreset` глобально
3. **Миграции через GRDB.** Регистрируй миграцию `v1_initial`. На старте приложения запускай. Не использовать автомиграции через Codable.
4. **Swift-модели.** Создай файлы:
   - `Project.swift` — `struct Project: Codable, FetchableRecord, PersistableRecord, Identifiable`. Поля из §4 брифа.
   - `RecordingPreset.swift` — `enum String: micOnly | systemAndMic | screen`.
   - `ProjectStorage.swift` — `enum: managed | external(bookmark: Data, displayPath: String)`. Кодируй как JSON в `storage_kind` + два других поля; или денормализуй на 3 колонки (cleaner). Выбирай денормализацию.
   - Расширь `Recording.swift` — добавь `projectId: UUID?`, `presetSnapshot: RecordingPreset`, `hasMicrophone/SystemAudio/Screen: Bool`, `titleSource: TitleSource`, `transcriptStatus: TranscriptStatus`.
5. **Store-слой.** Создай `ProjectStore.swift` со словарём методов:
   - `allProjects() -> [Project]` (sorted: pinned first, then updatedAt desc)
   - `create(name: String, preset: RecordingPreset, storage: ProjectStorage) -> Project`
   - `rename(_ project: Project, to: String)`
   - `setPinned(_ project: Project, _ pinned: Bool)`
   - `updateLastUsedPreset(_ project: Project, _ preset: RecordingPreset)`
   - `delete(_ project: Project, deleteRecordings: Bool)` — при `false` записи остаются с `projectId = nil`
   - `recordings(in project: Project?, limit: Int? = nil) -> [Recording]` — `nil` означает «без проекта»
   - `move(recording: Recording, to project: Project?)`
   
   `RecordingsStore` адаптируй под новую схему: убрать JSON-хранилище, читать из GRDB. Сохраняй immutable snapshot пресета при создании записи.
6. **app.lastUsedPreset.** В `app_state` пара `("global_last_preset", "micOnly")`. Хелперы `AppState.lastUsedPreset` getter/setter — обновляются после каждой orphan-записи.
7. **Где физически живут файлы записей.**
   - Managed-Проекты: `~/Library/Application Support/UshiNext/Projects/{project_id}/recordings/` (создаются по факту первой записи в проект).
   - Orphan-Записи (без Проекта): `~/Library/Application Support/UshiNext/Recordings/`.
   - Всё managed строго в Application Support. Не используем `~/Documents/UshiNext/` (это legacy-путь из Phase 0, унаследованный от старого Ushi через `AppContainer.name`) — после Phase 1 он не нужен. Если за время Phase 0 туда что-то записалось — это будет учтено в Phase 6 при миграции, сейчас не трогать.
   - `AppSettings.legacyDefaultRecordingsDirectory()` (или аналог) — либо удалить, либо переориентировать на новый путь в Application Support. Решай по месту.
8. **Миграция текущих записей.** Если в `~/Library/Application Support/UshiNext/` есть данные из старого Ushi (могут не быть — это новая папка) — не трогай. Перенос из старого Ushi — отдельная задача Phase 6.
9. **Юнит-тесты.** Для `ProjectStore` минимум:
   - create → читается обратно
   - rename → обновляется
   - delete с `deleteRecordings: false` → записи остаются с `projectId = nil`
   - delete с `deleteRecordings: true` → записи удаляются из БД (файлы не трогать в тестах)
   - move(recording, to: nil) → переходит в orphan
   - updateLastUsedPreset → читается обратно

## Готово когда

- GRDB подключён, схема создаётся при первом запуске.
- Все методы `ProjectStore` написаны и покрыты тестами.
- `RecordingsStore` работает с новой схемой: можно создать запись, сохранить, прочитать список.
- Существующие фичи Ushi (старт записи через текущий UI, остановка, сохранение) — работают, никаких регрессий.
- Никакого нового UI не появилось — только модель и Store.

## Не делай

- Не пиши SidebarView и любой UI для проектов — это Phase 2.
- Не пиши NSOpenPanel и bookmark-логику — это Phase 3. Сейчас `ProjectStorage` может быть только `.managed`, но enum должен поддерживать `.external` для будущей фазы.
- Не делай миграцию данных из старого Ushi — Phase 6.
- Не пиши авто-имя через whisper — Phase 4. Сейчас `titleSource = .fallback`, `title = "{дата время}"` достаточно.

## Отчёт

Перечисли: какие файлы создал/изменил, схему БД, список методов Store с сигнатурами, какие тесты прошли.
