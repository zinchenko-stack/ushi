# Задача: Phase 2 — забандлить статический whisper-cli в ushi.app

Тебе передают macOS-приложение **ushi** на промежуточной стадии разработки. Ниже — полный контекст и пошаговая задача. Работай как обычно: прочитай нужные файлы, спланируй, спроси у пользователя если что-то критично неясно, делай.

---

## 1. Что такое ushi (1 минута чтения)

Личный macOS-рекордер для созвонов и лекций. SwiftUI, target macOS 14.6+, Apple Silicon.
- Пишет **системный звук + микрофон** через ScreenCaptureKit на одну дорожку
- Может писать видео экрана
- Локально транскрибирует записи через **whisper.cpp** (модель `ggml-large-v3-turbo`)
- Распространяется через **DMG без подписи Apple** (нет $99/год)
- Подробнее в `CLAUDE.md` и `INSTALL.md` в корне репозитория

---

## 2. Проблема которую решаешь

Сейчас `TranscriptionService.swift` зовёт бинарь `whisper-cli` из Homebrew (`/opt/homebrew/bin/whisper-cli`). На машине автора всё работает. **На машине друга, который скачал DMG, нет brew → нет whisper-cli → транскрипция не работает.**

Нужно: положить whisper-cli внутрь `ushi.app` так, чтобы он работал везде.

---

## 3. Что уже исследовано и отвергнуто (НЕ повторяй)

Был проведён эксперимент с **WhisperKit** (Swift package от argmaxinc) — отвергнут. Замеры на этой машине (Apple Silicon, macOS Tahoe 26.5.1):

| | Время на 3-мин запись | Качество |
|---|---|---|
| текущий whisper-cli (Metal/GPU через whisper.cpp) | **15 сек** | чистый |
| WhisperKit large-v3-v20240930_turbo (release) | **133 сек** | пропускал куски |

whisper.cpp уже использует Metal на Apple Silicon. WhisperKit оказался в ~9× медленнее. Поэтому **остаёмся на whisper.cpp**.

Осталось от эксперимента: папка `whisperkit-probe/` в корне репозитория. **Удали её в первом же коммите** — она больше не нужна.

---

## 4. Текущий вид TranscriptionService

Файл: `ushi/TranscriptionService.swift`. Кратко как он работает:

```swift
private static let binaryCandidates = [
    "/opt/homebrew/bin/whisper-cli",
    "/opt/homebrew/bin/whisper-cpp",
    "/usr/local/bin/whisper-cli",
    "/usr/local/bin/whisper-cpp",
]

static func transcribe(audioURL: URL, ...) async throws -> URL {
    guard let binary = resolveBinary() else { throw .binaryNotFound(...) }
    let model = modelURL()  // ~/.ushi/models/ggml-large-v3-turbo.bin
    // m4a → wav через afconvert
    // вызов whisper-cli с флагами -m -f -l -otxt -of --suppress-nst --vad --vad-model
}
```

Зависимости whisper-cli из brew (вывод `otool -L /opt/homebrew/bin/whisper-cli`):
- `@rpath/libwhisper.1.dylib`
- `/opt/homebrew/opt/ggml/lib/libggml.0.dylib`
- `/opt/homebrew/opt/ggml/lib/libggml-base.0.dylib`
- `/usr/lib/libc++.1.dylib` (системная)
- `/usr/lib/libSystem.B.dylib` (системная)

То есть **просто скопировать бинарь из brew нельзя** — он притянет dylib'ы, которых на чужой машине нет. Нужно собрать статически.

---

## 5. Главная задача — Phase 2

### Что должно получиться в итоге
1. Бинарь `whisper-cli`, собранный статически (никаких внешних dylib кроме системных), с поддержкой **Metal** (GPU) на Apple Silicon
2. Этот бинарь лежит в `ushi.app/Contents/Resources/whisper-cli` после сборки приложения через Xcode
3. `TranscriptionService` сначала ищет бинарь в bundle, потом — в brew (как fallback для dev)
4. После сборки и упаковки в DMG (через `./scripts/build-release-dmg.sh`) приложение работает на чистой машине без brew

### Шаги

#### Шаг 1. Удалить наследие WhisperKit эксперимента
```bash
rm -rf whisperkit-probe
```
Закоммить это отдельным коммитом «chore: remove whisperkit-probe (rejected)».

#### Шаг 2. Собрать статический whisper-cli

Создай папку `vendor/whisper.cpp/` под подмодуль / клон. Удобный путь:

