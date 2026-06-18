//
//  AudioRecorder.swift
//  ushi
//
//  Движок записи созвона через ScreenCaptureKit.
//  Захватывает СИСТЕМНЫЙ звук (голос собеседника) и МИКРОФОН (твой голос)
//  одним стримом, сводит их вживую в один моно-AAC. Опционально пишет ещё и
//  ВИДЕО всего экрана — тогда выход .mov (видео + сведённый звук).
//
//  Всё пишется через AVAssetWriter: аудио-вход всегда, видео-вход — по флагу.
//  Аудио и видео идут по часам одного SCStream, поэтому совпадают по времени.
//  Захват микрофона требует macOS 15+; на 14.x пишется только система.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import Observation
import CoreMedia

@Observable
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    // MARK: Публичное состояние (UI наблюдает за ним)

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Float = 0          // 0...1, для индикатора

    /// Писать ли микрофон (твой голос). Меняется только когда запись не идёт.
    var micEnabled = true

    /// Писать ли видео всего экрана. Меняется только когда запись не идёт.
    /// false = только звук (.m4a), true = видео + звук (.mov).
    var captureVideo = false

    // MARK: Приватное

    private var stream: SCStream?
    private var writer: RecordingWriter?
    private var currentFileURL: URL?
    private var startDate: Date?
    private var timer: Timer?

    // Очередь для колбэков ScreenCaptureKit. Сюда приходят аудио, микрофон и видео —
    // writer живёт на этой же очереди, поэтому ему не нужны блокировки.
    private let sampleQueue = DispatchQueue(label: "ushi.audio.samples")

    // Дросселирование UI-апдейтов уровня (макс ~20 fps).
    private var lastLevelUpdate: Date = .distantPast
    private let levelUpdateInterval: TimeInterval = 0.05

    // Последний RMS по каждому источнику отдельно — индикатор показывает максимум.
    private var lastSystemRMS: Float = 0
    private var lastMicRMS: Float = 0

    // MARK: Старт

    func start() async throws {
        guard !isRecording else { return }

        // 0. Доступ к микрофону спрашиваем ПЕРВЫМ (до Screen Recording),
        //    чтобы prompt разрешился заранее и первая же запись писала твой голос.
        var useMic = false
        if micEnabled, #available(macOS 15.0, *) {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                useMic = true
            case .notDetermined:
                useMic = await AVCaptureDevice.requestAccess(for: .audio)
            default:
                throw NSError(domain: "ushi", code: 4, userInfo: [NSLocalizedDescriptionKey:
                    "Нет доступа к микрофону. Разреши его в Системных настройках → Конфиденциальность и безопасность → Микрофон, либо выключи микрофон в приложении, чтобы писать только системный звук."])
            }
        }

        // 1. Список захватываемых дисплеев (триггерит запрос на Screen Recording).
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "ushi", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Не найден дисплей для захвата"])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2

        // Видео всего экрана — по флагу. Без видео держим минимальный кадр 2×2 (нужен SCK).
        let wantVideo = captureVideo
        var videoSize = CGSize(width: 2, height: 2)
        var videoBitrate = 0
        if wantVideo {
            // Пресет качества из настроек: пропорциональное уменьшение по высоте.
            let quality = AppSettings.videoQuality()
            let srcW = max(2, display.width)
            let srcH = max(2, display.height)
            let (w, h): (Int, Int)
            if let maxH = quality.maxHeight, srcH > maxH {
                let scale = Double(maxH) / Double(srcH)
                w = max(2, Int((Double(srcW) * scale).rounded()))
                h = maxH
            } else {
                w = srcW
                h = srcH
            }
            videoSize = CGSize(width: w, height: h)
            videoBitrate = quality.bitrateBitsPerSecond
            config.width = w
            config.height = h
            config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(quality.fps))
            config.queueDepth = 8
            config.showsCursor = true
        } else {
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.queueDepth = 6
        }

        // Захват микрофона — отдельный поток того же стрима (macOS 15+).
        if useMic, #available(macOS 15.0, *) {
            config.captureMicrophone = true
            // microphoneCaptureDeviceID = nil → системный микрофон по умолчанию.
        }

        // 2. Готовим writer (на sampleQueue, чтобы избежать гонок).
        let fileURL = try makeOutputURL(video: wantVideo)
        let writer = try RecordingWriter(outputURL: fileURL, video: wantVideo,
                                         videoSize: videoSize, videoBitrate: videoBitrate)

        sampleQueue.sync {
            self.currentFileURL = fileURL
            self.writer = writer
        }

        // 3. Создаём поток и подписываемся на нужные типы.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        if useMic, #available(macOS 15.0, *) {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        if wantVideo {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream

        try await stream.startCapture()

        await MainActor.run {
            self.startDate = Date()
            self.elapsed = 0
            self.isRecording = true
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    // MARK: Стоп

    @discardableResult
    func stop() async throws -> (url: URL, duration: TimeInterval) {
        guard isRecording else {
            throw NSError(domain: "ushi", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Запись не идёт"])
        }

        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil

        let duration = elapsed
        await MainActor.run {
            self.timer?.invalidate()
            self.timer = nil
            self.isRecording = false
            self.level = 0
            self.elapsed = 0          // сбрасываем таймер сразу, чтобы не висели старые цифры
        }

        // На sampleQueue дописываем хвост и закрываем входы — после барьера гарантировано,
        // что все sample-колбэки отработали. finishWriting() ждём уже вне очереди.
        let (writer, url): (RecordingWriter?, URL?) = await withCheckedContinuation { cont in
            sampleQueue.async {
                let w = self.writer
                let u = self.currentFileURL
                w?.finishInputs()
                self.writer = nil
                self.currentFileURL = nil
                self.lastSystemRMS = 0
                self.lastMicRMS = 0
                cont.resume(returning: (w, u))
            }
        }
        await writer?.complete()

        await MainActor.run { self.startDate = nil }

        guard let url else {
            throw NSError(domain: "ushi", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Файл не создан"])
        }
        return (url, duration)
    }

    // MARK: SCStreamOutput — приём буферов (на sampleQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }

        switch outputType {
        case .screen:
            if Self.isCompleteFrame(sampleBuffer) {
                writer?.appendVideo(sampleBuffer)
            }
        case .audio:
            let rms = writer?.appendAudio(sampleBuffer, source: .system) ?? 0
            updateLevel(rms: rms, source: .system)
        default:
            if #available(macOS 15.0, *), outputType == .microphone {
                let rms = writer?.appendAudio(sampleBuffer, source: .microphone) ?? 0
                updateLevel(rms: rms, source: .microphone)
            }
        }
    }

    /// Видеокадр считается готовым только со статусом .complete (иначе это пустой/повторный кадр).
    private static func isCompleteFrame(_ sb: CMSampleBuffer) -> Bool {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = arr.first,
              let raw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async {
            let w = self.writer
            w?.finishInputs()
            self.writer = nil
            self.currentFileURL = nil
            self.lastSystemRMS = 0
            self.lastMicRMS = 0
            Task { await w?.complete() }
        }

        Task { @MainActor in
            self.isRecording = false
            self.timer?.invalidate()
            self.timer = nil
            self.level = 0
        }
    }

    // MARK: Уровень входа — с дросселированием

    private func updateLevel(rms: Float, source: RecordingWriter.Source) {
        switch source {
        case .system:     lastSystemRMS = rms
        case .microphone: lastMicRMS = rms
        }

        let now = Date()
        if now.timeIntervalSince(lastLevelUpdate) < levelUpdateInterval { return }
        lastLevelUpdate = now

        // Берём громкость самого активного источника — иначе тишина одного гасит другой.
        let combined = Swift.max(lastSystemRMS, lastMicRMS)
        let normalized = min(1, max(0, combined * 4))
        Task { @MainActor in
            self.level = self.level * 0.6 + normalized * 0.4
        }
    }

    // MARK: Файлы

    private func makeOutputURL(video: Bool) throws -> URL {
        let dir = try Self.documentsDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let ext = video ? "mov" : "m4a"
        let name = formatter.string(from: Date()) + "." + ext
        return dir.appendingPathComponent(name)
    }

    static func documentsDirectory() throws -> URL {
        try AppSettings.recordingsDirectory()
    }
}

