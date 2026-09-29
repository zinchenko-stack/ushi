//
//  SidebarViewModel.swift
//  UshiNext
//
//  Тонкая прокладка между sidebar и Store-слоем (§8 брифа): отдаёт Проекты,
//  последние записи по секциям и держит UI-состояние аккордеона, inline-rename
//  и модалок. Сама ничего не пишет на диск — всё уходит в ProjectsModel /
//  RecordingsStore.
//

import Foundation
import AppKit
import Observation

/// Что показано в правой панели.
enum MainSelection: Hashable {
    case home                 // hero «Начать запись»
    case search               // все записи + поиск (старый HistoryView, до Phase 4)
    case settings
    case recording(UUID)
}

@MainActor
@Observable
final class SidebarViewModel {
    let controller: RecordingController

    nonisolated static let recentLimit = 5

    // MARK: Аккордеон

    /// Свёрнутые Проекты. По умолчанию все раскрыты (§6.2), поэтому храним исключения.
    private(set) var collapsedProjectIDs: Set<UUID> {
        didSet { Self.saveCollapsed(collapsedProjectIDs) }
    }
    var isInboxExpanded = true

    /// Секции, где нажали «Показать больше» (ключ — id Проекта, nil — «Записи»).
    private var expandedAll: Set<UUID?> = []

    // MARK: Inline-rename и модалки

    var renamingProjectID: UUID?
    var renamingRecordingID: UUID?

    var isCreatingProject = false
    /// Запись, которую перенести в Проект сразу после его создания
    /// («Переместить в → Создать проект…», §6.7).
    var recordingToMoveAfterCreate: Recording?

    var projectPendingDeletion: Project?
    var recordingPendingDeletion: Recording?

    var alertMessage: String?

    init(controller: RecordingController) {
        self.controller = controller
        self.collapsedProjectIDs = Self.loadCollapsed()
    }

    private var store: RecordingsStore { controller.store }
    private var projectsModel: ProjectsModel { controller.projects }

    // MARK: - Данные

    var pinnedAndSortedProjects: [Project] { projectsModel.projects }

    /// Последние записи секции. `project == nil` — «Записи» (orphan).
    func recentRecordings(in project: Project?) -> [Recording] {
        let all = store.recordings(inProject: project?.id)
        return isShowingAll(project) ? all : Array(all.prefix(Self.recentLimit))
    }

    func orphanRecordings(limit: Int = SidebarViewModel.recentLimit) -> [Recording] {
        Array(store.recordings(inProject: nil).prefix(limit))
    }

    func totalCount(in project: Project?) -> Int {
        store.recordings(inProject: project?.id).count
    }

    func hasMore(in project: Project?) -> Bool {
        totalCount(in: project) > Self.recentLimit
    }

    func isShowingAll(_ project: Project?) -> Bool {
        expandedAll.contains(project?.id)
    }

    func toggleShowAll(_ project: Project?) {
        if expandedAll.contains(project?.id) {
            expandedAll.remove(project?.id)
        } else {
            expandedAll.insert(project?.id)
        }
    }

    func isExpanded(_ project: Project) -> Bool {
        !collapsedProjectIDs.contains(project.id)
    }

    func setExpanded(_ project: Project, _ expanded: Bool) {
        if expanded {
            collapsedProjectIDs.remove(project.id)
        } else {
            collapsedProjectIDs.insert(project.id)
        }
    }

    // MARK: - Действия с Проектами

    func togglePinned(_ project: Project) {
        projectsModel.togglePinned(project)
    }

    func revealInFinder(_ project: Project) {
        do {
            try projectsModel.revealInFinder(project)
        } catch {
            projectsModel.refreshFolders()
            alertMessage = error.localizedDescription
        }
    }

    func commitRename(_ project: Project, to name: String) {
        renamingProjectID = nil
        projectsModel.rename(project, to: name)
    }

    func startCreatingProject(thenMove recording: Recording? = nil) {
        recordingToMoveAfterCreate = recording
        isCreatingProject = true
    }

    /// Вызывается модалкой после создания Проекта.
    func didCreateProject(_ project: Project) {
        if let rec = recordingToMoveAfterCreate {
            move(rec, to: project)
        }
        recordingToMoveAfterCreate = nil
    }

    func deleteProject(_ project: Project, deleteRecordings: Bool) {
        Task {
            do {
                try await projectsModel.delete(project, deleteRecordings: deleteRecordings, recordings: store)
                collapsedProjectIDs.remove(project.id)
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func isAvailable(_ project: Project) -> Bool {
        projectsModel.isAvailable(project)
    }

    /// Путь папки external-Проекта для подсказки («~/Documents/Психолог»). nil — managed.
    func folderPath(of project: Project) -> String? {
        project.storage.displayPath.map(ProjectFolders.displayPath)
    }

    /// «Подключить заново…» (§7.6): выбрать папку взамен пропавшей.
    func reconnect(_ project: Project) {
        guard let folder = FolderPicker.chooseFolder(
            message: "Выберите папку для проекта «\(project.name)»"
        ) else { return }
        do {
            try projectsModel.reconnect(project, to: folder, recordings: store)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Действия с записями

    func move(_ recording: Recording, to project: Project?) {
        Task {
            do {
                try await store.move(recording, to: project)
                projectsModel.reload()
            } catch FileMoverError.cancelled {
                // Юзер сам отменил — сообщать нечего, запись на месте.
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    func commitRename(_ recording: Recording, to title: String) {
        renamingRecordingID = nil
        store.rename(recording, to: title)
    }

    func revealInFinder(_ recording: Recording) {
        guard let url = store.mediaURL(for: recording) else {
            alertMessage = "Файл записи не найден на диске."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func delete(_ recording: Recording) {
        store.delete(recording)
    }

    // MARK: - Хранение свёрнутых Проектов

    private static let collapsedKey = "sidebar.collapsedProjects"

    private static func loadCollapsed() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private static func saveCollapsed(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: collapsedKey)
    }
}

// MARK: - Относительное время для строк sidebar («2ч», «1д», «3н»)

enum RelativeTime {
    static func short(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        let days = hours / 24
        let weeks = days / 7

        if minutes < 1 { return "сейчас" }
        if hours < 1 { return "\(minutes)м" }
        if days < 1 { return "\(hours)ч" }
        if weeks < 1 { return "\(days)д" }
        if days < 60 { return "\(weeks)н" }
        return "\(days / 30)мес"
    }
}
