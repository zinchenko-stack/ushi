//
//  UshiMenuBarView.swift
//  ushi
//

import SwiftUI
import AppKit

struct UshiMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var recordingController: RecordingController

    private var recorder: AudioRecorder { recordingController.recorder }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuActionRow(
                title: recorder.isRecording ? "Остановить запись" : "Начать запись",
                isDisabled: recordingController.isBusy
            ) {
                Task {
                    if recorder.isRecording {
                        await recordingController.stop()
                    } else {
                        // Из menu bar — сразу, без отсчёта: окно может быть скрыто.
                        await recordingController.startInInbox(withCountdown: false)
                    }
                }
                dismissPopover()
            }

            MenuDivider()

            // Источники правят глобальный app.lastUsedPreset (§6.9) — тот же выбор,
            // что под кнопкой «Начать запись» в окне. Полное меню v2 — Phase 5.
            ForEach(RecordingPreset.Source.available, id: \.self) { source in
                Toggle(source.title, isOn: $recordingController.globalPreset.binding(for: source))
                    .disabled(
                        recorder.isRecording
                            || recordingController.isBusy
                            || !recordingController.globalPreset.canToggle(source)
                    )
            }

            MenuDivider()

            MenuActionRow(title: "Открыть Ushi") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                dismissPopover()
            }

            MenuActionRow(title: "Выйти") {
                NSApp.terminate(nil)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    private func dismissPopover() {
        // MenuBarExtra(.window) рисуется как NSPanel — закрываем его, чтобы попап
        // схлопнулся после клика на action-кнопку.
        for window in NSApp.windows where window.isVisible {
            let name = String(describing: type(of: window))
            if name.contains("MenuBarExtra") || name.contains("Popover") {
                window.close()
                return
            }
        }
    }
}

private struct MenuActionRow: View {
    let title: String
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered && !isDisabled ? Color.accentColor : .clear)
            )
            .foregroundStyle(isHovered && !isDisabled ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 6)
    }
}

private struct MenuToggleRow: View {
    let title: String
    let isOn: Bool
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(isOn ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered && !isDisabled ? Color.accentColor : .clear)
            )
            .foregroundStyle(
                isDisabled
                    ? Color.secondary
                    : (isHovered ? Color.white : Color.primary)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .padding(.horizontal, 6)
    }
}

private struct MenuDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
    }
}
