// Рисует фон окна установщика (ushi.dmg): стрелка от Ushi к «Программам»
// и подсказка снизу. Запуск: swift scripts/make-dmg-background.swift release/dmg
// Положение значков задаётся в release/dmg/settings.py — держать в согласии.

import SwiftUI
import AppKit

let size = CGSize(width: 640, height: 400)
let iconY: CGFloat = 175          // центр значков
let leftX: CGFloat = 170          // Ushi
let rightX: CGFloat = 470         // «Программы»

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.122, green: 0.133, blue: 0.153),
                         Color(red: 0.090, green: 0.098, blue: 0.114)],
                startPoint: .top, endPoint: .bottom
            )

            // Стрелка между значками.
            Path { p in
                let start = CGPoint(x: leftX + 78, y: iconY)
                let end = CGPoint(x: rightX - 78, y: iconY)
                p.move(to: start)
                p.addLine(to: end)
                p.move(to: CGPoint(x: end.x - 11, y: end.y - 9))
                p.addLine(to: end)
                p.addLine(to: CGPoint(x: end.x - 11, y: end.y + 9))
            }
            .stroke(Color(red: 0.353, green: 0.647, blue: 0.949),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            Text("Перетащите Ushi в папку «Программы»")
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.72))
                .position(x: size.width / 2, y: 330)
        }
        .frame(width: size.width, height: size.height)
    }
}

@MainActor
func write(scale: CGFloat, to url: URL) {
    let renderer = ImageRenderer(content: Background())
    renderer.scale = scale
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    rep.size = size   // 72 dpi на 1x, 144 dpi на 2x — так их понимает tiffutil
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
MainActor.assumeIsolated {
    write(scale: 1, to: dir.appendingPathComponent("background.png"))
    write(scale: 2, to: dir.appendingPathComponent("background@2x.png"))
}
print("ok")
