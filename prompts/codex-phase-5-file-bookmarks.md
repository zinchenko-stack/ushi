# Задача: Phase 5 — bookmark-based идентификация файлов

Тебе передают macOS-приложение **ushi**. Эта фаза не блокирует основной релиз — её делаем после Phase 3 (онбординг) и Phase 4 (уборка). Но логически важная — чинит реальный баг с потерей связи между записями и файлами.

---

## 1. Что такое ushi (1 минута)

Личный macOS-рекордер для созвонов и лекций. SwiftUI, target macOS 14.6+. Пишет аудио (.m4a) или видео+аудио (.mov) через ScreenCaptureKit. Метаданные в `~/Library/Application Support/ushi/recordings.json`, медиа — в пользовательской папке (по умолчанию `~/Documents/ushi/`). Подробнее в `CLAUDE.md`.

---

## 2. Что чиним и почему

### Проблема
Запись в метаданных хранит файл по **имени + папка**:
```json
{
  "audioFileName": "2026-06-14_011254.mov",
  "storageFolderPath": "/Users/icemac/Documents/pet project",
  ...
}
```

Если пользователь:
- Переименовал файл в Finder вручную
- Переместил в подпапку
- Что-то пошло не так в логике встроенного переименования

…то приложение **не находит файл**, кнопки «Открыть видео» и «Повторить транскрибацию» молча не работают.

**Реальный кейс уже всплыл:** видео `2026-06-14_011254.mov` оказалось на диске под именем `2-Блок-6:GTM:Урок-2mov.mov` (переименование в Finder с косой чертой в названии). Кнопка «Открыть видео» ничего не делала, пока вручную не подправили метаданные.

### Решение
Перевести идентификацию файлов на **NSURL bookmark data** (нативный macOS API). Это сериализованный «штрих-код» файла, который содержит inode + volume UUID + fallback path. Когда мы хотим открыть файл:
1. Разрешаем bookmark → получаем актуальный URL даже если файл переименовали или переместили
2. Если bookmark «протух» (stale) — обновляем его на новый URL
3. Если bookmark не разрешается совсем (файл удалён или volume отсутствует) — fallback на старую логику (по filename+folder)
4. Если и это не сработало — показываем пользователю модалку «Файл не найден. Указать вручную?» с `NSOpenPanel`

Bookmarks выживают:
- Переименование файла
- Перемещение файла в пределах того же диска
- Переименование родительских папок

Bookmarks НЕ выживают:
- Удаление файла
- Перемещение на другой volume (внешний диск, сетевая шара) — частично, зависит от macOS версии
- Восстановление из Time Machine (новый inode)

В этих редких случаях падаем на fallback и потом на ручной выбор.

---

## 3. Где что трогать

```
/Users/icemac/project/ushi/
├── ushi/
│   ├── Recording.swift              ← модель — добавляешь поля bookmark
│   ├── RecordingsStore.swift        ← персистенс — создание/разрешение bookmark
│   ├── RecordingDetailView.swift    ← UI — обработка ошибки «файл не найден»
│   ├── TranscriptionService.swift   ← смотришь как файлы используются
│   └── AudioPlayerModel.swift       ← тут тоже играется аудио из URL
```

Также может затронуться `AudioRecorder.swift` (создание новой записи — сразу делать bookmark) и `HistoryView.swift` (список записей — там тоже могут открываться файлы).

---

## 4. Конкретные шаги

### Шаг 1. Расширить модель Recording

Добавь опциональные поля для bookmarks. Опциональные — чтобы старые записи (без bookmark) продолжали работать через fallback.

```swift
struct Recording: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var audioFileName: String           // оставляем для fallback и UI
    var transcriptFileName: String?
    var storageFolderPath: String       // оставляем для fallback
    var status: TranscriptionStatus
    var audioRemoved: Bool

    // НОВОЕ
    var audioBookmark: Data?
    var transcriptBookmark: Data?
}
```

При декодировании старых json — Codable сам подставит `nil` для отсутствующих полей. Migration пройдёт автоматически при первом резолве (см. Шаг 4).

### Шаг 2. Хелпер для bookmarks

Создай `ushi/FileBookmark.swift`:

