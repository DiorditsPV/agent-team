import Foundation

/// Минимальный контраст текста к фону, как «Minimum contrast» в iTerm: цвет сдвигается по яркости,
/// оттенок и насыщенность сохраняются. Claude Code рисует вывод своими RGB-цветами, подобранными под тёмный фон;
/// на светлой теме голубой и оранжевый сливаются с белым.
public enum Contrast {
    public static let minimumRatio = 4.5

    /// Относительная яркость по WCAG для 0xRRGGBB.
    public static func luminance(_ rgb: UInt32) -> Double {
        func lin(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb >> 16 & 0xFF) + 0.7152 * lin(rgb >> 8 & 0xFF) + 0.0722 * lin(rgb & 0xFF)
    }

    /// Отношение контраста, от 1 до 21.
    public static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Цвет текста, читаемый на фоне: если контраст уже достаточен — тот же цвет; иначе яркость HSL сдвигается
    /// в сторону, дающую больше контраста (на светлом фоне темнее, на тёмном светлее), до порога.
    public static func ensure(_ fg: UInt32, on bg: UInt32, minRatio: Double = minimumRatio) -> UInt32 {
        guard ratio(fg, bg) < minRatio else { return fg }
        let (h, s, l) = hsl(fg)
        let darken = luminance(bg) > 0.5
        var lo = darken ? 0.0 : l          // диапазон яркости, в котором ищем ближайшую подходящую
        var hi = darken ? l : 1.0
        // Крайняя точка: если и она не проходит порог, берём её (лучшее возможное).
        let extreme = rgb(h, s, darken ? 0 : 1)
        guard ratio(extreme, bg) >= minRatio else { return extreme }
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let ok = ratio(rgb(h, s, mid), bg) >= minRatio
            if darken { if ok { lo = mid } else { hi = mid } } else { if ok { hi = mid } else { lo = mid } }
        }
        return rgb(h, s, darken ? lo : hi)
    }

    // MARK: HSL

    static func hsl(_ c: UInt32) -> (Double, Double, Double) {
        let r = Double(c >> 16 & 0xFF) / 255, g = Double(c >> 8 & 0xFF) / 255, b = Double(c & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) } else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h /= 6
        return (h, s, l)
    }

    static func rgb(_ h: Double, _ s: Double, _ l: Double) -> UInt32 {
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let r: Double, g: Double, b: Double
        if s == 0 { r = l; g = l; b = l } else {
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s
            let p = 2 * l - q
            r = hue(p, q, h + 1.0 / 3); g = hue(p, q, h); b = hue(p, q, h - 1.0 / 3)
        }
        func byte(_ v: Double) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(r) << 16 | byte(g) << 8 | byte(b)
    }
}
