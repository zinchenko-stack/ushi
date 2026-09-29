//
//  ProjectsModel.swift
//  UshiNext
//
//  @Observable-обёртка над ProjectStore для UI (Phase 2). Держит отсортированный
//  список Проектов в памяти и перечитывает его после каждой мутации.
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

    init(store: ProjectStore? = nil) {
        self.store = store ?? ProjectStore()
        reload()
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

    // MARK: - Мутации

    @discardableResult
    func create(name: String, preset: RecordingPreset) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectsModelError.emptyName }
        let project = try store.create(name: trimmed, preset: preset)
        // Папку создаём сразу, чтобы «Показать в Finder» работал и у пустого Проекта.
        _ = try? AppSettings.projectRecordingsDirectory(projectId: project.id)
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
    /// переезжают в «Записи». Папка managed-Проекта уходит в Корзину.
    func delete(_ project: Project, deleteRecordings: Bool, recordings: RecordingsStore) throws {
        let busy = recordings.recordings(inProject: project.id).contains { !recordings.canMove($0) }
        guard !busy else { throw ProjectsModelError.transcriptionInProgress }

        recordings.detachRecordings(fromProject: project.id, deleteFiles: deleteRecordings)
        try store.delete(project, deleteRecordings: false)

        if case .managed = project.storage,
           let dir = try? AppSettings.projectDirectory(projectId: project.id),
           FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        }
        reload()
    }

    /// Открыть папку Проекта в Finder (§6.6).
    func revealInFinder(_ project: Project) {
        guard let dir = try? AppSettings.projectRecordingsDirectory(projectId: project.id) else { return }
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
