//
//  RecordingController.swift
//  ushi
//

import Foundation
import AppKit
import AVFoundation
import Observation

enum RecordingMode {
    case systemAudio
    case systemAudioAndMicrophone
    case screen
}

@MainActor
@Observable
final class RecordingController {
    let recorder: AudioRecorder
    let store: RecordingsStore

    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var lastSavedRecording: Recording?

    init() {
        self.recorder = AudioRecorder()
        self.store = RecordingsStore()
    }

    init(
        recorder: AudioRecorder,
        store: RecordingsStore
    ) {
        self.recorder = recorder
        self.store = store
    }

    func startCurrentConfiguration() async {
        await start(alertOnFailure: false)
    }

    func start(mode: RecordingMode, alertOnFailure: Bool = true) async {
        configureRecorder(for: mode)
        await start(alertOnFailure: alertOnFailure)
    }

    func stop(alertOnFailure: Bool = true) async {
        guard !isBusy, recorder.isRecording else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let result = try await recorder.stop()
            let recording = store.addRecording(audioURL: result.url, duration: result.duration)
            lastSavedRecording = recording
            errorMessage = nil
        } catch {
            handle(error, alertOnFailure: alertOnFailure)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func consumeLastSavedRecording() -> Recording? {
        defer { lastSavedRecording = nil }
        return lastSavedRecording
    }

    private func start(alertOnFailure: Bool) async {
        guard !isBusy, !recorder.isRecording else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            try await ensurePermissionsForCurrentConfiguration()
            try await recorder.start()
            errorMessage = nil
        } catch {
            handle(error, alertOnFailure: alertOnFailure)
        }
    }

    private func configureRecorder(for mode: RecordingMode) {
        guard !recorder.isRecording else { return }

        switch mode {
        case .systemAudio:
            recorder.micEnabled = false
            recorder.captureVideo = false
        case .systemAudioAndMicrophone:
            recorder.micEnabled = true
            recorder.captureVideo = false
        case .screen:
            recorder.micEnabled = false
            recorder.captureVideo = true
        }
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
