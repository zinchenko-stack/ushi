//
//  Recording.swift
//  ushi
//

import Foundation

enum ProcessingStatus: String, Codable {
    case pending        // ждёт транскрипции
    case transcribing   // whisper работает
    case done
    case failed
}

struct Recording: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: TimeInterval
    var audioFileName: String
    var transcriptFileName: String?
    var storageFolderPath: String?
    var status: ProcessingStatus
    /// true если .m4a удалён по политике хранения (старше 7 дней). Транскрипт остаётся.
    var audioRemoved: Bool

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String = "",
        transcriptFileName: String? = nil,
        storageFolderPath: String? = nil,
        status: ProcessingStatus = .pending,
        audioRemoved: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.audioFileName = audioFileName
        self.transcriptFileName = transcriptFileName
        self.storageFolderPath = storageFolderPath
        self.status = status
        self.audioRemoved = audioRemoved
    }

    // MARK: - Совместимость со старым JSON
    //
    // Старые версии писали поля: transcriptionStatus (legacy enum), summaryFileName,
    // titleIsAuto. Их декодируем мягко: лишние поля игнорируем, новые статусы
    // (extracting/summarizing) маппим в .transcribing → .failed, чтобы пользователь
    // знал, что эти записи требовали внимания.

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration
        case audioFileName, transcriptFileName, storageFolderPath
        case status, audioRemoved
        case transcriptionStatus // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        audioFileName = try c.decode(String.self, forKey: .audioFileName)
        transcriptFileName = try c.decodeIfPresent(String.self, forKey: .transcriptFileName)
        storageFolderPath = try c.decodeIfPresent(String.self, forKey: .storageFolderPath)
        audioRemoved = try c.decodeIfPresent(Bool.self, forKey: .audioRemoved) ?? false

        // Сначала пробуем новый статус, потом legacy. Снятые статусы
        // (extracting/summarizing) маппим как незавершённую обработку.
        if let raw = try c.decodeIfPresent(String.self, forKey: .status) {
            switch raw {
            case "pending":      status = .pending
            case "transcribing": status = .transcribing
            case "done":         status = .done
            case "failed":       status = .failed
            case "extracting", "summarizing":
                // Запись прошла транскрипцию (если был transcriptFileName), но конспект
                // больше не делаем. Считаем готовой, если транскрипт есть, иначе failed.
                status = (transcriptFileName != nil) ? .done : .failed
            default: status = .pending
            }
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .transcriptionStatus) {
            switch legacy {
            case "pending":      status = .pending
            case "inProgress":   status = .transcribing
            case "done":         status = .done
            case "failed":       status = .failed
            default:             status = .pending
            }
        } else {
            status = .pending
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(duration, forKey: .duration)
        try c.encode(audioFileName, forKey: .audioFileName)
        try c.encodeIfPresent(transcriptFileName, forKey: .transcriptFileName)
        try c.encodeIfPresent(storageFolderPath, forKey: .storageFolderPath)
        try c.encode(status, forKey: .status)
        try c.encode(audioRemoved, forKey: .audioRemoved)
    }

    func storageDirectoryURL() -> URL {
        if let storageFolderPath, !storageFolderPath.isEmpty {
            return URL(fileURLWithPath: storageFolderPath, isDirectory: true)
        }
        return AppSettings.defaultRecordingsDirectory()
    }

    /// Папка с транскриптами — всегда служебная (Application Support/ushi/transcripts/),
    /// независимо от того, куда пользователь сохраняет медиа.
    func transcriptDirectoryURL() -> URL? {
        try? AppSettings.transcriptsDirectory()
    }

    /// Полный путь к .txt, если он есть.
    func transcriptURL() -> URL? {
        guard let name = transcriptFileName, !name.isEmpty,
              let dir = transcriptDirectoryURL() else { return nil }
        return dir.appendingPathComponent(name)
    }
}
