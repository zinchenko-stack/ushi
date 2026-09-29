//
//  SidebarView.swift
//  UshiNext
//
//  Sidebar Phase 2 (§6.1–6.3, §6.6–6.7 брифа): кнопка «Начать запись» + chip
//  пресета, поиск, аккордеон Проектов, секция «Записи», настройки внизу.
//  Иконки разделов — Mage Icons из Assets.xcassets (16pt, template).
//

import SwiftUI

struct SidebarView: View {
    @Bindable var model: SidebarViewModel
    @Binding var selection: MainSelection?

    private var controller: RecordingController { model.controller }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                // Обычный пункт меню, а не отдельная кнопка: ведёт на hero-экран,
                // где стартует запись. Во время записи показывает таймер.
                NewRecordingRow(controller: controller)
                    .tag(MainSelection.home)

                // Phase 4 заменит на глобальный поиск; пока ведёт в список всех записей
                // с поиском по названию и тексту, чтобы не потерять старую функцию.
                Label("Поиск", systemImage: "magnifyingglass")
                    .tag(MainSelection.search)

                Section {
                    if model.pinnedAndSortedProjects.isEmpty {
                        Button {
                            model.startCreatingProject()
                        } label: {
                            Label("Создать проект", systemImage: "plus")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(model.pinnedAndSortedProjects) { project in
                        projectGroup(project)
                    }
                } header: {
                    HStack {
                        Text("Проекты")
                        Spacer()
                        Button {
                            model.startCreatingProject()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.plain)
                        .help("Новый проект")
                    }
                }

                Section("Записи", isExpanded: $model.isInboxExpanded) {
                    recordingRows(in: nil)
                }
            }
            .listStyle(.sidebar)
            // Список обрезается ровно над «Настройками» — строки не наезжают на плашку.
            .clipped()

            // Настройки прижаты к низу: тот же фон sidebar, без разделителя.
            SettingsFooterRow(isSelected: selection == .settings) {
                selection = .settings
            }
        }
        .navigationTitle("Ushi")
        .sheet(isPresented: $model.isCreatingProject) {
            CreateProjectSheet(projects: controller.projects) { project in
                model.didCreateProject(project)
            }
        }
        .sheet(item: $model.projectPendingDeletion) { project in
            DeleteProjectSheet(
                project: project,
                recordingCount: model.totalCount(in: project),
                mediaSize: controller.store.mediaSize(ofProject: project.id)
            ) { deleteRecordings in
                model.deleteProject(project, deleteRecordings: deleteRecordings)
            }
        }
        .sheet(item: Binding(
            get: { controller.store.activeMove.map(IdentifiedMove.init) },
            set: { _ in }
        )) { move in
            MoveProgressSheet(progress: move.progress) {
                controller.store.cancelMove()
            }
        }
        // Юзер мог удалить или переименовать папку проекта в Finder — перепроверяем.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.projects.refreshFolders()
        }
        .confirmationDialog(
            "Удалить запись?",
            isPresented: Binding(
                get: { model.recordingPendingDeletion != nil },
                set: { if !$0 { model.recordingPendingDeletion = nil } }
            ),
            presenting: model.recordingPendingDeletion
        ) { rec in
            Button("Удалить", role: .destructive) {
                if selection == .recording(rec.id) { selection = .home }
                model.delete(rec)
            }
        } message: { rec in
            Text("«\(rec.title)» будет удалена вместе с файлом.")
        }
        .alert(
            "Не получилось",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    // MARK: - Проект

    private func projectGroup(_ project: Project) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { model.isExpanded(project) },
            set: { model.setExpanded(project, $0) }
        )) {
            recordingRows(in: project)
        } label: {
            ProjectRow(
                project: project,
                isAvailable: model.isAvailable(project),
                folderPath: model.folderPath(of: project),
                isRenaming: model.renamingProjectID == project.id,
                isRecordingHere: controller.isRecording && controller.activeProjectID == project.id,
                canStart: model.isAvailable(project)
                    && !controller.isRecording && !controller.isBusy && !controller.isCountingDown,
                onStart: {
                    selection = .home
                    Task { await controller.startInProject(project) }
                },
                onCommitRename: { model.commitRename(project, to: $0) },
                onCancelRename: { model.renamingProjectID = nil }
            ) {
                projectMenu(project)
            }
            .contextMenu { projectMenu(project) }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        if !model.isAvailable(project) {
            Button("Подключить заново…") {
                model.reconnect(project)
            }
            Divider()
        }
        Button("Загрузить аудио…") {
            model.importAudio(into: project)
        }
        .disabled(!model.isAvailable(project))
        Divider()
        Button(project.isPinned ? "Открепить" : "Закрепить") {
            model.togglePinned(project)
        }
        Button("Показать в Finder") {
            model.revealInFinder(project)
        }
        Button("Переименовать") {
            model.renamingProjectID = project.id
        }
        Divider()
        Button("Удалить…", role: .destructive) {
            model.projectPendingDeletion = project
        }
    }

    // MARK: - Записи секции

    @ViewBuilder
    private func recordingRows(in project: Project?) -> some View {
        let recent = model.recentRecordings(in: project)
        if recent.isEmpty {
            Text(project == nil ? "Здесь появятся записи без проекта" : "Пока нет записей")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        ForEach(recent) { rec in
            RecordingRow(
                recording: rec,
                isRenaming: model.renamingRecordingID == rec.id,
                onCommitRename: { model.commitRename(rec, to: $0) },
                onCancelRename: { model.renamingRecordingID = nil }
            )
            .tag(MainSelection.recording(rec.id))
            .contextMenu { recordingMenu(rec) }
        }
        if model.hasMore(in: project) {
            Button(model.isShowingAll(project) ? "Показать меньше" : "Показать больше →") {
                model.toggleShowAll(project)
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func recordingMenu(_ rec: Recording) -> some View {
        Menu("Переместить в") {
            ForEach(model.pinnedAndSortedProjects) { project in
                Button(project.name) { model.move(rec, to: project) }
                    .disabled(rec.projectId == project.id)
            }
            if !model.pinnedAndSortedProjects.isEmpty { Divider() }
            Button("Без проекта") { model.move(rec, to: nil) }
                .disabled(rec.projectId == nil)
            Divider()
            Button("Создать проект…") { model.startCreatingProject(thenMove: rec) }
        }
        Button("Переименовать") {
            model.renamingRecordingID = rec.id
        }
        Button("Показать в Finder") {
            model.revealInFinder(rec)
        }
        Divider()
        Button("Удалить", role: .destructive) {
            model.recordingPendingDeletion = rec
        }
    }
}

// MARK: - Пункт «Новая запись» (§6.4)

/// Строка sidebar, ведущая на hero-экран. Во время отсчёта и записи —
/// красная точка, таймер и Проект, куда идёт запись.
private struct NewRecordingRow: View {
    let controller: RecordingController

    var body: some View {
        HStack(spacing: 6) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.isRecording ? "Идёт запись" : "Новая запись")
                    if controller.isRecording || controller.isCountingDown {
                        Text(controller.activeProject?.name ?? "Записи")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: controller.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(controller.isRecording ? Color.red : Color.primary)
            }
            Spacer(minLength: 4)
            if let cd = controller.countdown {
                Text("\(cd)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if controller.isRecording {
                Text(formatTime(controller.recorder.elapsed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.red)
            }
        }
    }
}

extension Binding where Value == RecordingPreset {
    /// Галочка источника. Выключить последний звуковой источник нельзя —
    /// такое переключение молча игнорируется (пункт в UI и так disabled).
    func binding(for source: RecordingPreset.Source) -> Binding<Bool> {
        Binding<Bool>(
            get: { wrappedValue.contains(source) },
            set: { isOn in
                guard isOn != wrappedValue.contains(source),
                      let next = wrappedValue.toggling(source) else { return }
                wrappedValue = next
            }
        )
    }
}

// MARK: - Строка Проекта

private struct ProjectRow<MenuContent: View>: View {
    let project: Project
    /// false — папка external-Проекта пропала (degraded state, §7.6).
    let isAvailable: Bool
    /// Путь своей папки — в подсказке при наведении. nil — папка внутри Ushi.
    let folderPath: String?
    let isRenaming: Bool
    let isRecordingHere: Bool
    let canStart: Bool
    let onStart: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    @ViewBuilder let menu: () -> MenuContent

    @State private var isHovered = false

    private var iconName: String {
        if isRecordingHere { return "record.circle.fill" }
        if !isAvailable { return "exclamationmark.triangle.fill" }
        return folderPath == nil ? "folder" : "folder.badge.person.crop"
    }

    private var iconColor: Color {
        if isRecordingHere { return .red }
        if !isAvailable { return .yellow }
        return .secondary
    }

    private var helpText: String {
        if !isAvailable {
            return "Папка проекта недоступна. Правый клик → «Подключить заново…»"
        }
        return folderPath.map { "Папка: \($0)" } ?? project.name
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            if isRenaming {
                InlineRenameField(initial: project.name, onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                Text(project.name)
                    .lineLimit(1)
                    .foregroundStyle(isAvailable ? Color.primary : Color.secondary)
                if project.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            if isHovered && !isRenaming {
                Button(action: onStart) {
                    Image(systemName: "record.circle")
                        .foregroundStyle(canStart ? Color.red : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .help("Записать в «\(project.name)»")

                Menu {
                    menu()
                } label: {
                    Image(systemName: "ellipsis")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.primary)
                }
                .tint(.primary)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}

// MARK: - Строка записи

private struct RecordingRow: View {
    let recording: Recording
    let isRenaming: Bool
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                InlineRenameField(initial: recording.title, onCommit: onCommitRename, onCancel: onCancelRename)
            } else {
                Text(recording.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if recording.status == .transcribing {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(RelativeTime.short(since: recording.createdAt))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Inline rename

/// TextField на месте названия: Enter — сохранить, Esc или потеря фокуса — отменить.
struct InlineRenameField: View {
    let initial: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Название", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onAppear {
                text = initial
                focused = true
            }
            .onSubmit { onCommit(text) }
            .onExitCommand { onCancel() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { onCancel() }
            }
    }
}

/// Строка sidebar с фиксированным размером иконки 16pt (Label по умолчанию
/// масштабирует иконку с шрифтом, у Mage SVG это даёт слишком крупный значок).
private struct SidebarAssetRow: View {
    let title: String
    let imageName: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(imageName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }
}

private func formatTime(_ t: TimeInterval) -> String {
    let total = Int(t)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
        ? String(format: "%d:%02d:%02d", h, m, s)
        : String(format: "%02d:%02d", m, s)
}

/// Обёртка для `.sheet(item:)`: id стабилен, пока меняется процент,
/// иначе SwiftUI пересоздавал бы окно на каждом шаге прогресса.
private struct IdentifiedMove: Identifiable {
    let progress: MoveProgress
    var id: UUID { progress.recordingID }
}

// MARK: - Плашка «Настройки» внизу

/// Строка «Настройки», закреплённая под списком. Фон не свой — тот же материал
/// sidebar, поэтому цвет не отличается; выделение как у строк списка.
private struct SettingsFooterRow: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SidebarAssetRow(title: "Настройки", imageName: "Bolt")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.primary.opacity(0.1) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
