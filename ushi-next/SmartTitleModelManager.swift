import Foundation
import Observation
import CryptoKit

nonisolated enum SmartTitleModelSpec {
    static let fileName = "gemma-3-1b-it-Q4_K_M.gguf"
    static let byteCount: Int64 = 806_058_240
    static let sizeDescription = "806 МБ"
    static let sha256 = "8d78d9d059a7605c401c105e169e0b08e9f0edc603ceb842f1c4bbb834296d17"
    static let downloadURL = URL(string: "https://huggingface.co/lmstudio-community/gemma-3-1b-it-GGUF/resolve/a991bcc937ec839f890a92547945cfd4b07e23c8/gemma-3-1b-it-Q4_K_M.gguf")!
    static let modelURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ushi/models/" + fileName)
}

@MainActor @Observable
final class SmartTitleModelManager {
    enum State: Equatable {
        case missing, paused, checking, ready
        case downloading(received: Int64, total: Int64)
        case failed(String)
    }
    static let shared = SmartTitleModelManager()
    static let enabledKey = "settings.smartTitlesEnabled"
    private(set) var enabled: Bool
    private(set) var state: State = .missing
    private(set) var isPausing = false
    let modelURL: URL
    var isReady: Bool { enabled && state == .ready }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let support: URL
    @ObservationIgnored private let downloadURL: URL
    @ObservationIgnored private let expectedBytes: Int64
    @ObservationIgnored private let expectedHash: String
    @ObservationIgnored private let delegate: SmartTitleDownloadDelegate
    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86_400
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }()
    @ObservationIgnored private var download: URLSessionDownloadTask?
    @ObservationIgnored private var verification: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var resumed = false
    @ObservationIgnored private var resumeAfterPause = false

    private var resumeURL: URL { support.appendingPathComponent("gemma.resumeData") }
    private var stagedURL: URL { support.appendingPathComponent("gemma.partial") }

    init(modelURL: URL = SmartTitleModelSpec.modelURL,
         downloadURL: URL = SmartTitleModelSpec.downloadURL,
         support: URL? = nil, defaults: UserDefaults = .standard,
         expectedBytes: Int64 = SmartTitleModelSpec.byteCount,
         expectedHash: String = SmartTitleModelSpec.sha256) {
        self.modelURL = modelURL
        self.downloadURL = downloadURL
        self.support = support ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppContainer.name + "/smart-title-download")
        self.defaults = defaults
        self.expectedBytes = expectedBytes
        self.expectedHash = expectedHash
        enabled = defaults.bool(forKey: Self.enabledKey)
        delegate = SmartTitleDownloadDelegate(directory: self.support)
        delegate.owner = self
    }

    /// Restoring a disabled feature never creates folders or starts a request.
    func restore() {
        guard !restored else { return }
        restored = true
        if enabled { startDownload() }
    }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { startDownload() }
        else {
            revision = UUID()
            verification?.cancel()
            verification = nil
            if download != nil { pauseDownload() }
            else if state != .ready { state = .paused }
        }
    }

    func startDownload() {
        guard enabled else { return }
        if isPausing { resumeAfterPause = true; return }
        guard download == nil, verification == nil else { return }
        if FileManager.default.fileExists(atPath: modelURL.path) {
            verify(modelURL, installing: false)
        } else if FileManager.default.fileExists(atPath: stagedURL.path) {
            verify(stagedURL, installing: true)
        } else {
            beginRequest()
        }
    }

    private func beginRequest() {
        guard enabled, download == nil else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.createDirectory(at: modelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let capacity = try modelURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = capacity.volumeAvailableCapacityForImportantUsage, available < expectedBytes * 2 {
                throw SmartTitleDownloadError.message("Недостаточно места. Освободите около 1,7 ГБ для загрузки модели.")
            }
            let task: URLSessionDownloadTask
            if let data = try? Data(contentsOf: resumeURL), !data.isEmpty {
                resumed = true
                task = session.downloadTask(withResumeData: data)
            } else {
                resumed = false
                task = session.downloadTask(with: downloadURL)
            }
            download = task
            state = .downloading(received: 0, total: expectedBytes)
            task.resume()
        } catch { state = .failed(error.localizedDescription) }
    }

    func pauseDownload() { _ = pause(completion: {}) }

    /// AppDelegate waits for both model managers independently on termination.
    func prepareForTermination(completion: @escaping @MainActor () -> Void) -> Bool {
        pause(completion: completion)
    }

    @ObservationIgnored private var pauseCompletions: [@MainActor () -> Void] = []
    private func pause(completion: @escaping @MainActor () -> Void) -> Bool {
        guard let download else { return false }
        pauseCompletions.append(completion)
        guard !isPausing else { return true }
        isPausing = true
        let id = download.taskIdentifier
        download.cancel { [weak self] data in
            Task { @MainActor in
                guard let self, self.download?.taskIdentifier == id else { return }
                if let data { try? data.write(to: self.resumeURL, options: .atomic) }
                self.download = nil
                self.isPausing = false
                self.state = .paused
                let callbacks = self.pauseCompletions
                self.pauseCompletions.removeAll()
                callbacks.forEach { $0() }
                if self.resumeAfterPause {
                    self.resumeAfterPause = false
                    self.startDownload()
                }
            }
        }
        return true
    }

    fileprivate func progress(id: Int, bytes: Int64, total: Int64) {
        guard download?.taskIdentifier == id, !isPausing else { return }
        state = .downloading(received: bytes, total: total > 0 ? total : expectedBytes)
    }

    fileprivate func finished(id: Int, file: URL) {
        guard download?.taskIdentifier == id, !isPausing, enabled else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        download = nil
        do {
            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.moveItem(at: file, to: stagedURL)
            verify(stagedURL, installing: true)
        } catch { state = .failed(error.localizedDescription) }
    }

    fileprivate func failed(id: Int, error: Error, resumeData: Data?) {
        guard download?.taskIdentifier == id, !isPausing else { return }
        download = nil
        if let resumeData { try? resumeData.write(to: resumeURL, options: .atomic) }
        if resumed, resumeData == nil {
            try? FileManager.default.removeItem(at: resumeURL)
            resumed = false
            beginRequest()
            return
        }
        state = .failed("Не удалось скачать модель. Проверьте интернет и нажмите «Продолжить». " + error.localizedDescription)
    }

    private func verify(_ file: URL, installing: Bool) {
        state = .checking
        let current = UUID()
        revision = current
        let bytes = expectedBytes, hash = expectedHash
        verification = Task { [weak self] in
            let valid = await Task.detached(priority: .utility) {
                Self.validate(file: file, expectedBytes: bytes, expectedHash: hash)
            }.value
            guard let self, self.revision == current, self.enabled, !Task.isCancelled else { return }
            self.verification = nil
            guard valid else {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: self.resumeURL)
                self.state = .failed("Файл модели повреждён. Нажмите «Продолжить», чтобы скачать его заново.")
                return
            }
            do {
                if installing {
                    try FileManager.default.moveItem(at: file, to: self.modelURL)
                }
                try? FileManager.default.removeItem(at: self.resumeURL)
                self.state = .ready
            } catch { self.state = .failed(error.localizedDescription) }
        }
    }

    nonisolated static func validate(file: URL, expectedBytes: Int64, expectedHash: String) -> Bool {
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == expectedBytes else { return false }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == expectedHash
        } catch { return false }
    }
}

nonisolated private enum SmartTitleDownloadError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

nonisolated private final class SmartTitleDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var owner: SmartTitleModelManager?
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor [weak owner] in owner?.progress(id: id, bytes: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskIdentifier
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                throw SmartTitleDownloadError.message("Сервер не смог отдать модель.")
            }
            let destination = directory.appendingPathComponent(UUID().uuidString + ".partial")
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor [weak owner] in owner?.finished(id: id, file: destination) }
        } catch {
            Task { @MainActor [weak owner] in owner?.failed(id: id, error: error, resumeData: nil) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskIdentifier
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor [weak owner] in owner?.failed(id: id, error: error, resumeData: resume) }
    }
}
