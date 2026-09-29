import XCTest
import AVFoundation
@testable import UshiNextCore

final class RecordingFinalizationTests: XCTestCase {
    func testRecordingPreventsIdleSleepAndReleasesAssertion() throws {
        func assertions() throws -> String {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "assertions"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return String(decoding: data, as: UTF8.self)
        }
        let recorder = AudioRecorder()
        recorder.beginRecordingActivity()
        defer { recorder.endRecordingActivity() }
        let active = try assertions()
        let ownAssertions = active.split(separator: "\n").filter { $0.contains("pid \(ProcessInfo.processInfo.processIdentifier)(") }
        XCTAssertTrue(ownAssertions.contains { $0.contains("PreventUserIdleSystemSleep") }, active)
        XCTAssertTrue(ownAssertions.contains { $0.contains("PreventUserIdleDisplaySleep") }, active)
        recorder.endRecordingActivity()
        let released = try assertions().split(separator: "\n").filter { $0.contains("pid \(ProcessInfo.processInfo.processIdentifier)(") }
        XCTAssertFalse(released.contains { $0.contains("PreventUserIdleSystemSleep") || $0.contains("PreventUserIdleDisplaySleep") })
    }

    func testPartialAudioRemainsPlayableAfterInterruption() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(outputURL: url, video: false, videoSize: .zero, videoBitrate: 0)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        pcm.frameLength = 4_800
        for i in 0..<4_800 { pcm.floatChannelData![0][i] = Float(sin(Double(i) * 0.05)) * 0.2 }
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        for chunk in 0..<10 {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(chunk * 4_800), timescale: 48_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: 4_800,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
            writer.appendAudio(sample!, source: .system)
        }
        writer.finishInputs()
        try await writer.complete()
        let audio = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(audio.length, 40_000)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
    }

    func testEmptyCaptureIsNotReportedAsSaved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try RecordingWriter(outputURL: url, video: false, videoSize: .zero, videoBitrate: 0)
        writer.finishInputs()
        do {
            try await writer.complete()
            XCTFail("An empty recording must fail instead of claiming it was saved")
        } catch { }
    }
}
