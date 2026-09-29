//
//  ProjectStore.swift
//  UshiNext
//
//  Store-слой для Проектов и связанных с ними записей. Не знает про SwiftUI —
//  чистый CRUD + бизнес-логика (см. §8 брифа, разделение слоёв).
//

import Foundation
import GRDB

/// Сортировка Проектов в sidebar: закреплённые сверху, затем по updatedAt desc (§6.2).
final class ProjectStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue = AppDatabase.shared) {
        self.dbQueue = dbQueue
    }

    // MARK: - Projects

    func allProjects() throws -> [Project] {
        try dbQueue.read { db in
            try Project
                .order(
                    Project.Columns.isPinned.desc,
                    Project.Columns.updatedAt.desc
                )
                .fetchAll(db)
        }
    }

    @discardableResult
    func create(
        name: String,
        preset: RecordingPreset,
        storage: ProjectStorage = .managed
    ) throws -> Project {
        var project = Project(
            name: name,
            storage: storage,
            lastUsedPreset: preset
        )
        try dbQueue.write { db in
            try project.insert(db)
        }
        return project
    }

    func rename(_ project: Project, to newName: String) throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [trimmed, Date(), project.id.uuidString]
            )
        }
    }

    func setPinned(_ project: Project, _ pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET is_pinned = ?, updated_at = ? WHERE id = ?",
                arguments: [pinned, Date(), project.id.uuidString]
            )
        }
    }

    /// Сменить место хранения: «Подключить заново» или обновлённый bookmark/путь
    /// после переименования внешней папки (Phase 3). updated_at не трогаем —
    /// это не пользовательская активность, Проект не должен «всплывать».
    func updateStorage(_ project: Project, _ storage: ProjectStorage) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET storage_kind = ?, bookmark_data = ?, display_path = ? WHERE id = ?",
                arguments: [storage.kindString, storage.bookmark, storage.displayPath, project.id.uuidString]
            )
        }
    }

    func updateLastUsedPreset(_ project: Project, _ preset: RecordingPreset) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET last_used_preset = ?, updated_at = ? WHERE id = ?",
                arguments: [preset.rawValue, Date(), project.id.uuidString]
            )
        }
    }

    /// Удалить Проект. При `deleteRecordings = false` записи остаются с `projectId = nil`
    /// (ON DELETE SET NULL в schema). При `true` — записи и из БД удаляются;
    /// файлы на диске **не** трогает (это ответственность вызывающего, чтобы здесь
    /// не было IO в тестах). См. §6.8 брифа.
    func delete(_ project: Project, deleteRecordings: Bool) throws {
        try dbQueue.write { db in
            if deleteRecordings {
                try db.execute(
                    sql: "DELETE FROM recording WHERE project_id = ?",
                    arguments: [project.id.uuidString]
                )
            }
            try db.execute(
                sql: "DELETE FROM project WHERE id = ?",
                arguments: [project.id.uuidString]
            )
        }
    }

    // MARK: - Recordings (cross-store query)

    /// `nil` для project означает orphan-сегмент «Записи».
    func recordings(in project: Project?, limit: Int? = nil) throws -> [Recording] {
        try dbQueue.read { db in
            var request = Recording.all().order(Recording.Columns.createdAt.desc)
            if let project {
                request = request.filter(Recording.Columns.projectId == project.id.uuidString)
            } else {
                request = request.filter(Recording.Columns.projectId == nil)
            }
            if let limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    func move(recording: Recording, to project: Project?) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE recording SET project_id = ? WHERE id = ?",
                arguments: [project?.id.uuidString, recording.id.uuidString]
            )
            if let project {
                // Hint sidebar resort: проект «всплыл» наверх по recency.
                try db.execute(
                    sql: "UPDATE project SET updated_at = ? WHERE id = ?",
                    arguments: [Date(), project.id.uuidString]
                )
            }
        }
    }
}
