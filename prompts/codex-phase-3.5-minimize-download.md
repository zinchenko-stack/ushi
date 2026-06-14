# Задача: Phase 3.5 — «Свернуть и пользоваться» во время скачивания модели

Тебе передают macOS-приложение **ushi** после успешно завершённых Phase 2 (бандл whisper-cli) и Phase 3 (онбординг скачивания модели, коммит `1e117e1`). Эта задача — UX-улучшение Phase 3: дать пользователю возможность не ждать пока скачается модель, а пользоваться приложением (записывать) уже сейчас.

---

## 1. Что такое ushi (краткая выжимка)

Личный macOS-рекордер. SwiftUI, target macOS 14.6+. Пишет системный звук + микрофон через ScreenCaptureKit, транскрибирует через бандленный `whisper-cli` (Phase 2). Модель `ggml-large-v3-turbo.bin` (1.5 ГБ) скачивается на первом запуске через onboarding-окно (Phase 3). Подробнее в `CLAUDE.md`.

---

## 2. Текущее поведение (что есть)

`ushiApp.swift` сейчас ветвит:
```
state == .checking          → ProgressView (короткое мигание)
state == .missing/.downloading/.failed → OnboardingView (модальное окно, пользователь жёстко заперт)
state == .ready             → ContentView (основное приложение)
```

То есть пока модель не скачается (10-15 минут на нормальном интернете), **пользователь не может ни записывать, ни просматривать историю**. Это плохо: запись не нужна модель, можно было бы уже работать.

---

## 3. Что нужно сделать

### Новое поведение

Пользователь видит OnboardingView, **на нём есть новая кнопка «Свернуть в фон»** (или похожая по смыслу, ты сам подберёшь точный текст). При нажатии:

1. OnboardingView закрывается
2. Открывается основной `ContentView` с **компактной плашкой сверху**: "Загружаю модель распознавания · 67% · ~5 минут"
3. Пользователь **может записывать** новые встречи — это не зависит от модели
4. Кнопки **«Транскрибировать» / «Повторить транскрибацию»** показываются как `.disabled` с тултипом «Доступно после загрузки модели»
5. Когда модель докачается:
   - Плашка плавно исчезает
   - Кнопки транскрипции активируются
   - Все записи которые были сделаны во время скачивания и ждут транскрипцию — автоматически встают в очередь на обработку

### Что ещё важно

- Если пользователь **закрыл и снова открыл приложение** во время скачивания: онбординг **не показывается заново** если он уже один раз свернул его. Просто открывается ContentView с плашкой (скачивание продолжается через resumeData из Phase 3).
- Если у пользователя **уже была модель скачана** до того как он первый раз запустил — ничего этого вообще не показывается, всё как до Phase 3 (статус `.ready` мгновенно).
- Если скачивание **упало** — пользователь видит ошибку в плашке (вместо процента), при клике на плашку открывается онбординг где можно нажать «Повторить».

---

## 4. Что трогать

```
ushi/
├── ushiApp.swift          ← новая ветвь UI: ContentView+баннер при downloading-when-minimized
├── OnboardingView.swift   ← добавить кнопку «Свернуть в фон»
├── ContentView.swift      ← добавить компонент DownloadBanner сверху, conditionally
├── ModelManager.swift     ← возможно добавить флаг userDismissedOnboarding (UserDefaults)
├── RecordingDetailView.swift ← .disabled на кнопках транскрипции, тултип
└── RecordingsStore.swift  ← наблюдать ModelManager, при .ready автоматически запускать pending транскрипции
```

ВАЖНО: перед началом работы **прочитай реальный код этих файлов**, особенно `ushi/ModelManager.swift` и `ushi/OnboardingView.swift` — Codex в Phase 3 уже выбрал конкретные имена методов и состояний, твоя задача интегрироваться с ними, а не переписывать.

---

## 5. Пошагово

### Шаг 1. Добавить флаг «пользователь уже один раз свернул онбординг»

В `ModelManager.swift` (или в отдельном `OnboardingPreferences.swift`):
```swift
extension ModelManager {
    var userDismissedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "ushi.onboarding.dismissed") }
        set { UserDefaults.standard.set(newValue, forKey: "ushi.onboarding.dismissed") }
    }
}
```

Эту переменную обнуляем когда модель становится `.ready` (флаг больше не нужен).

