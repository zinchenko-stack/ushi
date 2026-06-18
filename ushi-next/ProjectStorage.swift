//
//  ProjectStorage.swift
//  UshiNext
//
//  Где физически живут файлы Проекта. См. §5 брифа.
//
//  Хранится денормализованно в таблице project тремя колонками:
//    storage_kind   TEXT     'managed' | 'external'
//    bookmark_data  BLOB?    security-scoped bookmark (только external)
//    display_path   TEXT?    человекочитаемый путь для UI (только external)
//

import Foundation

enum ProjectStorage: Equatable, Hashable {
    case managed
    case external(bookmark: Data, displayPath: String)

    var kindString: String {
        switch self {
        case .managed:  return "managed"
        case .external: return "external"
        }
    }

    var bookmark: Data? {
        if case let .external(bm, _) = self { return bm }
        return nil
    }

    var displayPath: String? {
        if case let .external(_, p) = self { return p }
        return nil
    }

    /// Конструктор из денормализованных колонок БД.
    /// При несовпадении (kind=external без bookmark) возвращает .managed
    /// как безопасный fallback — invariant будет восстановлен при следующем save.
    static func decode(kind: String, bookmark: Data?, displayPath: String?) -> ProjectStorage {
        switch kind {
        case "external":
            guard let bm = bookmark, let path = displayPath else { return .managed }
            return .external(bookmark: bm, displayPath: path)
        default:
            return .managed
        }
    }
}
