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
    static func pendingRecordings(existingIDs: Set<UUID>) -> [Recording] {
        guard let dir = legacyDirectory,
              let data = try? Data(contentsOf: dir.appendingPathComponent("recordings.json")) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let items = try? decoder.decode([Recording].self, from: data) else { return [] }
        return items.filter { !existingIDs.contains($0.id) }
    }

    /// Скопировать файлы одной записи и вернуть её в виде для UshiNext
    /// (без Проекта — попадает в «Записи»). Копирование — в фоне.
    static func prepare(_ old: Recording, legacyDir: URL) async -> Recording {
        var rec = old
        rec.projectId = nil

        // Медиа → «Записи» UshiNext.
        var hadMedia = false
        let sourceMedia = URL(fileURLWithPath: old.storageFolderPath ?? NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(old.audioFileName)
        if !old.audioRemoved, !old.audioFileName.isEmpty,
           FileManager.default.fileExists(atPath: sourceMedia.path),
           let dir = try? AppSettings.orphanRecordingsDirectory() {
            let dest = FileMover.uniqueDestination(for: old.audioFileName, in: dir)
            if await copy(sourceMedia, to: dest) {
                hadMedia = true
                rec.audioFileName = dest.lastPathComponent
                rec.storageFolderPath = dir.path
                rec.audioBookmark = FileBookmark.create(from: dest)
                rec.fileSize = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            }
        }
        if !hadMedia {
            rec.audioRemoved = true
            rec.audioBookmark = nil
        }

        // Транскрипт → служебная папка UshiNext.
        rec.transcriptBookmark = nil
        if let name = old.transcriptFileName, !name.isEmpty,
           let txtDir = try? AppSettings.transcriptsDirectory() {
            let source = legacyDir.appendingPathComponent("transcripts").appendingPathComponent(name)
            let dest = txtDir.appendingPathComponent(name)
            var available = FileManager.default.fileExists(atPath: dest.path)
            if !available { available = await copy(source, to: dest) }
            if available {
                rec.transcriptBookmark = FileBookmark.create(from: dest)
            } else {
                rec.transcriptFileName = nil
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

    private static func copy(_ source: URL, to dest: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.copyItem(at: source, to: dest)) != nil
        }.value
    }
}
