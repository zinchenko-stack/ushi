//
//  SettingsView.swift
//  ushi
//
//  Настройки приложения. Form/Section/LabeledContent — нативные macOS-компоненты.
//

import SwiftUI
import AppKit

struct SettingsView: View {

    // Подтверждение, когда срок хранения уменьшают (часть файлов уйдёт при следующем запуске).
    private enum PendingConfirmation: Identifiable {
        case shortenAudio(newDays: Int, previousDays: Int)
        case shortenVideo(newDays: Int, previousDays: Int)

        var id: String {
            switch self {
            case .shortenAudio(let n, let p): return "audio-\(p)-\(n)"
            case .shortenVideo(let n, let p): return "video-\(p)-\(n)"
            }
        }

        var title: String {
            switch self {
            case .shortenAudio(let n, _): return "Хранить аудио \(dayWord(n))?"
            case .shortenVideo(let n, _): return "Хранить видео \(dayWord(n))?"
            }
        }

        var message: String {
            switch self {
            case .shortenAudio(let n, _):
                return "Аудиозаписи старше \(dayWord(n)) будут удалены при следующем запуске."
            case .shortenVideo(let n, _):
                return "Видеозаписи старше \(dayWord(n)) будут удалены при следующем запуске."
            }
        }
    }

    @State private var folderURL = (try? AppSettings.recordingsDirectory())
        ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var videoQuality = AppSettings.videoQuality()
    @State private var autoDeleteAudio = AppSettings.autoDeleteAudio()
    @State private var autoDeleteVideo = AppSettings.autoDeleteVideo()
    @State private var audioDays = AppSettings.audioRetentionDays()
    @State private var videoDays = AppSettings.videoRetentionDays()
    @State private var folderError: String?
    @State private var pendingConfirmation: PendingConfirmation?

    var body: some View {
        Form {
            recordingSection
            qualitySection
            cleanupSection
        }
        .formStyle(.grouped)
        .navigationTitle("Настройки")
        .alert(
            pendingConfirmation?.title ?? "",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { revertPending() } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button("Отмена", role: .cancel) { revertPending() }
            Button("Подтвердить") { applyPending(confirmation) }
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    // MARK: - Запись (папка)

    private var recordingSection: some View {
        Section("Куда сохранять") {
            LabeledContent("Папка") {
                HStack(spacing: 6) {
                    Text(folderURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)

                    Button("Выбрать…") { chooseFolder() }

                    Menu {
                        Button("Открыть в Finder") { NSWorkspace.shared.open(folderURL) }
                        Button("Сбросить к стандартной") {
                            AppSettings.resetRecordingsDirectory()
                            refreshFolder()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            if let folderError {
                Text(folderError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Качество видео

    private var qualitySection: some View {
        Section("Качество видео") {
            Picker("Качество", selection: $videoQuality) {
                ForEach(VideoQuality.allCases) { q in
                    Text(q.title).tag(q)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: videoQuality) { _, new in
                AppSettings.setVideoQuality(new)
            }

            LabeledContent("Расход места") {
                Text(videoQuality.summary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Авто-очистка (аудио + видео в одной секции)

    private var cleanupSection: some View {
        Section {
            cleanupRow(
                title: "Аудио",
                enabled: $autoDeleteAudio,
                days: $audioDays,
                onToggle: { AppSettings.setAutoDeleteAudio($0) },
                onDaysChange: { old, new in
                    handleRetentionChange(old: old, new: new, isAudio: true)
                }
            )
            cleanupRow(
                title: "Видео",
                enabled: $autoDeleteVideo,
                days: $videoDays,
                onToggle: { AppSettings.setAutoDeleteVideo($0) },
                onDaysChange: { old, new in
                    handleRetentionChange(old: old, new: new, isAudio: false)
                }
            )
        } header: {
            Text("Автоматическая очистка")
        } footer: {
            Text("Транскрипты сохраняются отдельно — текст записи остаётся в истории даже после удаления исходного файла.")
        }
    }

    private func cleanupRow(
        title: String,
        enabled: Binding<Bool>,
        days: Binding<Int>,
        onToggle: @escaping (Bool) -> Void,
        onDaysChange: @escaping (Int, Int) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { enabled.wrappedValue },
                    set: { newValue in
                        enabled.wrappedValue = newValue
                        onToggle(newValue)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()

                Picker("", selection: days) {
                    ForEach(retentionOptions(currentValue: days.wrappedValue), id: \.self) { d in
                        Text(dayWord(d)).tag(d)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(!enabled.wrappedValue)
                .onChange(of: days.wrappedValue) { old, new in
                    onDaysChange(old, new)
                }
            }
        }
    }

    // MARK: - Папка: выбор/сброс

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Выбрать"
        panel.directoryURL = folderURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AppSettings.setRecordingsDirectory(url)
            folderURL = try AppSettings.recordingsDirectory()
            folderError = nil
        } catch {
            folderError = error.localizedDescription
        }
    }

    private func refreshFolder() {
        folderURL = (try? AppSettings.recordingsDirectory()) ?? folderURL
        folderError = nil
    }

    // MARK: - Срок хранения: применение / откат

    private func handleRetentionChange(old: Int, new: Int, isAudio: Bool) {
        if new < old {
            pendingConfirmation = isAudio
                ? .shortenAudio(newDays: new, previousDays: old)
                : .shortenVideo(newDays: new, previousDays: old)
        } else {
            if isAudio { AppSettings.setAudioRetentionDays(new) }
            else       { AppSettings.setVideoRetentionDays(new) }
        }
    }

    private func applyPending(_ confirmation: PendingConfirmation) {
        switch confirmation {
        case .shortenAudio(let new, _):
            audioDays = new
            AppSettings.setAudioRetentionDays(new)
        case .shortenVideo(let new, _):
            videoDays = new
            AppSettings.setVideoRetentionDays(new)
        }
        pendingConfirmation = nil
    }

    private func revertPending() {
        guard let confirmation = pendingConfirmation else { return }
        switch confirmation {
        case .shortenAudio(_, let previous): audioDays = previous
        case .shortenVideo(_, let previous): videoDays = previous
        }
        pendingConfirmation = nil
    }
}

// MARK: - Helpers

private func retentionOptions(currentValue: Int) -> [Int] {
    var options = [1, 7, 14, 30, 60, 90, 180, 365]
    if !options.contains(currentValue) {
        options.append(currentValue)
        options.sort()
    }
    return options
}

private func dayWord(_ value: Int) -> String {
    switch value % 100 {
    case 11...14:
        return "\(value) дней"
    default:
        switch value % 10 {
        case 1: return "\(value) день"
        case 2...4: return "\(value) дня"
        default: return "\(value) дней"
        }
    }
}
