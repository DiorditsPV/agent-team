import XCTest
@testable import AgentTeamCore

final class TermPaletteTests: XCTestCase {
    func testEveryThemeHasSixteenColorsAndUniqueID() {
        XCTAssertEqual(Set(TermPalettes.all.map(\.id)).count, TermPalettes.all.count)
        for p in TermPalettes.all { XCTAssertEqual(p.ansi.count, 16, p.name) }
        XCTAssertEqual(TermPalettes.light.count, 5)
        XCTAssertEqual(TermPalettes.dark.count + TermPalettes.light.count, TermPalettes.all.count)
    }

    /// Основной текст каждой темы на её фоне — не ниже WCAG AA для обычного текста.
    func testForegroundContrastMeetsAA() {
        for p in TermPalettes.all {
            let c = TermPalette.contrast(p.foreground, p.background)
            XCTAssertGreaterThanOrEqual(c, 4.5, "\(p.name): \(c)")
        }
    }

    func testRequestedThemesArePresent() {
        let names = Set(TermPalettes.all.map(\.name))
        for n in ["По умолчанию", "Dracula", "One Dark", "Dark+", "Light+", "Monokai", "GitHub Dark", "GitHub Light", "One Dark Pro",
                  "Darcula", "Nord", "Gruvbox Dark", "Gruvbox Light", "Tokyo Night", "Catppuccin Mocha", "Catppuccin Latte",
                  "Solarized Dark", "Solarized Light"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertEqual(TermPalettes.all.first?.id, TermPalettes.defaultID)
    }

    func testSelectionDiffersFromBackground() {
        for p in TermPalettes.all { XCTAssertNotEqual(p.selection, p.background, p.name) }
    }

    func testContrastBounds() {
        XCTAssertEqual(TermPalette.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(TermPalette.contrast(0x808080, 0x808080), 1, accuracy: 0.001)
    }

    func testFontOrderPutsCodeFontsFirst() {
        let out = FontOrder.arrange(installed: ["Menlo", "Hack", "Zed Mono", "Fira Code"], always: ["SF Mono", "JetBrains Mono"],
                                    monospaced: ["Zed Mono", "Hack", "Menlo", "Fira Code"], ui: ["Onest", "SF Pro"])
        XCTAssertEqual(out, ["SF Mono", "Menlo", "JetBrains Mono", "Fira Code", "Hack", "Zed Mono", "Onest", "SF Pro"])
    }

    /// Умолчание не должно менять вид: те же 16 цветов, фон панели (T.well) и основной текст (T.muted).
    func testDefaultPaletteKeepsCurrentLook() {
        let p = TermPalettes.standard
        XCTAssertEqual(p.ansi[1], 0xE58FA8)
        XCTAssertEqual(p.ansi[2], 0xC8F169)
        XCTAssertEqual(p.ansi[15], 0xEDEBE3)
        XCTAssertEqual(p.background, 0x0B0C0A)
        XCTAssertEqual(p.foreground, 0x9A988D)
    }

    func testSGRColorsFollowTheme() {
        let red = SGRParser.parse("\u{1B}[31mx").first!.runs.first!.style.fg!
        let bright = SGRParser.parse("\u{1B}[92mx").first!.runs.first!.style.fg!
        XCTAssertEqual(TermPalettes.standard.rgb(red), 0xE58FA8)
        XCTAssertEqual(TermPalettes.dracula.rgb(red), 0xFF5555)
        XCTAssertEqual(TermPalettes.solarizedDark.rgb(red), 0xDC322F)
        XCTAssertEqual(TermPalettes.dracula.rgb(bright), 0x69FF94)
        XCTAssertNotEqual(TermPalettes.oneDark.rgb(red), TermPalettes.dracula.rgb(red))
    }

    func testExtendedColorsDoNotDependOnTheme() {
        // Куб 6×6×6, серая шкала и RGB одинаковы у всех тем.
        for p in TermPalettes.all {
            XCTAssertEqual(p.rgb(.indexed(16)), 0x000000)
            XCTAssertEqual(p.rgb(.indexed(196)), 0xFF0000)
            XCTAssertEqual(p.rgb(.indexed(231)), 0xFFFFFF)
            XCTAssertEqual(p.rgb(.indexed(232)), 0x080808)
            XCTAssertEqual(p.rgb(.rgb(120, 200, 255)), 0x78C8FF)
        }
    }

    func testUnknownThemeFallsBackToDefault() {
        XCTAssertEqual(TermPalettes.palette(id: "нет такой").id, TermPalettes.defaultID)
        XCTAssertEqual(TermPalettes.palette(id: nil).id, TermPalettes.defaultID)
        XCTAssertEqual(TermPalettes.palette(id: "dracula").name, "Dracula")
    }
}

final class DisplaySettingsTests: XCTestCase {
    private func suite() -> (UserDefaults, String) {
        let name = "agent-team-tests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testDefaultsWhenNothingSaved() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(DisplaySettingsStore.load(d), DisplaySettings())
        XCTAssertEqual(DisplaySettings().terminal.spacing, 1.15)
    }

    func testSaveAndLoad() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        var s = DisplaySettings()
        s.chat = TextLook(family: "Menlo", size: 16, spacing: 8)
        s.terminal = TextLook(family: "SF Mono", size: 13, spacing: 1.3)
        s.themeID = "one-dark"
        DisplaySettingsStore.save(s, to: d)
        XCTAssertEqual(DisplaySettingsStore.load(d), s)
    }

    func testCorruptedDataGivesDefaults() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        d.set(Data("не json".utf8), forKey: DisplaySettingsStore.key)
        XCTAssertEqual(DisplaySettingsStore.load(d), DisplaySettings())
        d.set("строка вместо данных", forKey: DisplaySettingsStore.key)
        XCTAssertEqual(DisplaySettingsStore.load(d), DisplaySettings())
    }

