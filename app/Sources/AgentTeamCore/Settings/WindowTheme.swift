import Foundation
import Observation

/// Токены интерфейса окна в 0xRRGGBB: фон, поверхности, линии, три ступени текста, акцент и цвета статусов.
public struct WindowTheme: Equatable, Sendable {
    public var bg, side, surface, well, line: UInt32
    public var ink, muted, dim, faint: UInt32
    public var accent, onAccent, accentBg: UInt32
    public var amber, amberBg, cyan, violet, rose, periwinkle: UInt32

    /// Оформление приложения: прежние токены макета, вид без смены темы окна не меняется.
    public static let appearance = WindowTheme(
        bg: 0x11120F, side: 0x0E0F0C, surface: 0x1A1B17, well: 0x0B0C0A, line: 0x2C2E27,
        ink: 0xEDEBE3, muted: 0x9A988D, dim: 0x6B6A61, faint: 0x4A4C43,
        accent: 0xC8F169, onAccent: 0x11120F, accentBg: 0x161A0E,
        amber: 0xF2B35B, amberBg: 0x1E1A12, cyan: 0x7CC7D9, violet: 0xB9A3F0, rose: 0xE58FA8, periwinkle: 0x9FB4F5)

    /// Выделение текста в поле ввода: фон и цвет текста на нём. Фон — акцент, подмешанный к поверхности, заметный на ней
    /// (не слабее 1,3:1); текст — тот из ink, bg, чёрного и белого, что читается на фоне выделения (4,5:1).
    public var selectionStyle: (background: UInt32, text: UInt32) {
        var t = 0.5
        while t >= 0.1 {
            let c = TermPalette.mix(surface, accent, t)
            if TermPalette.contrast(c, surface) >= 1.3 {
                let text = [ink, bg, 0x000000, 0xFFFFFF].max { TermPalette.contrast($0, c) < TermPalette.contrast($1, c) }!
                if TermPalette.contrast(text, c) >= 4.5 { return (c, text) }
            }
            t -= 0.05
        }
        return (accent, onAccent)
    }
    /// Подсветка выбранной строки списка: акцент, подмешанный к поверхности не сильнее, чем держится 4,5:1 для основного текста.
    public var rowHighlight: UInt32 {
        var t = 0.14
        while t > 0.01 {
            let c = TermPalette.mix(surface, accent, t)
            if TermPalette.contrast(ink, c) >= 4.5, TermPalette.contrast(accent, c) >= 3 { return c }
            t -= 0.01
        }
        return surface
    }
    /// Подложка закреплённой записи: акцент, подмешанный к фону не сильнее, чем текст чата держит контраст (основной и
    /// приглушённый 4,5:1, ссылки и подписи 3:1). Слабая тема — подложки нет, остаётся метка слева.
    public var pinBackground: UInt32 {
        var t = 0.12
        while t > 0.01 {
            let c = TermPalette.mix(bg, accent, t)
            let ok = [ink, muted].allSatisfy { TermPalette.contrast($0, c) >= 4.5 }
                && [accent, periwinkle, cyan, dim, amber].allSatisfy { TermPalette.contrast($0, c) >= 3 }
            if ok { return c }
            t -= 0.01
        }
        return bg
    }
    public var selection: UInt32 { selectionStyle.background }
    public var selectionText: UInt32 { selectionStyle.text }

    /// Цвета ролей по порядку; менеджеру достаётся акцент. Из токенов cyan, violet, periwinkle, rose, amber, разведённых
    /// по оттенку так, чтобы любые два и акцент различались с первого взгляда (`RoleColors`).
    public var rolePalette: [UInt32] { RoleColors.palette(accent: accent, roles: [cyan, violet, periwinkle, rose, amber], ground: bg) }

    /// Фон светлее середины.
    public var isLight: Bool { TermPalette.contrast(bg, 0x000000) > TermPalette.contrast(bg, 0xFFFFFF) }

    /// Наименьшее расстояние между цветами ролей, иначе роли сливаются.
    static let minRoleDistance = 25.0

    static func distance(_ a: UInt32, _ b: UInt32) -> Double {
        func ch(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) }
        let dr = ch(a, 16) - ch(b, 16), dg = ch(a, 8) - ch(b, 8), db = ch(a, 0) - ch(b, 0)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    private static func chroma(_ c: UInt32) -> Int {
        let v = [Int(c >> 16 & 0xFF), Int(c >> 8 & 0xFF), Int(c & 0xFF)]
        return v.max()! - v.min()!
    }

