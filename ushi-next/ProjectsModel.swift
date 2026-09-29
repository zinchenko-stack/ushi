//
//  ProjectsModel.swift
//  UshiNext
//
//  @Observable-обёртка над ProjectStore для UI (Phase 2–3). Держит отсортированный
//  список Проектов в памяти и перечитывает его после каждой мутации.
//  Phase 3: external-Проекты — проверка папок (degraded state, §7.6)
//  и «Подключить заново».
//  Операции, затрагивающие записи (удаление Проекта), координирует с
//  RecordingsStore — см. комментарий там про кэш.
//

import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class ProjectsModel {
    @ObservationIgnored private let store: ProjectStore

    /// Закреплённые сверху, дальше по updatedAt desc (§6.2).
    private(set) var projects: [Project] = []

    /// External-Проекты, чью папку не удалось найти (удалили, переименовали
    /// так, что bookmark не резолвится, отключили диск).
    private(set) var unavailableProjectIDs: Set<UUID> = []

    init(store: ProjectStore? = nil) {
        self.store = store ?? ProjectStore()
        reload()
        refreshFolders()
    }

    func reload() {
        do {
            projects = try store.allProjects()
        } catch {
            print("❌ projects load failed: \(error.localizedDescription)")
        }
    }

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func isAvailable(_ project: Project) -> Bool {
        !unavailableProjectIDs.contains(project.id)
    }

    // MARK: - Папки external-Проектов

    /// Проверить папки всех external-Проектов (§10 Phase 3, п. 2). Зовём на старте
    /// и когда приложение становится активным — юзер мог что-то сделать в Finder.
    /// Если папку переименовали или перенесли — обновляем путь в БД.
    func refreshFolders() {
        var unavailable: Set<UUID> = []
        var changed = false
        for project in projects {
            guard case let .external(bookmark, displayPath) = project.storage else { continue }
            guard let res = ProjectFolders.resolveExternal(bookmark: bookmark, displayPath: displayPath) else {
                unavailable.insert(project.id)
                continue
            }
            if let updated = res.updatedStorage {
                try? store.updateStorage(project, updated)
                changed = true
            }
        }
        if unavailable != unavailableProjectIDs { unavailableProjectIDs = unavailable }
        if changed { reload() }
    }

    /// «Подключить заново…»: выбранная папка заменяет потерянную. Записи Проекта,
    /// чьи файлы лежат в новой папке, снова находятся.
    func reconnect(_ project: Project, to folder: URL, recordings: RecordingsStore) throws {
        let storage = try ProjectFolders.externalStorage(for: folder)
        try store.updateStorage(project, storage)
        reload()
        refreshFolders()
        if let updated = self.project(id: project.id),
           let dir = try? ProjectFolders.recordingsDirectory(for: updated) {
            recordings.relink(projectID: project.id, toDirectory: dir)
        }
    }

    // MARK: - Мутации

    @discardableResult
    func create(name: String, preset: RecordingPreset, folder: URL? = nil) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectsModelError.emptyName }
        let storage = try folder.map(ProjectFolders.externalStorage(for:)) ?? .managed
        let project = try store.create(name: trimmed, preset: preset, storage: storage)
        // Папку recordings/ создаём сразу, чтобы «Показать в Finder» работал и у пустого Проекта.
        _ = try? ProjectFolders.recordingsDirectory(for: project)
        reload()
        return project
    }

    func rename(_ project: Project, to newName: String) {
        try? store.rename(project, to: newName)
        reload()
    }

    func togglePinned(_ project: Project) {
        try? store.setPinned(project, !project.isPinned)
        reload()
    }

    func updateLastUsedPreset(_ project: Project, _ preset: RecordingPreset) {
        guard project.lastUsedPreset != preset else { return }
        try? store.updateLastUsedPreset(project, preset)
        reload()
    }

    /// Удаление Проекта (§6.8). Записи либо удаляются вместе с файлами, либо
    /// переезжают в «Записи». Папка managed-Проекта уходит в Корзину; папку
    /// external-Проекта не трогаем — это папка юзера.
    func delete(_ project: Project, deleteRecordings: Bool, recordings: RecordingsStore) async throws {
        let busy = recordings.recordings(inProject: project.id).contains { !recordings.canMove($0) }
        guard !busy else { throw ProjectsModelError.transcriptionInProgress }

        let isManaged = project.storage == .managed
        await recordings.detachRecordings(
            fromProject: project.id,
            deleteFiles: deleteRecordings,
            moveFiles: isManaged
        )
        try store.delete(project, deleteRecordings: false)

        if isManaged,
           let dir = try? AppSettings.projectDirectory(projectId: project.id),
           FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
        unavailableProjectIDs.remove(project.id)
        reload()
    }

    /// Открыть папку Проекта в Finder (§6.6).
    func revealInFinder(_ project: Project) throws {
        let dir = try ProjectFolders.recordingsDirectory(for: project)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }
}

enum ProjectsModelError: LocalizedError {
    case emptyName
    case transcriptionInProgress

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Введите название проекта."
        case .transcriptionInProgress:
            return "В проекте идёт расшифровка записи. Удалить проект можно после её окончания."
        }
    }
}
