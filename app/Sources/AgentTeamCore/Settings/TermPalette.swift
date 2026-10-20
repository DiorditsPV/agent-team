import Foundation

/// Палитра терминала: 16 цветов ANSI, фон и основной текст. Остальные индексы 16–255 одинаковы у всех тем
/// (куб 6×6×6 и серая шкала), RGB-цвета идут как есть.
public struct TermPalette: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Порядок: чёрный, красный, зелёный, жёлтый, синий, пурпурный, голубой, белый, затем те же яркие.
    public var ansi: [UInt32]
    public var background: UInt32
    public var foreground: UInt32
    /// Цвет выделенного текста.
    public var selection: UInt32
    public var isLight: Bool

    public init(id: String, name: String, ansi: [UInt32], background: UInt32, foreground: UInt32,
                selection: UInt32? = nil, isLight: Bool = false) {
        precondition(ansi.count == 16)
        self.id = id
        self.name = name
        self.ansi = ansi
        self.background = background
        self.foreground = foreground
        self.selection = selection ?? Self.mix(background, foreground, 0.25)
        self.isLight = isLight
    }

    /// Смесь двух цветов: доля `t` второго.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func ch(_ s: Int) -> UInt32 {
            let x = Double((a >> UInt32(s)) & 0xFF), y = Double((b >> UInt32(s)) & 0xFF)
            return UInt32((x + (y - x) * t).rounded())
        }
        return ch(16) << 16 | ch(8) << 8 | ch(0)
    }

    private static func linear(_ v: UInt32) -> Double {
        let c = Double(v) / 255
        return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Контраст двух цветов по WCAG 2: от 1 до 21.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ c: UInt32) -> Double {
            0.2126 * linear(c >> 16 & 0xFF) + 0.7152 * linear(c >> 8 & 0xFF) + 0.0722 * linear(c & 0xFF)
        }
        let (x, y) = (lum(a), lum(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Цвет терминала в 0xRRGGBB по палитре темы.
    public func rgb(_ c: TermColor) -> UInt32 {
        switch c {
        case let .indexed(i):
            let i = Int(i)
            if i < 16 { return ansi[i] }
            if i >= 232 {
                let v = UInt32(8 + (i - 232) * 10)
                return v << 16 | v << 8 | v
            }
            let n = i - 16
            let comp = { (x: Int) -> UInt32 in x == 0 ? 0 : UInt32(55 + x * 40) }
            return comp(n / 36) << 16 | comp((n / 6) % 6) << 8 | comp(n % 6)
        case let .rgb(r, g, b):
            return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        }
    }
}

/// Встроенные темы. Значения — публичные определения палитр; источник и лицензия у каждой темы в комментарии.
/// Значения, помеченные «по памяти», не сверены с первоисточником: набор ANSI взят из терминальных
/// вариантов темы и может отличаться от редактора в оттенках.
/// «По умолчанию» — палитра приложения, вид без смены темы не меняется.
public enum TermPalettes {
    public static let defaultID = "default"

    public static let standard = TermPalette(
        id: defaultID, name: "По умолчанию",
        ansi: [0x2C2E27, 0xE58FA8, 0xC8F169, 0xF2B35B, 0x7CC7D9, 0xB9A3F0, 0x7CC7D9, 0xC9C7BE,
               0x6B6A61, 0xF0A0B8, 0xD8F68C, 0xF7C77E, 0x9AD6E4, 0xCDBBF5, 0x9AD6E4, 0xEDEBE3],
        background: 0x0B0C0A, foreground: 0x9A988D)

    // Solarized — Ethan Schoonover, MIT. Основной текст — base1 (тёмная) и base01 (светлая): стандартные base0 и
    // base00 дают контраст ниже 4,5:1.
    static let solarizedANSI: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]

    public static let solarizedDark = TermPalette(
        id: "solarized-dark", name: "Solarized Dark", ansi: solarizedANSI,
        background: 0x002B36, foreground: 0x93A1A1, selection: 0x073642)

    // Dracula — Zeno Rocha, MIT.
    public static let dracula = TermPalette(
        id: "dracula", name: "Dracula",
        ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
               0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF],
        background: 0x282A36, foreground: 0xF8F8F2, selection: 0x44475A)

    // Atom One Dark — GitHub, MIT.
    public static let oneDark = TermPalette(
        id: "one-dark", name: "One Dark",
        ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF],
        background: 0x282C34, foreground: 0xABB2BF, selection: 0x3E4451)

    public static let solarizedLight = TermPalette(
        id: "solarized-light", name: "Solarized Light", ansi: solarizedANSI,
        background: 0xFDF6E3, foreground: 0x586E75, selection: 0xEEE8D5, isLight: true)

    // VS Code Dark+ — встроенные цвета терминала VS Code, Microsoft, MIT. По памяти.
    public static let vscodeDark = TermPalette(
        id: "vscode-dark-plus", name: "Dark+",
        ansi: [0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
               0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5],
        background: 0x1E1E1E, foreground: 0xCCCCCC, selection: 0x264F78)

    // VS Code Light+ — встроенные цвета терминала VS Code, Microsoft, MIT. По памяти.
    public static let vscodeLight = TermPalette(
        id: "vscode-light-plus", name: "Light+",
        ansi: [0x000000, 0xCD3131, 0x00BC00, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
               0x666666, 0xCD3131, 0x14CE14, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5],
        background: 0xFFFFFF, foreground: 0x333333, selection: 0xADD6FF, isLight: true)

    // Monokai — Wimer Hazenberg; ANSI по схеме base16 Monokai (Chris Kempson, MIT). По памяти.
    public static let monokai = TermPalette(
        id: "monokai", name: "Monokai",
        ansi: [0x272822, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
               0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75, 0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5],
        background: 0x272822, foreground: 0xF8F8F2, selection: 0x49483E)

    // GitHub Dark — Primer, GitHub, MIT. По памяти.
    public static let githubDark = TermPalette(
        id: "github-dark", name: "GitHub Dark",
        ansi: [0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
               0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC],
        background: 0x0D1117, foreground: 0xE6EDF3, selection: 0x1F3A5F)

    // GitHub Light — Primer, GitHub, MIT. По памяти.
    public static let githubLight = TermPalette(
        id: "github-light", name: "GitHub Light",
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F],
        background: 0xFFFFFF, foreground: 0x1F2328, selection: 0xB6E3FF, isLight: true)

    // One Dark Pro — Binaryify, MIT. По памяти.
    public static let oneDarkPro = TermPalette(
        id: "one-dark-pro", name: "One Dark Pro",
        ansi: [0x3F4451, 0xE05561, 0x8CC265, 0xD18F52, 0x4AA5F0, 0xC162DE, 0x42B3C2, 0xD7DAE0,
               0x4F5666, 0xFF616E, 0xA5E075, 0xF0A45D, 0x4DC4FF, 0xDE73FF, 0x4CD1E0, 0xE6E6E6],
        background: 0x282C34, foreground: 0xABB2BF, selection: 0x3E4451)

    // Darcula — тема JetBrains IDE, Apache 2.0; цвета консоли. По памяти.
    public static let darcula = TermPalette(
        id: "darcula", name: "Darcula",
        ansi: [0x000000, 0xFF6B68, 0x5FAF5F, 0xD6BF55, 0x5394EC, 0xAE8ABE, 0x299999, 0xA5A5A5,
               0x595959, 0xFF8785, 0x7EC87E, 0xFFFF55, 0x6CA5F5, 0xC5A3D3, 0x4FC4C4, 0xFFFFFF],
        background: 0x2B2B2B, foreground: 0xA9B7C6, selection: 0x214283)

    // Nord — Arctic Ice Studio, MIT. Палитра terminal-схемы Nord.
    public static let nord = TermPalette(
        id: "nord", name: "Nord",
        ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
               0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4],
        background: 0x2E3440, foreground: 0xD8DEE9, selection: 0x434C5E)

    // Gruvbox — Pavel Pertsev, MIT. Тёмный вариант, контраст medium.
    public static let gruvboxDark = TermPalette(
        id: "gruvbox-dark", name: "Gruvbox Dark",
        ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
               0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2],
        background: 0x282828, foreground: 0xEBDBB2, selection: 0x504945)

    // Gruvbox Light — Pavel Pertsev, MIT. Контраст medium. По памяти.
    public static let gruvboxLight = TermPalette(
        id: "gruvbox-light", name: "Gruvbox Light",
        ansi: [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
               0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836],
        background: 0xFBF1C7, foreground: 0x3C3836, selection: 0xD5C4A1, isLight: true)

    // Tokyo Night — enkia, MIT. Вариант Night; ANSI из терминальных портов. По памяти.
    public static let tokyoNight = TermPalette(
        id: "tokyo-night", name: "Tokyo Night",
        ansi: [0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
               0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5],
        background: 0x1A1B26, foreground: 0xC0CAF5, selection: 0x283457)

    // Catppuccin Mocha — Catppuccin, MIT. Терминальное сопоставление ANSI. По памяти.
    public static let catppuccinMocha = TermPalette(
        id: "catppuccin-mocha", name: "Catppuccin Mocha",
        ansi: [0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
               0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8],
        background: 0x1E1E2E, foreground: 0xCDD6F4, selection: 0x45475A)

    // Catppuccin Latte — Catppuccin, MIT. Терминальное сопоставление ANSI. По памяти.
    public static let catppuccinLatte = TermPalette(
        id: "catppuccin-latte", name: "Catppuccin Latte",
        ansi: [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
               0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC],
        background: 0xEFF1F5, foreground: 0x4C4F69, selection: 0xACB0BE, isLight: true)

    /// Порядок в списке: по умолчанию, затем тёмные и светлые (в экране они идут двумя группами).
    public static let all: [TermPalette] = [
        standard, dracula, oneDark,
        vscodeDark, oneDarkPro, monokai, githubDark, darcula, nord, gruvboxDark, tokyoNight, catppuccinMocha, solarizedDark,
        vscodeLight, githubLight, gruvboxLight, catppuccinLatte, solarizedLight,
    ]

    public static var dark: [TermPalette] { all.filter { !$0.isLight } }
    public static var light: [TermPalette] { all.filter(\.isLight) }

    /// Тема по идентификатору; неизвестная заменяется умолчанием.
    public static func palette(id: String?) -> TermPalette {
        all.first { $0.id == id } ?? standard
    }
}

/// Порядок шрифтов в «Настройках»: сначала привычные шрифты для кода, если они установлены, затем остальные
/// моноширинные, затем пропорциональные шрифты интерфейса.
public enum FontOrder {
    public static let preferred = ["SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Cascadia Code",
                                   "Source Code Pro", "IBM Plex Mono", "Hack"]

    /// - installed: все семейства системы; always: семейства, доступные без установки (SF Mono, встроенный JetBrains Mono);
    ///   monospaced: найденные моноширинные; ui: шрифты интерфейса, они идут в конце.
    public static func arrange(installed: Set<String>, always: Set<String>, monospaced: [String], ui: [String]) -> [String] {
        let first = preferred.filter { installed.contains($0) || always.contains($0) }
        let rest = monospaced.filter { !first.contains($0) && !ui.contains($0) }
        return first + rest + ui
    }
}
