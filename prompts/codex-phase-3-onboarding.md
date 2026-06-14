# Задача: Phase 3 — окно скачивания модели на первом запуске

Тебе передают macOS-приложение **ushi** после успешно завершённой Phase 2. Ниже — полный контекст и пошаговая задача.

---

## 1. Что такое ushi (1 минута чтения)

Личный macOS-рекордер для созвонов и лекций. SwiftUI, target macOS 14.6+, Apple Silicon.
- Системный звук + микрофон через ScreenCaptureKit
- Локально транскрибирует записи через **whisper.cpp** (модель `ggml-large-v3-turbo`, 1.5 ГБ)
- Распространяется через **DMG без подписи Apple**
- Подробнее в `CLAUDE.md` и `INSTALL.md`

---

## 2. Что уже сделано до тебя

**Phase 2** (коммиты `bc62b04`, `c08f19c`):
- Статический `whisper-cli` (3.1 МБ, ARM64, Metal embedded) собирается из vendored `whisper.cpp v1.8.6`
- Бинарь бандлится в `ushi.app/Contents/Resources/whisper-cli` через Copy Files Build Phase
- `TranscriptionService.resolveBinary()` сначала ищет в bundle, потом в brew (fallback для dev)
- Скрипт сборки: `scripts/build-whisper.sh`

**Что остаётся проблемой:** модель `ggml-large-v3-turbo.bin` (1.5 ГБ) **не бандлится** (слишком большая для DMG) и должна скачиваться при первом запуске. Сейчас если её нет — приложение упадёт с ошибкой `modelNotFound` при первой же попытке транскрипции. Это то что мы чиним.

---

## 3. Задача Phase 3 — окно скачивания модели на первом запуске

### Что должно получиться

1. При запуске приложения проверяется наличие файла `~/.ushi/models/ggml-large-v3-turbo.bin`
2. **Если файл есть** — приложение запускается как обычно (текущее поведение)
3. **Если файла нет** — вместо главного окна показывается **онбординг с прогресс-баром скачивания**
4. После успешного скачивания — переход в обычное окно приложения
5. Скачивание должно быть устойчивым к обрыву сети, поддерживать отмену, продолжать с того места где остановилось

### Где у текущего приложения вход

Файл `ushi/ushiApp.swift`:
```swift
@main
struct ushiApp: App {
    @State private var updateChecker = UpdateChecker()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 560)
                .environment(updateChecker)
        }
        ...
    }
}
```

Сюда нужно встроить ветвление между `OnboardingView` и `ContentView`.

---

## 4. Конкретные шаги

### Шаг 1. Создать `ushi/ModelManager.swift`

`@Observable` класс, который:
- Проверяет наличие модели
- Скачивает её с прогрессом
- Поддерживает отмену
- Сохраняет состояние (`.checking`, `.missing`, `.downloading(progress)`, `.ready`, `.failed(error)`)

URL модели: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`
Размер: ~1.5 ГБ (1 624 555 275 байт примерно — но не хардкодь, бери из `URLResponse.expectedContentLength` или из заголовка `Content-Length`)
Путь сохранения: тот же что использует `TranscriptionService.modelURL()` — посмотри как он формируется в `ushi/TranscriptionService.swift:38-41`

Примерная сигнатура:
```swift
import Foundation
import Observation

@Observable
final class ModelManager {
    enum State {
        case checking
        case missing
        case downloading(bytesDownloaded: Int64, bytesTotal: Int64, bytesPerSecond: Double)
        case ready
        case failed(String)
    }

    var state: State = .checking

    var modelURL: URL { TranscriptionService.modelURL() }

