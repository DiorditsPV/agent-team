import AgentTeamCore
import AppKit
import CoreText
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

/// Токены интерфейса. Значения берутся из темы окна (`ThemeStore`): «оформление приложения» даёт токены макета
/// (design/README.md), остальные темы — цвета из палитры. Чтение внутри `body` подписывает экран на смену темы.
enum T {
    private static var theme: WindowTheme { ThemeStore.shared.theme }

    static var bg: Color { Color(hex: theme.bg) }
    static var side: Color { Color(hex: theme.side) }
    static var surface: Color { Color(hex: theme.surface) }
    static var well: Color { Color(hex: theme.well) }
    static var line: Color { Color(hex: theme.line) }
    static var ink: Color { Color(hex: theme.ink) }
    static var muted: Color { Color(hex: theme.muted) }
    static var dim: Color { Color(hex: theme.dim) }
    static var faint: Color { Color(hex: theme.faint) }
    static var accent: Color { Color(hex: theme.accent) }
    /// Цвет текста и значков на акценте.
    static var onAccent: Color { Color(hex: theme.onAccent) }
    static var amber: Color { Color(hex: theme.amber) }
    static var amberBg: Color { Color(hex: theme.amberBg) }
    static var cyan: Color { Color(hex: theme.cyan) }
    static var violet: Color { Color(hex: theme.violet) }
    static var rose: Color { Color(hex: theme.rose) }
    static var periwinkle: Color { Color(hex: theme.periwinkle) }
    static var accentBg: Color { Color(hex: theme.accentBg) }

    static var rolePalette: [Color] { theme.rolePalette.map { Color(hex: $0) } }

    /// Моноширинный шрифт без лигатур и контекстных замен: их разбор в CoreText был главной статьёй
    /// нагрузки при перерисовке хвостов панелей. Шрифты кешируются по размеру и весу.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { MonoFonts.font(size, weight) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Onest", size: size).weight(weight) }
    static func title(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .custom("Unbounded", size: size).weight(weight) }

    /// Шрифты из бандла подключает Info.plist (ATSApplicationFontsPath). При запуске из `swift run`
    /// бандла нет — регистрируем файлы из каталога исходников.
    static func registerFontsIfNeeded() {
        if NSFont(name: "Onest", size: 12) != nil, NSFont(name: "Unbounded", size: 12) != nil { return }
        let here = URL(fileURLWithPath: #filePath)
        let dir = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in urls where u.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }
}

/// Токены чата менеджера: те же имена, что у `T`, но значения из темы чата (`ChatThemeStore`). По умолчанию тема чата
/// совпадает с темой окна. Файлы чата пишут `C.ink` там, где остальные экраны пишут `T.ink`.
enum ChatTokens {
    private static var theme: WindowTheme { ChatThemeStore.shared.theme }

    /// Подложка закреплённой записи.
    static var pin: Color { Color(hex: theme.pinBackground) }
    /// Подсветка выбранной строки списка подсказок.
    static var highlight: Color { Color(hex: theme.rowHighlight) }

    static var bg: Color { Color(hex: theme.bg) }
    static var side: Color { Color(hex: theme.side) }
    static var surface: Color { Color(hex: theme.surface) }
    static var well: Color { Color(hex: theme.well) }
    static var line: Color { Color(hex: theme.line) }
    static var ink: Color { Color(hex: theme.ink) }
    static var muted: Color { Color(hex: theme.muted) }
    static var dim: Color { Color(hex: theme.dim) }
    static var faint: Color { Color(hex: theme.faint) }
    static var accent: Color { Color(hex: theme.accent) }
    static var onAccent: Color { Color(hex: theme.onAccent) }
    static var amber: Color { Color(hex: theme.amber) }
    static var amberBg: Color { Color(hex: theme.amberBg) }
    static var cyan: Color { Color(hex: theme.cyan) }
    static var violet: Color { Color(hex: theme.violet) }
    static var rose: Color { Color(hex: theme.rose) }
    static var periwinkle: Color { Color(hex: theme.periwinkle) }
    static var accentBg: Color { Color(hex: theme.accentBg) }
    static var rolePalette: [Color] { theme.rolePalette.map { Color(hex: $0) } }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { T.mono(size, weight) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { T.text(size, weight) }
    static func title(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { T.title(size, weight) }
}

typealias C = ChatTokens

/// Токены области агента: те же имена, значения из темы терминала (`AgentAreaStore`).
enum AgentTokens {
    private static var theme: WindowTheme { AgentAreaStore.shared.theme }

    static var bg: Color { Color(hex: theme.bg) }
    static var side: Color { Color(hex: theme.side) }
    static var surface: Color { Color(hex: theme.surface) }
    static var well: Color { Color(hex: theme.well) }
    static var line: Color { Color(hex: theme.line) }
    static var ink: Color { Color(hex: theme.ink) }
    static var muted: Color { Color(hex: theme.muted) }
    static var dim: Color { Color(hex: theme.dim) }
    static var faint: Color { Color(hex: theme.faint) }
    static var accent: Color { Color(hex: theme.accent) }
    static var onAccent: Color { Color(hex: theme.onAccent) }
    static var amber: Color { Color(hex: theme.amber) }
    static var cyan: Color { Color(hex: theme.cyan) }
    static var rose: Color { Color(hex: theme.rose) }
    static var rolePalette: [Color] { theme.rolePalette.map { Color(hex: $0) } }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { T.mono(size, weight) }
    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { T.text(size, weight) }
}

typealias A = AgentTokens

/// Системные элементы (меню, поля, полосы прокрутки, диалоги) идут в светлом или тёмном виде по яркости фона темы окна.
struct WindowAppearance: ViewModifier {
    func body(content: Content) -> some View {
        let light = ThemeStore.shared.theme.isLight
        content
            .preferredColorScheme(light ? .light : .dark)
            .onChange(of: light, initial: true) { _, now in
                NSApp?.appearance = NSAppearance(named: now ? .aqua : .darkAqua)
            }
    }
}

extension View {
    func windowAppearance() -> some View { modifier(WindowAppearance()) }
}

enum MonoFonts {
    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]
    nonisolated(unsafe) private static var fonts: [String: Font] = [:]
    private static let lock = NSLock()

    static func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        let key = "\(size)-\(weight)"
        if let f = lock.withLock({ fonts[key] }) { return f }
        let f = Font(nsFont(size, weight))
        lock.withLock { fonts[key] = f }
        return f
    }

