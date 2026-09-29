import Foundation

enum AppSettings {
    enum Language: String { case en }
    static func transcriptionLanguage() -> Language { .en }
}
@main struct Smoke {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var outputs = Set<URL>()
        for ext in ["wav", "m4a", "mp3"] {
            let input = root.appendingPathComponent("sample." + ext)
            let before = try Data(contentsOf: input)
            let output = try await TranscriptionService.transcribe(audioURL: input, outputDirectory: root.appendingPathComponent("texts"))
            let after = try Data(contentsOf: input)
            precondition(after == before)
            let text = try String(contentsOf: output, encoding: .utf8)
            precondition(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            precondition(outputs.insert(output).inserted)
            precondition(AutoTitle.make(fromTranscript: text) != nil)
            print("PASS \(ext): audio preserved, transcript produced, auto-title available, output unique")
        }
    }
}
