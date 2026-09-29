import XCTest
import GRDB
@testable import UshiNextCore

@MainActor
final class RecordingWorkflowTests: XCTestCase {
    private func fixture() throws -> (RecordingsStore, ProjectsModel, DatabaseQueue) {
        AppSettings.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try AppDatabase.makeInMemory()
        return (RecordingsStore(dbQueue: db), ProjectsModel(store: ProjectStore(dbQueue: db)), db)
    }

    func testFailedMovePreventsProjectDeletionAndKeepsMedia() async throws {
        let (recordings, projects, db) = try fixture()
        let project = try projects.create(name: "Safe", preset: .systemAndMic)
        let dir = try ProjectFolders.recordingsDirectory(for: project)
        let audio = dir.appendingPathComponent("source.m4a")
        try Data("audio".utf8).write(to: audio)
        let rec = recordings.addRecording(audioURL: audio, duration: 1, project: project)
        recordings.saveNow()
        // A regular file blocks creation of the destination directory.
        let inbox = AppSettings.defaultRecordingsDirectory()
        try FileManager.default.removeItem(at: inbox)
        try Data("blocked".utf8).write(to: inbox)
        do {
            try await projects.delete(project, deleteRecordings: false, recordings: recordings)
            XCTFail("Deletion must fail when media cannot be moved")
        } catch { }
        XCTAssertEqual(recordings.recordings.first?.projectId, project.id)
        XCTAssertNotNil(projects.project(id: project.id))
        XCTAssertEqual(try Data(contentsOf: audio), Data("audio".utf8))
        let saved = try await db.read { try Recording.fetchOne($0, key: rec.id.uuidString) }
        XCTAssertEqual(saved?.projectId, project.id)
    }

    func testMoveAndDetachKeepAudio() async throws {
        let (recordings, projects, _) = try fixture()
        let project = try projects.create(name: "Move", preset: .micOnly)
        let audio = try AppSettings.recordingsDirectory().appendingPathComponent("test.m4a")
        try Data("audio".utf8).write(to: audio)
        let rec = recordings.addRecording(audioURL: audio, duration: 1)
        try await recordings.move(rec, to: project)
        let moved = try XCTUnwrap(recordings.recordings.first)
        XCTAssertEqual(moved.projectId, project.id)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recordings.mediaURL(for: moved))), Data("audio".utf8))
        try await recordings.detachRecordings(fromProject: project.id, deleteFiles: false, moveFiles: true)
        let detached = try XCTUnwrap(recordings.recordings.first)
        XCTAssertNil(detached.projectId)
        XCTAssertNotNil(recordings.mediaURL(for: detached))
    }

    func testUnsupportedImportDoesNotCreateRecording() async throws {
        let (recordings, _, _) = try fixture()
        do {
            _ = try await recordings.importAudio(from: AppSettings.root.appendingPathComponent("test.pdf"), into: nil)
            XCTFail("Unsupported input must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("неподдерживаемый формат"))
        }
        XCTAssertTrue(recordings.recordings.isEmpty)
    }

    func testCorruptAudioDoesNotCreateRecording() async throws {
        let (recordings, _, _) = try fixture()
        let source = AppSettings.root.appendingPathComponent("invalid.m4a")
        try Data("not audio".utf8).write(to: source)
        do {
            _ = try await recordings.importAudio(from: source, into: nil)
            XCTFail("Corrupt audio must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("повреждён"))
        }
        XCTAssertTrue(recordings.recordings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("not audio".utf8))
    }

    func testImportIntoProjectPreservesOriginalAndPreset() async throws {
        let (recordings, projects, _) = try fixture()
        let project = try projects.create(name: "Import", preset: .micOnly)
        let source = AppSettings.root.appendingPathComponent("sample.wav")
        // One second of 16-bit mono PCM. No microphone or private audio involved.
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append(UInt32(32036)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16000)); append(UInt32(32000)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(32000)); wav.append(Data(count: 32000))
        try wav.write(to: source)
        let rec = try await recordings.importAudio(from: source, into: project)
        XCTAssertEqual(rec.projectId, project.id)
        XCTAssertEqual(rec.status, .pending)
        XCTAssertEqual(rec.duration, 1, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: source), wav)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(recordings.mediaURL(for: rec))), wav)
        projects.reload()
        XCTAssertEqual(projects.project(id: project.id)?.lastUsedPreset, .micOnly)
        recordings.saveNow()
    }

    func testDeleteWithFilesRemovesAudioAndText() async throws {
        let (recordings, projects, _) = try fixture()
        let project = try projects.create(name: "Delete", preset: .systemAndMic)
        let audio = try ProjectFolders.recordingsDirectory(for: project).appendingPathComponent("delete.m4a")
        let text = try AppSettings.transcriptsDirectory().appendingPathComponent("delete.txt")
        try Data("audio".utf8).write(to: audio)
        try Data("text".utf8).write(to: text)
        recordings.recordings = [Recording(title: "Delete", audioFileName: audio.lastPathComponent,
            transcriptFileName: text.lastPathComponent, storageFolderPath: audio.deletingLastPathComponent().path,
            status: .done, projectId: project.id)]
        try await recordings.detachRecordings(fromProject: project.id, deleteFiles: true, moveFiles: true)
        XCTAssertTrue(recordings.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: text.path))
    }

    func testSearchFindsTranscriptText() async throws {
        _ = try fixture()
        let text = try AppSettings.transcriptsDirectory().appendingPathComponent("search.txt")
        try "Планируем поездку в Казань".write(to: text, atomically: true, encoding: .utf8)
        let rec = Recording(title: "Встреча", transcriptFileName: text.lastPathComponent)
        let index = TranscriptIndex()
        index.sync(with: [rec])
        for _ in 0..<100 {
            if index.match(query: "КАЗАНЬ", for: rec) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(index.match(query: "КАЗАНЬ", for: rec)?.transcriptHitRange)
    }

    func testSearchByTitleAndProject() throws {
        let index = TranscriptIndex()
        let rec = Recording(title: "Обсуждение бюджета")
        XCTAssertNotNil(index.match(query: "БЮДЖЕТ Лекции", for: rec, projectName: "Лекции"))
        XCTAssertNil(index.match(query: "несуществующее", for: rec, projectName: "Лекции"))
    }
}
