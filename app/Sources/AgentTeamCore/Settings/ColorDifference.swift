import Foundation

/// Видимое различие двух цветов — CIEDE2000 (ΔE00) в пространстве CIELAB (D65). Расстояние в RGB плохо
/// отвечает глазу: сиреневый и голубовато-лиловый расходятся в RGB на десятки единиц, а на тёмном фоне сливаются.
/// Ориентиры: ΔE00 около 2 — различие заметно при сравнении вплотную, больше 10 — цвета разные с первого взгляда.
public enum ColorDifference {
    /// CIELAB для 0xRRGGBB (sRGB, белая точка D65).
    public static func lab(_ c: UInt32) -> (l: Double, a: Double, b: Double) {
        func lin(_ v: UInt32) -> Double {
            let x = Double(v & 0xFF) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let r = lin(c >> 16), g = lin(c >> 8), b = lin(c)
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.95047
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// 0xRRGGBB из CIELAB; `nil` — цвет вне sRGB (каналы не обрезаются: обрезка меняет яркость, а с ней контраст).
    public static func rgb(l: Double, a: Double, b: Double) -> UInt32? {
        let fy = (l + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
        func inv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 216.0 / 24389 ? t3 : (116 * t - 16) / (24389.0 / 27) }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        let lin = [3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
                   -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
                   0.0556434 * x - 0.2040259 * y + 1.0572252 * z]
        guard lin.allSatisfy({ $0 >= -0.0005 && $0 <= 1.0005 }) else { return nil }
        func gamma(_ v: Double) -> UInt32 {
            let c = min(max(v, 0), 1)
            let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt32((s * 255).rounded())
        }
        return gamma(lin[0]) << 16 | gamma(lin[1]) << 8 | gamma(lin[2])
    }

    /// Тот же цвет с оттенком, повёрнутым на `degrees` в LCh, при той же светлоте L*. Светлота задаёт яркость Y, а с ней
    /// контраст к любому фону, поэтому поворот контраста не меняет. Вне sRGB насыщенность снижается, пока цвет не войдёт.
    /// Округление до 8 бит сдвигает яркость на волос: на тёмном фоне (`darkGround`) светлота после него подтягивается
    /// вверх, на светлом — вниз, чтобы контраст к фону не стал ниже исходного.
    public static func rotatedHue(_ c: UInt32, by degrees: Double, darkGround: Bool) -> UInt32 {
        let p = lab(c)
        let chroma = (p.a * p.a + p.b * p.b).squareRoot()
        let h = atan2(p.b, p.a) + degrees * Double.pi / 180
        let y0 = Contrast.luminance(c)
        func at(_ l: Double) -> UInt32? {
            func color(_ ch: Double) -> UInt32? { rgb(l: l, a: ch * cos(h), b: ch * sin(h)) }
            if let full = color(chroma) { return full }
            var lo = 0.0, hi = chroma
            for _ in 0..<20 {
                let mid = (lo + hi) / 2
                if color(mid) != nil { lo = mid } else { hi = mid }
            }
            return color(lo)
        }
        var l = p.l
        for _ in 0..<40 {
            guard let r = at(l) else { break }
            let y = Contrast.luminance(r)
            if darkGround ? y >= y0 : y <= y0 { return r }
            l += darkGround ? 0.05 : -0.05
        }
        return c
    }

    /// ΔE00 между двумя цветами.
    public static func deltaE(_ c1: UInt32, _ c2: UInt32) -> Double { deltaE(lab(c1), lab(c2)) }

    /// ΔE00 между двумя цветами в CIELAB.
    static func deltaE(_ p: (l: Double, a: Double, b: Double), _ q: (l: Double, a: Double, b: Double)) -> Double {
        let deg = Double.pi / 180
        let c1s = (p.a * p.a + p.b * p.b).squareRoot(), c2s = (q.a * q.a + q.b * q.b).squareRoot()
        let cMean = (c1s + c2s) / 2
        let g = 0.5 * (1 - (pow(cMean, 7) / (pow(cMean, 7) + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let cp1 = (a1 * a1 + p.b * p.b).squareRoot(), cp2 = (a2 * a2 + q.b * q.b).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) / deg
            return h < 0 ? h + 360 : h
        }
        let h1 = hue(p.b, a1), h2 = hue(q.b, a2)
        let dL = q.l - p.l, dC = cp2 - cp1
        var dh = 0.0
        if cp1 * cp2 != 0 {
            dh = h2 - h1
            if dh > 180 { dh -= 360 } else if dh < -180 { dh += 360 }
        }
        let dH = 2 * (cp1 * cp2).squareRoot() * sin(dh / 2 * deg)
        let lMean = (p.l + q.l) / 2, cpMean = (cp1 + cp2) / 2
        var hMean = h1 + h2
        if cp1 * cp2 != 0 {
            if abs(h1 - h2) > 180 { hMean += h1 + h2 < 360 ? 360 : -360 }
            hMean /= 2
        }
        let t = 1 - 0.17 * cos((hMean - 30) * deg) + 0.24 * cos(2 * hMean * deg)
            + 0.32 * cos((3 * hMean + 6) * deg) - 0.20 * cos((4 * hMean - 63) * deg)
        let dTheta = 30 * exp(-pow((hMean - 275) / 25, 2))
        let rc = 2 * (pow(cpMean, 7) / (pow(cpMean, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lMean - 50, 2) / (20 + pow(lMean - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cpMean
        let sh = 1 + 0.015 * cpMean * t
        let rt = -sin(2 * dTheta * deg) * rc
        let l = dL / sl, c = dC / sc, h = dH / sh
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }
}
