//
//  ProjectSheets.swift
//  UshiNext
//
//  Модалки Проектов: создание (§6.5, с Phase 3 — и в своей папке),
//  удаление (§6.8), прогресс переноса между дисками (Phase 3).
//

import SwiftUI

// MARK: - Новый проект

struct CreateProjectSheet: View {
    let projects: ProjectsModel
    var onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var preset: RecordingPreset = RecordingPreset.default.resolvedForThisMac
    /// Выбранная папка для external-Проекта. nil — «Создать в Ushi» (managed).
    @State private var folder: URL?
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Новый проект")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Название")
                    .font(.headline)
                TextField("Например, «Лекции»", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onSubmit(create)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Что записываем")
                    .font(.headline)
                ForEach(RecordingPreset.Source.available, id: \.self) { source in
                    Toggle(isOn: $preset.binding(for: source)) {
                        Label(source.title, systemImage: source.systemImage)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!preset.canToggle(source))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Где хранить")
                    .font(.headline)
                Picker("Где хранить", selection: storageChoice) {
                    Text("Создать в Ushi").tag(false)
                    Text("Использовать существующую папку").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                if let folder {
                    HStack(spacing: 6) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(ProjectFolders.displayPath(folder.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Изменить…", action: pickFolder)
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                    .padding(.leading, 20)
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
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { nameFocused = true }
    }

    /// Радио «Где хранить»: выбор «существующей папки» сразу открывает Finder;
    /// если там нажали «Отмена» — остаёмся на «Создать в Ushi».
    private var storageChoice: Binding<Bool> {
        Binding(
            get: { folder != nil },
            set: { useFolder in
                if useFolder {
                    pickFolder()
                } else {
                    folder = nil
                }
            }
        )
    }

    private func pickFolder() {
        guard let picked = FolderPicker.chooseFolder(message: "Выберите папку, где будут лежать записи проекта") else { return }
        folder = picked
        // Имя по умолчанию — имя папки, если юзер ещё ничего не ввёл (§6.5).
        if trimmedName.isEmpty { name = picked.lastPathComponent }
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        do {
            let project = try projects.create(name: trimmedName, preset: preset, folder: folder)
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