    static func nsFont(_ size: CGFloat, _ weight: Font.Weight) -> NSFont {
        let key = "\(size)-\(weight)"
        lock.lock()
        defer { lock.unlock() }
        if let f = cache[key] { return f }
        let w: NSFont.Weight
        switch weight {
        case .bold: w = .bold
        case .semibold: w = .semibold
        case .medium: w = .medium
        case .light: w = .light
        default: w = .regular
        }
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
        ]
        let desc = NSFontDescriptor(fontAttributes: [.family: "JetBrains Mono", .traits: [NSFontDescriptor.TraitKey.weight: w]])
            .addingAttributes([.featureSettings: features])
        let ns = NSFont(descriptor: desc, size: size) ?? .monospacedSystemFont(ofSize: size, weight: w)
        cache[key] = ns
        return ns
    }
}

/// Цвет роли: менеджер — акцент, остальные — по порядку ролей в agents/roles.
@MainActor
func roleColor(_ role: String, in project: ProjectModel?, agentArea: Bool = false) -> Color {
    // В области агента цвета ролей берутся из темы терминала, иначе — из темы окна.
    let accent = agentArea ? A.accent : T.accent
    let palette = agentArea ? A.rolePalette : T.rolePalette
    guard let project else { return agentArea ? A.cyan : T.cyan }
    if project.role(named: role)?.kind == "manager" || role == project.status?.manager?.role { return accent }
    let others = project.projectRoles.filter { $0.kind != "manager" }.map(\.role)
    if let i = others.firstIndex(of: role) { return palette[i % palette.count] }
    let h = role.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return palette[h % palette.count]
}

struct Swatch: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View { Rectangle().fill(color).frame(width: size, height: size) }
}

/// Плашка статуса: точка и подпись в рамке цвета статуса. Цвет приходит параметром, а моноширинный шрифт у всех тем один,
/// поэтому плашка годится для любой зоны — окна, чата или агентов. `size` — кегль подписи; отступы уменьшаются с ним.
struct StatusBadge: View {
    var text: String
    var color: Color
    var size: CGFloat = 11
    var body: some View {
        HStack(spacing: size >= 11 ? 6 : 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(T.mono(size)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, size >= 11 ? 8 : 6).padding(.vertical, size >= 11 ? 3 : 2)
        .overlay(Rectangle().stroke(color, lineWidth: 1))
    }
}

struct Chip: View {
    var text: String
    var color: Color = T.cyan
    var body: some View {
        Text(text).font(T.mono(12)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(T.surface, ignoresSafeAreaEdges: [])
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(T.mono(11)).kerning(1).foregroundStyle(T.dim) }
}

/// Кнопки макета: основная (акцент), обычная (рамка), тихая (без рамки).
struct AppButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, quiet, warn, danger }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(T.text(13, .medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(bg.opacity(configuration.isPressed ? 0.8 : 1), ignoresSafeAreaEdges: [])
            .overlay(Rectangle().stroke(border, lineWidth: kind == .primary || kind == .quiet ? 0 : 1))
            .contentShape(Rectangle())
    }

    var fg: Color {
        switch kind {
        case .primary: return T.onAccent
        case .warn: return T.amber
        case .danger: return T.rose
        case .quiet: return T.muted
        case .normal: return T.ink
        }
    }

    var bg: Color { kind == .primary ? T.accent : .clear }
    var border: Color {
        switch kind {
        case .warn: return T.amber.opacity(0.45)
        case .danger: return T.rose.opacity(0.45)
        default: return T.line
        }
    }
}

/// Переключатель сегментов (режимы, фильтры).
struct Segmented<V: Hashable>: View {
    var items: [(V, String, String?)]
    @Binding var selection: V
    /// Мельче кегль и отступы: переключатель в строке списка.
    var compact = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button {
                    selection = item.0
                } label: {
                    HStack(spacing: 6) {
                        if let icon = item.2 { Image(systemName: icon).font(.system(size: 11)) }
                        Text(item.1).font(T.text(compact ? 11 : 12)).lineLimit(1)
                    }
                    .foregroundStyle(selection == item.0 ? T.ink : T.muted)
                    .padding(.horizontal, compact ? 8 : (item.2 == nil ? 12 : 10)).padding(.vertical, compact ? 3 : 5)
                    .background(selection == item.0 ? T.line : .clear, ignoresSafeAreaEdges: [])
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 2 : 3)
        // Фон не должен уходить под скрытый заголовок окна: у верхнего края фон по умолчанию тянется в safe area.
        .background(T.surface, ignoresSafeAreaEdges: [])
    }
}

