//
//  Database.swift
//  UshiNext
//
//  Единая точка доступа к SQLite через GRDB. См. §8 брифа (Persistence-слой).
//  Схема версионируется через DatabaseMigrator.
//

import Foundation
import GRDB

enum AppDatabase {
    /// Production-инстанс. Лежит в Application Support/UshiNext/store.sqlite.
    /// Открывается лениво при первом обращении и переживает на всё время жизни процесса.
    static let shared: DatabaseQueue = {
        do {
            let folder = try AppSettings.metadataDirectory()
            let url = folder.appendingPathComponent("store.sqlite")
            let queue = try DatabaseQueue(path: url.path)
            try migrator.migrate(queue)
            return queue
        } catch {
            fatalError("Failed to open store.sqlite: \(error)")
        }
    }()

    /// Открыть БД по конкретному пути — для тестов.
    static func open(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try migrator.migrate(queue)
        return queue
    }

    /// Открыть in-memory БД — для unit-тестов без файлов.
    static func makeInMemory() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return queue
    }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        #if DEBUG
        // В DEBUG разрешаем eraseDatabaseOnSchemaChange — упрощает итерации
        // над схемой во время разработки. В Release миграции строгие.
        m.eraseDatabaseOnSchemaChange = true
        #endif

        m.registerMigration("v1_initial") { db in
            try db.create(table: "project") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("icon", .text)
                t.column("color_hex", .text)
                t.column("storage_kind", .text).notNull().defaults(to: "managed")
                t.column("bookmark_data", .blob)
                t.column("display_path", .text)
                t.column("last_used_preset", .text).notNull().defaults(to: "micOnly")
                t.column("is_pinned", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            try db.create(table: "recording") { t in
                t.column("id", .text).primaryKey()
                t.column("project_id", .text)
                    .references("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("file_url", .text).notNull()
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()

                // Immutable snapshot пресета на момент создания записи (§4 брифа).
                t.column("preset_snapshot", .text).notNull()
                t.column("has_microphone", .boolean).notNull().defaults(to: true)
                t.column("has_system_audio", .boolean).notNull().defaults(to: false)
                t.column("has_screen", .boolean).notNull().defaults(to: false)

                t.column("title_source", .text).notNull().defaults(to: "fallback")
                t.column("transcript_status", .text).notNull().defaults(to: "pending")

                // App-specific колонки, сохраняющие текущую функциональность
                // (bookmark-резолверы, политика автоудаления, transcription pipeline).
                // Брифом не описаны, но без них регрессии в UI/файловой работе.
                t.column("storage_folder_path", .text)
                t.column("audio_file_name", .text).notNull().defaults(to: "")
                t.column("transcript_file_name", .text)
                t.column("audio_removed", .boolean).notNull().defaults(to: false)
                t.column("audio_bookmark", .blob)
                t.column("transcript_bookmark", .blob)
                t.column("processing_status", .text).notNull().defaults(to: "pending")
            }
            try db.create(
                indexOn: "recording",
                columns: ["project_id", "created_at"]
            )

            try db.create(table: "app_state") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        // Разметка «Я / Собеседник»: имя стерео-дорожки в папке voices/.
        m.registerMigration("v2_voice_track") { db in
            try db.alter(table: "recording") { t in
                t.add(column: "voice_track_file_name", .text)
            }
        }

        return m
    }
}
