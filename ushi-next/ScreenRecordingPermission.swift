//
//  ScreenRecordingPermission.swift
//  ushi
//
//  Доступ к записи экрана (нужен ScreenCaptureKit для системного звука).
//  macOS считывает это разрешение только при запуске процесса, поэтому
//  после первой выдачи приложение надо один раз перезапустить — что мы и
//  делаем сами, по кнопке.
//

import SwiftUI
import AppKit
import CoreGraphics

enum ScreenRecordingPermission {

    /// Выдан ли доступ к записи экрана (проверка без prompt).
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Показывает системный запрос и регистрирует приложение в списке
    /// «Запись экрана». Возвращает true, если доступ уже есть.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Открывает раздел «Запись экрана» в Системных настройках.
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Перезапускает приложение (нужно один раз после первой выдачи доступа).
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
