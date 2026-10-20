import XCTest
@testable import AgentTeamCore

final class TurnStatusTests: XCTestCase {
    private func screen(_ spinner: String) -> [StyledLine] {
        SGRParser.parse("⏺ Read(src/a.py)\n  ⎿  Read 3 lines\n\n\(spinner)\n  ⎿  Tip: Name your conversations\n\n────────\n❯ \n────────\n  [Opus] ctx 3%")
    }

    func testSpinnerWithTimeTokensAndNote() {
        let s = TurnStatus.from(screen("✳ Shimmying… (5s · ↓ 25 tokens · thinking with high effort)"))
        XCTAssertEqual(s, TurnStatus(verb: "Shimmying", seconds: 5, tokens: "25", arrow: "↓", note: "thinking with high effort"))
    }

    func testMinutesAndKiloTokensAndInterruptHint() {
        let s = TurnStatus.from(screen("✶ Stewing… (2m 14s · ↓ 3.1k tokens · esc to interrupt)"))
        XCTAssertEqual(s?.seconds, 134)
        XCTAssertEqual(s?.tokens, "3.1k")
        XCTAssertNil(s?.note)
        XCTAssertEqual(s?.elapsedText, "2 мин 14 с")
    }

    func testSpinnerWithoutTokenCounterYet() {
        let s = TurnStatus.from(screen("· Harmonizing… (4s)"))
        XCTAssertEqual(s, TurnStatus(verb: "Harmonizing", seconds: 4))
    }

    func testNoSpinnerWhenIdleOrOnlyOldOutput() {
        XCTAssertNil(TurnStatus.from(SGRParser.parse("⏺ Готово.\n\n────\n❯ \n────")))
        // «Ran 2 shell commands (ctrl+o to expand)» — не спиннер.
        XCTAssertNil(TurnStatus.from(SGRParser.parse("  Ran 2 shell commands (ctrl+o to expand)")))
    }

    func testSpinnerFarAboveInputIsIgnored() {
        let old = "✻ Brewing… (9s · ↓ 1 tokens)\n" + (1...12).map { "строка \($0)" }.joined(separator: "\n")
        XCTAssertNil(TurnStatus.from(SGRParser.parse(old)))
    }

    /// Ход дольше часа: строка хода с часами разбирается, «Стоп» и строка хода не пропадают.
    func testHoursInTurnLine() {
        let s = TurnStatus.from(screen("✻ Cogitating… (1h 2m 3s · ↑ 12k tokens)"))
        XCTAssertEqual(s?.seconds, 3723)
        XCTAssertEqual(s?.tokens, "12k")
        XCTAssertEqual(s?.arrow, "↑")
        XCTAssertEqual(s?.elapsedText, "1 ч 2 мин")
    }

    /// Строка хода и рамка распознаются одним модулем: без скобок — только прямо над полем ввода.
    func testSharedTurnLineAndRule() {
        XCTAssertTrue(ScreenMarks.isTurnLine("✻ Stewing… (2m 14s · ↓ 3.1k tokens)"))
        XCTAssertFalse(ScreenMarks.isTurnLine("✳ Doodling…"))
        XCTAssertTrue(ScreenMarks.isTurnLine("✳ Doodling…", bare: true))
        XCTAssertTrue(ScreenMarks.isRule("  ──── Разработчик ─"))
        XCTAssertFalse(ScreenMarks.isRule("▔▔▔▔▔▔"))
        XCTAssertTrue(ScreenMarks.isRule("▔▔▔▔▔▔", menu: true))
    }
}
