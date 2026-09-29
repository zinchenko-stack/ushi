//
//  ContentView.swift
//  ushi
//

import SwiftUI
import AppKit

struct ContentView: View {
    let recordingController: RecordingController
    @State private var sidebarModel: SidebarViewModel
    @State private var selection: MainSelection? = .home
    @State private var hasScreenAccess = ScreenRecordingPermission.isGranted
    @State private var path: [Recording] = []
    @Environment(UpdateChecker.self) private var updateChecker
    @Environment(ModelManager.self) private var modelManager
    @AppStorage("update.dismissedVersion") private var dismissedUpdateVersion = ""

    init(recordingController: RecordingController) {
        self.recordingController = recordingController
        self._sidebarModel = State(initialValue: SidebarViewModel(controller: recordingController))
    }

    var body: some View {
        VStack(spacing: 0) {
            DownloadBanner()
                .transition(.move(edge: .top).combined(with: .opacity))

            Group {
                if hasScreenAccess {
                    mainView
                } else {
                    PermissionGateView()
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: modelManager.isReady)
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
        .task(id: modelManager.isReady) {
            guard modelManager.isReady else { return }
            await recordingController.store.processPendingTranscriptions()
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
            SidebarView(model: sidebarModel, selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            NavigationStack(path: $path) {
                detail
                    .navigationDestination(for: Recording.self) { rec in
                        RecordingDetailView(recording: rec, store: recordingController.store)
                    }
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        // При смене раздела сбрасываем стек, чтобы не оставалась открытая деталь.
        .onChange(of: selection) { _, _ in path = [] }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:
            HeroStartView(controller: recordingController) { rec in
                selection = .recording(rec.id)
            }
        case .search:
            HistoryView(store: recordingController.store)
        case .settings:
            SettingsView()
        case .recording(let id):
            if let rec = recordingController.store.recordings.first(where: { $0.id == id }) {
                RecordingDetailView(recording: rec, store: recordingController.store)
                    .id(id)   // новый плеер и состояние на каждую запись
            } else {
                // Запись удалили — возвращаемся на hero.
                Color.clear.task { selection = .home }
            }
        }
    }
}

#Preview {
    ContentView(recordingController: RecordingController())
        .frame(width: 900, height: 600)
        .environment(UpdateChecker())
        .environment(ModelManager.shared)
}

private struct DownloadBanner: View {
    @Environment(ModelManager.self) private var manager

    var body: some View {
        switch manager.state {
        case .downloading(let downloaded, let total, let speed):
            HStack(spacing: 12) {
                ProgressView(
                    value: total > 0 ? Double(downloaded) : 0,
                    total: total > 0 ? Double(total) : 1
                )
                .frame(width: 120)

                Text(downloadDescription(downloaded: downloaded, total: total, speed: speed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Подробнее") {
                    manager.showOnboarding()
                }
                .buttonStyle(.plain)
            }
            .bannerStyle()

        case .failed(let message):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text("Ошибка загрузки модели: \(message)")
                    .font(.caption)
                    .lineLimit(2)

                Spacer()

                Button("Подробнее") {
                    manager.showOnboarding()
                }
                .buttonStyle(.plain)

                Button("Повторить") {
                    manager.startDownload()
                }
            }
            .bannerStyle()

        default:
            EmptyView()
        }
    }

    private func downloadDescription(downloaded: Int64, total: Int64, speed: Double) -> String {
        var components = ["Загружаю модель распознавания"]
        if total > 0 {
            let percent = Int((Double(downloaded) / Double(total) * 100).rounded())
            components.append("\(min(max(percent, 0), 100))%")
        }
        if total > downloaded, speed > 0 {
            let seconds = Double(total - downloaded) / speed
            components.append("осталось ~\(formatDuration(seconds))")
        }
        return components.joined(separator: " · ")
    }

    private func formatDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .brief
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds)) ?? "несколько секунд"
    }
}

private extension View {
    func bannerStyle() -> some View {
        padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) {
                Divider()
            }
    }
}
