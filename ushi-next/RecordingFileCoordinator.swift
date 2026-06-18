//
//  RecordingFileCoordinator.swift
//  UshiNext
//
//  Сервис для координации I/O операций с файлами записей.
//

import Foundation

final class RecordingFileCoordinator {
    func deleteFiles(for recording: Recording) {
        let fm = FileManager.default
        // Идём через резолвер — он находит файл даже если был переименован/перемещён.
        if let (audioURL, _) = recording.resolveAudioURL() {
            try? fm.removeItem(at: audioURL)
        }
        if let (txtURL, _) = recording.resolveTranscriptURL() {
            try? fm.removeItem(at: txtURL)
        }
    }
}