```bash
mkdir -p vendor
cd vendor
git clone --depth 1 --branch v1.8.6 https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build \
  -DBUILD_SHARED_LIBS=OFF \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=ON \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="arm64" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.6
cmake --build build --config Release -j
```

**Важные флаги:**
- `BUILD_SHARED_LIBS=OFF` — статика
- `GGML_METAL=ON` + `GGML_METAL_EMBED_LIBRARY=ON` — Metal внутри бинаря, без внешнего `ggml-metal.metal` файла
- `CMAKE_OSX_ARCHITECTURES="arm64"` — только Apple Silicon (приложение всё равно ARM-only). Если решишь делать universal — `"arm64;x86_64"`
- `CMAKE_OSX_DEPLOYMENT_TARGET=14.6` — минимум согласно `Info.plist` приложения

После сборки бинарь должен лежать в `vendor/whisper.cpp/build/bin/whisper-cli`. **Проверь зависимости:**
```bash
otool -L vendor/whisper.cpp/build/bin/whisper-cli
```
Допустимо ТОЛЬКО `libc++.1.dylib` и `libSystem.B.dylib` (системные). Если есть `libggml*` или `libwhisper*` — статика не вышла, перебери флаги CMake.

**Размер ожидаемый:** ~5-10 МБ. Если 1-2 МБ — Metal не вошёл, проверь флаги.

Закоммить как `feat: vendored static whisper.cpp v1.8.6 build`. Сам бинарь **не коммить** (он строится из исходников), но добавь скрипт `scripts/build-whisper.sh` который воспроизводит сборку.

#### Шаг 3. Интегрировать в Xcode проект

Бинарь нужно положить в `ushi.app/Contents/Resources/whisper-cli` при каждой сборке.

Вариант A (рекомендую): **Copy Files Build Phase** в Xcode
1. Открой `ushi.xcodeproj` в Xcode
2. Target `ushi` → Build Phases → New Copy Files Phase
3. Destination: `Resources`
4. Перетащи туда `vendor/whisper.cpp/build/bin/whisper-cli`
5. Поставь галку «Copy only when installing» = OFF

Вариант B: **Run Script Build Phase** — копирует через `cp` команду. Менее декларативно, но проще автоматизировать.

После сборки проверь:
```bash
ls -la build/DerivedData/Build/Products/Release/ushi.app/Contents/Resources/whisper-cli
otool -L build/DerivedData/Build/Products/Release/ushi.app/Contents/Resources/whisper-cli
```

#### Шаг 4. Обновить TranscriptionService

В `ushi/TranscriptionService.swift` поправь `resolveBinary()`:

```swift
private static func resolveBinary() -> String? {
    // 1. Сначала bundle (production)
    if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil),
       FileManager.default.fileExists(atPath: bundled.path) {
        return bundled.path
    }
    // 2. Fallback на brew (dev на машине автора)
    return binaryCandidates.first { FileManager.default.fileExists(atPath: $0) }
}
```

Не меняй больше ничего в логике транскрипции. Поведение должно остаться идентичным.

#### Шаг 5. Подпись

В `scripts/build-release-dmg.sh` уже есть ad-hoc подпись `.app`:
```bash
codesign --force --deep --sign - "$APP_PATH"
```
Флаг `--deep` рекурсивно подпишет вложенные исполняемые файлы, включая `Resources/whisper-cli`. **Ничего менять не нужно**, просто убедись что после сборки:
```bash
codesign --verify --deep --strict /path/to/ushi.app
```
проходит без ошибок.

#### Шаг 6. Тест на текущей машине

1. Собери релиз через `./scripts/build-release-dmg.sh`
2. Скопируй полученный DMG в `/tmp/` (имитация чистой машины)
3. Смонтируй, перетащи `.app` в `/Applications`
4. Запусти, попробуй сделать новую запись или перетранскрибировать существующую
5. Проверь что в Console.app (или Xcode log) нет ошибок про missing binary

Чтобы убедиться что используется именно bundled бинарь, а не brew — временно переименуй `/opt/homebrew/bin/whisper-cli` в `whisper-cli.bak` и повтори тест. Транскрипция должна продолжать работать. После теста переименуй обратно.

#### Шаг 7. Финальная сверка

Сравни выход новой бандленной транскрипции с тем что давал brew whisper-cli на той же записи. Должно быть **идентично** — мы тот же `whisper-cli` бандлим, просто статически собранный.

Время: тоже идентично (~15 сек на 3-мин запись).

---

## 6. Где живут файлы

