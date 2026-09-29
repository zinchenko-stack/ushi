//
//  AutoTitle.swift
//  UshiNext
//
//  Авто-название записи из транскрипта (Phase 4, §7.3 брифа): первое осмысленное
//  предложение, ~5–12 слов. Если осмысленного текста нет (тишина, музыка,
//  галлюцинации whisper) — nil, и остаётся fallback-имя.
//
//  Берём готовый полный транскрипт, а не отдельный прогон первых 30 секунд:
//  whisper и так запускается сразу после остановки записи, второй прогон
//  удвоил бы нагрузку ради пары минут выигрыша на длинных записях.
//

import Foundation

nonisolated enum AutoTitle {
    static let maxWords = 12
    static let minWords = 3
    static let maxLength = 80

    /// Название из текста транскрипта. nil — ничего подходящего.
    static func make(fromTranscript raw: String) -> String? {
        let text = cleaned(raw)
        guard !text.isEmpty else { return nil }

        for sentence in sentences(in: text) {
            let s = strippingLeadingFillers(sentence)
            let words = s.split(whereSeparator: \.isWhitespace)
            guard words.count >= minWords, !isHallucination(s) else { continue }
            return finalize(words: words)
        }
        return nil
    }

    // MARK: - Шаги

    /// Одна строка без переносов, без «[музыка]», «(смех)», «*аплодисменты*».
    private static func cleaned(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Предложения по «.», «!», «?», «…». Знак остаётся при предложении.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ".!?…".contains(ch) {
                let t = current.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { result.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    /// Слова-паразиты в начале фразы: «Ну, так, эээ, давайте начнём» → «давайте начнём».
    private static let fillers: Set<String> = [
        "ну", "так", "итак", "вот", "короче", "значит", "эээ", "ээ", "э", "мм", "ммм", "ага",
        "да", "ок", "окей", "слушай", "слушайте", "смотри", "смотрите", "алло", "угу",
        "so", "well", "um", "uh", "okay", "ok", "like",
    ]

    private static func strippingLeadingFillers(_ sentence: String) -> String {
        var words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first {
            let bare = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
            guard fillers.contains(bare), words.count > 1 else { break }
            words.removeFirst()
        }
        return words.joined(separator: " ")
    }

    /// Типичные «галлюцинации» whisper на тишине и музыке.
    private static let hallucinationMarkers = [
        "субтитр", "продолжение следует", "спасибо за просмотр", "подписывайтесь",
        "редактор субтитров", "корректор", "thanks for watching", "subscribe", "subtitles by",
    ]

    private static func isHallucination(_ s: String) -> Bool {
        let lower = s.lowercased()
        return hallucinationMarkers.contains { lower.contains($0) }
    }

    /// Обрезка до 12 слов и 80 символов, заглавная первая буква, без точки в конце.
    private static func finalize(words: [Substring]) -> String {
        var truncated = words.count > maxWords
        var title = words.prefix(maxWords).joined(separator: " ")
        if title.count > maxLength {
            truncated = true
            title = String(title.prefix(maxLength))
            if let lastSpace = title.lastIndex(of: " ") { title = String(title[..<lastSpace]) }
        }
        // Хвостовые запятые/точки убираем; «?» и «!» оставляем — они часть смысла.
        while let last = title.last, ",;:.…—-".contains(last) { title.removeLast() }
        if truncated { title += "…" }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}
