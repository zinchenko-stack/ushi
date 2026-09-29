//
//  AutoTitleTests.swift
//
//  Phase 4: авто-название записи из транскрипта.
//

import XCTest
@testable import UshiNextCore

final class AutoTitleTests: XCTestCase {
    func testTakesFirstSentence() {
        let t = AutoTitle.make(fromTranscript: "Обсуждаем план запуска лендинга. Потом поговорим о ценах.")
        XCTAssertEqual(t, "Обсуждаем план запуска лендинга")
    }

    func testStripsLeadingFillers() {
        let t = AutoTitle.make(fromTranscript: "Ну, так, давайте начнём с отчёта за неделю.")
        XCTAssertEqual(t, "Давайте начнём с отчёта за неделю")
    }

    func testSkipsTooShortSentences() {
        let t = AutoTitle.make(fromTranscript: "Привет. Да. Сегодня разбираем домашнее задание по английскому.")
        XCTAssertEqual(t, "Сегодня разбираем домашнее задание по английскому")
    }

    func testTruncatesLongSentenceTo12Words() {
        let long = "один два три четыре пять шесть семь восемь девять десять одиннадцать двенадцать тринадцать четырнадцать"
        let t = AutoTitle.make(fromTranscript: long)
        XCTAssertEqual(t, "Один два три четыре пять шесть семь восемь девять десять одиннадцать двенадцать…")
    }

    func testMultilineWhisperOutput() {
        let t = AutoTitle.make(fromTranscript: " Добрый день, коллеги,\n сегодня у нас ретро по спринту.\n")
        XCTAssertEqual(t, "Добрый день, коллеги, сегодня у нас ретро по спринту")
    }

    func testKeepsQuestionMark() {
        let t = AutoTitle.make(fromTranscript: "Как нам поднять конверсию в оплату? Давайте подумаем.")
        XCTAssertEqual(t, "Как нам поднять конверсию в оплату?")
    }

    func testIgnoresBracketsAndHallucinations() {
        XCTAssertNil(AutoTitle.make(fromTranscript: "[музыка] Продолжение следует... Субтитры сделал DimaTorzok"))
        XCTAssertEqual(
            AutoTitle.make(fromTranscript: "[музыка] (смех) Сегодня говорим про новый дизайн."),
            "Сегодня говорим про новый дизайн"
        )
    }

    func testEmptyOrSilence() {
        XCTAssertNil(AutoTitle.make(fromTranscript: ""))
        XCTAssertNil(AutoTitle.make(fromTranscript: "   \n  "))
        XCTAssertNil(AutoTitle.make(fromTranscript: "Угу. Да. Ага."))
    }
}
