//
//  UshiMenuBarView.swift
//  ushi
//
//  Menu bar v2 (Phase 5, §6.9 брифа). Меню — зеркало глобального состояния:
//  источники правят тот же app.lastUsedPreset, что и окно. Во время записи
//  сверху видно, сколько идёт и куда пишется.
//  Стиль .menu: SwiftUI превращает содержимое в нативное NSMenu, поэтому здесь
//  только Button / Toggle / Menu / Divider.
//

import SwiftUI
import AppKit

struct UshiMenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var recordingController: RecordingController

    private var controller: RecordingController { recordingController }
    private var recorder: AudioRecorder { controller.recorder }
    private var projects: [Project] { controller.projects.projects }
    private var isIdle: Bool { !controller.isRecording && !controller.isBusy && !controller.isCountingDown }

    var body: some View {
        if controller.isRecording {
            Text("● Идёт запись · \(formatTime(recorder.elapsed)) · \(controller.activeProject?.name ?? "Записи")")
            Button("Остановить") {
                Task { await controller.stop() }
            }
        } else {
            // Верхняя строка — текущие источники (§6.9).
            Text(controller.globalPreset.title)

            Divider()

            Button("Начать запись") {
                // Из menu bar — сразу, без отсчёта: окно может быть скрыто.
                Task { await controller.startInInbox(withCountdown: false, alertOnFailure: true) }
            }
            .disabled(!isIdle)

            Menu("Записать в проект") {
                ForEach(projects) { project in
                    Button(project.name) {
                        Task { await controller.startInProject(project, withCountdown: false, alertOnFailure: true) }
                    }
                    .disabled(!controller.projects.isAvailable(project))
                }
                if !projects.isEmpty { Divider() }
                Button("Создать проект…") {
                    controller.isCreatingProjectFromMenu = true
                    openMainWindow()
                }
            }
            .disabled(!isIdle)

            Menu("Источник") {
                ForEach(RecordingPreset.Source.available, id: \.self) { source in
                    Toggle(source.title, isOn: $recordingController.globalPreset.binding(for: source))
                        .disabled(!controller.globalPreset.canToggle(source))
                }
            }
            .disabled(!isIdle)
        }

        Divider()

        Button("Открыть Ushi") { openMainWindow() }
        Button("Выйти") { NSApp.terminate(nil) }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Иконка в строке меню: во время записи рядом тикает таймер (§6.9).
struct UshiMenuBarLabel: View {
    let controller: RecordingController

    var body: some View {
        HStack(spacing: 4) {
            Image(controller.isRecording ? "MenuBarWaveform" : "MenuBarWaveformNext")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
            if controller.isRecording {
                Text(formatTime(controller.recorder.elapsed))
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(controller.isRecording ? "Ushi Next, идёт запись" : "Ushi Next")
    }
}

private func formatTime(_ t: TimeInterval) -> String {
    let total = Int(t)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
