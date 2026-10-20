import XCTest
@testable import AgentTeamCore

final class WindowThemeTests: XCTestCase {
    private var themes: [(String, WindowTheme)] {
        TermPalettes.all.map { ($0.name, WindowTheme.from($0)) }
    }

    /// «Оформление приложения» — прежние токены макета.
    func testAppearanceKeepsOriginalTokens() {
        let t = WindowTheme.appearance
        XCTAssertEqual([t.bg, t.side, t.surface, t.well, t.line], [0x11120F, 0x0E0F0C, 0x1A1B17, 0x0B0C0A, 0x2C2E27])
        XCTAssertEqual([t.ink, t.muted, t.dim, t.faint], [0xEDEBE3, 0x9A988D, 0x6B6A61, 0x4A4C43])
        XCTAssertEqual([t.accent, t.accentBg, t.amber, t.amberBg], [0xC8F169, 0x161A0E, 0xF2B35B, 0x1E1A12])
        XCTAssertEqual([t.cyan, t.violet, t.rose, t.periwinkle], [0x7CC7D9, 0xB9A3F0, 0xE58FA8, 0x9FB4F5])
        XCTAssertEqual(t.onAccent, t.bg)
        XCTAssertFalse(t.isLight)
    }

    func testDefaultChoiceIsAppearance() {
        XCTAssertEqual(DisplaySettings().windowThemeID, WindowThemeChoice.app)
        XCTAssertEqual(WindowThemeChoice.theme(id: "app"), .appearance)
        XCTAssertEqual(WindowThemeChoice.theme(id: "nord"), .from(TermPalettes.nord))
        XCTAssertEqual(WindowThemeChoice.theme(id: "terminal"), .from(TermPalettes.standard))
    }

    func testUnknownWindowThemeFallsBackToAppearance() throws {
        let s = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"windowThemeID":"нет такой"}"#.utf8))
        XCTAssertEqual(s.windowThemeID, WindowThemeChoice.app)
        let old = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"windowThemeID":"terminal"}"#.utf8))
        XCTAssertEqual(old.windowThemeID, WindowThemeChoice.app)
        let ok = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"windowThemeID":"nord"}"#.utf8))
        XCTAssertEqual(ok.windowThemeID, "nord")
    }

    /// Основной текст читается на фоне и на всех поверхностях окна.
    func testInkContrastOnEverySurface() {
        for (name, t) in themes + [("appearance", .appearance)] {
            for (label, surface) in [("bg", t.bg), ("side", t.side), ("surface", t.surface), ("well", t.well)] {
                let c = TermPalette.contrast(t.ink, surface)
                XCTAssertGreaterThanOrEqual(c, 4.5, "\(name): ink на \(label) = \(c)")
            }
        }
    }

    func testMutedTextIsReadable() {
        for (name, t) in themes {
            XCTAssertGreaterThanOrEqual(TermPalette.contrast(t.muted, t.bg), 4.5, "\(name) muted на bg")
            XCTAssertGreaterThanOrEqual(TermPalette.contrast(t.muted, t.surface), 4.5, "\(name) muted на surface")
            XCTAssertGreaterThanOrEqual(TermPalette.contrast(t.dim, t.bg), 3, "\(name) dim")
        }
    }

    func testStatusColorsAndAccentAreVisible() {
        for (name, t) in themes {
            for (label, c) in [("accent", t.accent), ("amber", t.amber), ("cyan", t.cyan), ("violet", t.violet),
                               ("rose", t.rose), ("periwinkle", t.periwinkle)] {
                XCTAssertGreaterThanOrEqual(TermPalette.contrast(c, t.bg), 3, "\(name) \(label)")
            }
            XCTAssertGreaterThanOrEqual(TermPalette.contrast(t.onAccent, t.accent), 3, "\(name) onAccent")
        }
    }

    // Различимость цветов ролей — RoleColorsTests (ΔE00 во всех темах окна, чата и области агента).

    func testLightnessFollowsBackground() {
        XCTAssertTrue(WindowTheme.from(TermPalettes.githubLight).isLight)
        XCTAssertTrue(WindowTheme.from(TermPalettes.solarizedLight).isLight)
        XCTAssertFalse(WindowTheme.from(TermPalettes.nord).isLight)
        XCTAssertEqual(TermPalettes.all.filter { WindowTheme.from($0).isLight }.map(\.id), TermPalettes.light.map(\.id))
    }

    @MainActor
    func testModelPublishesTheme() {
        let d = UserDefaults(suiteName: "wt-\(UUID().uuidString)")!
        let m = DisplayModel(defaults: d, launchArguments: [])
        XCTAssertEqual(ThemeStore.shared.theme, .appearance)
        m.selectWindowTheme("github-light")
        XCTAssertEqual(ThemeStore.shared.theme, .from(TermPalettes.githubLight))
        // Тема терминала окно не меняет, и наоборот.
        m.selectTheme("nord")
        XCTAssertEqual(ThemeStore.shared.theme, .from(TermPalettes.githubLight))
        XCTAssertEqual(m.palette.id, "nord")
        m.resetAgentColors()
        XCTAssertEqual(m.settings.windowThemeID, "github-light")
        m.resetWindowColors()
        XCTAssertEqual(m.settings.themeID, TermPalettes.defaultID)
        m.selectWindowTheme(WindowThemeChoice.app)
        XCTAssertEqual(ThemeStore.shared.theme, .appearance)
    }

    @MainActor
    func testLaunchArgumentOverridesWindowTheme() {
        let d = UserDefaults(suiteName: "wt-\(UUID().uuidString)")!
        let m = DisplayModel(defaults: d, launchArguments: ["--app-theme", "nord"])
        XCTAssertEqual(m.windowTheme, .from(TermPalettes.nord))
        XCTAssertEqual(m.windowThemeChoice, "nord")
        XCTAssertEqual(DisplayModel(defaults: d, launchArguments: ["--app-theme", "нет"]).windowTheme, .appearance)
        ThemeStore.shared.theme = .appearance
    }
}
