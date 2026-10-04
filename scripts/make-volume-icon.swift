// Иконка диска для ushi.dmg: логотип в скруглённом квадрате по сетке Apple
// (824 из 1024, мягкая тень). Иконка приложения — квадрат во весь размер: его
// скругляет сама macOS 26, а иконку диска — нет, и она выглядела квадратной.
// Запуск: swift scripts/make-volume-icon.swift assets/ushi-logo.svg release/dmg

import SwiftUI
import AppKit

let args = CommandLine.arguments
let logo = NSImage(contentsOfFile: args[1])!
let outDir = URL(fileURLWithPath: args[2])

struct Icon: View {
    let side: CGFloat
    var body: some View {
        let k = side / 1024
        Image(nsImage: logo)
            .resizable()
            .frame(width: 824 * k, height: 824 * k)
            .clipShape(RoundedRectangle(cornerRadius: 185.4 * k, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 10 * k, y: 10 * k)
            .frame(width: side, height: side)
    }
}

let iconset = outDir.appendingPathComponent("VolumeIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

MainActor.assumeIsolated {
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let side = CGFloat(base * scale)
            let renderer = ImageRenderer(content: Icon(side: side))
            renderer.scale = 1
            let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! rep.representation(using: .png, properties: [:])!
                .write(to: iconset.appendingPathComponent(name))
        }
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("VolumeIcon.icns").path]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "ok" : "iconutil failed")
