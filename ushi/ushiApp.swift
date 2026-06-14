//
//  ushiApp.swift
//  ushi
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let waitsForResumeData = ModelManager.shared.prepareForTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return waitsForResumeData ? .terminateLater : .terminateNow
    }
}

@main
struct ushiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // Один общий UpdateChecker — и баннер в ContentView, и команда меню используют его.
    @State private var updateChecker = UpdateChecker()
    @State private var modelManager = ModelManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                switch modelManager.state {
                case .checking:
                    ProgressView()
                        .controlSize(.large)
                        .frame(minWidth: 560, minHeight: 420)
                case .missing:
                    OnboardingView(manager: modelManager)
                case .downloading, .failed:
                    if modelManager.userDismissedOnboarding {
                        mainContent
                    } else {
                        OnboardingView(manager: modelManager)
                    }
                case .ready:
                    mainContent
                }
            }
            .task {
                modelManager.checkInstalled()
            }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") {
                    Task { await updateChecker.check() }
                }
            }
        }
    }

    private var mainContent: some View {
        ContentView()
            .frame(minWidth: 980, minHeight: 560)
            .environment(updateChecker)
            .environment(modelManager)
    }
}
