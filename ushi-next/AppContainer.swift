//
//  AppContainer.swift
//  UshiNext
//
//  Идентификатор контейнера приложения. Используется как имя поддиректории
//  внутри Application Support и как suite для UserDefaults, чтобы UshiNext
//  не пересекался с текущим Ushi.
//

import Foundation

enum AppContainer {
    /// Имя поддиректории в ~/Library/Application Support/ и в ~/Documents/.
    /// С 2.0 приложение называется просто Ushi, но папка данных и bundle id
    /// остаются от UshiNext: у тех, кто им пользовался, ничего не теряется,
    /// а папку старого Ushi 1.x («ushi») мы не трогаем — из неё только импорт.
    static let name = "UshiNext"

    /// Suite name для UserDefaults, если потребуется использовать
    /// `UserDefaults(suiteName:)`. По умолчанию `UserDefaults.standard`
    /// сам разделяется по bundle id, так что это нужно только для shared групп.
    static let userDefaultsSuite = "com.icemac.UshiNext"
}
