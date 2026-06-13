//
//  UpdateChecker.swift
//  ushi
//
//  Лёгкая проверка обновлений: тянет манифест latest-mac.json (формат —
//  как у scripts/build-release-dmg.sh), сравнивает с версией бандла,
//  и если новее — экспонит её через `available`.
//
//  Установка обновлений — без Sparkle и без автоматики: пользователь жмёт
//  «Скачать», открывается .dmg/.zip в браузере, дальше всё руками.
//  Этого достаточно для раздачи друзьям без Apple Developer аккаунта.
//

import Foundation
import Observation
import AppKit

/// URL манифеста с информацией о последней версии. Замени на свой,
/// когда настроишь GitHub Releases / GitHub Pages / S3 / любой статический хостинг.
private let manifestURL = URL(string: "https://example.com/ushi/latest-mac.json")!

@Observable
final class UpdateChecker {

    struct Manifest: Decodable {
        let version: String
        let publishedAt: String?
        let dmgUrl: String?
        let zipUrl: String?
        let notes: String?
    }

    enum CheckState: Equatable {
        case idle
        case checking
        case upToDate
        case available(Manifest)
        case failed(String)

        static func == (lhs: CheckState, rhs: CheckState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.checking, .checking), (.upToDate, .upToDate): true
            case (.available(let a), .available(let b)): a.version == b.version
            case (.failed(let a), .failed(let b)): a == b
            default: false
            }
        }
    }

    private(set) var state: CheckState = .idle

    /// Текущая версия из Info.plist (CFBundleShortVersionString).
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    @MainActor
    func check() async {
        if case .checking = state { return }
        state = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: manifestURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .failed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            if Self.isNewer(manifest.version, than: currentVersion) {
                state = .available(manifest)
            } else {
                state = .upToDate
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Открывает страницу/файл загрузки в браузере. Предпочитаем DMG, fallback на ZIP.
    func openDownload(for manifest: Manifest) {
        let urlString = manifest.dmgUrl?.isEmpty == false
            ? manifest.dmgUrl!
            : (manifest.zipUrl ?? "")
        guard let url = URL(string: urlString), !urlString.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - semver-ish compare

    /// «1.2.3» > «1.2» > «1.1.9». Игнорирует pre-release suffixes.
    private static func isNewer(_ a: String, than b: String) -> Bool {
        let aParts = parts(a)
        let bParts = parts(b)
        let n = Swift.max(aParts.count, bParts.count)
        for i in 0..<n {
            let ai = i < aParts.count ? aParts[i] : 0
            let bi = i < bParts.count ? bParts[i] : 0
            if ai != bi { return ai > bi }
        }
        return false
    }

    private static func parts(_ version: String) -> [Int] {
        version
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .first
            .map(String.init)
            .map { $0.split(separator: ".").compactMap { Int($0) } }
            ?? []
    }
}
