//
//  OnboardingView.swift
//  ushi
//

import SwiftUI

struct OnboardingView: View {
    let manager: ModelManager

    @State private var showingCancelConfirmation = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 8)

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Подготовка Ushi")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))

                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            content
                .frame(maxWidth: 420)

            Spacer(minLength: 8)
        }
        .padding(40)
        .frame(minWidth: 560, minHeight: 420)
        .alert("Точно отменить?", isPresented: $showingCancelConfirmation) {
            Button("Продолжить скачивание", role: .cancel) {}
            Button("Отменить скачивание", role: .destructive) {
                manager.cancelDownload()
            }
        } message: {
            Text("Без модели Ushi не сможет транскрибировать записи.")
        }
    }

    private var subtitle: String {
        switch manager.state {
        case .failed:
            return "Не удалось скачать модель распознавания речи"
        case .missing:
            return "Модель распознавания речи ещё не установлена"
        default:
            return "Скачиваю модель распознавания речи"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .checking:
            ProgressView()
                .controlSize(.large)

        case .missing:
            VStack(spacing: 16) {
                Text("Модель занимает около 1,5 ГБ и хранится только на этом Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("Скачать модель") {
                    manager.startDownload()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .downloading(let downloaded, let total, let speed):
            VStack(spacing: 14) {
                ProgressView(
                    value: total > 0 ? Double(downloaded) : 0,
                    total: total > 0 ? Double(total) : 1
                )
                .progressViewStyle(.linear)

                Text(progressDescription(downloaded: downloaded, total: total, speed: speed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Отмена") {
                        showingCancelConfirmation = true
                    }

                    Button("Свернуть и пользоваться сейчас") {
                        manager.dismissOnboarding()
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .failed(let message):
            VStack(spacing: 16) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                Button("Повторить") {
                    manager.startDownload()
                }
                .buttonStyle(.borderedProminent)
            }

        case .ready:
            EmptyView()
        }
    }

    private func progressDescription(downloaded: Int64, total: Int64, speed: Double) -> String {
        var parts = [formatBytes(downloaded)]
        if total > 0 {
            parts[0] += " из \(formatBytes(total))"
        }
        if speed > 0 {
            parts.append("\(formatBytes(Int64(speed)))/с")
        }
        if total > downloaded, speed > 0 {
            let seconds = Double(total - downloaded) / speed
            parts.append("осталось ~\(formatDuration(seconds))")
        }
        return parts.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = bytes >= 1_000_000_000 ? [.useGB] : [.useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .brief
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds)) ?? "несколько секунд"
    }
}

#Preview {
    OnboardingView(manager: .shared)
        .frame(width: 560, height: 420)
}
