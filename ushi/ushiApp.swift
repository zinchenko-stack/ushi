//
//  ushiApp.swift
//  ushi
//

import SwiftUI

@main
struct ushiApp: App {
    // Один общий UpdateChecker — и баннер в ContentView, и команда меню используют его.
    @State private var updateChecker = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 560)
                .environment(updateChecker)
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
}
