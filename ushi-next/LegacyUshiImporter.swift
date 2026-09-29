//
//  LegacyUshiImporter.swift
//  UshiNext
//
//  Phase 6 (§11 брифа): перенос записей из текущего Ushi.
//  Читает `~/Library/Application Support/ushi/recordings.json`, **копирует**
//  медиа в «Записи» UshiNext и транскрипты в служебную папку. Старый Ushi
//  остаётся целым. Повторный импорт пропускает уже перенесённые записи
//  (id записи сохраняется).
//

import Foundation

enum LegacyUshiImporter {
    /// Папка данных старого Ushi.
    static var legacyDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ushi", isDirectory: true)
    }

    /// Записи старого Ushi, которых ещё нет в UshiNext. Пусто — предлагать нечего.
    static func pendingRecordings(existingIDs: Set<UUID>, directory: URL? = legacyDirectory) -> [Recording] {
        guard let dir = directory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("recordings.json")) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let items = try? decoder.decode([Recording].self, from: data) else { return [] }
        return items.filter { !existingIDs.contains($0.id) }
    }

    /// Скопировать файлы одной записи и вернуть её в виде для UshiNext
    /// (без Проекта — попадает в «Записи»). Копирование — в фоне.
    static func prepare(_ old: Recording, legacyDir: URL) async throws -> Recording {
        var rec = old
        rec.projectId = nil
        rec.audioBookmark = nil
        rec.transcriptBookmark = nil
        rec.transcriptFileName = nil
        let dir = try AppSettings.orphanRecordingsDirectory()
        rec.storageFolderPath = dir.path
        var copied: [URL] = []
        var hadMedia = false
        do {
            if !old.audioRemoved, !old.audioFileName.isEmpty {
                let source = old.audioBookmark.flatMap { FileBookmark.resolve($0)?.url }
                    ?? URL(fileURLWithPath: old.storageFolderPath ?? NSHomeDirectory() + "/Documents/ushi")
                        .appendingPathComponent(old.audioFileName)
                let dest = FileMover.uniqueDestination(for: old.audioFileName, in: dir)
                try await copy(source, to: dest)
                copied.append(dest)
                hadMedia = true
                rec.audioFileName = dest.lastPathComponent
                rec.audioBookmark = FileBookmark.create(from: dest)
                rec.fileSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            }
            rec.audioRemoved = !hadMedia

            if let name = old.transcriptFileName, !name.isEmpty {
                let source = old.transcriptBookmark.flatMap { FileBookmark.resolve($0)?.url }
                    ?? legacyDir.appendingPathComponent("transcripts").appendingPathComponent(name)
                let txtDir = try AppSettings.transcriptsDirectory()
                let dest = FileMover.uniqueDestination(for: name, in: txtDir)
                try await copy(source, to: dest)
                copied.append(dest)
                rec.transcriptFileName = dest.lastPathComponent
                rec.transcriptBookmark = FileBookmark.create(from: dest)
            }
        } catch {
            for url in copied { try? FileManager.default.removeItem(at: url) }
            throw error
        }

        // Голосовая дорожка «Я / Собеседник» — нужна для повторной расшифровки.
        // Не критична: не скопировалась — запись переносится без неё.
        rec.voiceTrackFileName = nil
        if let name = old.voiceTrackFileName, !name.isEmpty, hadMedia,
           let voicesDir = try? AppSettings.voiceTracksDirectory() {
            let source = legacyDir.appendingPathComponent("voices").appendingPathComponent(name)
            let dest = FileMover.uniqueDestination(for: name, in: voicesDir)
            if (try? await copy(source, to: dest)) != nil {
                rec.voiceTrackFileName = dest.lastPathComponent
            }
        }

        // Статус: есть текст — готово; нет текста, но есть звук — в очередь; иначе — ошибка.
        if rec.transcriptFileName != nil {
            rec.status = .done
        } else {
            rec.status = hadMedia ? .pending : .failed
        }
        rec.transcriptStatus = rec.status.transcriptStatus

        // Название: авто-имя старого Ushi («Запись от …») — fallback, иначе юзер правил руками.
        rec.titleSource = old.title.hasPrefix("Запись от ") ? .fallback : .manual
        return rec
    }

    private static func copy(_ source: URL, to dest: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: source, to: dest)
        }.value
    }
}
