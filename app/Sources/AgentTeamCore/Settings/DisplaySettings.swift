import Foundation
import Observation

/// Шрифт, размер и интервал текста одного блока интерфейса.
public struct TextLook: Codable, Equatable, Sendable {
    public var family: String
    public var size: Double
    /// Чат: добавочный интервал между строками, pt. Терминал: высота строки в кеглях.
    public var spacing: Double

    public init(family: String, size: Double, spacing: Double) {
        self.family = family
        self.size = size
        self.spacing = spacing
    }
}

/// Вид текста в чате менеджера и в терминалах агентов, а также выбор тем окна, чата и терминала.
public struct DisplaySettings: Codable, Equatable, Sendable {
    public static let chatDefault = TextLook(family: "Onest", size: 14, spacing: 5)
    public static let terminalDefault = TextLook(family: "JetBrains Mono", size: 12, spacing: 1.15)

    public static let chatSize: ClosedRange<Double> = 11...22
    public static let chatSpacing: ClosedRange<Double> = 0...12

    /// Множитель расстояний между событиями ленты и внутри них по настройке «Интервал» чата. На умолчании (5 pt) равен 1,
    /// на минимуме — 0,25 (лента плотная, как в терминале), на максимуме — около 2.
    public static func chatGapFactor(spacing: Double) -> Double {
        let s = min(max(spacing, chatSpacing.lowerBound), chatSpacing.upperBound)
        return 0.25 + 0.15 * s
    }
    public static let terminalSize: ClosedRange<Double> = 9...20
    public static let terminalSpacing: ClosedRange<Double> = 1.0...1.6

    public var chat = chatDefault
    public var terminal = terminalDefault
    public var themeID = TermPalettes.defaultID
    /// Тема окна: `WindowThemeChoice.app` или идентификатор темы из набора.
    public var windowThemeID = WindowThemeChoice.app
    /// Тема чата менеджера: `ChatThemeChoice.window` («как окно») или идентификатор темы из набора.
    public var chatThemeID = ChatThemeChoice.window
    /// Что показывать в ленте чата менеджера и в лентах агентов (чат, «Диалог», панели «Команды»).
    public var feedManager = FeedVisibility()
    public var feedAgents = FeedVisibility()
    /// Поле ввода менеджеру: свое (`false`) или живая строка ввода Claude Code из панели (`true`).
    public var liveInput = false

    public init() {}

    private enum Keys: String, CodingKey { case chat, terminal, themeID, windowThemeID, chatThemeID, feedManager, feedAgents, liveInput }
    private enum LookKeys: String, CodingKey { case family, size, spacing }

    /// Недостающие поля берутся из умолчаний, значения ограничиваются диапазонами, неизвестная тема заменяется. Поле
    /// неверного типа заменяется умолчанием только само: остальные настройки владельца сохраняются.
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: Keys.self)
        chat = Self.decodeLook(c, .chat, default: Self.chatDefault, size: Self.chatSize, spacing: Self.chatSpacing)
        terminal = Self.decodeLook(c, .terminal, default: Self.terminalDefault, size: Self.terminalSize, spacing: Self.terminalSpacing)
        let id = (try? c.decodeIfPresent(String.self, forKey: .themeID)).flatMap { $0 }
        themeID = TermPalettes.all.contains { $0.id == id } ? id! : TermPalettes.defaultID
        let w = (try? c.decodeIfPresent(String.self, forKey: .windowThemeID)).flatMap { $0 }
        windowThemeID = w.flatMap { WindowThemeChoice.isValid($0) ? $0 : nil } ?? WindowThemeChoice.app
        let ct = (try? c.decodeIfPresent(String.self, forKey: .chatThemeID)).flatMap { $0 }
        chatThemeID = ct.flatMap { ChatThemeChoice.isValid($0) ? $0 : nil } ?? ChatThemeChoice.window
        feedManager = (try? c.decodeIfPresent(FeedVisibility.self, forKey: .feedManager)).flatMap { $0 } ?? FeedVisibility()
        feedAgents = (try? c.decodeIfPresent(FeedVisibility.self, forKey: .feedAgents)).flatMap { $0 } ?? FeedVisibility()
        liveInput = (try? c.decodeIfPresent(Bool.self, forKey: .liveInput)).flatMap { $0 } ?? false
    }

    private static func decodeLook(_ c: KeyedDecodingContainer<Keys>, _ key: Keys, default d: TextLook,
                                   size: ClosedRange<Double>, spacing: ClosedRange<Double>) -> TextLook {
        guard let n = try? c.nestedContainer(keyedBy: LookKeys.self, forKey: key) else { return d }
        let family = (try? n.decodeIfPresent(String.self, forKey: .family)).flatMap { $0 }
        let s = (try? n.decodeIfPresent(Double.self, forKey: .size)).flatMap { $0 }
        let sp = (try? n.decodeIfPresent(Double.self, forKey: .spacing)).flatMap { $0 }
        return TextLook(family: (family?.isEmpty == false ? family : nil) ?? d.family,
                        size: min(max(s ?? d.size, size.lowerBound), size.upperBound),
                        spacing: min(max(sp ?? d.spacing, spacing.lowerBound), spacing.upperBound))
    }

    public var palette: TermPalette { TermPalettes.palette(id: themeID) }
}

