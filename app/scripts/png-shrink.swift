// Сжатие снимка для README без внешних утилит: png-shrink.swift <вход.png> <выход.png> [ширина]
// Кадр приводится к нужной ширине и записывается PNG с палитрой в 256 цветов (интерфейс — плоские заливки и текст).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("usage: png-shrink.swift in.png out.png [width]\n".utf8))
    exit(2)
}
let width = args.count > 3 ? Int(args[3]) ?? 1600 : 1600
let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())

// Ресемплинг в 8-битный RGB.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var rgba = [UInt8](repeating: 0, count: width * height * 4)
rgba.withUnsafeMutableBytes { buf in
    let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// Палитра: самые частые цвета (ключ — по 5 бит на канал), остальные — ближайший из палитры.
func key(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int { Int(r >> 3) << 10 | Int(g >> 3) << 5 | Int(b >> 3) }
var counts = [Int: Int]()
var sums = [Int: (Int, Int, Int)]()
for i in 0..<(width * height) {
    let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2]
    let k = key(r, g, b)
    counts[k, default: 0] += 1
    let s = sums[k] ?? (0, 0, 0)
    sums[k] = (s.0 + Int(r), s.1 + Int(g), s.2 + Int(b))
}
let top = counts.sorted { $0.value > $1.value }.prefix(256).map(\.key)
var palette: [(Int, Int, Int)] = top.map { k in
    let n = counts[k]!, s = sums[k]!
    return (s.0 / n, s.1 / n, s.2 / n)
}
var lookup = [Int: UInt8]()
for (i, k) in top.enumerated() { lookup[k] = UInt8(i) }
func nearest(_ r: Int, _ g: Int, _ b: Int) -> UInt8 {
    var best = 0, bestD = Int.max
    for (i, p) in palette.enumerated() {
        let d = (p.0 - r) * (p.0 - r) + (p.1 - g) * (p.1 - g) + (p.2 - b) * (p.2 - b)
        if d < bestD { bestD = d; best = i }
    }
    return UInt8(best)
}
var indexed = [UInt8](repeating: 0, count: width * height)
for i in 0..<(width * height) {
    let r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2]
    let k = key(r, g, b)
    if let v = lookup[k] { indexed[i] = v; continue }
    let v = nearest(Int(r), Int(g), Int(b))
    lookup[k] = v
    indexed[i] = v
}
while palette.count < 256 { palette.append((0, 0, 0)) }
var table = [UInt8]()
for p in palette { table += [UInt8(p.0), UInt8(p.1), UInt8(p.2)] }
let indexedSpace = CGColorSpace(indexedBaseSpace: space, last: 255, colorTable: table)!
let provider = CGDataProvider(data: Data(indexed) as CFData)!
guard let out = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: indexedSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