// MARK: - Writer: сведённый звук (+ опц. видео) в один файл через AVAssetWriter

/// Пишет аудио-микс (система + микрофон) и, если задано, видео экрана в один файл.
/// Все методы вызываются на одной очереди (sampleQueue), кроме complete().
private final class RecordingWriter {

    enum Source { case system, microphone }

    private let writer: AVAssetWriter
    private let audioInput: AVAssetWriterInput
    private let videoInput: AVAssetWriterInput?

    // Общая точка отсчёта таймлайна (PTS первого пришедшего буфера любого типа).
    private var anchor: CMTime?

    // Канонический формат микса: mono float32 48 kHz.
    private let canonical: AVAudioFormat
    private var audioFormatDesc: CMFormatDescription?
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?

    // Аккумулятор моно-микса (суммирование с перекрытием по абсолютным сэмплам).
    private var mix: [Float] = []
    private var mixBase: Int64 = 0          // абсолютный индекс сэмпла mix[0] (0 == anchor)
    private var maxFrame: Int64 = 0         // максимум (start+len) среди принятых
    private let lagFrames: Int64 = 14_400   // ~0.3 с запас перед флашем

    init(outputURL: URL, video: Bool, videoSize: CGSize, videoBitrate: Int) throws {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: video ? .mov : .m4a)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw NSError(domain: "ushi", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось добавить аудио-дорожку"])
        }
        writer.add(audioInput)

