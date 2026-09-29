//
//  FileMover.swift
//  UshiNext
//
//  Перенос файла записи между папками (Move to, §7.4 брифа; Phase 3).
//  - Тот же том → moveItem, мгновенно.
//  - Разные тома → копирование кусками с прогрессом и отменой, оригинал
//    удаляется только после успешной копии. При ошибке или отмене частичная
//    копия удаляется, оригинал остаётся на месте.
//  Ничего не знает про Recording и БД — только файлы, чтобы легко тестировать.
//

import Foundation

enum FileMoverError: LocalizedError {
    case sourceMissing
    case cancelled

    var errorDescription: String? {
        switch self {
        case .sourceMissing: return "Файл записи не найден на диске."
        case .cancelled:     return "Перенос отменён."
        }
    }
}

/// nonisolated + @concurrent: копирование гигабайтного видео не должно идти
/// на главном потоке (в таргете по умолчанию всё MainActor).
nonisolated struct FileMover: Sendable {
    /// Размер куска при копировании между томами.
    var chunkSize = 4 * 1024 * 1024

    /// Лежат ли два пути на одном томе (тогда перенос — мгновенный rename).
    static func isSameVolume(_ a: URL, _ b: URL) -> Bool {
        let key: URLResourceKey = .volumeIdentifierKey
        guard let va = try? a.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject,
              let vb = try? b.resourceValues(forKeys: [key]).volumeIdentifier as? NSObject else {
            return false
        }
        return va.isEqual(vb)
    }

    /// Нужно ли копирование (и, значит, прогресс) для переноса в эту папку.
    static func needsCopy(from source: URL, toDirectory dir: URL) -> Bool {
        !isSameVolume(source, dir)
    }

    /// Перенести файл в папку. Возвращает новый URL (имя может получить « (2)»,
    /// если такое уже есть). `forceCopy` — для тестов кросс-томового пути.
    /// `progress` вызывается с долей 0…1 только при копировании.
    @concurrent
    func moveFile(
        at source: URL,
        toDirectory dir: URL,
        forceCopy: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw FileMoverError.sourceMissing }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if source.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            return source
        }

        let destination = Self.uniqueDestination(for: source.lastPathComponent, in: dir)

        if !forceCopy && Self.isSameVolume(source, dir) {
            try fm.moveItem(at: source, to: destination)
            return destination
        }

        do {
            try await copy(from: source, to: destination, progress: progress)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        // Копия цела — теперь можно убрать оригинал. Если не вышло, лучше
        // дубль, чем потеря: оставляем оба файла и не падаем.
        do {
            try fm.removeItem(at: source)
        } catch {
            print("⚠️ FileMover: copied, but failed to remove original: \(error.localizedDescription)")
        }
        return destination
    }

    // MARK: - Внутреннее

    @concurrent
    private func copy(
        from source: URL,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let fm = FileManager.default
        let total = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        var copied: Int64 = 0
        progress?(0)
        while true {
            if Task.isCancelled { throw FileMoverError.cancelled }
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            try writer.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            if total > 0 { progress?(min(1, Double(copied) / Double(total))) }
            await Task.yield()
        }
        try writer.synchronize()

        // Сохраняем даты создания/изменения, чтобы запись не «помолодела» в Finder.
        if let attrs = try? fm.attributesOfItem(atPath: source.path) {
            var keep: [FileAttributeKey: Any] = [:]
            if let created = attrs[.creationDate] { keep[.creationDate] = created }
            if let modified = attrs[.modificationDate] { keep[.modificationDate] = modified }
            try? fm.setAttributes(keep, ofItemAtPath: destination.path)
        }
        progress?(1)
    }

    /// `name.m4a` → если занято, `name (2).m4a`, `name (3).m4a`…
    static func uniqueDestination(for fileName: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(fileName)
        let ext = (fileName as NSString).pathExtension
        let base = (fileName as NSString).deletingPathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path), n < 1000 {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = dir.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }
}
