//
//  Shims.swift
//  UshiNextCore (test-only)
//
//  Минимальные заглушки для типов из app-target, на которые ссылаются
//  Recording.swift / Database.shared. В юнит-тестах ProjectStore мы не трогаем
//  ни файловую систему через AppSettings, ни bookmark-резолверы — используем
//  in-memory DB. Эти shim-ы существуют только чтобы файлы скомпилировались.
//

import Foundation

enum AppSettings {
    static func metadataDirectory() throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }
    static func defaultRecordingsDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }
    static func transcriptsDirectory() throws -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
    }
}

enum FileBookmark {
    static func resolve(_ data: Data) -> (url: URL, freshBookmark: Data?)? { nil }
    static func create(from url: URL) -> Data { Data() }
}
