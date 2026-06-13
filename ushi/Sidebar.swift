//
//  Sidebar.swift
//  ushi
//
//  Нативный macOS-сайдбар. Основные пункты — сверху, «Настройки» — прижаты к низу.
//  Иконки — Mage Icons (Apache 2.0), template SVG в Assets.xcassets, размер 16pt.
//

import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case recording, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: return "Новая запись"
        case .history:   return "Записи"
        case .settings:  return "Настройки"
        }
    }

    /// Имя ассета (Mage Icons, template SVG).
    var imageName: String {
        switch self {
        case .recording: return "Microphone"
        case .history:   return "Stack"
        case .settings:  return "Bolt"
        }
    }
}

struct Sidebar: View {
    @Binding var selection: SidebarSection?

    private let topItems: [SidebarSection] = [.recording, .history]

    var body: some View {
        List(selection: $selection) {
            ForEach(topItems) { section in
                SidebarRow(section: section)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Ushi")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Настройки прижаты к низу, селекшн делит общий $selection с верхним списком.
            List(selection: $selection) {
                SidebarRow(section: .settings)
                    .tag(SidebarSection.settings)
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: 44)
        }
    }
}

/// Строка сайдбара с фиксированным размером иконки 16pt (Label по умолчанию
/// масштабирует иконку с шрифтом, у Mage SVG это даёт слишком крупный значок).
private struct SidebarRow: View {
    let section: SidebarSection

    var body: some View {
        Label {
            Text(section.title)
        } icon: {
            Image(section.imageName)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 16, height: 16)
        }
    }
}
