//
//  AppState.swift
//  UshiNext
//
//  Глобальное состояние приложения, не привязанное к Проекту. См. §6.4, §7.2 брифа.
//  Лежит в таблице app_state как простой key-value словарь — это удобно для
//  добавления новых полей без миграции схемы.
//

import Foundation
import GRDB

enum AppState {
    /// Ключи, под которыми храним поля в app_state. Перечислены здесь,
    /// чтобы не разъезжаться: и читатель и писатель ссылаются на одну константу.
    enum Key {
        static let lastUsedPreset = "global_last_preset"
    }

    /// Глобальный «последний использованный» пресет (для orphan-Записей и Hero-экрана).
    /// Обновляется после каждой записи **без** Проекта; для записей **с** Проектом
    /// обновляется `project.lastUsedPreset` — это другая колонка в другой таблице.
    static func lastUsedPreset(in db: Database) throws -> RecordingPreset {
        let raw: String? = try String.fetchOne(
            db,
            sql: "SELECT value FROM app_state WHERE key = ?",
            arguments: [Key.lastUsedPreset]
        )
        guard let raw, let preset = RecordingPreset(rawValue: raw) else {
            return .default
        }
        return preset
    }

    static func setLastUsedPreset(_ preset: RecordingPreset, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO app_state (key, value) VALUES (?, ?) " +
                 "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [Key.lastUsedPreset, preset.rawValue]
        )
    }

    // MARK: - Удобные обёртки на shared DB

    static func lastUsedPreset() -> RecordingPreset {
        ((try? AppDatabase.shared.read { try lastUsedPreset(in: $0) }) ?? .default).resolvedForThisMac
    }

    static func setLastUsedPreset(_ preset: RecordingPreset) {
        try? AppDatabase.shared.write { try setLastUsedPreset(preset, in: $0) }
    }
}
