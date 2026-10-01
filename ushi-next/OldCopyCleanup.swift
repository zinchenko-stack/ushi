//
//  OldCopyCleanup.swift
//  UshiNext
//
//  С 2.0 приложение называется Ushi (Ushi.app), а у тех, кто ставил UshiNext,
//  в «Программах» остаётся UshiNext.app с тем же bundle id. Две копии одного
//  приложения путают macOS (может запуститься старая). Один раз предлагаем
//  убрать старую копию в Корзину — только по согласию, только UshiNext.app
//  с нашим bundle id.
//

import AppKit

enum OldCopyCleanup {
    private static let offeredKey = "cleanup.oldUshiNextCopyOffered"

    static func offerIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offeredKey) else { return }

        let current = Bundle.main.bundleURL.standardizedFileURL
        // Только у установленного Ushi, не у сборок разработчика из DerivedData.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard current.path.hasPrefix("/Applications/") || current.path.hasPrefix(home + "/Applications/") else { return }
        let candidates = [
            URL(fileURLWithPath: "/Applications/UshiNext.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/UshiNext.app"),
        ]
        guard let old = candidates.first(where: { url in
            url.standardizedFileURL != current
                && FileManager.default.fileExists(atPath: url.path)
                && Bundle(url: url)?.bundleIdentifier == Bundle.main.bundleIdentifier
        }) else { return }

        defaults.set(true, forKey: offeredKey)

        let alert = NSAlert()
        alert.messageText = "Удалить старую копию UshiNext?"
        alert.informativeText = "UshiNext теперь называется Ushi. Старая копия UshiNext.app больше не нужна — её можно убрать в Корзину. Записи, проекты и настройки останутся на месте."
        alert.addButton(withTitle: "Убрать в Корзину")
        alert.addButton(withTitle: "Оставить")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Если старая копия сейчас запущена — сначала просим её закрыться.
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.bundleURL?.standardizedFileURL == old.standardizedFileURL {
            app.terminate()
        }
        do {
            try FileManager.default.trashItem(at: old, resultingItemURL: nil)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Не получилось убрать UshiNext.app"
            failed.informativeText = "Удалите её из «Программ» вручную. \(error.localizedDescription)"
            failed.runModal()
        }
    }
}
