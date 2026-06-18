//
//  HistoryView.swift
//  ushi
//

import SwiftUI

struct HistoryView: View {
    @Bindable var store: RecordingsStore
    @State private var selection: Recording.ID?
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all
    @State private var index = TranscriptIndex()

    /// Записи, прошедшие фильтр + поиск. Для совпавших — заодно отдаём match для превью.
    private var filteredEntries: [(recording: Recording, match: SearchMatch?)] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !query.isEmpty

        return store.recordings.compactMap { rec in
            guard matchesFilter(rec) else { return nil }
            if !isSearching { return (rec, nil) }
            guard let match = index.match(query: query, for: rec) else { return nil }
            return (rec, match)
        }
    }

    private var filteredRecordings: [Recording] {
        filteredEntries.map(\.recording)
    }

    /// Быстрый доступ к match по id записи — для рендера превью в строке.
    private var matchById: [Recording.ID: SearchMatch] {
        var result: [Recording.ID: SearchMatch] = [:]
        for entry in filteredEntries {
            if let m = entry.match { result[entry.recording.id] = m }
        }
        return result
    }

    private var groupedRecordings: [HistorySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRecordings) { recording in
            sectionKind(for: recording.createdAt, calendar: calendar)
        }

        return HistorySectionKind.allCases.compactMap { kind in
            guard let items = grouped[kind], !items.isEmpty else { return nil }
            return HistorySection(kind: kind, recordings: items)
        }
    }

    var body: some View {
        Group {
            if store.recordings.isEmpty {
                ContentUnavailableView(
                    "Записей пока нет",
                    systemImage: "waveform",
                    description: Text("Перейдите в раздел «Запись», чтобы начать.")
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        Picker("", selection: $filter) {
                            ForEach(HistoryFilter.allCases) { item in
                                Text(item.title).tag(item)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 320)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if groupedRecordings.isEmpty {
                        ContentUnavailableView(
                            "Ничего не найдено",
                            systemImage: "magnifyingglass",
                            description: Text("Попробуйте изменить запрос или фильтр.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selection) {
                            ForEach(groupedRecordings) { section in
                                Section(section.kind.title) {
                                    ForEach(section.recordings) { rec in
                                        NavigationLink(value: rec) {
                                            RecordingRow(recording: rec, match: matchById[rec.id])
                                        }
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
        }
        .navigationTitle("Записи")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Поиск по названию и тексту")
        .task(id: store.recordings.map { "\($0.id)|\($0.transcriptFileName ?? "")|\($0.status.rawValue)" }) {
            // Срабатывает при добавлении/удалении записи и при появлении/смене транскрипта.
            // Тяжёлое IO внутри индекса делается в фоне.
            index.sync(with: store.recordings)
        }
    }

    private func matchesFilter(_ recording: Recording) -> Bool {
        switch filter {
        case .all:
            true
        case .audio:
            !recording.audioFileName.lowercased().hasSuffix(".mov")
        case .video:
            recording.audioFileName.lowercased().hasSuffix(".mov")
        }
    }

    private func sectionKind(for date: Date, calendar: Calendar) -> HistorySectionKind {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }

        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()), date >= weekAgo {
            return .thisWeek
        }

        return .earlier
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case audio
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Все"
        case .audio: return "Аудио"
        case .video: return "Видео"
        }
    }
}

private enum HistorySectionKind: CaseIterable, Identifiable {
    case today
    case yesterday
    case thisWeek
    case earlier

    var id: String { title }

    var title: String {
        switch self {
        case .today: return "Сегодня"
        case .yesterday: return "Вчера"
        case .thisWeek: return "На этой неделе"
        case .earlier: return "Ранее"
        }
    }
}

private struct HistorySection: Identifiable {
    let kind: HistorySectionKind
    let recordings: [Recording]

    var id: String { kind.id }
}

private struct RecordingRow: View {
    let recording: Recording
    let match: SearchMatch?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                Image(isVideo ? "VideoPlayer" : "SoundWaves")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.primary)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(height: 20)

                subtitleView
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Подпись: либо превью-сниппет с подсветкой (если поиск совпал в транскрипте),
    /// либо обычная мета-строка (дата · длительность · опц. статус).
    @ViewBuilder
    private var subtitleView: some View {
        if let preview = transcriptPreview {
            Text(preview)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            HStack(spacing: 4) {
                Text(metaText)
                    .foregroundStyle(.secondary)
                if let statusText {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(statusText)
                        .foregroundStyle(statusColor)
                }
            }
            .font(.system(size: 13))
            .lineLimit(1)
        }
    }

    /// Кусок транскрипта вокруг первого матча (≈80 символов), с подсветкой найденных токенов.
    private var transcriptPreview: AttributedString? {
        guard let match,
              let text = match.transcriptText,
              let hit = match.transcriptHitRange else { return nil }
        return Self.buildPreview(text: text, around: hit, tokens: match.tokens)
    }

    private static func buildPreview(
        text: String,
        around hit: Range<String.Index>,
        tokens: [String]
    ) -> AttributedString {
        // ±40 символов вокруг матча с обрезкой по границам слов.
        let windowChars = 40
        let lower = clampWordBoundary(
            text: text,
            index: text.index(hit.lowerBound, offsetBy: -windowChars, limitedBy: text.startIndex)
                ?? text.startIndex,
            forward: true
        )
        let upper = clampWordBoundary(
            text: text,
            index: text.index(hit.upperBound, offsetBy: windowChars, limitedBy: text.endIndex)
                ?? text.endIndex,
            forward: false
        )

        var snippet = String(text[lower..<upper])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        if lower != text.startIndex { snippet = "…" + snippet }
        if upper != text.endIndex   { snippet = snippet + "…" }

        // Подсветка каждого токена в собранном сниппете (жирным).
        var attr = AttributedString(snippet)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for token in tokens {
            var search = attr.startIndex..<attr.endIndex
            while let range = attr[search].range(of: token, options: options) {
                attr[range].font = .system(size: 13, weight: .semibold)
                attr[range].foregroundColor = .primary
                search = range.upperBound..<attr.endIndex
            }
        }
        return attr
    }

    /// Двигает индекс к ближайшей пробельной границе, чтобы не резать слово пополам.
    private static func clampWordBoundary(
        text: String,
        index: String.Index,
        forward: Bool
    ) -> String.Index {
        var i = index
        if forward {
            while i < text.endIndex, !text[i].isWhitespace {
                i = text.index(after: i)
            }
        } else {
            while i > text.startIndex {
                let prev = text.index(before: i)
                if text[prev].isWhitespace { break }
                i = prev
            }
        }
        return i
    }

    private var isVideo: Bool {
        recording.audioFileName.lowercased().hasSuffix(".mov")
    }

    /// «Сегодня, 15:38 · 4 с» / «Вчера, 15:38 · 1 мин 12 с» / «13 июня, 15:04 · …»
    private var metaText: String {
        "\(relativeDate) · \(formatDuration(recording.duration))"
    }

    private var relativeDate: String {
        let locale = Locale(identifier: "ru_RU")
        let time = recording.createdAt.formatted(
            .dateTime.hour().minute().locale(locale)
        )

        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let recDay = cal.startOfDay(for: recording.createdAt)
        let days = cal.dateComponents([.day], from: recDay, to: today).day ?? 0

        let prefix: String
        switch days {
        case 0:
            prefix = "Сегодня"
        case 1:
            prefix = "Вчера"
        case 2...6:
            // На этой неделе — день недели с большой буквы.
            let weekday = recording.createdAt.formatted(
                .dateTime.weekday(.wide).locale(locale)
            )
            prefix = weekday.prefix(1).uppercased() + weekday.dropFirst()
        default:
            prefix = recording.createdAt.formatted(
                .dateTime.day().month(.wide).locale(locale)
            )
        }
        return "\(prefix), \(time)"
    }

    private var statusText: String? {
        switch recording.status {
        case .pending, .transcribing: return "транскрибируется…"
        case .done:                   return nil
        case .failed:                 return "ошибка"
        }
    }

    private var statusColor: Color {
        recording.status == .failed ? .red : .orange
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин \(s) с" }
        return "\(s) с"
    }
}
