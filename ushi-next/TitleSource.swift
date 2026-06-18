//
//  TitleSource.swift
//  UshiNext
//
//  Откуда взялся title записи. См. §4, §7.3 брифа.
//

import Foundation

enum TitleSource: String, Codable, Hashable {
    case auto       // первое предложение из whisper-транскрипта
    case manual     // юзер переименовал руками
    case fallback   // whisper не сработал или ещё не отработал — авто-имя «{дата}»
}

/// Статус транскрипции, как он хранится в DB-колонке `transcript_status`.
/// Отдельно от `ProcessingStatus` в Recording — это конечный статус для UI/поиска,
/// без промежуточных «transcribing». См. §4 брифа.
enum TranscriptStatus: String, Codable, Hashable {
    case pending
    case done
    case failed
}
