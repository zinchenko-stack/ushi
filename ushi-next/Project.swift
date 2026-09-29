//
//  Project.swift
//  UshiNext
//
//  Контейнер для записей одного контекста. См. §4 брифа.
//

import Foundation
import GRDB

struct Project: Identifiable, Hashable {
    var id: UUID
    var name: String
    var icon: String?           // SF Symbol name
    var colorHex: String?       // акцент в sidebar
    var storage: ProjectStorage
    var lastUsedPreset: RecordingPreset
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        icon: String? = nil,
        colorHex: String? = nil,
        storage: ProjectStorage = .managed,
        lastUsedPreset: RecordingPreset = .micOnly,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.storage = storage
        self.lastUsedPreset = lastUsedPreset
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - GRDB

extension Project: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "project"

    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let icon = Column("icon")
        static let colorHex = Column("color_hex")
        static let storageKind = Column("storage_kind")
        static let bookmarkData = Column("bookmark_data")
        static let displayPath = Column("display_path")
        static let lastUsedPreset = Column("last_used_preset")
        static let isPinned = Column("is_pinned")
        static let createdAt = Column("created_at")
        static let updatedAt = Column("updated_at")
    }

    init(row: Row) throws {
        let idString: String = row[Columns.id]
        guard let parsedID = UUID(uuidString: idString) else {
            throw DatabaseError(message: "Invalid UUID in project.id: \(idString)")
        }
        self.id = parsedID
        self.name = row[Columns.name]
        self.icon = row[Columns.icon]
        self.colorHex = row[Columns.colorHex]
        let storageKind: String = row[Columns.storageKind]
        let bookmark: Data? = row[Columns.bookmarkData]
        let displayPath: String? = row[Columns.displayPath]
        self.storage = ProjectStorage.decode(
            kind: storageKind,
            bookmark: bookmark,
            displayPath: displayPath
        )
        let presetRaw: String = row[Columns.lastUsedPreset]
        self.lastUsedPreset = (RecordingPreset(rawValue: presetRaw) ?? .micOnly).resolvedForThisMac
        self.isPinned = row[Columns.isPinned]
        self.createdAt = row[Columns.createdAt]
        self.updatedAt = row[Columns.updatedAt]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container[Columns.id] = id.uuidString
        container[Columns.name] = name
        container[Columns.icon] = icon
        container[Columns.colorHex] = colorHex
        container[Columns.storageKind] = storage.kindString
        container[Columns.bookmarkData] = storage.bookmark
        container[Columns.displayPath] = storage.displayPath
        container[Columns.lastUsedPreset] = lastUsedPreset.rawValue
        container[Columns.isPinned] = isPinned
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
    }
}
