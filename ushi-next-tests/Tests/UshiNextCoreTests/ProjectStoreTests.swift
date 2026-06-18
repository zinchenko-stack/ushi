//
//  ProjectStoreTests.swift
//

import XCTest
import GRDB
@testable import UshiNextCore

final class ProjectStoreTests: XCTestCase {
    var dbQueue: DatabaseQueue!
    var store: ProjectStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dbQueue = try AppDatabase.makeInMemory()
        store = ProjectStore(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        store = nil
        dbQueue = nil
        try super.tearDownWithError()
    }

    // MARK: - create / read

    func testCreateProjectIsReadBack() throws {
        let project = try store.create(name: "Психолог", preset: .systemAndMic)

        let all = try store.allProjects()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, project.id)
        XCTAssertEqual(all.first?.name, "Психолог")
        XCTAssertEqual(all.first?.lastUsedPreset, .systemAndMic)
        XCTAssertEqual(all.first?.storage, .managed)
        XCTAssertFalse(all.first?.isPinned ?? true)
    }

    func testAllProjectsPinnedFirst() throws {
        let a = try store.create(name: "A", preset: .micOnly)
        let b = try store.create(name: "B", preset: .micOnly)
        let c = try store.create(name: "C", preset: .micOnly)
        try store.setPinned(b, true)

        let ids = try store.allProjects().map(\.id)
        XCTAssertEqual(ids.first, b.id, "Pinned должен быть первым")
        XCTAssertEqual(Set(ids), Set([a.id, b.id, c.id]))
    }

    // MARK: - rename

    func testRenameUpdatesProject() throws {
        let p = try store.create(name: "Старое", preset: .micOnly)
        try store.rename(p, to: "Новое имя")

        let reloaded = try store.allProjects().first!
        XCTAssertEqual(reloaded.name, "Новое имя")
    }

    func testRenameTrimsAndIgnoresEmpty() throws {
        let p = try store.create(name: "Имя", preset: .micOnly)
        try store.rename(p, to: "   ")
        try store.rename(p, to: "  Trimmed  ")

        let reloaded = try store.allProjects().first!
        XCTAssertEqual(reloaded.name, "Trimmed")
    }

    // MARK: - delete

    func testDeleteWithoutRecordingsKeepsThemAsOrphan() throws {
        let project = try store.create(name: "Лекции", preset: .micOnly)
        try insertRecording(in: project)
        try insertRecording(in: project)

        XCTAssertEqual(try store.recordings(in: project).count, 2)
        try store.delete(project, deleteRecordings: false)

        XCTAssertTrue(try store.allProjects().isEmpty)
        let orphans = try store.recordings(in: nil)
        XCTAssertEqual(orphans.count, 2, "Записи должны были переехать в orphan-сегмент")
        for rec in orphans {
            XCTAssertNil(rec.projectId, "После удаления Проекта projectId должен стать nil")
        }
    }

    func testDeleteWithRecordingsRemovesThem() throws {
        let project = try store.create(name: "Встречи", preset: .micOnly)
        try insertRecording(in: project)
        try insertRecording(in: project)

        try store.delete(project, deleteRecordings: true)

        XCTAssertTrue(try store.allProjects().isEmpty)
        XCTAssertTrue(try store.recordings(in: nil).isEmpty)
        let total = try dbQueue.read { try Recording.fetchCount($0) }
        XCTAssertEqual(total, 0)
    }

    // MARK: - move

    func testMoveRecordingToOrphan() throws {
        let project = try store.create(name: "Психолог", preset: .micOnly)
        let recID = try insertRecording(in: project)

        let recBefore = try dbQueue.read { db in
            try Recording.fetchOne(db, key: recID.uuidString)
        }!
        XCTAssertEqual(recBefore.projectId, project.id)

        try store.move(recording: recBefore, to: nil)

        let recAfter = try dbQueue.read { db in
            try Recording.fetchOne(db, key: recID.uuidString)
        }!
        XCTAssertNil(recAfter.projectId)
        XCTAssertEqual(try store.recordings(in: nil).count, 1)
        XCTAssertEqual(try store.recordings(in: project).count, 0)
    }

    func testMoveRecordingBetweenProjects() throws {
        let p1 = try store.create(name: "P1", preset: .micOnly)
        let p2 = try store.create(name: "P2", preset: .micOnly)
        let recID = try insertRecording(in: p1)

        let rec = try dbQueue.read { try Recording.fetchOne($0, key: recID.uuidString) }!
        try store.move(recording: rec, to: p2)

        XCTAssertEqual(try store.recordings(in: p1).count, 0)
        XCTAssertEqual(try store.recordings(in: p2).count, 1)
    }

    // MARK: - lastUsedPreset

    func testUpdateLastUsedPresetIsPersisted() throws {
        let p = try store.create(name: "P", preset: .micOnly)
        try store.updateLastUsedPreset(p, .screen)

        let reloaded = try store.allProjects().first!
        XCTAssertEqual(reloaded.lastUsedPreset, .screen)
    }

    func testAppStateGlobalLastUsedPresetRoundTrip() throws {
        try dbQueue.write { try AppState.setLastUsedPreset(.systemAndMic, in: $0) }
        let read = try dbQueue.read { try AppState.lastUsedPreset(in: $0) }
        XCTAssertEqual(read, .systemAndMic)
    }

    func testAppStateLastUsedPresetDefaultsToMicOnly() throws {
        let read = try dbQueue.read { try AppState.lastUsedPreset(in: $0) }
        XCTAssertEqual(read, .micOnly)
    }

    // MARK: - Helpers

    /// Вставляет в БД минимально валидную Recording, связанную с Проектом.
    /// Файловые поля заглушены — тесты Store не трогают диск.
    @discardableResult
    private func insertRecording(in project: Project?) throws -> UUID {
        var rec = Recording(
            title: "test",
            duration: 10,
            audioFileName: "test.m4a",
            status: .done,
            projectId: project?.id,
            presetSnapshot: project?.lastUsedPreset ?? .micOnly,
            hasMicrophone: true,
            hasSystemAudio: false,
            hasScreen: false,
            titleSource: .fallback,
            transcriptStatus: .done,
            fileSize: 1234
        )
        try dbQueue.write { try rec.save($0) }
        return rec.id
    }
}
