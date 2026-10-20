import XCTest
@testable import AgentTeamCore

final class ChatThemeTests: XCTestCase {
    private var allChoices: [String] { [ChatThemeChoice.window, WindowThemeChoice.app] + TermPalettes.all.map(\.id) }

    func testDecodingChatThemeID() throws {
        let ok = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"chatThemeID":"dracula"}"#.utf8))
        XCTAssertEqual(ok.chatThemeID, "dracula")
        let app = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"chatThemeID":"app"}"#.utf8))
        XCTAssertEqual(app.chatThemeID, "app")
        // Нет поля, пустое или выдуманное значение — «как окно»; остальные поля не страдают.
        for json in [#"{}"#, #"{"chatThemeID":""}"#, #"{"chatThemeID":"выдуманная"}"#, #"{"themeID":"dracula"}"#] {
            let s = try JSONDecoder().decode(DisplaySettings.self, from: Data(json.utf8))
            XCTAssertEqual(s.chatThemeID, ChatThemeChoice.window, json)
        }
        XCTAssertEqual(DisplaySettings().chatThemeID, ChatThemeChoice.window)
    }

    func testChatThemeRoundTripsThroughStore() {
        let name = "agent-team-tests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        var s = DisplaySettings()
        s.chatThemeID = "solarized-light"
        s.windowThemeID = "dracula"
        s.themeID = "one-dark"
        DisplaySettingsStore.save(s, to: d)
        XCTAssertEqual(DisplaySettingsStore.load(d), s)
    }

    func testAsWindowKeepsWindowTokensAndExplicitThemeDiffers() {
        let window = WindowTheme.from(TermPalettes.dracula)
        // Тема окна, у которой всё уже читается, остаётся без изменений.
        let app = WindowTheme.appearance
        XCTAssertEqual(ChatThemeChoice.theme(choice: ChatThemeChoice.window, window: app), app)
        XCTAssertEqual(ChatThemeChoice.theme(choice: "нет такой", window: app), app)
        XCTAssertEqual(ChatThemeChoice.theme(choice: ChatThemeChoice.window, window: window).bg, window.bg)
        let light = ChatThemeChoice.theme(choice: "solarized-light", window: window)
        XCTAssertEqual(light.bg, TermPalettes.solarizedLight.background)
        XCTAssertNotEqual(light.bg, window.bg)
    }

    /// В любой паре «окно + чат» текст чата читается: не ниже 4,5:1 на фоне, поверхности и подложке чата.
    func testChatTextContrastInEveryWindowAndChatPair() {
        for w in [WindowThemeChoice.app] + TermPalettes.all.map(\.id) {
            let window = WindowThemeChoice.theme(id: w)
            for c in allChoices {
                let chat = ChatThemeChoice.theme(choice: c, window: window)
                let explicit = c != ChatThemeChoice.window
                let texts: [(String, UInt32)] = [("ink", chat.ink), ("muted", chat.muted), ("accent", chat.accent), ("cyan", chat.cyan), ("violet", chat.violet),
                                                 ("rose", chat.rose), ("periwinkle", chat.periwinkle), ("amber", chat.amber)]
                    + (explicit ? [("dim", chat.dim), ("faint", chat.faint)] : [])
                for (name, color) in texts {
                    for (gname, ground) in [("bg", chat.bg), ("surface", chat.surface)] {
                        XCTAssertGreaterThanOrEqual(Contrast.ratio(color, ground), 4.5 - 0.01, "окно \(w) · чат \(c) · \(name) на \(gname)")
                    }
                }
            }
        }
    }

    @MainActor
    func testModelAppliesThreeThemesIndependently() {
        let name = "agent-team-tests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: [])
        m.selectWindowTheme("solarized-light")
        m.selectChatTheme("dracula")
        m.selectTheme("one-dark")
        XCTAssertEqual(ThemeStore.shared.theme.bg, TermPalettes.solarizedLight.background)
        XCTAssertEqual(ChatThemeStore.shared.theme.bg, TermPalettes.dracula.background)
        XCTAssertEqual(m.palette.id, "one-dark")
        m.selectChatTheme(ChatThemeChoice.window)
        XCTAssertEqual(ChatThemeStore.shared.theme.bg, TermPalettes.solarizedLight.background)
        m.resetChatColors()
        XCTAssertEqual(DisplaySettingsStore.load(d).chatThemeID, ChatThemeChoice.window)
        m.selectWindowTheme(WindowThemeChoice.app)
    }

    @MainActor
    func testLaunchChatThemeIsTransient() {
        let name = "agent-team-tests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: ["--chat-theme", "one-dark"])
        XCTAssertEqual(m.chatThemeChoice, "one-dark")
        XCTAssertEqual(ChatThemeStore.shared.theme.bg, TermPalettes.oneDark.background)
        XCTAssertEqual(DisplaySettingsStore.load(d).chatThemeID, ChatThemeChoice.window)
        m.selectChatTheme("dracula")
        XCTAssertEqual(DisplaySettingsStore.load(d).chatThemeID, "dracula")
        XCTAssertEqual(DisplayModel(defaults: d, launchArguments: ["--chat-theme", "нет"]).chatThemeChoice, "dracula")
        m.selectChatTheme(ChatThemeChoice.window)
        m.selectWindowTheme(WindowThemeChoice.app)
    }
}

