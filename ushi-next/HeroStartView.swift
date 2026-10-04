//
//  HeroStartView.swift
//  UshiNext
//
//  Экран «Новая запись» по макету в Figma («Ushi», Frame 16): плашка по центру —
//  заголовок, выбор проекта, большая кнопка записи и источники-«таблетки».
//  Во время отсчёта на месте заголовка — цифра, во время записи — таймер;
//  кнопка становится «отменить» / «стоп», внизу плашки — уровень звука.
//  Размер плашки между состояниями не меняется, поэтому ничего не прыгает.
//

import SwiftUI

struct HeroStartView: View {
    @Bindable var controller: RecordingController
    /// Целевой Проект для старта из hero. nil — «Без проекта». Живёт снаружи:
    /// «+» у проекта в sidebar открывает hero уже с выбранным проектом.
    @Binding var targetProjectID: UUID?
    /// Открыть запись по тапу на тост «Запись сохранена».
    var onOpenRecording: (Recording) -> Void
    @State private var isCreatingProject = false
    @State private var projectMenu = PopUpMenuAnchor()

    @State private var sourceHint: String?
    @State private var hintTask: Task<Void, Never>?

    @State private var savedRecording: Recording?     // показанный тост (nil = скрыт)
    @State private var toastTask: Task<Void, Never>?

    private var recorder: AudioRecorder { controller.recorder }
    private var projects: ProjectsModel { controller.projects }

    /// Идёт отсчёт или запись — chip-ы показывают активную запись и заблокированы.
    private var isActive: Bool { controller.isRecording || controller.isCountingDown }

