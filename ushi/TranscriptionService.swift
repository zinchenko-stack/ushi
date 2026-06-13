//
//  TranscriptionService.swift
//  ushi
//
//  Локальная транскрипция через whisper.cpp (бинарь whisper-cli из Homebrew).
//  Шаги: m4a -> wav (afconvert) -> whisper-cli -> .txt
//

import Foundation

enum TranscriptionError: LocalizedError {
    case binaryNotFound(String)
    case modelNotFound(String)
    case conversionFailed(String)
    case whisperFailed(String)
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path): return "Не найден whisper-cli по пути: \(path). Установите: brew install whisper-cpp"
        case .modelNotFound(let path):  return "Не найдена модель по пути: \(path)"
        case .conversionFailed(let msg): return "Конвертация m4a→wav упала: \(msg)"
        case .whisperFailed(let msg):   return "whisper-cli упал: \(msg)"
        case .outputMissing:            return "whisper-cli не создал .txt"
        }
    }
}

struct TranscriptionService {

    private static let binaryCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cli",
        "/usr/local/bin/whisper-cpp",
    ]

    static func modelURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ushi/models/ggml-large-v3-turbo.bin")
    }

    static func vadModelURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ushi/models/ggml-silero-v5.1.2.bin")
    }

    /// VAD-модель silero (~865 КБ) — отсекает тишину, чтобы whisper не галлюцинировал на ней.
    private static let vadModelDownloadURL = URL(string:
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    private static func resolveBinary() -> String? {
        binaryCandidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Гарантирует наличие VAD-модели: если нет — пытается скачать.
    /// Возвращает путь, если модель доступна, иначе nil (тогда транскрибируем без VAD).
    private static func ensureVADModel() async -> URL? {
        let url = vadModelURL()
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let (tmp, response) = try await URLSession.shared.download(from: vadModelDownloadURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                try? FileManager.default.removeItem(at: tmp)
                return nil
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
            return url
        } catch {
            print("⚠️ VAD model download failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Пост-фильтр: выкидывает известные галлюцинации whisper (титры из YouTube,
    /// которые он дорисовывает на тишине) и схлопывает подряд идущие повторы строк.
    static func cleanTranscript(_ raw: String) -> String {
        // Подстроки, которых в реальной речи не бывает — строку целиком выкидываем.
        let bannedSubstrings = ["dimatorzok", "amara.org", "subtitles by", "редактор субтитров"]
        // Фразы-галлюцинации целиком (после нормализации).
        let bannedExact: Set<String> = [
            "продолжение следует",
            "спасибо за просмотр",
            "спасибо за внимание",
            "подписывайтесь на канал",
            "ставьте лайки",
        ]

        var kept: [String] = []
        var lastNorm: String?

        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            let norm = line.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t.,!?…-—\"'«»()"))

            if bannedSubstrings.contains(where: { norm.contains($0) }) { continue }
            if bannedExact.contains(norm) { continue }
            if norm.hasPrefix("субтитр") { continue }

            // Схлопываем подряд идущие одинаковые строки (типичный луп галлюцинации).
            if norm == lastNorm { continue }
            lastNorm = norm
            kept.append(line)
        }

        return kept.joined(separator: "\n")
    }

    static func transcribe(audioURL: URL, language: String? = nil) async throws -> URL {
        // nil → берём язык из настроек (Авто/Русский/Английский).
        let language = language ?? AppSettings.transcriptionLanguage().rawValue
        guard let binary = resolveBinary() else {
            throw TranscriptionError.binaryNotFound(binaryCandidates.joined(separator: ", "))
        }
        let model = modelURL()
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw TranscriptionError.modelNotFound(model.path)
        }

        // Запрещаем системе уходить в idle-сон, пока идёт транскрипция.
        // (Сон по закрытию крышки этим не отключается — это требует caffeinate.)
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "ushi transcription"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }

        #if DEBUG
        print("🧠 [transcribe] input: \(audioURL.path)")
        let t0 = Date()
        #endif

        let wavURL = audioURL.deletingPathExtension().appendingPathExtension("wav")
        try await convertToWav(input: audioURL, output: wavURL)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        #if DEBUG
        print("🧠 [transcribe] wav ready in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        let t1 = Date()
        #endif

        // VAD-модель (silero) — отсекает тишину. Если её нет/не скачалась, идём без VAD.
        let vadModel = await ensureVADModel()

        let outputPrefix = audioURL.deletingPathExtension().path
        try await runWhisper(
            binary: binary,
            model: model.path,
            wavPath: wavURL.path,
            language: language,
            outputPrefix: outputPrefix,
            vadModel: vadModel
        )

        #if DEBUG
        print("🧠 [transcribe] whisper done in \(String(format: "%.1f", Date().timeIntervalSince(t1)))s")
        #endif

        let txtURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: txtURL.path) else {
            throw TranscriptionError.outputMissing
        }

        // Пост-фильтр галлюцинаций (сетка безопасности поверх VAD).
        if let raw = try? String(contentsOf: txtURL, encoding: .utf8) {
            let cleaned = cleanTranscript(raw)
            try? cleaned.write(to: txtURL, atomically: true, encoding: .utf8)
        }

        return txtURL
    }

    // MARK: - afconvert

    private static func convertToWav(input: URL, output: URL) async throws {
        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [
            input.path,
            output.path,
            "-d", "LEI16@16000",
            "-f", "WAVE",
            "-c", "1",
        ]
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try await runProcess(process) { code, errData in
            if code != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? "code \(code)"
                throw TranscriptionError.conversionFailed(msg)
            }
        }
    }

    // MARK: - whisper-cli

    private static func runWhisper(
        binary: String, model: String, wavPath: String,
        language: String, outputPrefix: String, vadModel: URL?
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = [
            "-m", model,
            "-f", wavPath,
            "-l", language,
            "-otxt",
            "-of", outputPrefix,
            "--suppress-nst",            // давим неречевые токены
        ]
        if let vadModel {
            args += ["--vad", "--vad-model", vadModel.path]
        }
        process.arguments = args
        process.standardError = Pipe()
        process.standardOutput = Pipe()

        try await runProcess(process) { code, errData in
            if code != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? "code \(code)"
                throw TranscriptionError.whisperFailed(msg)
            }
        }
    }

    // MARK: - Process helper

    private static func runProcess(
        _ process: Process,
        onExit: @escaping (Int32, Data) throws -> Void
    ) async throws {
        let errPipe = process.standardError as? Pipe
        let outPipe = process.standardOutput as? Pipe

        let errBox = DataBox()
        errPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                errBox.append(data)
            }
        }
        outPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                errPipe?.fileHandleForReading.readabilityHandler = nil
                outPipe?.fileHandleForReading.readabilityHandler = nil
                try? errPipe?.fileHandleForReading.close()
                try? outPipe?.fileHandleForReading.close()
                try? errPipe?.fileHandleForWriting.close()
                try? outPipe?.fileHandleForWriting.close()
                do {
                    try onExit(proc.terminationStatus, errBox.snapshot())
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