    func testPartialJSONKeepsDefaultsForMissingFields() throws {
        let json = #"{"terminal":{"size":15},"themeID":"dracula"}"#
        let s = try JSONDecoder().decode(DisplaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.terminal, TextLook(family: "JetBrains Mono", size: 15, spacing: 1.15))
        XCTAssertEqual(s.chat, DisplaySettings.chatDefault)
        XCTAssertEqual(s.themeID, "dracula")
    }

    func testUnknownThemeAndOutOfRangeValuesAreCorrected() throws {
        let json = #"{"chat":{"family":"","size":500,"spacing":-4},"terminal":{"size":1,"spacing":9},"themeID":"выдуманная"}"#
        let s = try JSONDecoder().decode(DisplaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.themeID, TermPalettes.defaultID)
        XCTAssertEqual(s.chat.family, "Onest")
        XCTAssertEqual(s.chat.size, 22)
        XCTAssertEqual(s.chat.spacing, 0)
        XCTAssertEqual(s.terminal.size, 9)
        XCTAssertEqual(s.terminal.spacing, 1.6)
    }

    /// Поле темы неверного типа (правка руками, старая версия) заменяется умолчанием только само: шрифт чата, тема
    /// окна и показ ленты владельца остаются. Прежде одно такое поле сбрасывало все настройки вида.
    func testWrongTypeFieldKeepsOtherSettings() throws {
        let json = #"{"chat":{"family":"Menlo","size":16,"spacing":3},"themeID":7,"windowThemeID":true,"chatThemeID":["x"],"feedManager":{"bash":false},"liveInput":true}"#
        let s = try JSONDecoder().decode(DisplaySettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.chat, TextLook(family: "Menlo", size: 16, spacing: 3))
        XCTAssertEqual(s.themeID, TermPalettes.defaultID)
        XCTAssertEqual(s.windowThemeID, WindowThemeChoice.app)
        XCTAssertEqual(s.chatThemeID, ChatThemeChoice.window)
        XCTAssertFalse(s.feedManager.bash)
        XCTAssertTrue(s.liveInput)
    }

