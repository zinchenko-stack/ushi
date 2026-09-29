import XCTest
@testable import UshiNextCore

@MainActor
final class LegacyImportTests: XCTestCase {
    func testCopyIsIndependentAndTranscriptCollisionKeepsBothTexts() async throws {
        AppSettings.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = try AppSettings.directory("legacy")
        let oldTexts = legacy.appendingPathComponent("transcripts")
        try FileManager.default.createDirectory(at: oldTexts, withIntermediateDirectories: true)
        let audio = legacy.appendingPathComponent("same.m4a")
        try Data("original audio".utf8).write(to: audio)
        try "old text".write(to: oldTexts.appendingPathComponent("same.txt"), atomically: true, encoding: .utf8)
        let existingText = try AppSettings.transcriptsDirectory().appendingPathComponent("same.txt")
        try "new text".write(to: existingText, atomically: true, encoding: .utf8)
        let old = Recording(title: "Original", audioFileName: "same.m4a", transcriptFileName: "same.txt", storageFolderPath: legacy.path, status: .done)
        let rec = try await LegacyUshiImporter.prepare(old, legacyDir: legacy)
        XCTAssertNil(rec.projectId)
        XCTAssertNotEqual(rec.transcriptFileName, "same.txt")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(rec.transcriptURL())), "old text")
        XCTAssertEqual(try String(contentsOf: existingText), "new text")
        XCTAssertEqual(try Data(contentsOf: audio), Data("original audio".utf8))
        XCTAssertNotEqual(rec.resolveAudioURL()?.url, audio)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([old]).write(to: legacy.appendingPathComponent("recordings.json"))
        XCTAssertEqual(LegacyUshiImporter.pendingRecordings(existingIDs: [], directory: legacy).count, 1)
        XCTAssertTrue(LegacyUshiImporter.pendingRecordings(existingIDs: [rec.id], directory: legacy).isEmpty)
    }

    func testCopyFailureCanBeRetriedAndRollsBackMedia() async throws {
        AppSettings.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let legacy = try AppSettings.directory("legacy")
        let audio = legacy.appendingPathComponent("test.m4a")
        try Data("original".utf8).write(to: audio)
        let old = Recording(title: "Original", audioFileName: "test.m4a", transcriptFileName: "missing.txt", storageFolderPath: legacy.path)
        do {
            _ = try await LegacyUshiImporter.prepare(old, legacyDir: legacy)
            XCTFail("Must report missing transcript instead of marking the import complete")
        } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: AppSettings.orphanRecordingsDirectory().path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: audio), Data("original".utf8))
    }

    func testPreviouslyRemovedAudioDoesNotPointToLegacyFolder() async throws {
        AppSettings.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = Recording(title: "Removed", audioFileName: "removed.m4a", storageFolderPath: "/legacy", audioRemoved: true)
        let rec = try await LegacyUshiImporter.prepare(old, legacyDir: URL(fileURLWithPath: "/legacy"))
        XCTAssertTrue(rec.audioRemoved)
        XCTAssertNotEqual(rec.storageFolderPath, old.storageFolderPath)
        XCTAssertNil(rec.audioBookmark)
    }
}