        if video {
            var compression: [String: Any] = [:]
            if videoBitrate > 0 {
                compression[AVVideoAverageBitRateKey] = videoBitrate
            }
            var videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(videoSize.width),
                AVVideoHeightKey: Int(videoSize.height),
            ]
            if !compression.isEmpty {
                videoSettings[AVVideoCompressionPropertiesKey] = compression
            }
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vi.expectsMediaDataInRealTime = true
            if writer.canAdd(vi) {
                writer.add(vi)
                videoInput = vi
            } else {
                videoInput = nil
            }
        } else {
            videoInput = nil
        }

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 48_000, channels: 1, interleaved: false) else {
            throw NSError(domain: "ushi", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось создать аудиоформат"])
        }
        canonical = fmt

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "ushi", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось начать запись"])
        }
    }

    // MARK: Видео

    func appendVideo(_ sb: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isNumeric else { return }
        ensureAnchor(pts)
        guard let anchor, CMTimeCompare(pts, anchor) >= 0 else { return }
        guard let vi = videoInput, vi.isReadyForMoreMediaData else { return }
        vi.append(sb)
    }

    // MARK: Аудио (микс)

    /// Подмешивает буфер источника в аккумулятор и флашит готовую (старую) часть.
    /// Возвращает RMS этого куска — для индикатора уровня.
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer, source: Source) -> Float {
        guard let mono = monoSamples(from: sampleBuffer, source: source) else { return 0 }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isNumeric else { return 0 }
        ensureAnchor(pts)
        guard let anchor else { return 0 }

        let start = Int64(((CMTimeGetSeconds(pts) - CMTimeGetSeconds(anchor)) * 48_000).rounded())
        let n = mono.count
        guard n > 0 else { return 0 }

        // Куда писать в аккумуляторе. Если кусок старше уже флашнутого — отрезаем начало.
        var idx = Int(start - mixBase)
        var srcOffset = 0
        if idx < 0 {
            srcOffset = -idx
            idx = 0
        }
        guard srcOffset < n else { return 0 }

        let end = idx + (n - srcOffset)
        if end > mix.count {
            mix.append(contentsOf: repeatElement(0, count: end - mix.count))
        }

        var i = idx
        var s = srcOffset
        var sumSq: Float = 0
        while s < n {
            let v = mono[s]
            mix[i] += v
            sumSq += v * v
            i += 1
            s += 1
        }
        maxFrame = Swift.max(maxFrame, start + Int64(n))

        flush(upTo: maxFrame - lagFrames)
        return sqrt(sumSq / Float(n))
    }

    // MARK: Финал

    /// Дописывает остаток и помечает входы законченными. Вызывать на sampleQueue.
    func finishInputs() {
        flush(upTo: maxFrame, force: true)
        audioInput.markAsFinished()
        videoInput?.markAsFinished()
    }

    /// Дожидается записи файла на диск. Вызывать вне sampleQueue.
    func complete() async {
        await writer.finishWriting()
        if let err = writer.error {
            print("❌ writer error: \(err)")
        }
    }

    // MARK: Внутреннее

    private func ensureAnchor(_ pts: CMTime) {
        guard anchor == nil else { return }
        anchor = pts
        writer.startSession(atSourceTime: pts)
    }

    private func flush(upTo absFrame: Int64, force: Bool = false) {
        guard let anchor else { return }
        let count = Int(absFrame - mixBase)
        guard count > 0, count <= mix.count else { return }
        guard force || audioInput.isReadyForMoreMediaData else { return }

        guard let pcm = AVAudioPCMBuffer(pcmFormat: canonical,
                                         frameCapacity: AVAudioFrameCount(count)) else { return }
        pcm.frameLength = AVAudioFrameCount(count)
        if let dst = pcm.floatChannelData?[0] {
            mix.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    dst.update(from: base, count: count)
                }
            }
        }

        let pts = CMTimeAdd(anchor, CMTime(value: mixBase, timescale: 48_000))
        guard let sb = makeAudioSampleBuffer(from: pcm, pts: pts) else { return }
        audioInput.append(sb)

        mix.removeFirst(count)
        mixBase += Int64(count)
    }

    private func makeAudioSampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        if audioFormatDesc == nil {
            var fd: CMFormatDescription?
            let status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: pcm.format.streamDescription,
                layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &fd)
            guard status == noErr else { return nil }
            audioFormatDesc = fd
        }
        guard let fd = audioFormatDesc else { return nil }

        var sb: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: fd, sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &sb)
        guard createStatus == noErr, let sb else { return nil }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sb, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.mutableAudioBufferList)
        guard setStatus == noErr else { return nil }
        return sb
    }

    // MARK: CMSampleBuffer → mono float32 48k

    private func monoSamples(from sampleBuffer: CMSampleBuffer, source: Source) -> [Float]? {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return nil }
        var asbd = asbdPtr.pointee
        guard let inFormat = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        inBuf.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: inBuf.mutableAudioBufferList)
        guard status == noErr else { return nil }

        guard let converter = converter(for: source, from: inFormat) else { return nil }

        let ratio = canonical.sampleRate / inFormat.sampleRate
        let outCap = AVAudioFrameCount(Double(frames) * ratio + 1_024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: outCap) else { return nil }

        var fed = false
        var convError: NSError?
        let result = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if result == .error { return nil }

        let outN = Int(outBuf.frameLength)
        guard outN > 0, let ch = outBuf.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: outN))
    }

    private func converter(for source: Source, from inFormat: AVAudioFormat) -> AVAudioConverter? {
        switch source {
        case .system:
            if systemConverter == nil {
                systemConverter = AVAudioConverter(from: inFormat, to: canonical)
            }
            return systemConverter
        case .microphone:
            if micConverter == nil {
                micConverter = AVAudioConverter(from: inFormat, to: canonical)
            }
            return micConverter
        }
    }
}