    /// Токены из темы терминала: фон и текст берутся из неё, акцент и статусы — из ANSI-цветов.
    public static func from(_ p: TermPalette) -> WindowTheme {
        let bg = p.background, fg = p.foreground
        let black: UInt32 = 0x000000

        /// Цвет не слабее 3:1 на фоне: слабый подмешивается к тексту.
        func visible(_ color: UInt32) -> UInt32 {
            var c = color
            var n = 0
            while TermPalette.contrast(c, bg) < 3, n < 10 { c = TermPalette.mix(c, fg, 0.1); n += 1 }
            return c
        }
        /// Из обычного и яркого варианта — тот, что контрастнее фону; серый «яркий» (как у Solarized) не берётся.
        func hue(_ i: Int) -> UInt32 {
            let n = p.ansi[i], b = p.ansi[i + 8]
            let brightOK = chroma(b) * 10 >= chroma(n) * 6
            let pick = brightOK && TermPalette.contrast(b, bg) > TermPalette.contrast(n, bg) ? b : n
            return visible(pick)
        }
        /// Подмешивает `to` к `from` с наибольшей долей до `limit`, пока контраст с `on` не ниже `min`.
        func fade(_ from: UInt32, _ to: UInt32, limit: Double, on: UInt32, min: Double) -> UInt32 {
            var t = limit
            while t > 0 {
                let c = TermPalette.mix(from, to, t)
                if TermPalette.contrast(c, on) >= min { return c }
                t -= 0.02
            }
            return from
        }
        /// Подложка, смешанная с чёрным, не должна ронять контраст текста ниже 4,5:1.
        func shaded(_ amount: Double) -> UInt32 {
            var a = amount
            while a > 0.001 {
                let c = TermPalette.mix(bg, black, a)
                if TermPalette.contrast(fg, c) >= 4.5 { return c }
                a /= 2
            }
            return bg
        }

        let surface = TermPalette.mix(bg, fg, 0.07)
        let light = TermPalette.contrast(bg, black) > TermPalette.contrast(bg, 0xFFFFFF)
        let accent = hue(2)
        var chosen = [accent]
        /// Цвет роли: предпочтительный из ANSI; если он слишком близок к уже занятым, берётся другой цветной.
        func role(_ preferred: Int) -> UInt32 {
            let want = hue(preferred)
            func free(_ c: UInt32) -> Bool { chosen.allSatisfy { distance($0, c) >= minRoleDistance } }
            if free(want) { chosen.append(want); return want }
            for i in [6, 5, 4, 1, 3] {
                for c in [hue(i), visible(p.ansi[i + 8])] where chroma(c) >= 40 && free(c) {
                    chosen.append(c)
                    return c
                }
            }
            let mixed = visible(TermPalette.mix(chosen[1], chosen.count > 2 ? chosen[2] : chosen[0], 0.5))
            chosen.append(mixed)
            return mixed
        }
        let cyan = role(6), violet = role(5), periwinkle = role(4), rose = role(1), amber = role(3)

        return WindowTheme(
            bg: bg,
            side: shaded(light ? 0.03 : 0.12),
            surface: surface,
            well: shaded(light ? 0.06 : 0.25),
            line: TermPalette.mix(bg, fg, 0.2),
            ink: fg,
            muted: fade(fg, bg, limit: 0.3, on: surface, min: 4.5),
            dim: fade(fg, bg, limit: 0.5, on: surface, min: 3),
            faint: TermPalette.mix(fg, bg, 0.65),
            accent: accent,
            onAccent: TermPalette.contrast(accent, bg) > TermPalette.contrast(accent, fg) ? bg : fg,
            accentBg: TermPalette.mix(bg, accent, 0.1),
            amber: amber, amberBg: TermPalette.mix(bg, amber, 0.1),
            cyan: cyan, violet: violet, rose: rose, periwinkle: periwinkle)
    }

    /// Все цвета для проверок.
    var all: [UInt32] { [bg, side, surface, well, line, ink, muted, dim, faint, accent, onAccent, amber, cyan, violet, rose, periwinkle] }
}

/// Какую тему окна выбрал владелец: независимо от темы терминала.
public enum WindowThemeChoice {
    /// «Оформление приложения».
    public static let app = "app"

    public static func isValid(_ id: String) -> Bool { id == app || TermPalettes.all.contains { $0.id == id } }

    public static func theme(id: String) -> WindowTheme {
        id == app ? .appearance : .from(TermPalettes.palette(id: id))
    }
}

/// Текущая тема окна. Токены интерфейса читают её отсюда, а SwiftUI перерисовывает экраны при смене.
@Observable
public final class ThemeStore: @unchecked Sendable {
    public static let shared = ThemeStore()
    public var theme = WindowTheme.appearance
    private init() {}
}