    private var targetProject: Project? { projects.project(id: targetProjectID) }

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        card
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) { savedToast }
            .animation(.spring(duration: 0.3), value: savedRecording)
            // Без заголовка в окне: на экране и так крупное «Новая запись».
            .modifier(HiddenWindowTitle())
            // Загрузка готового аудио — кнопкой справа вверху, как в Claude Code.
            .toolbar {
                TrailingToolbarButton(
                    imageName: "Download",
                    title: "Загрузить",
                    help: "Аудио для расшифровки",
                    isEnabled: !isActive
                ) {
                    importAudio()
                }
            }
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

    // MARK: - Плашка

    private var card: some View {
        VStack(spacing: HeroMetrics.blockSpacing) {
            // Что и куда записываем.
            VStack(spacing: HeroMetrics.titleSpacing) {
                title
                HeroProjectButton(
                    title: (isActive ? controller.activeProject : targetProject)?.name ?? "Без проекта",
                    isEnabled: !isActive
                ) {
                    projectMenu.popUp(projectMenuItems)
                }
                .background(PopUpMenuAnchorView(anchor: projectMenu))
            }

            // Сама запись: кнопка и источники.
            VStack(spacing: HeroMetrics.recordSpacing) {
                recordButton
                VStack(spacing: 16) {
                    sources
                    if let errorMessage = controller.errorMessage {
                        // Про разрешения — спокойная подсказка: macOS в этот момент сама
                        // показывает запрос, пользователь ничего не сделал не так.
                        Text(errorMessage)
                            .font(.system(size: HeroMetrics.textSize))
                            .foregroundStyle(controller.errorIsPermissionHint ? Color.secondary : AppColors.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, HeroMetrics.cardPaddingV)
        .padding(.horizontal, HeroMetrics.cardPaddingH)
        .background(cardShape.fill(Color.primary.opacity(0.04)))
        .overlay(cardShape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1 / displayScale))
        .overlay(alignment: .bottom) { levelMeter }
        .animation(.easeInOut(duration: 0.2), value: controller.isRecording)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HeroMetrics.cardRadius, style: .continuous)
    }

    /// «Новая запись»; во время отсчёта — цифра, во время записи — таймер.
    /// Шрифт тот же, чтобы плашка не меняла высоту.
    private var title: some View {
        Group {
            if let cd = controller.countdown {
                Text("\(cd)")
                    .foregroundStyle(AppColors.accent)
            } else if controller.isRecording {
                Text(formatTime(recorder.elapsed))
                    .foregroundStyle(.primary)
            } else {
                Text("Новая запись")
                    .foregroundStyle(.primary)
            }
        }
        .font(.system(size: HeroMetrics.titleSize, weight: .medium).monospacedDigit())
        .contentTransition(.numericText())
        .animation(.easeInOut(duration: 0.15), value: controller.countdown)
    }

    private var recordButton: some View {
        Button(action: handleTap) {
            ZStack {
                Circle().fill(recordFill)
                Circle().strokeBorder(recordStroke, lineWidth: HeroMetrics.accentBorder)
                recordGlyph
            }
            .frame(width: HeroMetrics.recordSize, height: HeroMetrics.recordSize)
            .contentShape(Circle())
            .opacity(controller.isBusy ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(controller.isBusy)
        .accessibilityLabel(controller.isRecording ? "Остановить запись"
                            : controller.isCountingDown ? "Отменить" : "Начать запись")
    }

    // Источники — «таблетки» со значком и подписью.
    private var sources: some View {
        HStack(spacing: HeroMetrics.pillSpacing) {
            ForEach(RecordingPreset.Source.available, id: \.self) { source in
                SourcePill(
                    source: source,
                    isOn: presetBinding.wrappedValue.contains(source),
                    isEnabled: !isActive
                ) {
                    toggleSource(source)
                }
            }
        }
    }

    /// Уровень звука — тонкой полоской внизу плашки, только во время записи.
    @ViewBuilder
    private var levelMeter: some View {
        if controller.isRecording {
            Capsule()
                .fill(Color.primary.opacity(0.08))
                .frame(width: HeroMetrics.meterWidth, height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(levelColor)
                            .frame(width: geo.size.width * CGFloat(recorder.level))
                            .animation(.easeOut(duration: 0.1), value: recorder.level)
                    }
                }
                .padding(.bottom, HeroMetrics.meterBottom)
                .transition(.opacity)
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

    private var projectMenuItems: [PopUpMenuItem] {
        var items: [PopUpMenuItem] = [
            .item("Без проекта", isChecked: targetProjectID == nil) { targetProjectID = nil }
        ]
        if !projects.projects.isEmpty {
            items.append(.separator)
            for project in projects.projects {
                items.append(.item(project.name, isChecked: project.id == targetProjectID) {
                    targetProjectID = project.id
                })
            }
        }
        items.append(.separator)
        items.append(.item("Создать проект…") { isCreatingProject = true })
        return items
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

    /// Ожидание — голубая рамка и точка; отсчёт — серая с крестиком («отменить»);
    /// запись — красная с квадратом «стоп».
    private var recordFill: Color {
        if controller.isRecording { return AppColors.red.opacity(0.2) }
        if controller.isCountingDown { return Color.primary.opacity(0.06) }
        return AppColors.accentFill
    }

    private var recordStroke: Color {
        if controller.isRecording { return AppColors.red }
        if controller.isCountingDown { return Color.primary.opacity(0.25) }
        return AppColors.accent
    }

    @ViewBuilder
    private var recordGlyph: some View {
        if controller.isRecording {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppColors.red)
                .frame(width: HeroMetrics.stopSize, height: HeroMetrics.stopSize)
        } else if controller.isCountingDown {
            // Крестик, а не «стоп»: запись ещё не началась.
            Image(systemName: "xmark")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
        } else {
            Circle()
                .fill(AppColors.accent)
                .frame(width: HeroMetrics.dotSize, height: HeroMetrics.dotSize)
        }
    }

    private var levelColor: Color {
        if recorder.level > 0.85 { return AppColors.red }
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

// MARK: - Размеры

/// Размеры по макету в Figma, × 0,6: макет нарисован крупнее окна, а так плашка
/// помещается и в самое маленькое окно, текст — 12 pt. В комментариях — значения
/// из макета.
private enum HeroMetrics {
    static let cardRadius: CGFloat = 24        // 40
    static let cardPaddingV: CGFloat = 48      // 80
    static let cardPaddingH: CGFloat = 96      // 160
    static let blockSpacing: CGFloat = 48      // 80: заголовок с проектом ↔ кнопка записи
    static let titleSpacing: CGFloat = 24      // 40: заголовок ↔ проект
    static let recordSpacing: CGFloat = 72     // 120: кнопка записи ↔ источники
    static let titleSize: CGFloat = 34         // 56
    static let textSize: CGFloat = 12          // 20
    static let iconSize: CGFloat = 14          // 24
    static let symbolSize: CGFloat = 12
    static let iconSpacing: CGFloat = 5        // 8
    static let projectRadius: CGFloat = 10     // 16
    static let projectPaddingH: CGFloat = 15   // 24 + рамка
    static let projectPaddingV: CGFloat = 10   // 16 + рамка
    static let recordSize: CGFloat = 124       // 206
    static let dotSize: CGFloat = 46           // 76
    static let stopSize: CGFloat = 38
    static let accentBorder: CGFloat = 1.25    // 2
    static let pillSpacing: CGFloat = 7        // 12
    static let pillPaddingH: CGFloat = 11      // 16 + рамка
    static let pillPaddingV: CGFloat = 8.5     // 12 + рамка
    static let meterWidth: CGFloat = 160
    static let meterBottom: CGFloat = 20
}

// MARK: - Кнопка проекта

/// Куда пойдёт запись: папка, название и стрелка на полупрозрачной плашке
/// с тонкой рамкой; по клику — список проектов.
private struct HeroProjectButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Button(action: action) {
            HStack(spacing: HeroMetrics.iconSpacing) {
                Image("FolderOpen")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: HeroMetrics.iconSize, height: HeroMetrics.iconSize)
                Text(title)
                    .font(.system(size: HeroMetrics.textSize))
                    .lineLimit(1)
                    .frame(maxWidth: 200)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(AppColors.accent)
            .padding(.horizontal, HeroMetrics.projectPaddingH)
            .padding(.vertical, HeroMetrics.projectPaddingV)
            .background(shape.fill(Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0.04)))
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1 / displayScale))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .accessibilityLabel("Проект: \(title)")
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HeroMetrics.projectRadius, style: .continuous)
    }
}

// MARK: - Источник

/// Источник записи — «таблетка» со значком и подписью: включён — голубая рамка
/// и подложка, выключен — серая.
private struct SourcePill: View {
    let source: RecordingPreset.Source
    let isOn: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HeroMetrics.iconSpacing) {
                Image(systemName: source.systemImage)
                    .font(.system(size: HeroMetrics.symbolSize, weight: .medium))
                    .frame(minWidth: HeroMetrics.iconSize, minHeight: HeroMetrics.iconSize)
                Text(source.shortTitle)
                    .font(.system(size: HeroMetrics.textSize))
            }
            .foregroundStyle(isOn ? AppColors.accent : Color.primary.opacity(0.8))
            .padding(.horizontal, HeroMetrics.pillPaddingH)
            .padding(.vertical, HeroMetrics.pillPaddingV)
            .background {
                ZStack {
                    Capsule().fill(Color.primary.opacity(0.04))
                    if isOn { Capsule().fill(AppColors.accentFill) }
                }
            }
            .overlay(Capsule().strokeBorder(isOn ? AppColors.accent : Color.clear, lineWidth: HeroMetrics.accentBorder))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .help(isOn ? "\(source.title): включено" : "\(source.title): выключено")
        .accessibilityLabel(source.title)
        .accessibilityValue(isOn ? "включено" : "выключено")
    }
}