final class AgentAreaThemeTests: XCTestCase {
    func testDefaultTerminalThemeKeepsAppTokens() {
        XCTAssertEqual(AgentAreaTheme.theme(terminalThemeID: TermPalettes.defaultID), .appearance)
    }

    func testAreaFollowsTerminalPaletteNotWindow() {
        let light = AgentAreaTheme.theme(terminalThemeID: "solarized-light")
        XCTAssertEqual(light.bg, TermPalettes.solarizedLight.background)
        XCTAssertTrue(light.isLight)
        let dark = AgentAreaTheme.theme(terminalThemeID: "dracula")
        XCTAssertEqual(dark.bg, TermPalettes.dracula.background)
        XCTAssertFalse(dark.isLight)
    }

    /// Текст области агента читается в любой теме терминала: не ниже 4,5:1 на фоне и поверхности.
    func testAreaTextContrastForEveryTerminalTheme() {
        for p in TermPalettes.all {
            let t = AgentAreaTheme.theme(terminalThemeID: p.id)
            let texts = [t.ink, t.muted, t.accent, t.cyan, t.violet, t.rose, t.periwinkle, t.amber]
                + (p.id == TermPalettes.defaultID ? [] : [t.dim, t.faint])
            for c in texts {
                for g in [t.bg, t.surface] {
                    XCTAssertGreaterThanOrEqual(Contrast.ratio(c, g), 4.5 - 0.01, "\(p.id) \(String(c, radix: 16)) на \(String(g, radix: 16))")
                }
            }
        }
    }

    @MainActor
    func testModelPublishesAreaTheme() {
        let name = "agent-team-tests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: [])
        m.selectWindowTheme("dracula")
        m.selectTheme("solarized-light")
        XCTAssertEqual(AgentAreaStore.shared.theme.bg, TermPalettes.solarizedLight.background)
        XCTAssertEqual(ThemeStore.shared.theme.bg, TermPalettes.dracula.background)
        m.selectTheme(TermPalettes.defaultID)
        XCTAssertEqual(AgentAreaStore.shared.theme, .appearance)
        m.selectWindowTheme(WindowThemeChoice.app)
    }
}

final class LiveInputSettingTests: XCTestCase {
    func testDefaultIsAppFieldAndDecodesFlag() throws {
        XCTAssertFalse(DisplaySettings().liveInput)
        XCTAssertTrue(try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"liveInput":true}"#.utf8)).liveInput)
        // Нет поля или испорчено — своё поле приложения.
        XCTAssertFalse(try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{}"#.utf8)).liveInput)
        XCTAssertFalse(try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"liveInput":"да"}"#.utf8)).liveInput)
    }

    @MainActor
    func testModelFlagAndPersistence() {
        let name = "agent-team-tests-" + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: [])
        m.settings.liveInput = true
        XCTAssertTrue(DisplaySettingsStore.load(d).liveInput)
        XCTAssertTrue(m.liveInputOn)
        m.settings.liveInput = false
        XCTAssertFalse(DisplaySettingsStore.load(d).liveInput)
    }
}