/// Хранение настроек одним JSON-ключом UserDefaults.
public enum DisplaySettingsStore {
    public static let key = "displaySettings"

    public static func load(_ defaults: UserDefaults = AppDefaults.store) -> DisplaySettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(DisplaySettings.self, from: data) else {
            return DisplaySettings()
        }
        return s
    }

    public static func save(_ s: DisplaySettings, to defaults: UserDefaults = AppDefaults.store) {
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }
}

/// Живые настройки вида: меняются на экране «Настройки», применяются сразу и сохраняются.
@MainActor
@Observable
public final class DisplayModel {
    public var settings: DisplaySettings {
        didSet {
            if settings != oldValue { DisplaySettingsStore.save(settings, to: defaults) }
            applyWindowTheme()
        }
    }
    /// Тема чата, заданная аргументом запуска `--chat-theme <id>` (для снимков): не сохраняется.
    public private(set) var transientChatTheme: String?
    /// Тема окна, заданная аргументом запуска `--app-theme <id>` (для снимков): не сохраняется.
    public private(set) var transientWindowTheme: String?
    /// Тема, заданная аргументом запуска (для снимков): не сохраняется, пока владелец не выбрал другую.
    public private(set) var transientTheme: String?
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppDefaults.store, launchArguments: [String] = []) {
        self.defaults = defaults
        settings = DisplaySettingsStore.load(defaults)
        if let i = launchArguments.firstIndex(of: "--term-theme"), i + 1 < launchArguments.count,
           TermPalettes.all.contains(where: { $0.id == launchArguments[i + 1] }) {
            transientTheme = launchArguments[i + 1]
        }
        if let i = launchArguments.firstIndex(of: "--app-theme"), i + 1 < launchArguments.count,
           WindowThemeChoice.isValid(launchArguments[i + 1]) {
            transientWindowTheme = launchArguments[i + 1]
        }
        if let i = launchArguments.firstIndex(of: "--chat-theme"), i + 1 < launchArguments.count,
           ChatThemeChoice.isValid(launchArguments[i + 1]) {
            transientChatTheme = launchArguments[i + 1]
        }
        applyWindowTheme()
    }

    public var windowTheme: WindowTheme {
        WindowThemeChoice.theme(id: transientWindowTheme ?? settings.windowThemeID)
    }

    /// Выбор темы окна, как он показан на экране: идентификатор из аргумента запуска или из настроек.
    public var windowThemeChoice: String { transientWindowTheme ?? settings.windowThemeID }

    private func applyWindowTheme() {
        let t = windowTheme
        if ThemeStore.shared.theme != t { ThemeStore.shared.theme = t }
        let chat = ChatThemeChoice.theme(choice: chatThemeChoice, window: t)
        if ChatThemeStore.shared.theme != chat { ChatThemeStore.shared.theme = chat }
        let area = AgentAreaTheme.theme(terminalThemeID: palette.id)
        if AgentAreaStore.shared.theme != area { AgentAreaStore.shared.theme = area }
    }

    /// Выбор темы чата, как он показан на экране: из аргумента запуска или из настроек.
    public var chatThemeChoice: String { transientChatTheme ?? settings.chatThemeID }

    public func selectChatTheme(_ id: String) {
        transientChatTheme = nil
        settings.chatThemeID = id
    }

    public func selectWindowTheme(_ id: String) {
        transientWindowTheme = nil
        settings.windowThemeID = id
    }

    public var palette: TermPalette { TermPalettes.palette(id: transientTheme ?? settings.themeID) }

    public func selectTheme(_ id: String) {
        transientTheme = nil
        settings.themeID = id
        applyWindowTheme()
    }

    /// Живая строка ввода включена настройкой; переменная `AGENT_TEAM_LIVE_INPUT=1` включает её для снимков и проверок.
    public var liveInputOn: Bool { settings.liveInput || Self.liveInputForced }
    private static let liveInputForced = ProcessInfo.processInfo.environment["AGENT_TEAM_LIVE_INPUT"] == "1"

    // Сброс в «Настройках»: цвет сбрасывается в колонках палитр, шрифт — в блоках текста. Каждый сброс возвращает
    // только свою часть: сброс цвета чата не трогает его шрифт, и наоборот.

    /// Цвет окна — «Оформление приложения».
    public func resetWindowColors() { selectWindowTheme(WindowThemeChoice.app) }

    /// Цвет чата — «как окно».
    public func resetChatColors() { selectChatTheme(ChatThemeChoice.window) }

    /// Цвет агентов и терминала — тема «По умолчанию».
    public func resetAgentColors() { selectTheme(TermPalettes.defaultID) }

    /// Шрифт, размер и интервал чата менеджера.
    public func resetChatText() { settings.chat = DisplaySettings.chatDefault }

    /// Шрифт, размер и интервал терминала агентов.
    public func resetTerminalText() { settings.terminal = DisplaySettings.terminalDefault }

    public func resetFeed() {
        settings.feedManager = FeedVisibility()
        settings.feedAgents = FeedVisibility()
    }
}
