//
//  ModelManager.swift
//  ushi
//

import Foundation
import Observation
import CryptoKit

@MainActor
@Observable
final class ModelManager {
    enum State {
        case checking
        case missing
        case downloading(bytesDownloaded: Int64, bytesTotal: Int64, bytesPerSecond: Double)
        case ready
        case failed(String)
    }

    static let shared = ModelManager()

    private static let defaultDownloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    )!
    /// Известный SHA-256 ggml-large-v3-turbo.bin с HuggingFace.
    /// Сверен с актуальным файлом 2026-06-14. Если HF обновит модель — этот хеш надо обновить.
    private static let expectedModelSHA256 =
        "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
    private static let minimumFreeSpace: Int64 = 2_000_000_000
    private static let dismissedOnboardingKey = "ushi.onboarding.dismissed"

    var state: State = .checking
    var userDismissedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(
                userDismissedOnboarding,
                forKey: Self.dismissedOnboardingKey
            )
        }
    }

    let modelURL: URL

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    @ObservationIgnored private let fileManager = FileManager.default
    @ObservationIgnored private let delegate: ModelDownloadDelegate
    @ObservationIgnored private let downloadURL: URL
    @ObservationIgnored private let supportDirectory: URL
    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60 * 24
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }()
    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var speedSamples: [(date: Date, bytes: Int64)] = []
    @ObservationIgnored private var hasChecked = false
    @ObservationIgnored private var usedResumeData = false
    @ObservationIgnored private var isUserCancellation = false
    @ObservationIgnored private var isPreparingForTermination = false

    private var resumeDataURL: URL {
        supportDirectory.appendingPathComponent("large-v3-turbo.resumeData")
    }

    private var stagingURL: URL {
        modelURL.appendingPathExtension("partial")
    }

    private convenience init() {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("ushi", isDirectory: true)
            .appendingPathComponent("model-download", isDirectory: true)
        self.init(
            modelURL: TranscriptionService.modelURL(),
            downloadURL: Self.defaultDownloadURL,
            supportDirectory: supportDirectory
        )
    }

    init(modelURL: URL, downloadURL: URL, supportDirectory: URL) {
        self.modelURL = modelURL
        self.downloadURL = downloadURL
        self.supportDirectory = supportDirectory
        self.userDismissedOnboarding = UserDefaults.standard.bool(
            forKey: Self.dismissedOnboardingKey
        )
        delegate = ModelDownloadDelegate(
            stagingURL: modelURL.appendingPathExtension("partial"),
            resumeDataURL: self.supportDirectory
                .appendingPathComponent("large-v3-turbo.resumeData")
        )
        delegate.owner = self
    }

    func checkInstalled() {
        guard !hasChecked else { return }
        hasChecked = true

        if fileManager.fileExists(atPath: modelURL.path) {
            try? fileManager.removeItem(at: resumeDataURL)
            try? fileManager.removeItem(at: stagingURL)
            userDismissedOnboarding = false
            state = .ready
            return
        }

        state = .missing
        startDownload()
    }

    func startDownload() {
        guard downloadTask == nil else { return }

        do {
            try prepareDirectories()
            try checkFreeSpace()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }

        isUserCancellation = false
        isPreparingForTermination = false
        speedSamples.removeAll(keepingCapacity: true)

        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumeDataURL), !resumeData.isEmpty {
            usedResumeData = true
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            usedResumeData = false
            task = session.downloadTask(with: downloadURL)
        }

        downloadTask = task
        state = .downloading(bytesDownloaded: 0, bytesTotal: 0, bytesPerSecond: 0)
        task.resume()
    }

    func cancelDownload() {
        guard let downloadTask else {
            try? fileManager.removeItem(at: resumeDataURL)
            try? fileManager.removeItem(at: stagingURL)
            state = .missing
            return
        }

        isUserCancellation = true
        delegate.discardResumeDataForNextCompletion()
        downloadTask.cancel()
    }

    /// Returns true when app termination must wait for resume data to be persisted.
    func prepareForTermination(completion: @escaping @MainActor () -> Void) -> Bool {
        guard let downloadTask else { return false }
        if isPreparingForTermination {
            return true
        }

        isPreparingForTermination = true
        let resumeDataURL = resumeDataURL
        let supportDirectory = supportDirectory

        downloadTask.cancel { resumeData in
            if let resumeData {
                try? FileManager.default.createDirectory(
                    at: supportDirectory,
                    withIntermediateDirectories: true
                )
                try? resumeData.write(to: resumeDataURL, options: .atomic)
            }

            Task { @MainActor in
                self.downloadTask = nil
                completion()
            }
        }
        return true
    }

    fileprivate func didWriteData(
        totalBytesWritten: Int64,
        totalBytesExpected: Int64
    ) {
        let now = Date()
        speedSamples.append((now, totalBytesWritten))
        speedSamples.removeAll { now.timeIntervalSince($0.date) > 5 }

        let speed: Double
        if let first = speedSamples.first,
           totalBytesWritten > first.bytes,
           now.timeIntervalSince(first.date) > 0 {
            speed = Double(totalBytesWritten - first.bytes) / now.timeIntervalSince(first.date)
        } else {
            speed = 0
        }

        state = .downloading(
            bytesDownloaded: totalBytesWritten,
            bytesTotal: max(0, totalBytesExpected),
            bytesPerSecond: speed
        )
    }

    fileprivate func didFinishDownload() {
        downloadTask = nil
        Task { @MainActor in
            await finalizeDownload()
        }
    }

    private func finalizeDownload() async {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: stagingURL.path)
            guard let fileSize = attributes[.size] as? NSNumber,
                  fileSize.int64Value > 0 else {
                throw ModelDownloadError.invalidDownload
            }

            if case .downloading(_, let expected, _) = state,
               expected > 0,
               fileSize.int64Value != expected {
                throw ModelDownloadError.incompleteDownload
            }

            let stagingPath = stagingURL.path
            let actualHash = try await Task.detached(priority: .userInitiated) {
                try Self.computeSHA256(ofFileAt: stagingPath)
            }.value
            guard actualHash.caseInsensitiveCompare(Self.expectedModelSHA256) == .orderedSame else {
                throw ModelDownloadError.checksumMismatch
            }

            try? fileManager.removeItem(at: modelURL)
            try fileManager.moveItem(at: stagingURL, to: modelURL)
            try? fileManager.removeItem(at: resumeDataURL)
            userDismissedOnboarding = false
            state = .ready
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            state = .failed(error.localizedDescription)
        }
    }

    /// Стриминговый SHA-256 для больших файлов — не грузит 1.5ГБ в память.
    /// Вызывается вне MainActor (через Task.detached).
    nonisolated private static func computeSHA256(ofFileAt path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func dismissOnboarding() {
        userDismissedOnboarding = true
    }

    func showOnboarding() {
        userDismissedOnboarding = false
    }

    fileprivate func didFailDownload(_ error: Error, resumeDataWasSaved: Bool) {
        downloadTask = nil

        if isUserCancellation {
            isUserCancellation = false
            try? fileManager.removeItem(at: resumeDataURL)
            try? fileManager.removeItem(at: stagingURL)
            speedSamples.removeAll()
            state = .missing
            return
        }
        if isPreparingForTermination {
            return
        }

        if usedResumeData, !resumeDataWasSaved {
            usedResumeData = false
            try? fileManager.removeItem(at: resumeDataURL)
            startDownload()
            return
        }

        state = .failed(friendlyMessage(for: error, canResume: resumeDataWasSaved))
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
    }

    private func checkFreeSpace() throws {
        let values = try modelURL.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        if let available = values.volumeAvailableCapacityForImportantUsage,
           available < Self.minimumFreeSpace {
            throw ModelDownloadError.insufficientDiskSpace
        }
    }

    private func friendlyMessage(for error: Error, canResume: Bool) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .timedOut:
                return canResume
                    ? "Соединение прервалось. Нажмите «Повторить», чтобы продолжить скачивание."
                    : "Нет соединения с интернетом. Проверьте сеть и попробуйте снова."
            case .cancelled:
                return "Скачивание было остановлено."
            default:
                break
            }
        }
        return "Не удалось скачать модель: \(error.localizedDescription)"
    }
}

