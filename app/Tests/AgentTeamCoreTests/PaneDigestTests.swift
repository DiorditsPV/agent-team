import XCTest
@testable import AgentTeamCore

/// Образцы экрана Claude Code обезличены: нейтральные пути и слова.
final class PaneDigestTests: XCTestCase {
    private let esc = "\u{1B}"

    private func parse(_ s: String) -> [StyledLine] { SGRParser.parse(s) }

    private var sample: String {
        let pad = String(repeating: " ", count: 60)
        return """
        \(esc)[2m✻ Compacted while idle (ctrl+o to see full summary)\(esc)[0m

        ⏺ Read(src/dates.py)
          ⎿  Read 10 lines (ctrl+o to expand)

        ⏺ Разбор дат вынесен в модуль.
          Тесты: 148 прошли, 0 упали.
          Ветка executor, коммит a1b2c3d.

        ⏺ Update(src/dates.py)
          ⎿  Updated src/dates.py with 2 additions

        ✻ Stewing… (2m 14s · ↓ 3.1k tokens · esc to interrupt)
          ⎿  Tip: Name your conversations with /rename

        \(pad)1 new message (click) ↓
        \(pad)\(esc)[31m✘ Auto-update failed · Run claude doctor\(esc)[0m
        ────────────────────────────
        ❯\u{a0}
        ────────────────────────────
          [Opus] high ctx 32% · main
          ⏵⏵ auto mode on (shift+tab to cycle)
        """
    }

    func testAutoUpdateLineRemovedWithWrappedTail() {
        let wrapped = "вывод\n   ✘ Auto-update failed · Run c\nlaude doctor\nещё вывод"
        XCTAssertEqual(PaneTail.content(parse(wrapped)).map(\.plain), ["вывод", "ещё вывод"])
        let whole = "вывод\n          ✘ Auto-update failed · Run claude doctor\nещё вывод"
        XCTAssertEqual(PaneTail.content(parse(whole)).map(\.plain), ["вывод", "ещё вывод"])
    }

    func testNewMessagesPlaqueRemovedAsSegmentKeepingOutput() {
        let line = "  Ran 1 shell command   \(esc)[48;5;237m 2 new messages (click) ↓ \(esc)[0m"
        XCTAssertEqual(PaneTail.content(parse(line)).map(\.plain), ["  Ran 1 shell command"])
        XCTAssertEqual(PaneTail.content(parse("вывод\n         1 new message (click) ↓\nдальше")).map(\.plain), ["вывод", "дальше"])
    }

    func testStripKeepsDiffBackgroundPadding() {
        let line = "\(esc)[42m+ added   \(esc)[0m"
        XCTAssertEqual(PaneTail.content(parse(line)).map(\.plain), ["+ added   "])
    }

    func testDigestHeadlineIsSpinnerAndBodyIsLastAgentText() {
        let d = PaneDigest.make(parse(sample))
        XCTAssertEqual(d.headlineKind, .spinner)
        XCTAssertEqual(d.headline?.plain, "✻ Stewing… (2m 14s · ↓ 3.1k tokens · esc to interrupt)")
        XCTAssertEqual(d.body.map(\.plain), ["Разбор дат вынесен в модуль.", "Тесты: 148 прошли, 0 упали.", "Ветка executor, коммит a1b2c3d."])
    }

    func testDigestWithoutSpinnerUsesLastToolAction() {
        let screen = "⏺ Read(src/a.py)\n  ⎿  Read 3 lines\n\n⏺ Готово.\n\n⏺ Bash(make test)\n  ⎿  ok\n────────\n❯ \n────────"
        let d = PaneDigest.make(parse(screen))
        XCTAssertEqual(d.headlineKind, .action)
        XCTAssertEqual(d.headline?.plain, "⏺ Bash(make test)")
        XCTAssertEqual(d.body.map(\.plain), ["Готово."])
    }

    func testDigestDropsNoiseAndIdleScreen() {
        let rows = PaneDigest.make(parse(sample)).rows.map(\.plain).joined(separator: "\n")
        for noise in ["Tip:", "Compacted", "Auto-update", "new message", "shift+tab", "ctx 32%", "❯", "────"] {
            XCTAssertFalse(rows.contains(noise), noise)
        }
    }

    func testDigestWithoutBulletsFallsBackToLastLines() {
        let d = PaneDigest.make(parse("a\nb\n\n\nc\nd\ne\nf\ng"), bodyLines: 3)
        XCTAssertNil(d.headline)
        XCTAssertEqual(d.body.map(\.plain), ["e", "f", "g"])
    }

    func testDigestCapsBodyAndAlignsLeft() {
        let long = (1...9).map { "  строка \($0)" }.joined(separator: "\n")
        let d = PaneDigest.make(parse("⏺ Итог:\n" + long + "\n" + String(repeating: " ", count: 40) + "правая"), bodyLines: 4)
        XCTAssertEqual(d.body.count, 4)
        XCTAssertEqual(d.body.last?.plain, "правая")
    }

    func testPlainFocusKeepsEverythingElse() {
        // Экран агента остаётся полным: Tip и «Compacted» на месте, пропадают только плашка и автообновление.
        let kept = PaneTail.content(parse(sample)).map(\.plain).joined(separator: "\n")
        XCTAssertTrue(kept.contains("Tip: Name your conversations"))
        XCTAssertTrue(kept.contains("Compacted while idle"))
        XCTAssertFalse(kept.contains("Auto-update"))
        XCTAssertFalse(kept.contains("new message"))
    }
}
