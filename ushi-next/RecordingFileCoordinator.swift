//
//  RecordingFileCoordinator.swift
//  UshiNext
//
//  Сервис для координации I/O операций с файлами записей.
//

import Foundation

struct RenameResult {
    let audioFileName: String
    let audioBookmark: Data?
    let transcriptFileName: String?
    let transcriptBookmark: Data?
}

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
        if let voiceURL = recording.voiceTrackURL() {
            try? fm.removeItem(at: voiceURL)
        }
    }

    /// Переименовывает файлы записи на диске под новое название и возвращает обновленные пути и закладки.
    /// Не делает изменений в UI-кэше стора, работает только с файловой системой.
    func renameFilesOnDisk(
        recording: Recording,
        newTitle: String,
        mediaDir: URL
    ) -> RenameResult {
        let base = sanitizeFilename(newTitle)
        guard !base.isEmpty else {
            return RenameResult(
                audioFileName: recording.audioFileName,
                audioBookmark: recording.audioBookmark,
                transcriptFileName: recording.transcriptFileName,
                transcriptBookmark: recording.transcriptBookmark
            )
        }

        let fm = FileManager.default
        let txtDir = recording.transcriptDirectoryURL()
        let audioExt = (recording.audioFileName as NSString).pathExtension
        let resolved = uniqueBaseName(
            base: base,
            mediaDir: mediaDir,
            txtDir: txtDir,
            audioExt: audioExt,
            currentAudio: recording.audioFileName,
            currentTranscript: recording.transcriptFileName
        )

        var audioFileName = recording.audioFileName
        var audioBookmark = recording.audioBookmark
        var transcriptFileName = recording.transcriptFileName
        var transcriptBookmark = recording.transcriptBookmark

        // Аудио / видео — переименовываем только если файл ещё на диске и не помечен как удалённый.
        if !recording.audioFileName.isEmpty, !recording.audioRemoved, !audioExt.isEmpty {
            let from = mediaDir.appendingPathComponent(recording.audioFileName)
            let to = mediaDir.appendingPathComponent("\(resolved).\(audioExt)")
            if from != to, fm.fileExists(atPath: from.path) {
                do {
                    try fm.moveItem(at: from, to: to)
                    audioFileName = to.lastPathComponent
                    audioBookmark = FileBookmark.create(from: to)
                } catch {
                    print("❌ rename audio failed: \(error.localizedDescription)")
                }
            }
        }

        // Текстовый транскрипт.
        if let txt = recording.transcriptFileName, !txt.isEmpty, let txtDir {
            let from = txtDir.appendingPathComponent(txt)
            let to = txtDir.appendingPathComponent("\(resolved).txt")
            if from != to, fm.fileExists(atPath: from.path) {
                do {
                    try fm.moveItem(at: from, to: to)
                    transcriptFileName = to.lastPathComponent
                    transcriptBookmark = FileBookmark.create(from: to)
                } catch {
                    print("❌ rename transcript failed: \(error.localizedDescription)")
                }
            }
        }

        return RenameResult(
            audioFileName: audioFileName,
            audioBookmark: audioBookmark,
            transcriptFileName: transcriptFileName,
            transcriptBookmark: transcriptBookmark
        )
    }

    private func uniqueBaseName(
        base: String,
        mediaDir: URL,
        txtDir: URL?,
        audioExt: String,
        currentAudio: String,
        currentTranscript: String?
    ) -> String {
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while true {
            let audioName = audioExt.isEmpty ? "" : "\(candidate).\(audioExt)"
            let txtName = "\(candidate).txt"
            let audioPath = audioName.isEmpty ? nil : mediaDir.appendingPathComponent(audioName).path
            let txtPath = txtDir?.appendingPathComponent(txtName).path

            let audioOK = audioPath.map { !fm.fileExists(atPath: $0) || audioName == currentAudio } ?? true
            let txtOK = txtPath.map { !fm.fileExists(atPath: $0) || txtName == currentTranscript } ?? true

            if audioOK && txtOK { return candidate }
            candidate = "\(base) (\(n))"
            n += 1
            if n > 999 { return candidate }
        }
    }

    private func sanitizeFilename(_ raw: String) -> String {
        let invalid: Set<Character> = ["/", "\\", ":", "\0"]
        var s = String(raw.map { invalid.contains($0) ? "-" : $0 })
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.count > 100 {
            s = String(s.prefix(100)).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
