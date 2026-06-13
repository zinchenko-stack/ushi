//
//  ContentView.swift
//  ushi
//

import SwiftUI
import AppKit

struct ContentView: View {
    @State private var store = RecordingsStore()
    @State private var recorder = AudioRecorder()
    @State private var selection: SidebarSection? = .recording
    @State private var hasScreenAccess = ScreenRecordingPermission.isGranted
    @State private var path: [Recording] = []
    @Environment(UpdateChecker.self) private var updateChecker
    @AppStorage("update.dismissedVersion") private var dismissedUpdateVersion = ""

    var body: some View {
        Group {
            if hasScreenAccess {
                mainView
            } else {
                PermissionGateView()
            }
        }
        .alert(
            "Доступно обновление",
            isPresented: updateAlertBinding,
            presenting: availableManifest
        ) { manifest in
            Button("Позже", role: .cancel) {
                dismissedUpdateVersion = manifest.version
            }
            Button("Скачать") {
                updateChecker.openDownload(for: manifest)
            }
        } message: { manifest in
            Text(updateAlertMessage(for: manifest))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !hasScreenAccess {
                hasScreenAccess = ScreenRecordingPermission.isGranted
            }
        }
        .task {
            await updateChecker.check()
        }
    }

    /// Манифест доступного обновления (если есть и пользователь его ещё не «отложил»).
    private var availableManifest: UpdateChecker.Manifest? {
        guard case .available(let m) = updateChecker.state else { return nil }
        return m.version == dismissedUpdateVersion ? nil : m
    }

    private var updateAlertBinding: Binding<Bool> {
        Binding(
            get: { availableManifest != nil },
            set: { showing in
                // Если алерт закрывают системно (Esc / клик вне) — считаем «Позже».
                if !showing, let m = availableManifest {
                    dismissedUpdateVersion = m.version
                }
            }
        )
    }

    private func updateAlertMessage(for manifest: UpdateChecker.Manifest) -> String {
        var lines = ["ushi \(manifest.version) доступна для загрузки."]
        if let notes = manifest.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append(notes)
        }
        return lines.joined(separator: "\n")
    }

    private var mainView: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    switch selection ?? .recording {
                    case .recording:
                        RecordingView(recorder: recorder, store: store) { rec in
                            path.append(rec)
                        }
                    case .history:
                        HistoryView(store: store)
                    case .settings:
                        SettingsView()
                    }
                }
                .navigationDestination(for: Recording.self) { rec in
                    RecordingDetailView(recording: rec, store: store)
                }
            }
            .frame(minWidth: 680, maxWidth: .infinity, maxHeight: .infinity)
        }
        // При смене раздела сбрасываем стек, чтобы не оставалась открытая деталь.
        .onChange(of: selection) { _, _ in path = [] }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 600)
}