private enum ModelDownloadError: LocalizedError {
    case insufficientDiskSpace
    case invalidDownload
    case incompleteDownload
    case checksumMismatch
    case serverError(Int)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace:
            return "Недостаточно свободного места на диске. Освободите хотя бы 2 ГБ."
        case .invalidDownload:
            return "Сервер вернул пустой файл модели. Попробуйте скачать ещё раз."
        case .incompleteDownload:
            return "Модель скачалась не полностью. Попробуйте продолжить скачивание."
        case .checksumMismatch:
            return "Скачанный файл повреждён (контрольная сумма не совпала). Нажмите «Повторить»."
        case .serverError(let statusCode):
            return "Сервер не смог отдать модель (HTTP \(statusCode)). Попробуйте позже."
        }
    }
}

private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var owner: ModelManager?

    private let stagingURL: URL
    private let resumeDataURL: URL
    private let lock = NSLock()
    private var shouldDiscardResumeData = false

    init(stagingURL: URL, resumeDataURL: URL) {
        self.stagingURL = stagingURL
        self.resumeDataURL = resumeDataURL
    }

    func discardResumeDataForNextCompletion() {
        lock.lock()
        shouldDiscardResumeData = true
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak owner] in
            owner?.didWriteData(
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                throw ModelDownloadError.serverError(response.statusCode)
            }

            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            Task { @MainActor [weak owner] in
                owner?.didFinishDownload()
            }
        } catch {
            Task { @MainActor [weak owner] in
                owner?.didFailDownload(error, resumeDataWasSaved: false)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        lock.lock()
        let discardResumeData = shouldDiscardResumeData
        shouldDiscardResumeData = false
        lock.unlock()

        if !discardResumeData, let resumeData, !resumeData.isEmpty {
            try? FileManager.default.createDirectory(
                at: resumeDataURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? resumeData.write(to: resumeDataURL, options: .atomic)
        }

        Task { @MainActor [weak owner] in
            owner?.didFailDownload(
                error,
                resumeDataWasSaved: !discardResumeData && resumeData != nil
            )
        }
    }
}
