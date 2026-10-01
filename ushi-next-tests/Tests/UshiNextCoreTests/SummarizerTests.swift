import XCTest
@testable import UshiNextCore

final class SummarizerTests: XCTestCase {

    /// Задание должно идти после текста: иначе на длинных записях маленькая модель
    /// забывает инструкцию и отвечает мусором («Thanks!», «干得好»).
    func testPromptPutsTaskAfterTranscript() {
        let transcript = "Обсуждаем\nредизайн   портала <и> сроки"
        let prompt = Summarizer.prompt(for: transcript)
        let textRange = prompt.range(of: "Обсуждаем редизайн портала ‹и› сроки")
        let taskRange = prompt.range(of: "Задание:")
        XCTAssertNotNil(textRange, "переносы и пробелы схлопнуты, угловые скобки заменены")
        XCTAssertNotNil(taskRange)
        if let textRange, let taskRange {
            XCTAssertLessThan(textRange.upperBound, taskRange.lowerBound)
        }
        XCTAssertTrue(prompt.hasSuffix("<start_of_turn>model\n"))
    }

    /// Модель видит первые ~6000 символов; если ответ не годится — пробуем 2000.
    func testContextLimitsAndTruncation() {
        let long = String(repeating: "слово ", count: 3_000)   // ~18 000 символов
        XCTAssertEqual(Summarizer.contextLimits(for: long), [6000, 2000])
        XCTAssertEqual(Summarizer.contextLimits(for: "коротко про дизайн"), [6000])

        let prompt6000 = Summarizer.prompt(for: long)
        let prompt2000 = Summarizer.prompt(for: long, limit: 2000)
        XCTAssertGreaterThan(prompt6000.count, prompt2000.count + 3_900)
        XCTAssertLessThan(prompt6000.count, 6_000 + 600, "огромный звонок целиком не берём")
    }

    func testCleanTitleTakesTextAfterInlineHeaderMarker() {
        XCTAssertEqual(
            Summarizer.cleanTitle("Оценка и анализ записи. **Заголовок:** Обсуждение и детализация задач."),
            "Обсуждение и детализация задач"
        )
    }

    func testShouldGenerateWordCountRule() {
        // Less than or equal to 40 words -> false
        let shortText = (1...40).map { "слово\($0)" }.joined(separator: " ")
        XCTAssertFalse(Summarizer.shouldGenerate(for: shortText))
        XCTAssertFalse(Summarizer.shouldGenerate(for: "Короткий текст на несколько слов"))
        XCTAssertFalse(Summarizer.shouldGenerate(for: ""))

        // Exactly 41 words -> true
        let exactly41 = (1...41).map { "слово\($0)" }.joined(separator: " ")
        XCTAssertTrue(Summarizer.shouldGenerate(for: exactly41))

        // 100 words -> true
        let longText = (1...100).map { "слово\($0)" }.joined(separator: " ")
        XCTAssertTrue(Summarizer.shouldGenerate(for: longText))
    }

    func testCleanTitleBasicValid() {
        let raw = "инвестиции для начинающих"
        let cleaned = Summarizer.cleanTitle(raw)
        XCTAssertEqual(cleaned, "Инвестиции для начинающих")
    }

    func testCleanTitleStripsQuotesAndPunctuation() {
        let raw = "  «Европа устаёт от помощи Украине».  "
        let cleaned = Summarizer.cleanTitle(raw)
        XCTAssertEqual(cleaned, "Европа устаёт от помощи Украине")

        let rawQuestion = "\"Почему деньги уходят на войну?\""
        let cleanedQuestion = Summarizer.cleanTitle(rawQuestion)
        XCTAssertEqual(cleanedQuestion, "Почему деньги уходят на войну")
    }

    func testCleanTitleStripsPrefixHeader() {
        let raw1 = "Заголовок: Разговор о планах на отпуск"
        XCTAssertEqual(Summarizer.cleanTitle(raw1), "Разговор о планах на отпуск")

        let raw2 = "Название: Планирование релиза и задач"
        XCTAssertEqual(Summarizer.cleanTitle(raw2), "Планирование релиза и задач")
    }

    func testCleanTitleStripsSpecialTokensAndAnsi() {
        let raw = "\u{001B}[32mПаст симпл и презент перфект\u{001B}[0m<end_of_turn>"
        XCTAssertEqual(Summarizer.cleanTitle(raw), "Паст симпл и презент перфект")
    }

    func testCleanTitleRejectsOutOfWordRange() {
        // Less than 3 words -> nil
        XCTAssertNil(Summarizer.cleanTitle("Инвестиции"))
        XCTAssertNil(Summarizer.cleanTitle("Два слова"))

        // More than 7 words -> nil
        XCTAssertNil(Summarizer.cleanTitle("Раз два три четыре пять шесть семь восемь"))
        XCTAssertNil(Summarizer.cleanTitle("Очень длинный заголовок который содержит больше семи различных слов в предложении"))
    }

    func testCleanTitleRejectsPseudosAndEmpty() {
        XCTAssertNil(Summarizer.cleanTitle(""))
        XCTAssertNil(Summarizer.cleanTitle("   \n\n  "))
        XCTAssertNil(Summarizer.cleanTitle("<model>Привет мир</model>"))
    }

    func testSmartTitleModelSpec() {
        XCTAssertEqual(SmartTitleModelSpec.fileName, "gemma-3-1b-it-Q4_K_M.gguf")
        XCTAssertEqual(SmartTitleModelSpec.sizeDescription, "806 МБ")
        XCTAssertTrue(SmartTitleModelSpec.byteCount > 800_000_000)
    }

    func testSummarizerEndToEndIfModelAvailable() async {
        let scratchModel = URL(fileURLWithPath: "/Users/volosiy/Documents/Проекты/Ushi/scratch/models/gemma-3-1b-it-Q4_K_M.gguf")
        guard FileManager.default.fileExists(atPath: scratchModel.path) else { return }

        let summarizer = Summarizer(modelURL: scratchModel)
        let sampleTranscript = "Так значит сегодня мы поговорим о причинах Первой мировой войны и сразу скажу что это не так просто как кажется многие думают ну убили эрцгерцога Франца Фердинанда и всё началось но на самом деле это была лишь искра а пороховая бочка копилась десятилетиями и вот давайте разберём какие факторы привели к тому что в 1914 году Европа взорвалась значит первый фактор это система союзов которая сложилась к началу двадцатого века"
        let title = await summarizer.title(for: sampleTranscript)
        XCTAssertNotNil(title)
        if let title {
            let words = title.split(whereSeparator: { $0.isWhitespace })
            XCTAssertTrue((3...7).contains(words.count), "Generated title word count must be 3-7: \(title)")
        }
    }
}