```
/Users/icemac/project/ushi/
├── ushi/                              ← Swift код
│   ├── TranscriptionService.swift     ← главный файл этой задачи
│   ├── AppSettings.swift
│   ├── Recording.swift
│   ├── RecordingsStore.swift
│   ├── RecordingView.swift
│   ├── RecordingDetailView.swift
│   ├── UpdateChecker.swift
│   └── TranscriptIndex.swift
├── ushi.xcodeproj/
├── assets/                            ← DMG фон (уже сделан, не трогай)
├── scripts/
│   └── build-release-dmg.sh           ← пайплайн сборки DMG (готов)
├── release/build/                     ← артефакты сборки
├── vendor/                            ← НОВОЕ: сюда положишь whisper.cpp клон
├── INSTALL.md
├── CLAUDE.md
└── prompts/codex-phase-2-whisper.md   ← этот файл
```

Модель и VAD при работе находятся в:
- `~/.ushi/models/ggml-large-v3-turbo.bin` (1.5 ГБ, **не бандль**)
- `~/.ushi/models/ggml-silero-v5.1.2.bin` (VAD, скачивается автоматически)

**Phase 3 будет про скачивание модели в окне первого запуска.** Эту задачу пока не трогай — только бандл бинаря.

---

## 7. Окружение

- macOS Tahoe 26.5.1, Apple Silicon (arm64)
- Xcode 26.5
- Homebrew установлен (для CMake, текущего whisper-cpp если нужно)
- CMake 3.30+ (поставится через `brew install cmake` если нет)
- Текущий рабочий каталог: `/Users/icemac/project/ushi/`

---

## 8. Чего НЕ делать

- ❌ Не мигрируй на WhisperKit — отвергнут
- ❌ Не бандль модель `ggml-large-v3-turbo.bin` (1.5 ГБ) в DMG. Модель скачивается отдельно в Phase 3
- ❌ Не трогай существующий пайплайн DMG (`scripts/build-release-dmg.sh`) кроме случая если нужно подпись подкорректировать
- ❌ Не меняй логику самой транскрипции в `TranscriptionService` (`runWhisper`, `convertToWav`, `cleanTranscript`)
- ❌ Не делай git push сам — только локальные коммиты. У автора нет remote ещё для релизов

---

## 9. Чек-лист готовности Phase 2

- [ ] Папка `whisperkit-probe/` удалена
- [ ] `vendor/whisper.cpp/` склонирован на тег v1.8.6
- [ ] `scripts/build-whisper.sh` есть и воспроизводит сборку с одной команды
- [ ] `otool -L` на собранном `whisper-cli` показывает только системные либы
- [ ] Размер бинаря ~5-10 МБ (Metal внутри)
- [ ] В Xcode проекте `whisper-cli` копируется в `Resources` через Build Phase
- [ ] `TranscriptionService.resolveBinary()` ищет в bundle сначала, потом в brew
- [ ] После сборки `.app` бинарь физически лежит в `Contents/Resources/whisper-cli`
- [ ] `codesign --verify --deep --strict` проходит без ошибок
- [ ] Тест с переименованным `/opt/homebrew/bin/whisper-cli.bak`: транскрипция работает
- [ ] Скорость и качество транскрипции не деградировали

---

## 10. После Phase 2 (для понимания целостной картины)

Когда Phase 2 закрыта — есть ещё две фазы (НЕ делай в этой задаче, просто для контекста):

**Phase 3.** Окно скачивания модели на первом запуске.
- Если `~/.ushi/models/ggml-large-v3-turbo.bin` отсутствует — показать onboarding-окно
- Скачивать с HuggingFace: `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin`
- Прогресс-бар, отмена, продолжение при reconnect
- Только после скачивания — перейти в основное окно приложения

**Phase 4.** Уборка.
- Обновить `INSTALL.md` — убрать упоминания brew
- Обновить `CLAUDE.md` про новую раскладку
- Возможно поправить error messages в `TranscriptionService.binaryNotFound`

---

## 11. Если застрял

Если что-то не получается на шаге сборки whisper.cpp или интеграции в Xcode — **остановись и спроси автора через короткое сообщение**, что именно не идёт, со ссылкой на конкретный лог. Не лепи костыли «лишь бы скомпилировалось».

Особенно стоит спросить если:
- CMake падает с непонятной ошибкой про Metal
- `otool -L` показывает лишние dylib и непонятно как от них избавиться
- Xcode не подхватывает скопированный бинарь после Build Phase

---

Удачи. Начни с Шага 1 (удаление `whisperkit-probe/`), это самый безопасный warm-up чтобы убедиться что доступ к репозиторию работает.
