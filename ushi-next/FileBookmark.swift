//
//  FileBookmark.swift
//  ushi
//
//  Хелпер для NSURL bookmark data — «штрих-кода» файла, который выживает
//  переименование, перемещение в подпапки и переименование родительских папок.
//  Не security-scoped (ushi не sandboxed).
//

import Foundation

enum FileBookmark {
    /// Создать bookmark из URL. Возвращает nil если файла нет или произошла ошибка.
    static func create(from url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return nil
        }
    }

    /// Разрешить bookmark в актуальный URL.
    /// Возвращает (url, freshBookmark): url — найденный файл; freshBookmark — обновлённая
    /// версия bookmark, которую следует сохранить, если bookmark был stale (изменился
    /// inode или volume переподключился). nil если файл не найден совсем.
    static func resolve(_ data: Data) -> (url: URL, freshBookmark: Data?)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let fresh: Data? = isStale ? create(from: url) : nil
            return (url, fresh)
        } catch {
            return nil
        }
    }
}
