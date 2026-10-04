// Рисует фон окна установщика (ushi.dmg): стрелка от Ushi к «Программам»
// и подсказка снизу. Фон светлый: подписи под значками Finder рисует тёмными
// поверх любой картинки — на тёмном фоне их было бы не видно. Запуск: swift scripts/make-dmg-background.swift release/dmg
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
            // Как светлая тема сайта: #F8F7F6 → #EFEEEC.
            LinearGradient(
                colors: [Color(red: 0.973, green: 0.969, blue: 0.965),
                         Color(red: 0.937, green: 0.933, blue: 0.925)],
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
            // Синий акцент Ushi для светлой темы, #164E93.
            .stroke(Color(red: 0.086, green: 0.306, blue: 0.576),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            Text("Перетащите Ushi в папку «Программы»")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 0.239, green: 0.239, blue: 0.227))   // #3D3D3A
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
