//
//  ProjectSheets.swift
//  UshiNext
//
//  Модалки Проектов (Phase 2): создание (§6.5) и удаление (§6.8).
//

import SwiftUI

// MARK: - Новый проект

struct CreateProjectSheet: View {
    let projects: ProjectsModel
    var onCreated: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var preset: RecordingPreset = RecordingPreset.systemAndMic.resolvedForThisMac
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
                // External-папки — Phase 3. Пока только managed.
                Picker("Где хранить", selection: .constant(0)) {
                    Text("Создать в Ushi").tag(0)
                    Text("Использовать существующую папку — скоро").tag(1)
                        .disabled(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
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

    private func create() {
        guard !trimmedName.isEmpty else { return }
        do {
            let project = try projects.create(name: trimmedName, preset: preset)
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
                     : "Если оставить — записи переместятся в «Записи».")
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
