//
//  HardwareSupport.swift
//  UshiNext
//
//  Ushi работает только на Mac с Apple Silicon (M1 и новее): расшифровка
//  (whisper-cli) и умные названия (llama-completion) собраны только под arm64.
//  Само приложение — универсальное и на Intel запускается, поэтому проверяем
//  железо при старте и вместо приложения показываем понятный экран, не скачивая
//  модель на 1,5 ГБ впустую.
//

import SwiftUI
import Darwin

nonisolated enum HardwareSupport {
    /// Mac с Apple Silicon. Смотрим на железо (`hw.optional.arm64`), а не на то,
    /// какой срез бинаря запущен: под Rosetta на M1 это тоже true.
    static let isAppleSilicon: Bool = {
        #if DEBUG
        // Проверить экран для Intel на своём Mac: USHI_FORCE_INTEL=1.
        if ProcessInfo.processInfo.environment["USHI_FORCE_INTEL"] == "1" { return false }
        #endif
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()
}

/// Экран вместо приложения на Mac с Intel.
struct UnsupportedMacView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            Text("Ushi работает только на Mac с Apple Silicon")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Этот Mac — на процессоре Intel. Расшифровка записей в Ushi рассчитана на Mac с чипами M1 и новее, поэтому здесь она не заработает. Ничего не скачивалось и не устанавливалось.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Button("Закрыть Ushi") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.top, 6)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
    }
}
