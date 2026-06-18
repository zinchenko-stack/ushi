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

/// Экран-заглушка: показывается, пока нет доступа к записи экрана.
struct PermissionGateView: View {

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "lock.display")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Text("Нужен доступ к записи экрана")
                    .font(.title2.weight(.semibold))
                Text("ushi записывает системный звук через запись экрана. Без этого доступа запись не работает.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 10) {
                Button {
                    ScreenRecordingPermission.request()
                    ScreenRecordingPermission.openSettings()
                } label: {
                    Text("1. Открыть настройки доступа")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    ScreenRecordingPermission.relaunch()
                } label: {
                    Text("2. Я включил — перезапустить")
                        .frame(maxWidth: 240)
                }
                .buttonStyle(.bordered)
            }

            Text("Включи ushi в списке «Запись экрана», затем нажми «Перезапустить». Это нужно сделать один раз.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