### Шаг 2. Кнопка на OnboardingView

Под прогресс-баром (только при `state == .downloading`) добавить кнопку:
```
"Свернуть и пользоваться сейчас"   (вторичный стиль, не основной)
```
При нажатии: `modelManager.userDismissedOnboarding = true` — состояние ModelManager не меняется (скачивание продолжается), просто флаг.

При `state == .missing` или `.failed` — кнопку не показывать (там скачивание не запущено, нет смысла сворачивать).

### Шаг 3. Обновить ветвление в `ushiApp.swift`

```swift
var body: some Scene {
    WindowGroup {
        Group {
            switch modelManager.state {
            case .checking:
                ProgressView()
            case .ready:
                ContentView()
                    .environment(updateChecker)
                    .environment(modelManager)
            case .missing, .failed:
                OnboardingView(manager: modelManager)
            case .downloading:
                if modelManager.userDismissedOnboarding {
                    ContentView()
                        .environment(updateChecker)
                        .environment(modelManager)
                } else {
                    OnboardingView(manager: modelManager)
                }
            }
        }
        .task { modelManager.checkInstalled() }
    }
}
```

Окно меняется автоматически когда `state` или `userDismissedOnboarding` обновляются.

### Шаг 4. DownloadBanner внутри ContentView

Добавить компонент сверху ContentView. Показывается только когда `modelManager.state` — это `.downloading` или `.failed` (после dismissed).

```swift
struct DownloadBanner: View {
    @Environment(ModelManager.self) var manager
    var body: some View {
        if case .downloading(let bytesDone, let bytesTotal, let bps) = manager.state {
            HStack {
                ProgressView(value: Double(bytesDone), total: Double(bytesTotal))
                    .frame(width: 120)
                Text("Загружаю модель распознавания · \(percent(bytesDone, bytesTotal)) · \(eta(bytesDone, bytesTotal, bps))")
                    .font(.caption)
                Spacer()
                Button("Подробнее") {
                    manager.userDismissedOnboarding = false  // вернёт к OnboardingView
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        } else if case .failed(let err) = manager.state {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Ошибка загрузки модели: \(err)")
                    .font(.caption)
                Spacer()
                Button("Повторить") {
                    Task { await manager.startDownload() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }
}
```

Имена методов (`startDownload`, состояния) — **сверь с реальным кодом Codex Phase 3**.

Подключи в ContentView:
```swift
VStack(spacing: 0) {
    DownloadBanner()
    // существующая разметка ContentView
}
```

### Шаг 5. Disabled-состояние транскрипции

В `RecordingDetailView.swift` (и других местах где есть кнопки транскрипции) добавь модификатор:
```swift
.disabled(modelManager.state != .ready)
.help(modelManager.state != .ready ? "Доступно после загрузки модели" : "")
```

Подсказку покажет macOS на hover автоматически.

Найти все места: `grep -n "Повторить транскрибацию\|Транскрибировать" ushi/*.swift`.

### Шаг 6. Авто-транскрипция накопленной очереди

В `RecordingsStore.swift` подписаться на изменение `ModelManager.state`. Когда становится `.ready`:
- Пройтись по всем записям где `status == .pending` или `.failed` (с подходящей причиной)
- Запустить транскрипцию для каждой по очереди (не параллельно — whisper-cli тяжёлый)

Псевдокод:
```swift
@Observable
final class RecordingsStore {
    init(modelManager: ModelManager) {
        observeModelReady(modelManager)
    }

    private func observeModelReady(_ mm: ModelManager) {
        // SwiftUI Observation — можно использовать withObservationTracking
        // или просто проверять при каждом запросе.
        // Самое простое: добавить публичный метод processPendingTranscriptions()
        // и вызывать его из ushiApp когда state переходит в .ready.
    }

    func processPendingTranscriptions() async {
        let pending = recordings.filter { $0.status == .pending }
        for rec in pending {
            try? await transcribe(rec)
        }
    }
}
```

В `ushiApp.swift` в `.onChange(of: modelManager.state)`:
```swift
.onChange(of: modelManager.state) { _, new in
    if case .ready = new {
        Task { await recordingsStore.processPendingTranscriptions() }
    }
}
```

### Шаг 7. Записи во время скачивания не должны падать