    /// Каждый сброс «Настроек» возвращает только свою часть: цвет окна, чата, агентов, текст чата, текст терминала.
    @MainActor
    func testEachResetTouchesOnlyItsPart() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d)
        let chatLook = TextLook(family: "Menlo", size: 18, spacing: 2)
        let termLook = TextLook(family: "Menlo", size: 15, spacing: 1.3)
        func customize() {
            m.selectWindowTheme("dracula")
            m.selectChatTheme("github-light")
            m.selectTheme("nord")
            m.settings.chat = chatLook
            m.settings.terminal = termLook
        }
        customize()
        let custom = m.settings

        m.resetWindowColors()
        var want = custom
        want.windowThemeID = WindowThemeChoice.app
        XCTAssertEqual(m.settings, want)

        customize()
        m.resetChatColors()
        want = custom
        want.chatThemeID = ChatThemeChoice.window
        XCTAssertEqual(m.settings, want)

        customize()
        m.resetAgentColors()
        want = custom
        want.themeID = TermPalettes.defaultID
        XCTAssertEqual(m.settings, want)
        XCTAssertEqual(m.palette.id, TermPalettes.defaultID)

        customize()
        m.resetChatText()
        want = custom
        want.chat = DisplaySettings.chatDefault
        XCTAssertEqual(m.settings, want)

        customize()
        m.resetTerminalText()
        want = custom
        want.terminal = DisplaySettings.terminalDefault
        XCTAssertEqual(m.settings, want)
        XCTAssertEqual(DisplaySettingsStore.load(d), want)
    }

    /// Сброс цвета снимает и тему из аргумента запуска: владелец видит то, что выбрал.
    @MainActor
    func testColorResetsClearLaunchThemes() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: ["--app-theme", "dracula", "--chat-theme", "nord", "--term-theme", "monokai"])
        XCTAssertEqual(m.windowThemeChoice, "dracula")
        m.resetWindowColors()
        m.resetChatColors()
        m.resetAgentColors()
        XCTAssertEqual(m.windowThemeChoice, WindowThemeChoice.app)
        XCTAssertEqual(m.chatThemeChoice, ChatThemeChoice.window)
        XCTAssertEqual(m.palette.id, TermPalettes.defaultID)
    }

    @MainActor
    func testModelPersistsChangesAndResets() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d)
        m.selectTheme("dracula")
        m.settings.chat.size = 18
        XCTAssertEqual(DisplaySettingsStore.load(d).themeID, "dracula")
        XCTAssertEqual(DisplaySettingsStore.load(d).chat.size, 18)
        XCTAssertEqual(m.palette.id, "dracula")
        m.resetChatText()
        m.resetTerminalText()
        m.resetAgentColors()
        XCTAssertEqual(DisplaySettingsStore.load(d), DisplaySettings())
    }

    @MainActor
    func testLaunchThemeIsNotSavedUntilOwnerChoosesOne() {
        let (d, name) = suite()
        defer { d.removePersistentDomain(forName: name) }
        let m = DisplayModel(defaults: d, launchArguments: ["app", "--term-theme", "one-dark"])
        XCTAssertEqual(m.palette.id, "one-dark")
        XCTAssertEqual(DisplaySettingsStore.load(d).themeID, TermPalettes.defaultID)
        m.selectTheme("dracula")
        XCTAssertEqual(m.palette.id, "dracula")
        XCTAssertEqual(DisplaySettingsStore.load(d).themeID, "dracula")
        XCTAssertEqual(DisplayModel(defaults: d, launchArguments: ["--term-theme", "нет"]).palette.id, "dracula")
    }
}

final class ChatGapFactorTests: XCTestCase {
    func testFactorIsOneAtDefaultDenseAtMinimumAndGrowsToMaximum() {
        let d = DisplaySettings.chatGapFactor(spacing: DisplaySettings.chatDefault.spacing)
        XCTAssertEqual(d, 1.0, accuracy: 1e-9, "умолчание не меняется")
        XCTAssertEqual(DisplaySettings.chatGapFactor(spacing: DisplaySettings.chatSpacing.lowerBound), 0.25, accuracy: 1e-9)
        XCTAssertGreaterThan(DisplaySettings.chatGapFactor(spacing: DisplaySettings.chatSpacing.upperBound), 1.9)
        var prev = 0.0
        for s in stride(from: 0.0, through: 12.0, by: 1.0) {
            let f = DisplaySettings.chatGapFactor(spacing: s)
            XCTAssertGreaterThan(f, prev, "множитель растёт с интервалом")
            prev = f
        }
    }

    func testFactorClampsOutsideRange() {
        XCTAssertEqual(DisplaySettings.chatGapFactor(spacing: -3), DisplaySettings.chatGapFactor(spacing: 0))
        XCTAssertEqual(DisplaySettings.chatGapFactor(spacing: 99), DisplaySettings.chatGapFactor(spacing: 12))
    }
}
