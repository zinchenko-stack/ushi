//
//  FileMoverTests.swift
//
//  Phase 3: перенос файла записи — тот же том, копирование между томами,
//  отмена и откат при ошибке. Настоящий второй том — RAM-образ через hdiutil
//  (если не получилось смонтировать — тест пропускается).
//

import XCTest
@testable import UshiNextCore

final class FileMoverTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileMoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Вернуть права, если тест их отнимал, иначе не удалится.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func makeFile(_ name: String, in dir: URL, bytes: Int) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var data = Data(count: bytes)
        for i in stride(from: 0, to: bytes, by: 997) { data[i] = UInt8(i % 251) }
        try data.write(to: url)
        return url
    }

    // MARK: - Тот же том

    func testSameVolumeMoveIsRename() async throws {
        let src = try makeFile("a.m4a", in: root.appendingPathComponent("from"), bytes: 10_000)
        let dest = root.appendingPathComponent("to")

        let result = try await FileMover().moveFile(at: src, toDirectory: dest)

        XCTAssertEqual(result.lastPathComponent, "a.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileMover.isSameVolume(src.deletingLastPathComponent(), dest))
    }

    func testNameClashGetsSuffix() async throws {
        let src = try makeFile("a.m4a", in: root.appendingPathComponent("from"), bytes: 100)
        let dest = root.appendingPathComponent("to")
        _ = try makeFile("a.m4a", in: dest, bytes: 50)

        let result = try await FileMover().moveFile(at: src, toDirectory: dest)

        XCTAssertEqual(result.lastPathComponent, "a (2).m4a")
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("a.m4a")).count, 50)
    }

    // MARK: - Копирование (путь между томами)

    func testCopyPathPreservesContentAndRemovesOriginal() async throws {
        let src = try makeFile("b.mov", in: root.appendingPathComponent("from"), bytes: 3_000_000)
        let original = try Data(contentsOf: src)
        let dest = root.appendingPathComponent("to")
        let fractions = LockedArray()

        var mover = FileMover()
        mover.chunkSize = 256 * 1024
        let result = try await mover.moveFile(at: src, toDirectory: dest, forceCopy: true) { fractions.append($0) }

        XCTAssertEqual(try Data(contentsOf: result), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(fractions.values.last, 1)
        XCTAssertGreaterThan(fractions.values.count, 3, "прогресс должен приходить по ходу копирования")
    }

    func testCancelKeepsOriginalAndRemovesPartialCopy() async throws {
        let src = try makeFile("c.mov", in: root.appendingPathComponent("from"), bytes: 20_000_000)
        let dest = root.appendingPathComponent("to")

        var mover = FileMover()
        mover.chunkSize = 64 * 1024
        let task = Task {
            try await mover.moveFile(at: src, toDirectory: dest, forceCopy: true)
        }
        try await Task.sleep(for: .milliseconds(5))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("перенос должен был отмениться")
        } catch FileMoverError.cancelled {
            // ок
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "оригинал должен остаться")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("c.mov").path),
                       "частичная копия должна быть удалена")
    }

    func testErrorKeepsOriginal() async throws {
        let src = try makeFile("d.m4a", in: root.appendingPathComponent("from"), bytes: 1_000)
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        do {
            _ = try await FileMover().moveFile(at: src, toDirectory: locked, forceCopy: true)
            XCTFail("запись в папку без прав должна упасть")
        } catch {
            // ок
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testMissingSourceThrows() async throws {
        let missing = root.appendingPathComponent("nope.m4a")
        do {
            _ = try await FileMover().moveFile(at: missing, toDirectory: root.appendingPathComponent("to"))
            XCTFail("нет файла — должна быть ошибка")
        } catch FileMoverError.sourceMissing {
            // ок
        }
    }

    // MARK: - Настоящий второй том

    func testRealCrossVolumeMove() async throws {
        let image = root.appendingPathComponent("vol.dmg")
        let mount = root.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["create", "-size", "20m", "-fs", "APFS", "-volname", "UshiTest", image.path]) == 0,
              run("/usr/bin/hdiutil", ["attach", image.path, "-mountpoint", mount.path, "-nobrowse"]) == 0 else {
            throw XCTSkip("не удалось смонтировать тестовый том")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let src = try makeFile("e.m4a", in: root.appendingPathComponent("from"), bytes: 2_000_000)
        let original = try Data(contentsOf: src)
        let dest = mount.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        XCTAssertTrue(FileMover.needsCopy(from: src, toDirectory: dest))
        let fractions = LockedArray()
        let result = try await FileMover().moveFile(at: src, toDirectory: dest) { fractions.append($0) }

        XCTAssertEqual(try Data(contentsOf: result), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(fractions.values.last, 1)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Потокобезопасный сбор значений прогресса из фоновой задачи.
private final class LockedArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ v: Double) { lock.lock(); storage.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
