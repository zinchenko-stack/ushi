//
//  TranscriptIndex.swift
//  ushi
//
//  Поисковой индекс по транскриптам. В памяти держит сырой текст по id записи;
//  при изменении списка пере-читает с диска ТОЛЬКО новые/изменившиеся файлы
//  и делает это в фоне, не блокируя UI.
//
//  Матчинг — case-insensitive + diacritic-insensitive (ё↔е, ё↔Е и т.п. из коробки),
//  через String.range(of:options:), без своих нормализаций.
//

import Foundation
import Observation

/// Результат сопоставления запроса с одной записью.
struct SearchMatch {
    /// Где совпало в транскрипте — нужно для построения превью. nil если матч только по title.
    let transcriptHitRange: Range<String.Index>?
    /// Полный текст транскрипта (для рендера превью). nil если нет транскрипта в индексе.
    let transcriptText: String?
    /// Токены запроса в исходном виде — для подсветки в превью.
    let tokens: [String]
}

@Observable
final class TranscriptIndex {

    private struct Entry {
        let text: String
        let modDate: Date
    }

    /// id записи → запись индекса. Доступ только из MainActor (см. sync()).
    private var entries: [UUID: Entry] = [:]

    /// Тяжёлое IO живёт здесь, чтобы не мешать main.
    private let ioQueue = DispatchQueue(label: "ushi.transcript.index", qos: .utility)

    /// Чтобы не плодить параллельные синки на каждый чих.
    private var syncTask: Task<Void, Never>?

    // MARK: - Sync

    /// Сводит индекс со списком записей. Идемпотентно, можно звать на каждое изменение.
    /// Считает диск только для новых записей и для тех, у кого транскрипт обновился.
    /// Возвращается мгновенно — обновление состояния прилетит позже на MainActor.
    @MainActor
    func sync(with recordings: [Recording]) {
        syncTask?.cancel()
        let snapshot = entries
        syncTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let updated = await self.computeUpdatedIndex(recordings: recordings, current: snapshot)
            if Task.isCancelled { return }
            await MainActor.run { self.entries = updated }
        }
    }

    /// Бэкграунд-перерасчёт. Возвращает новый словарь, не трогая self.entries напрямую.
    private func computeUpdatedIndex(
        recordings: [Recording],
        current: [UUID: Entry]
    ) async -> [UUID: Entry] {
        await withCheckedContinuation { (cont: CheckedContinuation<[UUID: Entry], Never>) in
            ioQueue.async {
                let fm = FileManager.default
                var working: [UUID: Entry] = [:]

                for rec in recordings {
                    guard let name = rec.transcriptFileName else { continue }
                    let url = rec.storageDirectoryURL().appendingPathComponent(name)
                    guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                          let modDate = attrs[.modificationDate] as? Date else { continue }

                    // Уже есть и не устарел — переиспользуем из старого индекса.
                    if let existing = current[rec.id], existing.modDate >= modDate {
                        working[rec.id] = existing
                        continue
                    }
                    // Иначе читаем с диска.
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                    working[rec.id] = Entry(text: text, modDate: modDate)
                }
                cont.resume(returning: working)
            }
        }
    }

    // MARK: - Search

    /// Пробует сопоставить запрос с записью. Возвращает SearchMatch при попадании, иначе nil.
    /// Логика: запрос разбивается на токены по whitespace; запись подходит, если
    /// КАЖДЫЙ токен встречается в title или транскрипте.
    func match(query: String, for recording: Recording) -> SearchMatch? {
        let tokens = Self.tokenize(query)
        guard !tokens.isEmpty else { return nil }

        let title = recording.title
        let transcript = entries[recording.id]?.text ?? ""
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        var firstTranscriptHit: Range<String.Index>?

        for token in tokens {
            let titleHit = title.range(of: token, options: options) != nil
            let transcriptHit = transcript.range(of: token, options: options)

            if !titleHit && transcriptHit == nil {
                return nil   // токен не нашёлся ни там, ни там → запись не подходит
            }

            // Запомнить самое раннее попадание в транскрипт — для превью.
            if let hit = transcriptHit {
                if firstTranscriptHit == nil || hit.lowerBound < firstTranscriptHit!.lowerBound {
                    firstTranscriptHit = hit
                }
            }
        }

        return SearchMatch(
            transcriptHitRange: firstTranscriptHit,
            transcriptText: firstTranscriptHit != nil ? transcript : nil,
            tokens: tokens
        )
    }

    /// Разбивает запрос на токены по whitespace, чистит пустые.
    private static func tokenize(_ query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
