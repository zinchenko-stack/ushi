//
//  Recording.swift
//  UshiNext
//
//  Расширено в Phase 1: добавлены поля Проектов (projectId, presetSnapshot,
//  hasMicrophone/SystemAudio/Screen, titleSource, transcriptStatus, fileSize).
//  Сохраняем JSON Codable для обратной миграции старого recordings.json и
//  параллельно поддерживаем GRDB FetchableRecord/PersistableRecord.
//

import Foundation
import GRDB

enum ProcessingStatus: String, Codable {
    case pending        // ждёт транскрипции
    case transcribing   // whisper работает
    case done
    case failed

    /// Сворачивает гранулярный pipeline-статус в TranscriptStatus для DB-колонки
    /// `transcript_status` (см. §4 брифа).
    var transcriptStatus: TranscriptStatus {
        switch self {
        case .pending, .transcribing: return .pending
        case .done:                   return .done
        case .failed:                 return .failed
        }
    }
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
    var audioRemoved: Bool
    var audioBookmark: Data?
    var transcriptBookmark: Data?

    // MARK: - Поля Проектов (Phase 1)

    /// nil → запись в orphan-сегменте «Записи» (§6.3 брифа).
    var projectId: UUID?

    /// Immutable snapshot пресета на момент создания записи. Если пресет Проекта
    /// потом изменят — старая запись свой snapshot не теряет (§3 брифа, принцип 2).
    var presetSnapshot: RecordingPreset

    var hasMicrophone: Bool
    var hasSystemAudio: Bool
    var hasScreen: Bool

    /// Откуда взялся `title` — будет переключаться на .auto/.manual в Phase 4
    /// (whisper-based авто-имя). Сейчас всегда .fallback.
    var titleSource: TitleSource

    /// Конечный статус транскрипции для UI/поиска. Производный от
    /// `status` (ProcessingStatus), но хранится отдельно для миграционной
    /// совместимости с DB-схемой и быстрого фильтра запросом.
    var transcriptStatus: TranscriptStatus

    /// Размер файла в байтах. 0 если ещё не посчитан.
    var fileSize: Int64

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        audioFileName: String = "",
        transcriptFileName: String? = nil,
        storageFolderPath: String? = nil,
        status: ProcessingStatus = .pending,
        audioRemoved: Bool = false,
        audioBookmark: Data? = nil,
        transcriptBookmark: Data? = nil,
        projectId: UUID? = nil,
        presetSnapshot: RecordingPreset = .micOnly,
        hasMicrophone: Bool = true,
        hasSystemAudio: Bool = false,
        hasScreen: Bool = false,
        titleSource: TitleSource = .fallback,
        transcriptStatus: TranscriptStatus? = nil,
        fileSize: Int64 = 0
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
        self.audioBookmark = audioBookmark
        self.transcriptBookmark = transcriptBookmark
        self.projectId = projectId
        self.presetSnapshot = presetSnapshot
        self.hasMicrophone = hasMicrophone
        self.hasSystemAudio = hasSystemAudio
        self.hasScreen = hasScreen
        self.titleSource = titleSource
        self.transcriptStatus = transcriptStatus ?? status.transcriptStatus
        self.fileSize = fileSize
    }

    // MARK: - JSON Codable (для миграции старого recordings.json)

    enum CodingKeys: String, CodingKey {
        case id, title, createdAt, duration
        case audioFileName, transcriptFileName, storageFolderPath
        case status, audioRemoved
        case audioBookmark, transcriptBookmark
        case transcriptionStatus // legacy
        case projectId
        case presetSnapshot
        case hasMicrophone, hasSystemAudio, hasScreen
        case titleSource, transcriptStatus, fileSize
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
        audioBookmark = try c.decodeIfPresent(Data.self, forKey: .audioBookmark)
        transcriptBookmark = try c.decodeIfPresent(Data.self, forKey: .transcriptBookmark)

        if let raw = try c.decodeIfPresent(String.self, forKey: .status) {
            switch raw {
            case "pending":      status = .pending
            case "transcribing": status = .transcribing
            case "done":         status = .done
            case "failed":       status = .failed
            case "extracting", "summarizing":
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

        // Phase 1 поля — у старого JSON их нет, фолбечим в безопасные дефолты.
        projectId = try c.decodeIfPresent(UUID.self, forKey: .projectId)
        presetSnapshot = (try c.decodeIfPresent(RecordingPreset.self, forKey: .presetSnapshot)) ?? .micOnly
        hasMicrophone = try c.decodeIfPresent(Bool.self, forKey: .hasMicrophone) ?? true
        hasSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .hasSystemAudio) ?? false
        hasScreen = try c.decodeIfPresent(Bool.self, forKey: .hasScreen) ?? false
        titleSource = (try c.decodeIfPresent(TitleSource.self, forKey: .titleSource)) ?? .fallback
        transcriptStatus = (try c.decodeIfPresent(TranscriptStatus.self, forKey: .transcriptStatus))
            ?? status.transcriptStatus
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
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
        try c.encodeIfPresent(audioBookmark, forKey: .audioBookmark)
        try c.encodeIfPresent(transcriptBookmark, forKey: .transcriptBookmark)
        try c.encodeIfPresent(projectId, forKey: .projectId)
        try c.encode(presetSnapshot, forKey: .presetSnapshot)
        try c.encode(hasMicrophone, forKey: .hasMicrophone)
        try c.encode(hasSystemAudio, forKey: .hasSystemAudio)
        try c.encode(hasScreen, forKey: .hasScreen)
        try c.encode(titleSource, forKey: .titleSource)
        try c.encode(transcriptStatus, forKey: .transcriptStatus)
        try c.encode(fileSize, forKey: .fileSize)
    }

    // MARK: - URL helpers (без изменений по сравнению с Phase 0)

    func storageDirectoryURL() -> URL {
        if let storageFolderPath, !storageFolderPath.isEmpty {
            return URL(fileURLWithPath: storageFolderPath, isDirectory: true)
        }
        return AppSettings.defaultRecordingsDirectory()
    }

    func transcriptDirectoryURL() -> URL? {
        try? AppSettings.transcriptsDirectory()
    }

    func transcriptURL() -> URL? {
        guard let name = transcriptFileName, !name.isEmpty,
              let dir = transcriptDirectoryURL() else { return nil }
        return dir.appendingPathComponent(name)
    }

    func resolveAudioURL() -> (url: URL, freshBookmark: Data?)? {
        if let bm = audioBookmark, let res = FileBookmark.resolve(bm) {
            return (res.url, res.freshBookmark)
        }
        let fallback = storageDirectoryURL().appendingPathComponent(audioFileName)
        if FileManager.default.fileExists(atPath: fallback.path) {
            return (fallback, FileBookmark.create(from: fallback))
        }
        return nil
    }

    func resolveTranscriptURL() -> (url: URL, freshBookmark: Data?)? {
        if let bm = transcriptBookmark, let res = FileBookmark.resolve(bm) {
            return (res.url, res.freshBookmark)
        }
        if let fallback = transcriptURL(),
           FileManager.default.fileExists(atPath: fallback.path) {
            return (fallback, FileBookmark.create(from: fallback))
        }
        return nil
    }
}

