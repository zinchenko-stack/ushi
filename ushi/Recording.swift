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
    /// «Штрих-код» аудио/видео файла — выживает переименование и перемещение
    /// в подпапки. Опционален: nil у старых записей, мигрируется на первом резолве.
    var audioBookmark: Data?
    /// Аналогично для .txt транскрипта.
    var transcriptBookmark: Data?

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
        transcriptBookmark: Data? = nil
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
        case audioBookmark, transcriptBookmark
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
        audioBookmark = try c.decodeIfPresent(Data.self, forKey: .audioBookmark)
        transcriptBookmark = try c.decodeIfPresent(Data.self, forKey: .transcriptBookmark)

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
        try c.encodeIfPresent(audioBookmark, forKey: .audioBookmark)
        try c.encodeIfPresent(transcriptBookmark, forKey: .transcriptBookmark)
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

    /// Полный путь к .txt, если он есть (по имени + папке).
    /// Не использует bookmark — это синхронный legacy-доступ. Для надёжного резолва
    /// зови `resolveTranscriptURL()`.
    func transcriptURL() -> URL? {
        guard let name = transcriptFileName, !name.isEmpty,
              let dir = transcriptDirectoryURL() else { return nil }
        return dir.appendingPathComponent(name)
    }

    // MARK: - Bookmark-based резолверы

    /// Найти актуальный URL аудио-файла. Возвращает (url, freshBookmark):
    /// url — найденный файл; freshBookmark — обновлённая версия bookmark, которую
    /// store должен сохранить (если bookmark был stale или мы его создали по fallback).
    /// nil-кортеж означает что файл потерян, и резолвер не смог его найти.
    func resolveAudioURL() -> (url: URL, freshBookmark: Data?)? {
        // 1. Bookmark — самый надёжный путь (выживает переименование/перемещение)
        if let bm = audioBookmark, let res = FileBookmark.resolve(bm) {
            return (res.url, res.freshBookmark)
        }
        // 2. Fallback: storageFolderPath + audioFileName (как было раньше)
        let fallback = storageDirectoryURL().appendingPathComponent(audioFileName)
        if FileManager.default.fileExists(atPath: fallback.path) {
            // Создаём bookmark на будущее (миграция старых записей)
            return (fallback, FileBookmark.create(from: fallback))
        }
        return nil
    }

    /// Аналогично для транскрипта.
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
