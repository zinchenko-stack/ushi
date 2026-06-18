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
    /// При миграции на основную сборку меняется на "ushi".
    static let name = "UshiNext"

    /// Suite name для UserDefaults, если потребуется использовать
    /// `UserDefaults(suiteName:)`. По умолчанию `UserDefaults.standard`
    /// сам разделяется по bundle id, так что это нужно только для shared групп.
    static let userDefaultsSuite = "com.icemac.UshiNext"
}