// MARK: - GRDB

extension Recording: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "recording"

    enum Columns {
        static let id = Column("id")
        static let projectId = Column("project_id")
        static let title = Column("title")
        static let fileURL = Column("file_url")
        static let fileSize = Column("file_size")
        static let duration = Column("duration")
        static let createdAt = Column("created_at")
        static let presetSnapshot = Column("preset_snapshot")
        static let hasMicrophone = Column("has_microphone")
        static let hasSystemAudio = Column("has_system_audio")
        static let hasScreen = Column("has_screen")
        static let titleSource = Column("title_source")
        static let transcriptStatus = Column("transcript_status")

        // App-specific:
        static let storageFolderPath = Column("storage_folder_path")
        static let audioFileName = Column("audio_file_name")
        static let transcriptFileName = Column("transcript_file_name")
        static let audioRemoved = Column("audio_removed")
        static let audioBookmark = Column("audio_bookmark")
        static let transcriptBookmark = Column("transcript_bookmark")
        static let processingStatus = Column("processing_status")
    }

    init(row: Row) throws {
        let idString: String = row[Columns.id]
        guard let parsedID = UUID(uuidString: idString) else {
            throw DatabaseError(message: "Invalid UUID in recording.id: \(idString)")
        }
        self.id = parsedID
        if let projectIDString: String = row[Columns.projectId] {
            self.projectId = UUID(uuidString: projectIDString)
        } else {
            self.projectId = nil
        }
        self.title = row[Columns.title]
        self.duration = row[Columns.duration]
        self.createdAt = row[Columns.createdAt]
        self.fileSize = row[Columns.fileSize]
        let presetRaw: String = row[Columns.presetSnapshot]
        self.presetSnapshot = RecordingPreset(rawValue: presetRaw) ?? .micOnly
        self.hasMicrophone = row[Columns.hasMicrophone]
        self.hasSystemAudio = row[Columns.hasSystemAudio]
        self.hasScreen = row[Columns.hasScreen]
        let titleSourceRaw: String = row[Columns.titleSource]
        self.titleSource = TitleSource(rawValue: titleSourceRaw) ?? .fallback
        let transcriptStatusRaw: String = row[Columns.transcriptStatus]
        self.transcriptStatus = TranscriptStatus(rawValue: transcriptStatusRaw) ?? .pending

        self.storageFolderPath = row[Columns.storageFolderPath]
        self.audioFileName = row[Columns.audioFileName]
        self.transcriptFileName = row[Columns.transcriptFileName]
        self.audioRemoved = row[Columns.audioRemoved]
        self.audioBookmark = row[Columns.audioBookmark]
        self.transcriptBookmark = row[Columns.transcriptBookmark]
        let processingRaw: String = row[Columns.processingStatus]
        self.status = ProcessingStatus(rawValue: processingRaw) ?? .pending
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id.uuidString
        container[Columns.projectId] = projectId?.uuidString
        container[Columns.title] = title
        container[Columns.fileURL] = audioFileName  // file_url хранит имя файла; storage_folder_path — папку
        container[Columns.fileSize] = fileSize
        container[Columns.duration] = duration
        container[Columns.createdAt] = createdAt
        container[Columns.presetSnapshot] = presetSnapshot.rawValue
        container[Columns.hasMicrophone] = hasMicrophone
        container[Columns.hasSystemAudio] = hasSystemAudio
        container[Columns.hasScreen] = hasScreen
        container[Columns.titleSource] = titleSource.rawValue
        container[Columns.transcriptStatus] = transcriptStatus.rawValue

        container[Columns.storageFolderPath] = storageFolderPath
        container[Columns.audioFileName] = audioFileName
        container[Columns.transcriptFileName] = transcriptFileName
        container[Columns.audioRemoved] = audioRemoved
        container[Columns.audioBookmark] = audioBookmark
        container[Columns.transcriptBookmark] = transcriptBookmark
        container[Columns.processingStatus] = status.rawValue
    }
}
