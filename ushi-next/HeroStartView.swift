//
//  HeroStartView.swift
//  UshiNext
//
//  Hero-стейт (§6.4, §7.1 путь 3): «Начать запись» с chip-ами пресета и Проекта.
//  Во время отсчёта и записи — таймер, уровень и кнопка стопа (как в старом
//  RecordingView), chip-ы показывают, куда и как идёт запись.
//

import SwiftUI

struct HeroStartView: View {
    @Bindable var controller: RecordingController
    /// Открыть запись по тапу на тост «Запись сохранена».
    var onOpenRecording: (Recording) -> Void

    /// Целевой Проект для старта из hero. nil — «Без проекта».
    @State private var targetProjectID: UUID?
    @State private var isCreatingProject = false

    @State private var sourceHint: String?
    @State private var hintTask: Task<Void, Never>?

    @State private var savedRecording: Recording?     // показанный тост (nil = скрыт)
    @State private var toastTask: Task<Void, Never>?

    private var recorder: AudioRecorder { controller.recorder }
    private var projects: ProjectsModel { controller.projects }

    /// Идёт отсчёт или запись — chip-ы показывают активную запись и заблокированы.
    private var isActive: Bool { controller.isRecording || controller.isCountingDown }

    private var targetProject: Project? { projects.project(id: targetProjectID) }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Group {
                if let cd = controller.countdown {
                    Text("\(cd)")
                        .foregroundStyle(Color.accentColor)
                } else if controller.isRecording {
                    Text(formatTime(recorder.elapsed))
                        .foregroundStyle(.primary)
                } else {
                    Text("Начать запись")
                        .foregroundStyle(.primary)
                }
            }
            .font(controller.isRecording || controller.isCountingDown
                  ? .system(size: 80, weight: .medium, design: .rounded).monospacedDigit()
                  : .system(size: 40, weight: .semibold, design: .rounded))
            .contentTransition(.numericText())
            .animation(.easeInOut(duration: 0.15), value: controller.countdown)

            projectChip

