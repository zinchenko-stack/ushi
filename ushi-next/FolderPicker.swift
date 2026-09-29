//
//  FolderPicker.swift
//  UshiNext
//
//  Выбор папки через NSOpenPanel — для external-Проектов (Phase 3):
//  создание Проекта и «Подключить заново…».
//

import AppKit

enum FolderPicker {
    /// Модально показать выбор папки. nil — юзер отменил.
    static func chooseFolder(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Выбрать"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