    func checkInstalled() { /* выставить state .missing или .ready */ }
    func startDownload() async { /* URLSession download task с прогрессом */ }
    func cancelDownload() { /* отменить task, удалить .partial */ }
}
```

**Технические требования:**
- Используй `URLSession.download(for:)` или `URLSessionDownloadTask` с делегатом для прогресса
- При обрыве — сохраняй `resumeData` через `cancelByProducingResumeData` и сохраняй на диск; на следующем старте проверь есть ли `.resumeData` в Application Support, и если да — `download(resumeFrom:)`
- Скачивай во временный путь, потом атомарно перемести в финальный (через `FileManager.moveItem`)
- Считай `bytesPerSecond` как скользящее среднее за последние 5 секунд
- При сетевой ошибке — пользователю показывай дружелюбное сообщение + кнопку «Повторить»

### Шаг 2. Сделать `TranscriptionService.modelURL()` публичной

Сейчас она `static func` — оставь так же, но убедись что она `public` или `internal` доступна из `ModelManager`. В том же таргете она автоматически internal — должно работать.

Также добавь helper:
```swift
extension TranscriptionService {
    static func isModelInstalled() -> Bool {
        FileManager.default.fileExists(atPath: modelURL().path)
    }
}
```

### Шаг 3. Создать `ushi/OnboardingView.swift`

SwiftUI view с:
- Большой иконкой приложения (используй `Image("AppIcon")` или просто `Image(systemName: "waveform")` пока)
- Заголовок: **«Подготовка Ushi»**
- Подзаголовок: **«Скачиваю модель распознавания речи»**
- `ProgressView` с `value` от 0 до 1
- Под прогрессом: `"567 МБ из 1.5 ГБ · 12 МБ/с · осталось ~80 секунд"`
- Кнопка «Отмена» (с `.alert` подтверждением — «Точно отменить? Без модели ushi не сможет транскрибировать»)
- При `.failed` — текст ошибки + кнопка «Повторить»

Дизайн: единый стиль с остальным приложением (см. `ushi/ContentView.swift`, `ushi/SettingsView.swift` для референса). Светлая/тёмная тема через native macOS, ничего экзотичного. Размер окна — чуть меньше основного, например 560×420.

Форматирование:
- Размеры → `ByteCountFormatter` с `.useMB`/`.useGB`
- Время → `DateComponentsFormatter` (`.brief` style)

### Шаг 4. Встроить ветвление в `ushiApp.swift`

```swift
@main
struct ushiApp: App {
    @State private var updateChecker = UpdateChecker()
    @State private var modelManager = ModelManager()

    var body: some Scene {
        WindowGroup {
            Group {
                switch modelManager.state {
                case .checking:
                    ProgressView()                      // короткое мигание
                case .missing, .downloading, .failed:
                    OnboardingView(manager: modelManager)
                        .frame(minWidth: 560, minHeight: 420)
                case .ready:
                    ContentView()
                        .frame(minWidth: 980, minHeight: 560)
                        .environment(updateChecker)
                }
            }
            .task { modelManager.checkInstalled() }
        }
        .windowResizability(.contentMinSize)
        .commands { /* существующие команды */ }
    }
}
```

Важно: при переходе из `.missing` → `.downloading` пользователь жмёт «Начать скачивание» (или скачивание стартует автоматически — выбор за тобой, рекомендую авто-старт с возможностью отмены). При завершении (`state == .ready`) окно само переключится на `ContentView`.

### Шаг 5. Обработка edge cases

1. **Прерванный download:** при следующем запуске приложения — если есть `resumeData`, продолжи. Если нет — начни с нуля.
2. **Нет интернета на момент старта:** покажи `.failed("Нет соединения с интернетом")` + кнопку «Повторить». При нажатии — снова попытка.
3. **Disk space check:** перед стартом проверь что доступно >2 ГБ свободного места. Если нет — `.failed("Недостаточно свободного места на диске")`.
4. **Уже скачано:** если `.bin` уже лежит — `state = .ready`, переход в основное приложение мгновенный.
5. **Существующий бракованный файл** (например 800 МБ из 1.5 ГБ, без `resumeData`): подумай о валидации. **Минимум:** сверка размера с `Content-Length`. **Хорошо бы:** sha256 хеш модели в HuggingFace (можно фиксированно в коде). Если решишь не валидировать через хеш — просто проверяй размер и оставляй как есть, валидация в Phase 4.

### Шаг 6. Тест на чистом сценарии

```bash
# 1. Удалить модель
rm -rf ~/.ushi/models/ggml-large-v3-turbo.bin