```swift
import Foundation

enum FileBookmark {
    /// Создать bookmark из URL. Возвращает nil если файла нет или ошибка.
    static func create(from url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("⚠️ bookmark create failed for \(url.path): \(error)")
            return nil
        }
    }

    /// Разрешить bookmark в актуальный URL.
    /// Возвращает (url, isStale, updatedBookmark).
    /// Если bookmark stale — updatedBookmark содержит обновлённую версию которую надо сохранить.
    static func resolve(_ data: Data) -> (url: URL, isStale: Bool, updated: Data?)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let updated: Data? = isStale ? create(from: url) : nil
            return (url, isStale, updated)
        } catch {
            return nil
        }
    }
}
```

Замечания:
- Без `.withSecurityScope` — ushi не sandboxed (DMG-distribution)
- Без `.minimalBookmark` — нам нужна максимальная устойчивость
- Опционально: можно подмешать `.suitableForBookmarkFile`, но это для другого кейса

### Шаг 3. Создание bookmark при записи новой записи

Где-то в `AudioRecorder` или `RecordingsStore.create(...)` после того как файл записан на диск:

```swift
let audioURL = storageFolder.appendingPathComponent(audioFileName)
let bookmark = FileBookmark.create(from: audioURL)
let recording = Recording(
    ...,
    audioBookmark: bookmark
)
```

Аналогично при появлении транскрипта (`TranscriptionService.transcribe(...)` возвращает URL .txt — найди где он сохраняется в Recording и там создавай `transcriptBookmark`).

### Шаг 4. Разрешение URL — централизованный хелпер в Recording

Добавь в `Recording.swift`:

```swift
extension Recording {
    /// Получить актуальный URL аудио-файла.
    /// Возвращает URL если файл найден (через bookmark или fallback),
    /// либо nil если файл потерян.
    /// Если bookmark был stale или ещё не было bookmark — second tuple value содержит
    /// обновлённую версию которую store должен сохранить.
    func resolveAudioURL() -> (url: URL?, freshBookmark: Data?) {
        // 1. Попробовать bookmark
        if let bm = audioBookmark, let res = FileBookmark.resolve(bm) {
            return (res.url, res.updated)
        }
        // 2. Fallback: filename + storageFolderPath
        let fallback = URL(fileURLWithPath: storageFolderPath)
            .appendingPathComponent(audioFileName)
        if FileManager.default.fileExists(atPath: fallback.path) {
            // Создаём bookmark для будущих обращений (миграция старых записей)
            let bm = FileBookmark.create(from: fallback)
            return (fallback, bm)
        }
        return (nil, nil)
    }

    /// Аналогично для транскрипта.
    func resolveTranscriptURL(transcriptsDirectory: URL) -> (url: URL?, freshBookmark: Data?) {
        if let bm = transcriptBookmark, let res = FileBookmark.resolve(bm) {
            return (res.url, res.updated)
        }
        guard let name = transcriptFileName else { return (nil, nil) }
        let fallback = transcriptsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: fallback.path) {
            let bm = FileBookmark.create(from: fallback)
            return (fallback, bm)
        }
        return (nil, nil)
    }
}
```

### Шаг 5. Использовать резолвер во всех местах открытия файлов

Поищи в коде все места где собирается URL аудио/видео/транскрипта:
- `RecordingDetailView.openExternally(...)` (стр. ~101)
- `RecordingDetailView` — где грузится аудио плеер
- `RecordingsStore.canRetryTranscription(...)` и `retryTranscription(...)`
- `TranscriptionService.transcribe(audioURL: ...)` — вызывается со стороны Store, сюда передаём резолвленный URL
- `AudioPlayerModel` — если играет аудио из файла
- Везде где есть `storageDirectoryURL() + appendingPathComponent(audioFileName)` или похожий паттерн

В каждом таком месте:
```swift
let (resolved, freshBookmark) = recording.resolveAudioURL()
guard let url = resolved else {
    // показать ошибку или вернуть с error
    return
}
if let fresh = freshBookmark {
    store.updateBookmark(for: recording.id, audio: fresh)
}
// использовать url для операции
```

Добавь в `RecordingsStore` методы:
```swift
func updateAudioBookmark(for id: UUID, bookmark: Data)
func updateTranscriptBookmark(for id: UUID, bookmark: Data)
```
Они обновляют запись в массиве и сохраняют json.

### Шаг 6. UI обработка «файл не найден»

В `RecordingDetailView.openExternally`:

```swift
private func openExternally(_ rec: Recording) {
    let (resolved, fresh) = rec.resolveAudioURL()
    if let fresh { store.updateAudioBookmark(for: rec.id, bookmark: fresh) }
    if let url = resolved {
        NSWorkspace.shared.open(url)
        return
    }
    // Файл не найден — спрашиваем пользователя
    askUserToLocate(rec)
}

private func askUserToLocate(_ rec: Recording) {
    let alert = NSAlert()
    alert.messageText = "Файл не найден"
    alert.informativeText = "Похоже что «\(rec.title)» был перемещён или удалён. Указать вручную?"
    alert.addButton(withTitle: "Указать")
    alert.addButton(withTitle: "Отмена")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "Найдите файл «\(rec.audioFileName)»"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    // Сохраняем новый bookmark и обновляем filename
    if let bm = FileBookmark.create(from: url) {
        store.updateAudioBookmark(for: rec.id, bookmark: bm)
        store.updateAudioFileName(for: rec.id,
                                  fileName: url.lastPathComponent,
                                  folder: url.deletingLastPathComponent().path)
    }
    NSWorkspace.shared.open(url)
}
```

Аналогичную логику добавь для транскрипта (кнопка «Скопировать транскрипцию», «Повторить транскрибацию»).

### Шаг 7. Тесты руками

1. **Миграция старых записей.** Запусти app — открой существующую запись (без bookmark), нажми «Открыть видео». Должно открыться. После этого посмотри `recordings.json` — должен появиться `audioBookmark` (base64 строка).
2. **Переименование в Finder.** Переименуй файл в Finder. Открой ту же запись в ushi → «Открыть видео» → должно работать (через bookmark).
3. **Перемещение в подпапку.** В Finder создай подпапку, перетащи файл туда. Открой запись → должно работать.
4. **Удаление.** Удали файл в корзину. Открой запись → должна появиться модалка «Файл не найден» с кнопкой «Указать вручную». Восстанови файл и укажи через панель — должно подхватиться.
5. **Новая запись.** Сделай новую запись в ushi → проверь что в `recordings.json` сразу есть `audioBookmark`.

---

## 5. Чего НЕ делать

- ❌ Не удаляй поля `audioFileName` и `storageFolderPath` — они нужны как fallback и для отображения в UI
- ❌ Не делай security-scoped bookmarks (мы не sandboxed)
- ❌ Не пиши сложную систему «следящую» за изменениями (FSEvents и т.п.) — bookmark достаточно
- ❌ Не делай это для самой модели whisper (`~/.ushi/models/ggml-large-v3-turbo.bin`) — она в фиксированном месте, не для пользовательского управления
- ❌ Не ломай существующий `recordings.json` — миграция должна быть прозрачной (Codable + опциональные поля)

---

## 6. Чек-лист

- [ ] Поля `audioBookmark`, `transcriptBookmark` добавлены в `Recording`
- [ ] Создан `FileBookmark.swift` с create/resolve хелперами
- [ ] При новой записи сразу создаётся bookmark
- [ ] При появлении транскрипта создаётся transcript bookmark
- [ ] `Recording.resolveAudioURL()` и `.resolveTranscriptURL(...)` имплементированы
- [ ] Все места открытия файлов используют резолвер
- [ ] `RecordingsStore.updateAudioBookmark/updateTranscriptBookmark` есть
- [ ] При файл-не-найден показывается модалка с `NSOpenPanel`
- [ ] После ручного указания файла bookmark и filename обновляются и сохраняются
- [ ] Старые записи мигрируют прозрачно (создаётся bookmark при первом открытии)
- [ ] Все 5 ручных тестов проходят
- [ ] Никаких регрессий в существующем потоке (запись, транскрипция, плеер)

---

## 7. Окружение

- macOS Tahoe 26.5.1, Apple Silicon
- Xcode 26.5
- Текущая рабочая директория: `/Users/icemac/project/ushi/`
- Backup `recordings.json` уже есть: `~/Library/Application Support/ushi/recordings.json.backup` — на случай если миграция пойдёт не так

---

## 8. Если застрял

- Если bookmark резолвится но `FileManager.fileExists` возвращает false — возможно permission issue (попроси автора посмотреть)
- Если в `Recording.swift` Codable ломается на старых json — проверь что новые поля **optional** (`Data?`)
- Если NSOpenPanel не показывается — проверь что вызов идёт на main thread

---

Начни с Шага 1 (поля в `Recording`) и Шага 2 (`FileBookmark.swift`) — они независимы и безопасны. Дальше Шаг 4 (резолвер) и Шаг 5 (использование), потом UI fallback (Шаг 6).

Удачи.
