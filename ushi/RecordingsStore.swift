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

    init() {
        load()
        recoverStuckRecordings()
        cleanupOrphanedSummaries()
        purgeOldSourceMedia()
    }

    // MARK: - Mutations

    func delete(_ recording: Recording) {
        deleteFiles(for: recording)
        recordings.removeAll { $0.id == recording.id }
    }

    func rename(_ recording: Recording, to newTitle: String) {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }
        recordings[idx].title = newTitle
    }

    @discardableResult
    func addRecording(audioURL: URL, duration: TimeInterval) -> Recording {
        let rec = Recording(
            title: "Запись от " + Self.shortDateString(Date()),
            duration: duration,
            audioFileName: audioURL.lastPathComponent,
            storageFolderPath: audioURL.deletingLastPathComponent().path,
            status: .transcribing
        )
        recordings.insert(rec, at: 0)

        let recordingID = rec.id
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTranscription(id: recordingID, audioURL: audioURL)
        }
        return rec
    }

    /// Может ли запись быть перетранскрибирована (аудио ещё на диске).
    func canRetryTranscription(_ recording: Recording) -> Bool {
        guard !recording.audioRemoved,
              !recording.audioFileName.isEmpty else { return false }
        let dir = mediaDirectory(for: recording)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(recording.audioFileName).path)
    }

    /// Перезапуск транскрипции (для failed или явного "перетранскрибировать").
    func retryTranscription(_ recording: Recording) {
        let dir = mediaDirectory(for: recording)
        let audioURL = dir.appendingPathComponent(recording.audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return }

        if let txt = recording.transcriptFileName {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(txt))
        }
        update(id: recording.id) {
            $0.transcriptFileName = nil
            $0.status = .transcribing
        }

        let recordingID = recording.id
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runTranscription(id: recordingID, audioURL: audioURL)
        }
    }

    // MARK: - Recovery

    /// Зависшие в transcribing после краша — переводим в failed.
    private func recoverStuckRecordings() {
        for idx in recordings.indices {
            if recordings[idx].status == .transcribing || recordings[idx].status == .pending {
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

    /// На прошлых версиях оставались .summary.md и .vtt в каталоге — чистим.
    private func cleanupOrphanedSummaries() {
        guard let dir = try? AudioRecorder.documentsDirectory() else { return }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in items where name.hasSuffix(".summary.md") || name.hasSuffix(".vtt") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: - Pipeline

    private func runTranscription(id: UUID, audioURL: URL) async {
        do {
            let txtURL = try await TranscriptionService.transcribe(audioURL: audioURL)
            await MainActor.run {
                self.update(id: id) {
                    $0.transcriptFileName = txtURL.lastPathComponent
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
        let dir = mediaDirectory(for: recording)
        if !recording.audioFileName.isEmpty {
            try? fm.removeItem(at: dir.appendingPathComponent(recording.audioFileName))
        }
        if let txt = recording.transcriptFileName {
            try? fm.removeItem(at: dir.appendingPathComponent(txt))
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