# 2. Запустить приложение из Xcode (Run)
# 3. Убедиться:
#    - Открывается онбординг, НЕ основное окно
#    - Стартует скачивание, прогресс растёт
#    - Скорость и ETA отображаются разумно
# 4. Через 30 секунд — нажать Cmd+Q (выйти)
# 5. Снова запустить
# 6. Убедиться: скачивание продолжается, не начинается заново
# 7. Дождаться окончания
# 8. Убедиться: приложение само переключается на основное окно
# 9. Сделать тестовую запись и транскрибировать → должно работать
```

Также протестируй:
- Запуск с уже скачанной моделью → онбординг **не показывается**, сразу основное окно
- Отмена скачивания → файл `.partial` удаляется, состояние `.missing`, кнопка «Скачать» снова доступна

---

## 5. Где живут файлы

```
/Users/icemac/project/ushi/
├── ushi/
│   ├── ushiApp.swift                  ← модифицируешь (ветвление)
│   ├── ContentView.swift              ← смотришь для контекста стиля
│   ├── SettingsView.swift             ← смотришь для контекста стиля
│   ├── TranscriptionService.swift     ← добавляешь isModelInstalled()
│   ├── ModelManager.swift             ← НОВЫЙ
│   ├── OnboardingView.swift           ← НОВЫЙ
│   └── ... (остальное не трогаешь)
├── ushi.xcodeproj/
└── prompts/codex-phase-3-onboarding.md ← этот файл
```

При создании новых `.swift` файлов — добавь их в Xcode target `ushi` (через Xcode UI или прямую правку `project.pbxproj`).

---

## 6. Окружение

- macOS Tahoe 26.5.1, Apple Silicon
- Xcode 26.5
- SwiftUI на macOS 14.6+ (поддерживаем `@Observable`, новые API)
- Текущий каталог: `/Users/icemac/project/ushi/`

---

## 7. Чего НЕ делать

- ❌ Не бандль модель в DMG (~1.5 ГБ — слишком много)
- ❌ Не меняй логику самой транскрипции в `TranscriptionService` (`runWhisper`, `convertToWav`, `cleanTranscript`)
- ❌ Не трогай `scripts/build-release-dmg.sh` и DMG-пайплайн
- ❌ Не делай git push
- ❌ Не добавляй сторонние зависимости через SPM (URLSession достаточно)
- ❌ Не трогай `vendor/whisper.cpp/`
- ❌ Не делай скачивание модели **внутри** `ContentView` — это должна быть отдельная фаза до основного UI

---

## 8. Чек-лист готовности Phase 3

- [ ] `ushi/ModelManager.swift` создан, имплементирует `@Observable` класс
- [ ] `ushi/OnboardingView.swift` создан, показывает прогресс/отмену/ошибку
- [ ] `ushi/ushiApp.swift` ветвит между `OnboardingView` и `ContentView` по состоянию модели
- [ ] `TranscriptionService.isModelInstalled()` добавлен
- [ ] Скачивание устойчиво к Cmd+Q посередине (`resumeData` сохраняется)
- [ ] Скачивание устойчиво к отсутствию интернета на старте
- [ ] Отмена работает корректно (`.partial` удаляется)
- [ ] Перед стартом проверяется свободное место на диске
- [ ] При повторном запуске с уже скачанной моделью — онбординг **не появляется**
- [ ] После успешного скачивания — автоматический переход в основное окно
- [ ] Стиль OnboardingView согласован с остальным приложением
- [ ] Все новые файлы добавлены в Xcode target

---

## 9. Phase 4 — финальная уборка (НЕ делай в этой задаче)

Когда Phase 3 закрыта:
- Обновить `INSTALL.md` — убрать упоминания brew, добавить про автоскачивание модели
- Обновить `CLAUDE.md` — отметить что whisper.cpp теперь бандлится, модель скачивается на первом запуске
- Возможно поправить error messages в `TranscriptionService.binaryNotFound`
- Подумать про валидацию модели через sha256 (если в Phase 3 решил отложить)

---

## 10. Если застрял

Остановись и спроси автора с конкретной проблемой:
- Если URLSession resumeData не работает на конкретных серверах HuggingFace
- Если sha256 модели нужен (см. https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo.bin для актуального — но не парси HTML, лучше спросить)
- Если SwiftUI ProgressView ведёт себя странно при стриминговом обновлении value

---

Начни с создания `ModelManager.swift` — это сердце задачи. Когда сделаешь — обернись `OnboardingView`. UI и интеграция в `ushiApp.swift` — последнее.

Удачи.
