//
//  RecordingView.swift
//  ushi
//

import SwiftUI

struct RecordingView: View {
    @Bindable var recorder: AudioRecorder
    @Bindable var store: RecordingsStore
    /// Открыть запись по тапу на тост «Запись сохранена».
    var onOpenRecording: (Recording) -> Void

    @State private var isWorking = false   // блокируем кнопку, пока async start/stop
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?

    @State private var savedRecording: Recording?     // показанный тост (nil = скрыт)
    @State private var toastTask: Task<Void, Never>?

    // Обратный отсчёт перед стартом: успеть переключиться в нужное окно,
    // не записывая лишнего. Тап по кнопке во время отсчёта = отмена.
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    private let countdownStart = 3

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Group {
                if let cd = countdown {
                    Text("\(cd)")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Text(formatTime(recorder.elapsed))
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(size: 80, weight: .medium, design: .rounded).monospacedDigit())
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.15), value: countdown)

            Button {
                handleTap()
            } label: {
                ZStack {
                    Circle()
                        .fill(buttonFill)
                        .frame(width: 120, height: 120)
                    buttonGlyph
                }
                .opacity(isWorking ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(isWorking)

            Text(statusText)
                .font(.title3)
                .foregroundStyle(.secondary)

            // Индикатор уровня — заполняется от реального сигнала
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .frame(width: 240, height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(levelColor)
                            .frame(width: geo.size.width * CGFloat(recorder.level))
                            .animation(.easeOut(duration: 0.1), value: recorder.level)
                    }
                    .frame(height: 8)
                }

            // Режимы — задаются до старта записи.
            HStack(spacing: 12) {
                toggleCapsule(
                    on: recorder.micEnabled,
                    onIcon: "mic.fill", offIcon: "mic.slash.fill",
                    onText: "Микрофон включён", offText: "Микрофон выключен",
                    help: "Писать ли твой голос. Выкл — только системный звук"
                ) { recorder.micEnabled.toggle() }

                toggleCapsule(
                    on: recorder.captureVideo,
                    onIcon: "video.fill", offIcon: "video.slash.fill",
                    onText: "Видео экрана", offText: "Только звук",
                    help: "Писать ли видео всего экрана. Выкл — только аудио"
                ) { recorder.captureVideo.toggle() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { savedToast }
        .animation(.spring(duration: 0.3), value: savedRecording)
        .navigationTitle("Новая запись")
    }

    // MARK: - Тост «Запись сохранена»

    @ViewBuilder
    private var savedToast: some View {
        if let rec = savedRecording {
            Button {
                dismissToast()
                onOpenRecording(rec)
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Запись сохранена")
                        .fontWeight(.medium)
                    Image(systemName: "chevron.right")
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showSavedToast(_ rec: Recording) {
        savedRecording = rec
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled {
                savedRecording = nil
            }
        }
    }

    private func dismissToast() {
        toastTask?.cancel()
        savedRecording = nil
    }

    private var statusText: String {
        if isWorking { return "Подождите…" }
        if countdown != nil { return "Нажмите, чтобы отменить" }
        return recorder.isRecording ? "Идёт запись…" : "Нажмите, чтобы начать"
    }

    private var buttonFill: Color {
        if recorder.isRecording { return .red }
        if countdown != nil { return .secondary.opacity(0.6) }
        return .accentColor
    }

    @ViewBuilder
    private var buttonGlyph: some View {
        if recorder.isRecording {
            Image(systemName: "stop.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
        } else if countdown != nil {
            // X = «отменить отсчёт»: визуально это не stop (та же серая палитра, что и mute),
            // не вводит в заблуждение «уже идёт запись».
            Image(systemName: "xmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            // Красная точка = универсальный «record» (Voice Memos / QuickTime).
            Image(systemName: "circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
        }
    }

    private var levelColor: Color {
        if recorder.level > 0.85 { return .red }
        if recorder.level > 0.6 { return .yellow }
        return .green
    }

    /// Капсула-переключатель режима записи (микрофон / видео). Активна до старта записи.
    private func toggleCapsule(
        on: Bool,
        onIcon: String, offIcon: String,
        onText: String, offText: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: on ? onIcon : offIcon)
                Text(on ? onText : offText)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(on ? Color.accentColor : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill((on ? Color.accentColor : Color.secondary).opacity(0.15))
            )
            .overlay(
                Capsule().strokeBorder((on ? Color.accentColor : Color.secondary).opacity(0.35),
                                       lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(recorder.isRecording)
        .opacity(recorder.isRecording ? 0.4 : 1)
        .help(recorder.isRecording ? "Поменять можно только до старта записи" : help)
    }

    private func handleTap() {
        guard !isWorking else { return }

        // Идёт обратный отсчёт → отменяем и выходим, ничего не запуская.
        if countdown != nil {
            countdownTask?.cancel()
            countdownTask = nil
            countdown = nil
            return
        }

        // Идёт запись → стоп.
        if recorder.isRecording {
            guard activeTask == nil else { return }
            activeTask = Task {
                await stopRecording()
                activeTask = nil
            }
            return
        }

        // Иначе — начинаем с обратного отсчёта.
        errorMessage = nil
        countdownTask = Task { await runCountdownThenStart() }
    }

    private func runCountdownThenStart() async {
        for n in stride(from: countdownStart, through: 1, by: -1) {
            countdown = n
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                countdown = nil
                return
            }
            if Task.isCancelled {
                countdown = nil
                return
            }
        }
        countdown = nil
        countdownTask = nil

        isWorking = true
        defer { isWorking = false }
        do {
            try await recorder.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stopRecording() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await recorder.stop()
            let rec = store.addRecording(audioURL: result.url, duration: result.duration)
            showSavedToast(rec)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}