func clock(_ date: Date?) -> String {
    guard let date else { return "" }
    return DateFormats.string(date, "HH:mm", locale: nil)
}

func duration(ms: Int) -> String {
    let s = ms / 1000
    if s < 60 { return "\(s) с" }
    if s < 3600 { return "\(s / 60) мин \(s % 60) с" }
    return "\(s / 3600) ч \((s / 60) % 60) мин"
}

/// «6 агентов», «2 агента», «1 агент».
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    "\(n) " + RussianPlural.word(n, one, few, many)
}

extension DisplayModel {
    /// Единственная модель вида: тема подхватывается и из аргумента запуска `--term-theme <id>` (для снимков).
    @MainActor static let shared = DisplayModel(launchArguments: CommandLine.arguments)
}

/// Шрифты на выбор в «Настройках»: встроенные, системные и установленные моноширинные.
enum FontCatalog {
    static let onest = "Onest"
    static let jetBrains = "JetBrains Mono"
    static let sfMono = "SF Mono"
    static let system = "SF Pro"

    nonisolated(unsafe) private static var cache: [String: NSFont] = [:]
    private static let lock = NSLock()

    /// Привычные шрифты для кода (если установлены), затем остальные моноширинные, затем шрифты интерфейса.
    /// Список считается один раз; ничего не скачивается и не встраивается сверх уже встроенного JetBrains Mono.
    static let families: [String] = {
        let ui = [onest, system]
        let all = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        let fixed = all.filter { f in
            !ui.contains(f) && (NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: f]), size: 12)?.isFixedPitch ?? false)
        }
        return FontOrder.arrange(installed: Set(all), always: [sfMono, jetBrains], monospaced: fixed, ui: ui)
    }()

    static func nsFont(family: String, size: CGFloat, weight: Font.Weight) -> NSFont {
        let key = "\(family)|\(size)|\(weight)"
        if let f = lock.withLock({ cache[key] }) { return f }
        let w: NSFont.Weight
        switch weight {
        case .bold: w = .bold
        case .semibold: w = .semibold
        case .medium: w = .medium
        case .light: w = .light
        default: w = .regular
        }
        let font: NSFont
        switch family {
        case jetBrains: font = MonoFonts.nsFont(size, weight)
        case sfMono: font = .monospacedSystemFont(ofSize: size, weight: w)
        case system: font = .systemFont(ofSize: size, weight: w)
        default:
            let features: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
            ]
            let desc = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: w]])
                .addingAttributes([.featureSettings: features])
            font = NSFont(descriptor: desc, size: size) ?? MonoFonts.nsFont(size, weight)
        }
        lock.withLock { cache[key] = font }
        return font
    }
}

/// Шрифт и интервал текста чата менеджера по настройкам.
@MainActor
enum ChatFont {
    static var look: TextLook { DisplayModel.shared.settings.chat }
    static var size: CGFloat { CGFloat(look.size) }
    static var spacing: CGFloat { CGFloat(look.spacing) }

    /// Расстояние между событиями ленты и внутри них: исходное значение умножается на множитель настройки «Интервал».
    /// Читается в теле вида, поэтому смена настройки применяется сразу.
    static func gap(_ base: CGFloat) -> CGFloat {
        (base * CGFloat(DisplaySettings.chatGapFactor(spacing: look.spacing)) * 2).rounded() / 2
    }

    static func text(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let family = look.family
        return family == FontCatalog.onest ? T.text(size, weight) : Font(FontCatalog.nsFont(family: family, size: size, weight: weight))
    }
}
