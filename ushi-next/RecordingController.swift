//
//  RecordingController.swift
//  ushi
//
//  Единая точка старта/стопа записи для окна и menu bar.
//  Phase 2: запись стартует с пресетом и целевым Проектом (или в «Записи»),
//  см. §7.1 брифа. Обратный отсчёт тоже живёт здесь, чтобы кнопка в sidebar,
//  ⏺ у Проекта и hero-экран делили одно состояние.
//

import Foundation
import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class RecordingController {
    let recorder: AudioRecorder
    let store: RecordingsStore
    let projects: ProjectsModel

    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var lastSavedRecording: Recording?

    /// Идёт обратный отсчёт перед стартом (3…2…1). nil — отсчёта нет.
    private(set) var countdown: Int?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    private let countdownStart = 3

    /// Куда и с каким пресетом пишется текущая (или готовящаяся) запись.
    private(set) var activePreset: RecordingPreset?
    private(set) var activeProjectID: UUID?

    /// Глобальный `app.lastUsedPreset` (§6.4, §13). Зеркалит таблицу app_state,
    /// чтобы chip-ы в UI обновлялись без перечитывания БД.
    var globalPreset: RecordingPreset {
        didSet {
            guard globalPreset != oldValue else { return }
            AppState.setLastUsedPreset(globalPreset)
        }
    }

    init() {
        self.recorder = AudioRecorder()
        self.store = RecordingsStore()
        self.projects = ProjectsModel()
        self.globalPreset = AppState.lastUsedPreset()
    }

    init(
        recorder: AudioRecorder,
        store: RecordingsStore,
        projects: ProjectsModel
    ) {
        self.recorder = recorder
        self.store = store
        self.projects = projects
        self.globalPreset = AppState.lastUsedPreset()
    }

    var isRecording: Bool { recorder.isRecording }
    var isCountingDown: Bool { countdown != nil }

    /// Проект, в который идёт текущая запись (nil — «Записи»).
    var activeProject: Project? { projects.project(id: activeProjectID) }

    // MARK: - Старт

    /// Главная кнопка / menu bar «Начать запись»: в «Записи» с глобальным пресетом (§7.1, путь 1).
    func startInInbox(withCountdown: Bool = true) async {
        await start(preset: globalPreset, project: nil, withCountdown: withCountdown)
    }

    /// ⏺ у Проекта: в Проект с его пресетом (§7.1, путь 2).
    func startInProject(_ project: Project, withCountdown: Bool = true) async {
        await start(preset: project.lastUsedPreset, project: project, withCountdown: withCountdown)
    }

    /// Общий путь старта, в т.ч. из hero-экрана с выбранными chip-ами (§7.1, путь 3).
    func start(
        preset: RecordingPreset,
        project: Project?,
        withCountdown: Bool = true,
        alertOnFailure: Bool = false
    ) async {
        guard !isBusy, !recorder.isRecording, countdown == nil else { return }
        errorMessage = nil
        activePreset = preset
        activeProjectID = project?.id

        if withCountdown {
            let task = Task { await runCountdown() }
            countdownTask = task
            await task.value
            countdownTask = nil
            guard !task.isCancelled else {
                activePreset = nil
                activeProjectID = nil
                return
            }
        }

        isBusy = true
        defer { isBusy = false }

        do {
            configureRecorder(for: preset, project: project)
            try await ensurePermissionsForCurrentConfiguration()
            try await recorder.start()
            errorMessage = nil
        } catch {
            activePreset = nil
            activeProjectID = nil
            handle(error, alertOnFailure: alertOnFailure)
        }
    }

    /// Тап во время отсчёта = отмена.
    func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
    }

    private func runCountdown() async {
        for n in stride(from: countdownStart, through: 1, by: -1) {
            countdown = n
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                countdown = nil
                return
            }
        }
        countdown = nil
    }

    // MARK: - Стоп

    func stop(alertOnFailure: Bool = true) async {
        guard !isBusy, recorder.isRecording else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await recorder.stop()
            let project = activeProject
            let preset = activePreset ?? project?.lastUsedPreset ?? globalPreset
            // addRecording сам обновляет sticky-пресет контекста (§7.2).
            let recording = store.addRecording(
                audioURL: result.url,
                duration: result.duration,
                project: project,
                preset: preset
            )
            if project == nil {
                globalPreset = preset
            }
            projects.reload()
            lastSavedRecording = recording
            errorMessage = nil
        } catch {
            handle(error, alertOnFailure: alertOnFailure)
        }
        activePreset = nil
        activeProjectID = nil
    }

    func dismissError() {
        errorMessage = nil
    }

    func consumeLastSavedRecording() -> Recording? {
        defer { lastSavedRecording = nil }
        return lastSavedRecording
    }

    // MARK: - Конфигурация

    private func configureRecorder(for preset: RecordingPreset, project: Project?) {
        guard !recorder.isRecording else { return }
        recorder.micEnabled = preset.hasMicrophone
        recorder.systemAudioEnabled = preset.hasSystemAudio
        recorder.captureVideo = preset.hasScreen
        recorder.outputDirectory = project.flatMap { try? AppSettings.recordingsDirectory(for: $0) }
    }

    private func ensurePermissionsForCurrentConfiguration() async throws {
        try ensureScreenRecordingAccess()
        if recorder.micEnabled {
            try await ensureMicrophoneAccess()
        }
    }

    private func ensureScreenRecordingAccess() throws {
        guard !recorder.captureVideo || ScreenRecordingPermission.isGranted else {
            try requestScreenRecordingAccess()
            return
        }

        if !ScreenRecordingPermission.isGranted {
            try requestScreenRecordingAccess()
        }
    }

    private func requestScreenRecordingAccess() throws {
        let hadAccess = ScreenRecordingPermission.isGranted
        let granted = ScreenRecordingPermission.request()

        guard hadAccess else {
            ScreenRecordingPermission.openSettings()
            if granted {
                throw RecordingControllerError.screenPermissionRequiresRelaunch
            }
            throw RecordingControllerError.screenPermissionDenied
        }

        guard granted else {
            ScreenRecordingPermission.openSettings()
            throw RecordingControllerError.screenPermissionDenied
        }
    }

    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                throw RecordingControllerError.microphonePermissionDenied
            }
        default:
            throw RecordingControllerError.microphonePermissionDenied
        }
    }

    private func handle(_ error: Error, alertOnFailure: Bool) {
        let message = (error as NSError).localizedDescription
        errorMessage = message
        if alertOnFailure {
            presentAlert(message: message)
        }
    }

    private func presentAlert(message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Не удалось начать запись"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

private enum RecordingControllerError: LocalizedError {
    case microphonePermissionDenied
    case screenPermissionDenied
    case screenPermissionRequiresRelaunch

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Нет доступа к микрофону. Разреши его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
        case .screenPermissionDenied:
            return "Нет доступа к записи экрана. Ushi использует его для системного звука и записи экрана. Разреши доступ в Системных настройках → Конфиденциальность и безопасность → Запись экрана."
        case .screenPermissionRequiresRelaunch:
            return "Доступ к записи экрана был выдан только что. Перезапусти Ushi, чтобы системный звук и запись экрана начали работать."
        }
    }
}
