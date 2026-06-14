//
//  RecordingsStore.swift
//  ushi
//

import Foundation
import Observation

@Observable
final class RecordingsStore {
    var recordings: [Recording] = [] {
        didSet { scheduleSave() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var isProcessingPending = false

    init() {
        load()
        recoverStuckRecordings()
        cleanupOrphanedSummaries()
        migrateTranscriptsToServiceFolder()
        sweepStrayTranscriptsFromMediaFolders()
        purgeOldSourceMedia()
    }

    // MARK: - Mutations

    func delete(_ recording: Recording) {
        deleteFiles(for: recording)
        recordings.removeAll { $0.id == recording.id }
    }

    func rename(_ recording: Recording, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        recordings[idx].title = trimmed
        renameFilesOnDisk(at: idx)
    }

    /// Подгоняет имена файлов (.m4a / .mov / .txt) под текущий title.
    /// Безопасно: пока транскрибация в процессе — не трогаем (whisper-cli ещё пишет в старый путь).
    private func renameFilesOnDisk(at idx: Int) {
        var rec = recordings[idx]

        // Транскрибация в процессе — пропускаем, иначе сломаем whisper.
        if rec.status == .transcribing || rec.status == .pending { return }

        let base = Self.sanitizeFilename(rec.title)
        guard !base.isEmpty else { return }

        let fm = FileManager.default
        let mediaDir = mediaDirectory(for: rec)
        let txtDir = rec.transcriptDirectoryURL()
        let audioExt = (rec.audioFileName as NSString).pathExtension
        let resolved = uniqueBaseName(
            base: base,
            mediaDir: mediaDir,
            txtDir: txtDir,
            audioExt: audioExt,
            currentAudio: rec.audioFileName,
            currentTranscript: rec.transcriptFileName
        )

        // Аудио / видео — переименовываем только если файл ещё на диске и не помечен как удалённый.
        if !rec.audioFileName.isEmpty, !rec.audioRemoved, !audioExt.isEmpty {
            let from = mediaDir.appendingPathComponent(rec.audioFileName)
            let to = mediaDir.appendingPathComponent("\(resolved).\(audioExt)")
            if from != to, fm.fileExists(atPath: from.path) {
                do {
                    try fm.moveItem(at: from, to: to)
                    rec.audioFileName = to.lastPathComponent
                    // Обновляем bookmark под новое имя (хотя bookmark пережил бы и через
                    // inode — но явное обновление безопаснее, особенно если файл
                    // менял volume в процессе).
                    rec.audioBookmark = FileBookmark.create(from: to)
                } catch {
                    print("❌ rename audio failed: \(error.localizedDescription)")
                }
            }
        }

        // Транскрипт (служебная папка, не пользовательская).
        if let txt = rec.transcriptFileName, !txt.isEmpty, let txtDir {
            let from = txtDir.appendingPathComponent(txt)
            let to = txtDir.appendingPathComponent("\(resolved).txt")
            if from != to, fm.fileExists(atPath: from.path) {
                do {
                    try fm.moveItem(at: from, to: to)
                    rec.transcriptFileName = to.lastPathComponent
                    rec.transcriptBookmark = FileBookmark.create(from: to)
                } catch {
                    print("❌ rename transcript failed: \(error.localizedDescription)")
                }
            }
        }

        recordings[idx] = rec
    }

    /// Подбирает базовое имя, не конфликтующее с другими файлами ни в media-, ни в transcripts-папке.
    /// Текущие файлы самой записи считаются «своими» — на них не реагируем.
    private func uniqueBaseName(
        base: String,
        mediaDir: URL,
        txtDir: URL?,
        audioExt: String,
        currentAudio: String,
        currentTranscript: String?
    ) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while true {
            let audioName = audioExt.isEmpty ? "" : "\(candidate).\(audioExt)"
            let txtName = "\(candidate).txt"
            let audioPath = audioName.isEmpty ? nil : mediaDir.appendingPathComponent(audioName).path
            let txtPath = txtDir?.appendingPathComponent(txtName).path

            let audioOK = audioPath.map { !fm.fileExists(atPath: $0) || audioName == currentAudio } ?? true
            let txtOK = txtPath.map { !fm.fileExists(atPath: $0) || txtName == currentTranscript } ?? true

            if audioOK && txtOK { return candidate }
            candidate = "\(base) (\(n))"
            n += 1
            if n > 999 { return candidate }   // на всякий случай
        }
    }

    /// Чистит имя от символов, опасных для файловой системы. Кириллицу, пробелы,
    /// числа — оставляем как есть, macOS APFS это всё нормально хранит.
    private static func sanitizeFilename(_ raw: String) -> String {
        let invalid: Set<Character> = ["/", "\\", ":", "\0"]
        var s = String(raw.map { invalid.contains($0) ? "-" : $0 })
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 100 {
            s = String(s.prefix(100)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    @discardableResult
    func addRecording(audioURL: URL, duration: TimeInterval) -> Recording {
        let canTranscribe = ModelManager.shared.isReady
        let rec = Recording(
            title: "Запись от " + Self.shortDateString(Date()),
            duration: duration,
            audioFileName: audioURL.lastPathComponent,
            storageFolderPath: audioURL.deletingLastPathComponent().path,
            status: canTranscribe ? .transcribing : .pending,
            audioBookmark: FileBookmark.create(from: audioURL)
        )
        recordings.insert(rec, at: 0)

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
            await MainActor.run {
                self.update(id: id) {
                    $0.transcriptFileName = txtURL.lastPathComponent
                    $0.transcriptBookmark = transcriptBookmark
                    $0.status = .done
                }
            }
        } catch {
            print("❌ transcription failed: \(error.localizedDescription)")
            await MainActor.run { self.update(id: id) { $0.status = .failed } }
        }
    }

    private func update(id: UUID, _ mutate: (inout Recording) -> Void) {
        guard let idx = recordings.firstIndex(where: { $0.id == id }) else { return }
        mutate(&recordings[idx])
    }

    // MARK: - Persistence

    private static func storeURL() throws -> URL {
        try AppSettings.metadataDirectory().appendingPathComponent("recordings.json")
    }

    private func load() {
        do {
            let url = try Self.storeURL()
            guard FileManager.default.fileExists(atPath: url.path) else {
                recordings = migrateLegacyStores()
                save()
                return
            }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            recordings = try decoder.decode([Recording].self, from: data)
            normalizeStoragePaths()
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
        do {
            let url = try Self.storeURL()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(recordings)
            try data.write(to: url, options: .atomic)
        } catch {
            print("❌ store save failed: \(error.localizedDescription)")
        }
    }

    private func deleteFiles(for recording: Recording) {
        let fm = FileManager.default
        // Идём через резолвер — он находит файл даже если был переименован/перемещён.
        if let (audioURL, _) = recording.resolveAudioURL() {
            try? fm.removeItem(at: audioURL)
        }
        if let (txtURL, _) = recording.resolveTranscriptURL() {
            try? fm.removeItem(at: txtURL)
        }
    }

    private func mediaDirectory(for recording: Recording) -> URL {
        recording.storageDirectoryURL()
    }

    private func migrateLegacyStores() -> [Recording] {
        let candidates = [
            AppSettings.defaultRecordingsDirectory(),
            (try? AppSettings.recordingsDirectory())
        ]
        .compactMap { $0 }

        var merged: [UUID: Recording] = [:]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for dir in candidates {
            let url = dir.appendingPathComponent("recordings.json")
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
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
