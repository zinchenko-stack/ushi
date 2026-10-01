//
//  FolderPicker.swift
//  UshiNext
//
//  Выбор папки через NSOpenPanel — для external-Проектов (Phase 3):
//  создание Проекта и «Подключить заново…».
//

import AppKit
import UniformTypeIdentifiers

enum FolderPicker {
    /// Модально показать выбор папки. nil — юзер отменил.
    static func chooseFolder(message: String, prompt: String = "Выбрать") -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Выбрать один или несколько аудиофайлов для загрузки на расшифровку.
    static func chooseAudioFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = RecordingsStore.importableAudioExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Выберите аудио для расшифровки"
        panel.prompt = "Загрузить"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }
}