При новой записи если модель ещё не готова — НЕ пытайся транскрибировать. Просто сохрани запись со статусом `.pending` (или эквивалент в твоей модели Recording). Авто-обработается на Шаге 6 когда модель появится.

Найди код где после остановки записи запускается транскрипция (вероятно в `RecordingsStore` или `AudioRecorder`). Добавь там guard:
```swift
guard modelManager.state == .ready else {
    // mark as pending, return
    return
}
// existing transcription start
```

---

## 6. Чек-лист

- [ ] Кнопка «Свернуть и пользоваться сейчас» есть в OnboardingView (только при .downloading)
- [ ] `userDismissedOnboarding` хранится в UserDefaults и сбрасывается при .ready
- [ ] `ushiApp.swift` ветвится с учётом нового флага
- [ ] `DownloadBanner` показывается в ContentView при .downloading или .failed (если был dismissed)
- [ ] Клик «Подробнее» в баннере возвращает OnboardingView
- [ ] При .failed в баннере есть кнопка «Повторить»
- [ ] Кнопки транскрипции `.disabled` пока state != .ready, с подсказкой
- [ ] Новая запись во время скачивания не падает, сохраняется как pending
- [ ] При state → .ready, pending записи автоматически встают в очередь на транскрипцию
- [ ] Если модель уже скачана при старте — никаких баннеров и онбординга
- [ ] Cmd+Q во время скачивания: при следующем старте всё восстанавливается (Phase 3 уже это умеет)

---

## 7. Тесты руками

1. **Свежий старт без модели.** `rm -rf ~/.ushi/models/ggml-large-v3-turbo.bin` → запусти. Открывается онбординг → стартует скачивание → жмёшь «Свернуть» → попадаешь в ContentView с баннером → делаешь запись → останавливаешь → запись в истории со статусом «ждёт модели». Дожидаешься скачивания → баннер исчезает → запись начинает транскрибироваться сама.

2. **Повторный запуск.** В разгар скачивания нажми Cmd+Q. Снова открой ushi. Должен открыться ContentView с баннером (не онбординг — флаг dismissed сохранён). Скачивание продолжается.

3. **Возврат к онбордингу.** В баннере нажми «Подробнее» → открывается OnboardingView с прогрессом. Снова нажми «Свернуть» → возвращаешься в ContentView.

4. **Уже скачано.** `~/.ushi/models/ggml-large-v3-turbo.bin` есть. Запусти → должно сразу открыться ContentView без всяких баннеров и онбординга.

5. **Ошибка во время скачивания (свёрнуто).** Отключи Wi-Fi во время скачивания после dismiss. Баннер должен сменить состояние на «Ошибка загрузки» + кнопку «Повторить». Включи Wi-Fi обратно, жми «Повторить» → продолжается.

---

## 8. Чего НЕ делать

- ❌ Не убирай OnboardingView совсем — он остаётся как первое окно для тех кто не свернул
- ❌ Не запускай транскрипцию параллельно с активным скачиванием (whisper-cli + 1.5 ГБ модели может быть болезненно)
- ❌ Не делай background-thread transcription без проверки `state == .ready` — может выпасть на полпути если что-то пойдёт не так
- ❌ Не плодай новых сторонних зависимостей
- ❌ Не трогай `vendor/whisper.cpp/`, `scripts/build-*`, `assets/`, DMG-пайплайн

---

## 9. Окружение

- macOS Tahoe 26.5.1, Apple Silicon
- Xcode 26.5
- Текущая директория: `/Users/icemac/project/ushi/`

---

## 10. Если застрял

- Если `withObservationTracking` ведёт себя странно — упрости через `.onChange(of: modelManager.state)` в ushiApp.swift
- Если RecordingsStore не имеет ссылки на ModelManager — пробрось его через инициализатор или `@Environment`
- Если SwiftUI не перерисовывает ContentView когда меняется `userDismissedOnboarding` — убедись что флаг отслеживается через `@Observable` (а не просто UserDefaults — нужна обёртка которая дёргает обновление)

---

Начни с Шага 2 (кнопка в OnboardingView) и Шага 3 (ветвление в ushiApp) — это самые маленькие изменения с быстрым видимым эффектом. Шаг 4 (баннер) — следующим. Шаги 5-7 — после.

Удачи.
