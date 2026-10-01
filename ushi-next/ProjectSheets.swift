//
//  ProjectSheets.swift
//  UshiNext
//
//  Модалки Проектов: создание (§6.5, с Phase 3 — и в своей папке),
//  удаление (§6.8), прогресс переноса между дисками (Phase 3).
//

import SwiftUI

// MARK: - Новый проект

/// Либо вписываем название (проект внутри Ushi), либо выбираем папку — тогда
/// название берётся из её имени. Что записывать, не спрашиваем: новый проект
/// стартует с источниками последней записи, дальше запоминает свои.
struct CreateProjectSheet: View {
    let projects: ProjectsModel
    var onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    /// Название, вписанное руками. Не теряется, если выбрали и потом убрали папку.
    @State private var typedName = ""
    /// Выбранная папка (external-Проект). nil — проект внутри Ushi (managed).
    @State private var folder: URL?
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    /// Название будущего проекта: имя папки, если она выбрана.
    private var effectiveName: String {
        (folder?.lastPathComponent ?? typedName).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Новый проект")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Название")
                    .font(.headline)

                if let folder {
                    TextField("", text: .constant(folder.lastPathComponent))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)

                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(ProjectFolders.displayPath(folder.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Другая…", action: pickFolder)
                            .buttonStyle(.link)
                        Button {
                            self.folder = nil
                            nameFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Не использовать папку — вписать название")
                    }
                    .font(.callout)

                    Text("Название проекта = имя папки. Переименуете проект — переименуется и папка.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Например, «Лекции»", text: $typedName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit(create)

                    HStack(spacing: 4) {
                        Text("или")
                            .foregroundStyle(.secondary)
                        Button("выберите папку на Mac…", action: pickFolder)
                            .buttonStyle(.link)
                        Text("— записи будут лежать в ней")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Отменить", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Создать", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(effectiveName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { nameFocused = true }
    }

    private func pickFolder() {
        guard let picked = FolderPicker.chooseFolder(message: "Выберите папку, где будут лежать записи проекта") else { return }
        folder = picked
        errorMessage = nil
    }

    private func create() {
        guard !effectiveName.isEmpty else { return }
        do {
            // Источники — как у последней записи; дальше проект запоминает свои.
            let project = try projects.create(name: effectiveName, preset: AppState.mostRecentPreset(), folder: folder)
            onCreated(project)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Удаление проекта

struct DeleteProjectSheet: View {
    let project: Project
    let recordingCount: Int
    let mediaSize: Int64
    var onDelete: (_ deleteRecordings: Bool) -> Void

    /// Выше этого объёма удаление файлов требует ввести имя Проекта (§6.8).
    static let typedConfirmThreshold: Int64 = 500 * 1024 * 1024

    @Environment(\.dismiss) private var dismiss
    @State private var deleteRecordings = false
    @State private var typedName = ""

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: mediaSize, countStyle: .file)
    }

    private var needsTypedConfirm: Bool {
        deleteRecordings && mediaSize > Self.typedConfirmThreshold
    }

    private var canDelete: Bool {
        !needsTypedConfirm || typedName.trimmingCharacters(in: .whitespaces) == project.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Удалить «\(project.name)»?")
                .font(.title2.weight(.semibold))

            Text(summary)
                .foregroundStyle(.secondary)

            if recordingCount > 0 {
                Toggle("Удалить также записи (\(sizeText))", isOn: $deleteRecordings)

                Text(deleteRecordings
                     ? "Записи и их файлы будут удалены без возможности восстановления."
                     : keepText)
                    .font(.callout)
                    .foregroundStyle(deleteRecordings ? Color.red : Color.secondary)

                if needsTypedConfirm {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Чтобы подтвердить, введите название проекта:")
                            .font(.callout)
                        TextField(project.name, text: $typedName)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Отменить", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Удалить", role: .destructive) {
                    onDelete(deleteRecordings)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canDelete)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    /// Что будет с записями, если их не удалять. Папку external-Проекта не трогаем.
    private var keepText: String {
        guard let path = project.storage.displayPath else {
            return "Если оставить — записи переместятся в «Записи»."
        }
        return "Если оставить — записи появятся в «Записях», а файлы останутся в папке \(ProjectFolders.displayPath(path))."
    }

    private var summary: String {
        guard recordingCount > 0 else { return "В проекте нет записей." }
        return "В проекте \(recordingCount) \(Self.recordingsWord(recordingCount)) (\(sizeText))."
    }

    /// «1 запись», «2 записи», «5 записей».
    static func recordingsWord(_ n: Int) -> String {
        let mod100 = n % 100
        let mod10 = n % 10
        if (11...14).contains(mod100) { return "записей" }
        switch mod10 {
        case 1: return "запись"
        case 2, 3, 4: return "записи"
        default: return "записей"
        }
    }
}

// MARK: - Перенос между дисками

/// Прогресс копирования записи на другой диск (Phase 3, п. 5). «Отменить» —
/// частичная копия удаляется, запись остаётся на старом месте.
struct MoveProgressSheet: View {
    let progress: MoveProgress
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Переношу запись")
                .font(.title3.weight(.semibold))
            Text("«\(progress.recordingTitle)» → «\(progress.destinationName)»")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ProgressView(value: progress.fraction)
            HStack {
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отменить", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled()
    }
}
