// Иконка приложения, нарисованная кодом: `swift scripts/make-icon.swift <owner|dev> <каталог.iconset>`.
// Знак: большой акцентный круг (менеджер) и три малых вокруг него (команда), соединённые линиями. Читается и на 16 px.
// owner — тёмный фон приложения #11120F и акцент #C8F169; dev — серая проверочная сборка с меткой DEV.
// Только AppKit и CoreGraphics, без сети и внешних файлов.
import AppKit

let args = CommandLine.arguments
guard args.count == 3, ["owner", "dev"].contains(args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <owner|dev> <out.iconset>\n".utf8))
    exit(2)
}
let dev = args[1] == "dev"
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let background: UInt32 = dev ? 0x45474B : 0x11120F
let accent: UInt32 = dev ? 0xD4D6DA : 0xC8F169
let satellite: UInt32 = dev ? 0x9EA2A8 : 0x7CC7D9
let line: UInt32 = dev ? 0x6A6D73 : 0x2C2E27

/// Один размер: квадрат в стиле macOS (поля 10 %, скругление ~22 %), знак в центре.
func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let g = ctx.cgContext
    let s = CGFloat(px)
    let inset = s * 0.1
    let box = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: box, cornerWidth: box.width * 0.225, cornerHeight: box.width * 0.225, transform: nil)

    // Фон с тонкой тенью, как у иконок macOS.
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.35))
    g.setFillColor(color(background))
    g.addPath(path); g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addPath(path); g.clip()

    let c = CGPoint(x: s / 2, y: s / 2 + (dev ? s * 0.035 : 0))
    let r = box.width * 0.2                    // менеджер
    let rs = box.width * 0.098                   // роли
    let orbit = box.width * 0.365
    let angles: [CGFloat] = [90, 210, 330].map { $0 * .pi / 180 }
    let sats = angles.map { CGPoint(x: c.x + orbit * cos($0), y: c.y + orbit * sin($0)) }

    g.setStrokeColor(color(accent, 0.7))
    g.setLineWidth(max(1.5, s * 0.022))
    g.setLineCap(.round)
    for p in sats { g.move(to: c); g.addLine(to: p); g.strokePath() }
    _ = line

    g.setFillColor(color(satellite))
    for p in sats { g.fillEllipse(in: CGRect(x: p.x - rs, y: p.y - rs, width: rs * 2, height: rs * 2)) }
    g.setFillColor(color(accent))
    g.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))

    if dev {
        // Метка DEV крупными буквами в нижней полосе: сборка не должна путаться с настоящей.
        let band = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 0.25)
        g.setFillColor(color(0xE0A030))
        g.fill(band)
        let font = NSFont.systemFont(ofSize: band.height * 0.72, weight: .heavy)
        let str = NSAttributedString(string: "DEV", attributes: [.font: font, .foregroundColor: NSColor(cgColor: color(0x1A1204))!, .kern: band.height * 0.06])
        let size = str.size()
        str.draw(at: CGPoint(x: band.midX - size.width / 2, y: band.midY - size.height / 2))
    }
    g.restoreGState()
    NSGraphicsContext.current = nil
    return rep
}

// Набор .iconset для iconutil: 16…512 и @2x.
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in entries {
    let data = render(px).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent(name + ".png"))
}
