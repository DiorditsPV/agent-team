import XCTest
@testable import AgentTeamCore

/// Мигающий кружок идущего инструмента. Экраны — по записи живой панели менеджера: в погашенной фазе на
/// месте «⏺» стоит пробел того же серого цвета. Текст экранов заменён, строение и коды цвета — как в записи.
final class BlinkingBulletTests: XCTestCase {
    private func screen(_ name: String) throws -> [StyledLine] {
        SGRParser.parse(String(decoding: try fixture("live-blink-\(name).txt"), as: UTF8.self))
    }

    /// Без выравнивания фаз разбор ответа зависел от фазы — так чат и прыгал.
    func testPhasesParsedDifferentlyWithoutSteadyBullets() throws {
        let on = PaneScreen.read(try screen("on")), off = PaneScreen.read(try screen("off"))
        XCTAssertNotEqual(on.reply, off.reply, "запись подтверждает гипотезу: черновик зависит от фазы мигания")
    }

    func testBothPhasesParseTheSame() throws {
        let on = ScreenMarks.steadyBullets(try screen("on")), off = ScreenMarks.steadyBullets(try screen("off"))
        XCTAssertEqual(on.map(\.plain), off.map(\.plain))
        XCTAssertEqual(PaneScreen.read(on), PaneScreen.read(off))
    }

    /// Строки продолжения, пустые строки и окрашенный фон (полосы diff) не трогаются.
    func testOnlyBlinkedBulletRestored() {
        var gray = TermStyle(); gray.fg = .indexed(246)
        var bg = TermStyle(); bg.bg = .indexed(22)
        let lines = [
            StyledLine(runs: [StyledRun(text: "  продолжение абзаца", style: TermStyle())]),
            StyledLine(runs: [StyledRun(text: " ", style: bg), StyledRun(text: " + добавлено", style: TermStyle())]),
            StyledLine(runs: [StyledRun(text: " ", style: gray), StyledRun(text: "   отступ", style: TermStyle())]),
            StyledLine(runs: [StyledRun(text: " ", style: gray), StyledRun(text: " Bash(ls)", style: TermStyle())]),
        ]
        let out = ScreenMarks.steadyBullets(lines).map(\.plain)
        XCTAssertEqual(out, ["  продолжение абзаца", "  + добавлено", "    отступ", "⏺ Bash(ls)"])
    }

    /// Строка идущего инструмента («⏺ Advising using Opus 5.5», строки результата под ней нет) — не черновик ответа:
    /// что делает менеджер, показывает строка хода. Цвет кружка инструмента известен по миганию.
    func testToolLineIsNotDraft() throws {
        var colors = Set<TermColor>()
        _ = ScreenMarks.steadyBullets(try screen("off"), blinked: &colors)
        XCTAssertEqual(colors, [.indexed(246)], "цвет погашенного кружка — цвет идущего инструмента")
        let lit = ScreenMarks.steadyBullets(try screen("on"), blinked: &colors)
        XCTAssertNil(PaneScreen.read(lit, toolColors: colors).reply, "строка инструмента не попадает в «пишет…»")
        XCTAssertEqual(PaneScreen.read(lit).reply?.text, "Advising using Opus 5.5", "без цвета инструмента — как раньше")
        // Белый кружок ответа — не инструмент: текст ответа остаётся черновиком.
        let reply = SGRParser.parse("\u{1b}[38;5;231m⏺\u{1b}[39m Пишу сводку для владельца.\n\u{1b}[38;5;174m✽\u{1b}[39m Moonwalking… (3s · ↓ 10 tokens)\n"
                                    + String(repeating: "─", count: 40) + "\n❯ \n" + String(repeating: "─", count: 40))
        XCTAssertEqual(PaneScreen.read(reply, toolColors: colors).reply?.text, "Пишу сводку для владельца.")
    }
}
