import XCTest
@testable import AgentTeamCore

/// Цвета ролей различимы с первого взгляда во всех темах окна, чата и области агента.
final class RoleColorsTests: XCTestCase {
    /// Все темы, в которых приложение рисует цвета ролей: окно, область агента (тема терминала), чат «как окно» и
    /// чат своей темой.
    private var variants: [(String, WindowTheme)] {
        var out: [(String, WindowTheme)] = [("окно: app", WindowThemeChoice.theme(id: WindowThemeChoice.app)),
                                            ("чат как окно: app", ChatThemeChoice.theme(choice: ChatThemeChoice.window, window: .appearance))]
        for p in TermPalettes.all {
            let window = WindowThemeChoice.theme(id: p.id)
            out.append(("окно: \(p.id)", window))
            out.append(("область агента: \(p.id)", AgentAreaTheme.theme(terminalThemeID: p.id)))
            out.append(("чат: \(p.id)", ChatThemeChoice.theme(choice: p.id, window: .appearance)))
            out.append(("чат как окно: \(p.id)", ChatThemeChoice.theme(choice: ChatThemeChoice.window, window: window)))
        }
        return out
    }

    // MARK: ΔE00

    /// Сверка с таблицей Sharma, Wu, Dalal (2005): обычная пара, нулевая насыщенность, оттенки через 0°/360°,
    /// большая разница по светлоте.
    func testDeltaEMatchesSharmaTable() {
        let pairs: [((Double, Double, Double), (Double, Double, Double), Double)] = [
            ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
            ((50, 0, 0), (50, -1, 2), 2.3669),
            ((50, 2.49, -0.001), (50, -2.49, 0.0009), 7.1792),
            ((50, 2.5, 0), (73, 25, -18), 27.1492),
            ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644),
        ]
        for (p, q, want) in pairs {
            let d = ColorDifference.deltaE((l: p.0, a: p.1, b: p.2), (l: q.0, a: q.1, b: q.2))
            XCTAssertEqual(d, want, accuracy: 0.0001, "\(p) — \(q)")
        }
    }

    /// Поворот оттенка не снижает контраст к фону своей стороны (тёмной или светлой) и почти не меняет его.
    func testHueRotationKeepsContrast() {
        for c: UInt32 in [0x9FB4F5, 0xB9A3F0, 0x81A1C1, 0x268BD2, 0xF2B35B] {
            for d in stride(from: -180.0, through: 180, by: 15) {
                for bg: UInt32 in [0x11120F, 0x2E3440, 0xFFFFFF, 0xFDF6E3] {
                    let dark = Contrast.luminance(bg) < 0.18
                    let r = ColorDifference.rotatedHue(c, by: d, darkGround: dark)
                    let was = TermPalette.contrast(c, bg), now = TermPalette.contrast(r, bg)
                    let label = String(format: "%06X на %+.0f° на фоне %06X", c, d, bg)
                    XCTAssertGreaterThanOrEqual(now, was, label)
                    XCTAssertLessThan(now - was, was * 0.02, label)
                }
            }
        }
    }

    // MARK: палитра

    /// Любые два цвета ролей и акцент менеджера различаются не меньше чем на `RoleColors.minDelta` во всех темах.
    func testRoleColorsAreDistinctEverywhere() {
        for (name, t) in variants {
            let colors = [t.accent] + t.rolePalette
            for i in colors.indices {
                for j in colors.indices where j > i {
                    let d = ColorDifference.deltaE(colors[i], colors[j])
                    XCTAssertGreaterThanOrEqual(d, RoleColors.minDelta,
                                                String(format: "%@: цвета %d и %d (%06X, %06X) — ΔE00 %.1f", name, i, j, colors[i], colors[j], d))
                }
            }
        }
    }

    /// Контраст каждого цвета ролей к фону и поверхностям не ниже, чем у исходного токена.
    func testContrastNotLowerThanTokens() {
        for (name, t) in variants {
            let tokens = [t.cyan, t.violet, t.periwinkle, t.rose, t.amber]
            for (k, (was, now)) in zip(tokens, t.rolePalette).enumerated() {
                for (label, ground) in [("bg", t.bg), ("surface", t.surface), ("well", t.well)] {
                    XCTAssertGreaterThanOrEqual(TermPalette.contrast(now, ground), TermPalette.contrast(was, ground),
                                                "\(name): роль \(k) на \(label)")
                }
            }
        }
    }

    /// Разводится только то, что сливалось: в оформлении приложения сдвинут один periwinkle (он сливался с violet),
    /// в Catppuccin Mocha цвета и так различимы — палитра совпадает с токенами.
    func testOnlyConflictingColorsMove() {
        let app = WindowTheme.appearance
        let palette = app.rolePalette
        XCTAssertEqual([palette[0], palette[1], palette[3], palette[4]], [app.cyan, app.violet, app.rose, app.amber])
        XCTAssertNotEqual(palette[2], app.periwinkle)
        XCTAssertGreaterThanOrEqual(ColorDifference.deltaE(palette[2], app.violet), RoleColors.minDelta)
        let mocha = WindowThemeChoice.theme(id: "catppuccin-mocha")
        XCTAssertEqual(mocha.rolePalette, [mocha.cyan, mocha.violet, mocha.periwinkle, mocha.rose, mocha.amber])
    }

    /// Токены темы не трогаются: periwinkle — ещё и цвет ссылок, amber — статус «ждёт».
    func testTokensStayAsTheme() {
        let t = WindowTheme.appearance
        XCTAssertEqual([t.cyan, t.violet, t.rose, t.periwinkle, t.amber], [0x7CC7D9, 0xB9A3F0, 0xE58FA8, 0x9FB4F5, 0xF2B35B])
    }

    func testPaletteIsCachedAndStable() {
        let t = WindowThemeChoice.theme(id: "nord")
        XCTAssertEqual(t.rolePalette, t.rolePalette)
        XCTAssertEqual(RoleColors.spread(accent: t.accent, roles: [t.cyan, t.violet, t.periwinkle, t.rose, t.amber], ground: t.bg,
                                         minDelta: RoleColors.minDelta),
                       t.rolePalette)
    }
}