            Button(action: handleTap) {
                ZStack {
                    Circle()
                        .fill(buttonFill)
                        .frame(width: 120, height: 120)
                    buttonGlyph
                }
                .opacity(controller.isBusy ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .disabled(controller.isBusy)

            // Источники — три круглые кнопки-переключателя под кнопкой записи.
            HStack(spacing: 14) {
                ForEach(RecordingPreset.Source.available, id: \.self) { source in
                    SourceToggleButton(
                        source: source,
                        isOn: presetBinding.wrappedValue.contains(source),
                        isEnabled: !isActive
                    ) {
                        toggleSource(source)
                    }
                }
            }

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
                .opacity(controller.isRecording ? 1 : 0.4)

            Button {
                importAudio()
            } label: {
                Label("Загрузить аудио на расшифровку…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.link)
            .disabled(isActive)

            if let errorMessage = controller.errorMessage {
                // Про разрешения — спокойная подсказка: macOS в этот момент сама
                // показывает запрос, пользователь ничего не сделал не так.
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(controller.errorIsPermissionHint ? Color.secondary : Color.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { savedToast }
        .animation(.spring(duration: 0.3), value: savedRecording)
        .navigationTitle("Новая запись")
        .sheet(isPresented: $isCreatingProject) {
            CreateProjectSheet(projects: projects) { project in
                targetProjectID = project.id
            }
        }
        // Запись могли остановить из sidebar или menu bar — тост показываем всё равно.
        .onChange(of: controller.lastSavedRecording) { _, rec in
            guard rec != nil, let saved = controller.consumeLastSavedRecording() else { return }
            showSavedToast(saved)
        }
    }

    // MARK: - Chip-ы

    /// Пресет: для «Без проекта» — глобальный app.lastUsedPreset, для Проекта — его
    /// lastUsedPreset (§6.4). Во время записи показывает фактический пресет.
    private var presetBinding: Binding<RecordingPreset> {
        Binding(
            get: {
                if isActive, let active = controller.activePreset { return active }
                return targetProject?.lastUsedPreset ?? controller.globalPreset
            },
            set: { newValue in
                if let project = targetProject {
                    projects.updateLastUsedPreset(project, newValue)
                } else {
                    controller.globalPreset = newValue
                }
            }
        )
    }

    private var projectChip: some View {
        let shown = isActive ? controller.activeProject : targetProject
        return Menu {
            Button("Без проекта") { targetProjectID = nil }
            if !projects.projects.isEmpty {
                Divider()
                ForEach(projects.projects) { project in
                    Button(project.name) { targetProjectID = project.id }
                }
            }
            Divider()
            Button("Создать проект…") { isCreatingProject = true }
        } label: {
            Label(shown?.name ?? "Без проекта", systemImage: shown == nil ? "tray" : "folder")
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .disabled(isActive)
    }

    // MARK: - Загрузка аудио

    /// Файлы уходят в выбранный на chip-е Проект (или в «Записи»).
    private func importAudio() {
        let files = FolderPicker.chooseAudioFiles()
        guard !files.isEmpty else { return }
        let project = targetProject
        Task {
            var imported: Recording?
            for file in files {
                do {
                    imported = try await controller.store.importAudio(from: file, into: project)
                } catch {
                    showSourceHint(error.localizedDescription)
                }
            }
            controller.projects.reload()
            if let imported, files.count == 1 {
                showSavedToast(imported)
            }
        }
    }

    // MARK: - Источники

    /// Выключить последний звуковой источник нельзя — вместо молчаливой
    /// блокировки показываем подсказку на пару секунд.
    private func toggleSource(_ source: RecordingPreset.Source) {
        let preset = presetBinding.wrappedValue
        guard preset.canToggle(source) else {
            showSourceHint("Выберите хотя бы один источник звука")
            return
        }
        presetBinding.binding(for: source).wrappedValue.toggle()
    }

    private func showSourceHint(_ text: String) {
        withAnimation { sourceHint = text }
        hintTask?.cancel()
        hintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                withAnimation { sourceHint = nil }
            }
        }
    }

    // MARK: - Кнопка

    private func handleTap() {
        if controller.isCountingDown {
            controller.cancelCountdown()
            return
        }
        if controller.isRecording {
            Task { await controller.stop(alertOnFailure: false) }
            return
        }
        dismissToast()
        let preset = presetBinding.wrappedValue
        let project = targetProject
        Task { await controller.start(preset: preset, project: project) }
    }

    private var statusText: String {
        if controller.isBusy { return "Подождите…" }
        if controller.isCountingDown { return "Нажмите, чтобы отменить" }
        if controller.isRecording {
            if let project = controller.activeProject { return "Идёт запись в «\(project.name)»…" }
            return "Идёт запись…"
        }
        return "Нажмите, чтобы начать"
    }

    private var buttonFill: Color {
        if controller.isRecording { return .red }
        if controller.isCountingDown { return .secondary.opacity(0.6) }
        return .accentColor
    }

    @ViewBuilder
    private var buttonGlyph: some View {
        if controller.isRecording {
            Image(systemName: "stop.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white)
        } else if controller.isCountingDown {
            // X = «отменить отсчёт»: визуально это не stop, не вводит в заблуждение
            // «уже идёт запись».
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

    // MARK: - Тост «Запись сохранена»

    @ViewBuilder
    private var savedToast: some View {
        if let sourceHint {
            // Подсказка — в той же плашке, что и «Запись сохранена».
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(sourceHint)
                    .fontWeight(.medium)
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let rec = savedRecording {
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

/// Круглая кнопка-переключатель источника: включена — залита акцентом,
/// выключена — серая. Название — во всплывающей подсказке.
private struct SourceToggleButton: View {
    let source: RecordingPreset.Source
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: source.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(isOn ? Color.accentColor : Color.secondary.opacity(0.18)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.6)
        .help(isOn ? "\(source.title): включено" : "\(source.title): выключено")
        .accessibilityLabel(source.title)
        .accessibilityValue(isOn ? "включено" : "выключено")
    }
}
