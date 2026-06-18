//
//  RecordingPreset.swift
//  UshiNext
//
//  Пресет записи. Один глобальный (app.lastUsedPreset) + по одному
//  на каждый Проект (project.lastUsedPreset). См. §4, §7.2 брифа.
//

import Foundation

enum RecordingPreset: String, Codable, CaseIterable, Hashable {
    case micOnly        // только микрофон
    case systemAndMic   // системный звук + микрофон
    case screen         // экран + системный звук (+ микрофон если включён)

    /// Какие источники задействованы. Используется для immutable snapshot
    /// при создании записи (Recording.hasMicrophone/hasSystemAudio/hasScreen).
    var hasMicrophone: Bool {
        switch self {
        case .micOnly, .systemAndMic, .screen: return true
        }
    }

    var hasSystemAudio: Bool {
        switch self {
        case .micOnly: return false
        case .systemAndMic, .screen: return true
        }
    }

    var hasScreen: Bool {
        switch self {
        case .micOnly, .systemAndMic: return false
        case .screen: return true
        }
    }
}
