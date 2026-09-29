//
//  RecordingsStore.swift
//  ushi
//

import Foundation
import GRDB
import Observation

@MainActor
@Observable
final class RecordingsStore {
    @ObservationIgnored private let dbQueue: DatabaseQueue
    @ObservationIgnored private let fileCoordinator = RecordingFileCoordinator()
    var recordings: [Recording] = [] {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isProcessingPending = false

    init(dbQueue: DatabaseQueue = AppDatabase.shared) {
        self.dbQueue = dbQueue
        load()
        recoverStuckRecordings()
        cleanupOrphanedSummaries()
        migrateTranscriptsToServiceFolder()
        sweepStrayTranscriptsFromMediaFolders()
        purgeOldSourceMedia()
    }

    // MARK: - Mutations

    func delete(_ recording: Recording) {
        fileCoordinator.deleteFiles(for: recording)
        recordings.removeAll { $0.id == recording.id }
    }

    func rename(_ recording: Recording, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recordings[idx].title = trimmed
        recordings[idx].titleSource = .manual
        renameFilesOnDisk(at: idx)
    }

    // MARK: - Проекты (Phase 2)
    //
    // Все мутации записей идут через этот стор, а не через ProjectStore:
    // `recordings` — кэш, который целиком upsert-ится в БД. Если поменять
    // project_id в обход кэша, следующий save() откатит изменение обратно.

    /// Записи Проекта (или orphan-Записи при `projectID == nil`), новые сверху.
    func recordings(inProject projectID: UUID?) -> [Recording] {
        recordings.filter { $0.projectId == projectID }
    }

    /// Можно ли сейчас переносить запись: пока whisper читает файл, не трогаем его.
    func canMove(_ recording: Recording) -> Bool {
        recording.status != .transcribing
    }

    /// Move to (§7.4 брифа): файл физически переезжает в папку целевого Проекта,
    /// затем меняется projectId. Если файл не удалось перенести — запись остаётся
    /// в исходном Проекте, ошибка пробрасывается в UI.
    func move(_ recording: Recording, to project: Project?) throws {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        let current = recordings[idx]
        guard current.projectId != project?.id else { return }
        guard canMove(current) else { throw RecordingsStoreError.busyTranscribing }

        let targetDir = try AppSettings.recordingsDirectory(for: project)
        let result = try fileCoordinator.moveMedia(of: current, to: targetDir)

        var rec = current
        rec.projectId = project?.id
        rec.audioFileName = result.audioFileName
        rec.storageFolderPath = result.storageFolderPath
        rec.audioBookmark = result.audioBookmark ?? rec.audioBookmark
        recordings[idx] = rec

        if let project {
            // Проект «всплывает» в sidebar по recency (§6.2).
            try? dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE project SET updated_at = ? WHERE id = ?",
                    arguments: [Date(), project.id.uuidString]
                )
            }
        }
    }

    /// Готовит удаление Проекта (§6.8): либо удаляет его записи вместе с файлами,
    /// либо переносит их в «Записи» (orphan) — и файлы тоже, потому что папка
    /// Проекта будет удалена. Сразу пишет в БД, чтобы ON DELETE у project
    /// не разошёлся с кэшем.
    func detachRecordings(fromProject projectID: UUID, deleteFiles: Bool) {
        for rec in recordings(inProject: projectID) {
            if deleteFiles {
                delete(rec)
            } else {
                do {
                    try move(rec, to: nil)
                } catch {
                    // Файл не переехал (например, идёт транскрипция) — всё равно
                    // отвязываем от Проекта; bookmark найдёт файл, если он остался.
                    update(id: rec.id) { $0.projectId = nil }
                    print("⚠️ move to orphan failed: \(error.localizedDescription)")
                }
            }
        }
        saveNow()
    }

    /// Суммарный размер медиа Проекта в байтах — для диалога удаления.
    func mediaSize(ofProject projectID: UUID) -> Int64 {
        recordings(inProject: projectID).reduce(0) { sum, rec in
            guard !rec.audioRemoved else { return sum }
            if rec.fileSize > 0 { return sum + rec.fileSize }
            guard let (url, _) = rec.resolveAudioURL(),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return sum }
            return sum + Int64(size)
        }
    }

    /// Файл записи на диске (для «Показать в Finder»). nil — файла нет.
    func mediaURL(for recording: Recording) -> URL? {
        guard !recording.audioRemoved else { return nil }
        return recording.resolveAudioURL()?.url
    }

    /// Сбросить отложенное сохранение и записать кэш в БД прямо сейчас.
    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        save()
    }

    /// Подгоняет имена файлов (.m4a / .mov / .txt) под текущий title.
    /// Безопасно: пока транскрибация в процессе — не трогаем (whisper-cli ещё пишет в старый путь).
    private func renameFilesOnDisk(at idx: Int) {
        var rec = recordings[idx]

        // Транскрибация в процессе — пропускаем, иначе сломаем whisper.
        if rec.status == .transcribing || rec.status == .pending { return }

        let mediaDir = mediaDirectory(for: rec)
        let result = fileCoordinator.renameFilesOnDisk(
            recording: rec,
            newTitle: rec.title,
            mediaDir: mediaDir
        )

        rec.audioFileName = result.audioFileName
        rec.audioBookmark = result.audioBookmark
        rec.transcriptFileName = result.transcriptFileName
        rec.transcriptBookmark = result.transcriptBookmark

        recordings[idx] = rec
    }

    @discardableResult
    func addRecording(
        audioURL: URL,
        duration: TimeInterval,
        project: Project? = nil,
        preset: RecordingPreset? = nil
    ) -> Recording {
        let canTranscribe = ModelManager.shared.isReady
        let resolvedPreset = preset
            ?? project?.lastUsedPreset
            ?? AppState.lastUsedPreset()
        let fileSize: Int64 = {
            let v = try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size]
            return (v as? Int64) ?? Int64((v as? Int) ?? 0)
        }()

        let rec = Recording(
            title: "Запись от " + Self.shortDateString(Date()),
            duration: duration,
            audioFileName: audioURL.lastPathComponent,
            storageFolderPath: audioURL.deletingLastPathComponent().path,
            status: canTranscribe ? .transcribing : .pending,
            audioBookmark: FileBookmark.create(from: audioURL),
            projectId: project?.id,
            presetSnapshot: resolvedPreset,
            hasMicrophone: resolvedPreset.hasMicrophone,
            hasSystemAudio: resolvedPreset.hasSystemAudio,
            hasScreen: resolvedPreset.hasScreen,
            titleSource: .fallback,
            fileSize: fileSize
        )
        recordings.insert(rec, at: 0)

        // Sticky-пресет: обновляем тот контекст, в который пошла запись (§7.2 брифа).
        if let project {
            try? dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE project SET last_used_preset = ?, updated_at = ? WHERE id = ?",
                    arguments: [resolvedPreset.rawValue, Date(), project.id.uuidString]
                )
            }
        } else {
            AppState.setLastUsedPreset(resolvedPreset)
        }

        if canTranscribe {
            let recordingID = rec.id
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.runTranscription(id: recordingID, audioURL: audioURL)
            }
        }
        return rec
    }

    /// Может ли запись быть перетранскрибирована (аудио ещё на диске).
    /// Проверка через bookmark-резолвер, т.к. файл мог быть переименован/перемещён.
    func canRetryTranscription(_ recording: Recording) -> Bool {
        guard !recording.audioRemoved,
              !recording.audioFileName.isEmpty else { return false }
        return recording.resolveAudioURL() != nil
    }

    /// Перезапуск транскрипции (для failed или явного "перетранскрибировать").
    func retryTranscription(_ recording: Recording) {
        guard let (audioURL, fresh) = recording.resolveAudioURL() else { return }
        if let fresh { setAudioBookmark(for: recording.id, fresh) }

        if let (oldTxt, _) = recording.resolveTranscriptURL() {
            try? FileManager.default.removeItem(at: oldTxt)
        }
        update(id: recording.id) {
            $0.transcriptFileName = nil
            $0.transcriptBookmark = nil
            $0.status = ModelManager.shared.isReady ? .transcribing : .pending
        }

        guard ModelManager.shared.isReady else { return }

        let recordingID = recording.id
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTranscription(id: recordingID, audioURL: audioURL)
        }
    }

    // MARK: - Bookmark helpers (public)

    /// Обновить аудио-bookmark для записи (например, после ручного выбора через NSOpenPanel).
    func setAudioBookmark(for id: UUID, _ bookmark: Data) {
        update(id: id) { $0.audioBookmark = bookmark }
    }

    /// Обновить transcript-bookmark для записи.
    func setTranscriptBookmark(for id: UUID, _ bookmark: Data) {
        update(id: id) { $0.transcriptBookmark = bookmark }
    }

    /// Полное обновление расположения аудио-файла: bookmark + filename + folder.
    /// Зовём из UI после того как пользователь указал файл через NSOpenPanel.
    func relocateAudio(for id: UUID, to url: URL) {
        let bookmark = FileBookmark.create(from: url)
        update(id: id) {
            $0.audioFileName = url.lastPathComponent
            $0.storageFolderPath = url.deletingLastPathComponent().path
            $0.audioBookmark = bookmark
        }
    }

    // MARK: - Recovery

    /// Зависшие в transcribing после краша — переводим в failed.
    /// pending остаются в очереди: они могли ждать загрузки модели.
    private func recoverStuckRecordings() {
        for idx in recordings.indices {
            if recordings[idx].status == .transcribing {
                recordings[idx].status = .failed
            }
        }
    }

    /// Удаляет исходный медиафайл у старых записей. Транскрипт оставляем.
    /// Помечает `audioRemoved = true`, чтобы UI скрыл плеер / кнопку открытия.
    private func purgeOldSourceMedia() {
        let fm = FileManager.default

        for idx in recordings.indices {
            var rec = recordings[idx]
            guard !rec.audioRemoved,
                  !rec.audioFileName.isEmpty else { continue }

            let isVideo = rec.audioFileName.lowercased().hasSuffix(".mov")
            let shouldDelete = isVideo ? AppSettings.autoDeleteVideo() : AppSettings.autoDeleteAudio()
            guard shouldDelete else { continue }

            let retentionDays = isVideo ? AppSettings.videoRetentionDays() : AppSettings.audioRetentionDays()
            let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
            guard rec.createdAt < cutoff else { continue }

            let dir = mediaDirectory(for: rec)
            let url = dir.appendingPathComponent(rec.audioFileName)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
            rec.audioRemoved = true
            recordings[idx] = rec
        }
    }

    /// Одноразовая миграция: переносит .txt из пользовательской медиа-папки в служебную
    /// `transcripts/`, чтобы пользовательская папка содержала только медиа.
    /// После переноса метаданные не меняются (имя файла то же), меняется только локация.
    private func migrateTranscriptsToServiceFolder() {
        let fm = FileManager.default
        guard let txtDir = try? AppSettings.transcriptsDirectory() else { return }

        for rec in recordings {
            guard let name = rec.transcriptFileName, !name.isEmpty else { continue }
            let mediaDir = mediaDirectory(for: rec)
            let oldURL = mediaDir.appendingPathComponent(name)
            let newURL = txtDir.appendingPathComponent(name)

            // Уже в служебной папке — пропускаем. Если и там и там лежит — старый удаляем.
            let newExists = fm.fileExists(atPath: newURL.path)
            let oldExists = fm.fileExists(atPath: oldURL.path)

            if newExists, oldExists {
                try? fm.removeItem(at: oldURL)
                continue
            }
            if newExists { continue }
            guard oldExists else { continue }

            do {
                try fm.moveItem(at: oldURL, to: newURL)
            } catch {
                print("⚠️ migrate transcript failed: \(error.localizedDescription)")
            }
        }
    }

    /// Чистит «осиротевшие» .txt в медиа-папках: записи в JSON для них нет
    /// (или это дубликат уже мигрировавшего транскрипта). Безопасно: трогаем
    /// только файлы, чьё имя точно соответствует нашему шаблону `YYYY-MM-DD_HHmmss.txt`
    /// (так формирует AudioRecorder.makeOutputURL) — пользовательские .txt в этой
    /// папке не пострадают. Отправляем в Корзину, чтобы можно было вернуть.
    private func sweepStrayTranscriptsFromMediaFolders() {
        let fm = FileManager.default

        // Все папки, в которых могли осесть наши .txt.
        var dirs: Set<String> = []
        for rec in recordings { dirs.insert(mediaDirectory(for: rec).path) }
        dirs.insert(AppSettings.defaultRecordingsDirectory().path)
        if let user = try? AppSettings.recordingsDirectory() { dirs.insert(user.path) }

        let pattern = #"^\d{4}-\d{2}-\d{2}_\d{6}\.txt$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }

        for dirPath in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for name in items {
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                guard regex.firstMatch(in: name, range: range) != nil else { continue }
                let url = URL(fileURLWithPath: dirPath).appendingPathComponent(name)
                var trashed: NSURL?
                try? fm.trashItem(at: url, resultingItemURL: &trashed)
            }
        }
    }

    /// На прошлых версиях оставались .summary.md и .vtt в каталоге — чистим.
    private func cleanupOrphanedSummaries() {
        guard let dir = try? AudioRecorder.documentsDirectory() else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where name.hasSuffix(".summary.md") || name.hasSuffix(".vtt") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Pipeline

    /// Последовательно обрабатывает записи, накопившиеся пока модель скачивалась.
    func processPendingTranscriptions() async {
        guard ModelManager.shared.isReady, !isProcessingPending else { return }
        isProcessingPending = true
        defer { isProcessingPending = false }

        let pendingIDs = recordings
            .filter { $0.status == .pending }
            .map(\.id)

        for id in pendingIDs {
            guard ModelManager.shared.isReady,
                  let recording = recordings.first(where: { $0.id == id }),
                  recording.status == .pending else { continue }

            guard canRetryTranscription(recording) else {
                update(id: id) { $0.status = .failed }
                continue
            }

            let audioURL = mediaDirectory(for: recording)
                .appendingPathComponent(recording.audioFileName)
            update(id: id) { $0.status = .transcribing }
            await runTranscription(id: id, audioURL: audioURL)
        }
    }

    private func runTranscription(id: UUID, audioURL: URL) async {
        do {
            let outputDir = try AppSettings.transcriptsDirectory()
            let txtURL = try await TranscriptionService.transcribe(
                audioURL: audioURL,
                outputDirectory: outputDir
            )
            let transcriptBookmark = FileBookmark.create(from: txtURL)
            self.update(id: id) {
                $0.transcriptFileName = txtURL.lastPathComponent
                $0.transcriptBookmark = transcriptBookmark
                $0.status = .done
            }
        } catch {
            print("❌ transcription failed: \(error.localizedDescription)")
            self.update(id: id) { $0.status = .failed }
        }
    }

    private func update(id: UUID, _ mutate: (inout Recording) -> Void) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&recordings[idx])
    }

    // MARK: - Persistence (Phase 1: GRDB)
    //
    // Источник правды на диске — SQLite (`store.sqlite`). В памяти держим
    // `recordings: [Recording]` как @Observable-кэш для UI. Любая мутация
    // через didSet триггерит `scheduleSave()`, который дебаунсит и делает
    // транзакционный upsert всего массива в DB. JSON больше не пишем; старый
    // recordings.json остаётся как страховка только для миграции при первом
    // запуске.

    private func load() {
        do {
            let count = try dbQueue.read { try Recording.fetchCount($0) }
            if count > 0 {
                recordings = try dbQueue.read { try Recording
                    .order(Recording.Columns.createdAt.desc)
                    .fetchAll($0)
                }
                return
            }

            // DB пустая — пробуем миграцию из старого JSON-стора.
            let legacy = migrateLegacyStores()
            recordings = legacy
            if !legacy.isEmpty { save() }
        } catch {
            print("❌ store load failed: \(error.localizedDescription)")
            recordings = []
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        let snapshot = recordings
        do {
            try dbQueue.write { db in
                let livingIDs = Set(snapshot.map { $0.id.uuidString })
                // Удалить записи, которых больше нет в памяти.
                let storedIDs = try String.fetchAll(db, sql: "SELECT id FROM recording")
                for id in storedIDs where !livingIDs.contains(id) {
                    try db.execute(sql: "DELETE FROM recording WHERE id = ?", arguments: [id])
                }
                // Upsert текущих.
                for var rec in snapshot {
                    try rec.save(db)
                }
            }
        } catch {
            print("❌ store save failed: \(error.localizedDescription)")
        }
    }

    private func mediaDirectory(for recording: Recording) -> URL {
        recording.storageDirectoryURL()
    }

    /// Импорт из старого JSON-стора (`Application Support/UshiNext/recordings.json`
    /// и legacy-локаций) — выполняется один раз при первом запуске после миграции на GRDB.
    private func migrateLegacyStores() -> [Recording] {
        var candidates: [URL] = []
        if let meta = try? AppSettings.metadataDirectory() {
            candidates.append(meta)
        }
        candidates.append(AppSettings.defaultRecordingsDirectory())
        if let user = try? AppSettings.recordingsDirectory() {
            candidates.append(user)
        }

        var merged: [UUID: Recording] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in candidates {
            let url = dir.appendingPathComponent("recordings.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  !data.isEmpty,
                  let items = try? decoder.decode([Recording].self, from: data) else { continue }

            for var item in items {
                if item.storageFolderPath == nil || item.storageFolderPath?.isEmpty == true {
                    item.storageFolderPath = dir.path
                }
                merged[item.id] = item
            }
        }

        return merged.values.sorted { $0.createdAt > $1.createdAt }
    }

    private func normalizeStoragePaths() {
        let defaultPath = AppSettings.defaultRecordingsDirectory().path
        for idx in recordings.indices {
            if recordings[idx].storageFolderPath == nil || recordings[idx].storageFolderPath?.isEmpty == true {
                recordings[idx].storageFolderPath = defaultPath
            }
        }
    }

    // MARK: - Helpers

    static func shortDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "dd.MM.yyyy, HH:mm"
        return f.string(from: date)
    }
}

enum RecordingsStoreError: LocalizedError {
    case busyTranscribing

    var errorDescription: String? {
        switch self {
        case .busyTranscribing:
            return "Запись сейчас расшифровывается. Перенести её можно после окончания расшифровки."
        }
    }
}
