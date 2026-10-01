//
//  SidebarToggle.swift
//  UshiNext
//
//  Кнопка сворачивания левой колонки — как в Claude Code: простая иконка
//  панели без «пузыря». Пока колонка открыта, кнопка стоит в правом верхнем
//  углу колонки (напротив «светофора»); свёрнута — сразу после «светофора».
//
//  Кнопка живёт в панели инструментов окна (иначе по ней нельзя кликнуть —
//  заголовок окна перехватывает клики). Чтобы сдвинуть её к правому краю
//  колонки, меряем, где в окне начинается элемент панели инструментов, и
//  добавляем перед кнопкой прозрачный отступ нужной ширины.
//

import SwiftUI
import AppKit

struct SidebarToggleToolbar: ToolbarContent {
    @Binding var isSidebarVisible: Bool
    /// X начала элемента панели инструментов в координатах окна (меряется на лету).
    @Binding var itemStartX: CGFloat

    private let buttonSize: CGFloat = 28
    private let trailingInset: CGFloat = 8

    /// Отступ, чтобы кнопка встала у правого края открытой колонки.
    private var offset: CGFloat {
        guard isSidebarVisible else { return 0 }
        return max(0, SidebarMetrics.width - itemStartX - buttonSize - trailingInset)
    }

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { content }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { content }
        }
    }

    private var content: some View {
        HStack(spacing: 0) {
            WindowXReader { x in
                if abs(x - itemStartX) > 0.5 { itemStartX = x }
            }
            .frame(width: 0, height: 0)

            Color.clear.frame(width: offset, height: 1)

            SidebarToggleButton(isSidebarVisible: $isSidebarVisible, size: buttonSize)
        }
    }
}

private struct SidebarToggleButton: View {
    @Binding var isSidebarVisible: Bool
    let size: CGFloat

    var body: some View {
        ToolbarIconButton(
            imageName: "PanelLeft",
            help: isSidebarVisible ? "Скрыть боковую панель (⌃⌘S)" : "Показать боковую панель (⌃⌘S)"
        ) {
            withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() }
        }
        .keyboardShortcut("s", modifiers: [.control, .command])
    }
}

/// Сообщает X своего левого края в координатах окна (на каждой раскладке).
private struct WindowXReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReportingView, context: Context) {
        nsView.onChange = onChange
        nsView.report()
    }

    final class ReportingView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard window != nil else { return }
            let x = convert(bounds.origin, to: nil).x
            DispatchQueue.main.async { [weak self] in self?.onChange?(x) }
        }
    }
}

/// Убирает заголовок экрана из панели инструментов окна.
struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content.navigationTitle("")
        }
    }
}

// MARK: - Иконки в панели окна в стиле Claude Code

/// Простая иконка без «пузыря»: серая, при наведении ярче и с лёгкой подложкой.
struct ToolbarIconButton: View {
    let imageName: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(imageName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 17, height: 17)
                .foregroundStyle(isHovered && isEnabled ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isHovered && isEnabled ? 0.07 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Иконка справа вверху окна (без стеклянной подложки на macOS 26).
struct TrailingToolbarIcon: ToolbarContent {
    let imageName: String
    let help: String
    var isEnabled = true
    let action: () -> Void

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { button }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { button }
        }
    }

    private var button: some View {
        ToolbarIconButton(imageName: imageName, help: help, isEnabled: isEnabled, action: action)
    }
}
