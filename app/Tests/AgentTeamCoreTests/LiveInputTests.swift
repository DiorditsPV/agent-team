import XCTest
@testable import AgentTeamCore

/// Экраны сняты с живого claude 2.1.295 на временном сокете tmux (панель 140×50); пути обезличены.
final class LiveInputTests: XCTestCase {
    private func screen(_ name: String) throws -> [StyledLine] {
        SGRParser.parse(String(decoding: try fixture("live-\(name).txt"), as: UTF8.self))
    }

    private func firstRows(_ name: String, _ n: Int = 3) throws -> [String] {
        let lines = try screen(name)
        let r = try XCTUnwrap(LiveInput.region(lines), name)
        return r.rows.prefix(n).map { $0.plain.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces) }
    }

    func testTypedInputStartsAtUpperRule() throws {
        let rows = try firstRows("typed", 2)
        XCTAssertTrue(rows[0].hasPrefix("────"))
        XCTAssertEqual(rows[1], "❯ привет")
        let all = try XCTUnwrap(LiveInput.region(screen("typed"))).rows.map(\.plain).joined(separator: "\n")
        XCTAssertTrue(all.contains("manual mode on"), "строка режима внизу входит в часть")
        XCTAssertFalse(all.contains("User declined"), "текст ленты не попадает")
    }

    func testSlashMenuAboveInputIsIncluded() throws {
        let rows = try firstRows("slash", 2)
        XCTAssertTrue(rows[0].hasPrefix("❯ /loop"), rows[0])
        let all = try XCTUnwrap(LiveInput.region(screen("slash"))).rows.map(\.plain).joined(separator: "\n")
        XCTAssertTrue(all.contains("/superpowers:brainstorming"))
        XCTAssertTrue(all.contains("❯ /"))
    }

    func testAtMenuAboveInputIsIncluded() throws {
        let rows = try firstRows("at", 1)
        XCTAssertTrue(rows[0].hasPrefix("◇"), rows[0])
    }

    func testMultilineInputKeepsAllLines() throws {
        let lines = try firstRows("multi", 4)
        XCTAssertTrue(lines[0].hasPrefix("────"))
        XCTAssertEqual(lines[1], "❯ line one")
        let all = try XCTUnwrap(LiveInput.region(screen("multi"))).rows.map(\.plain).joined(separator: "\n")
        XCTAssertTrue(all.contains("line two"))
    }

    func testPermissionDialogStartsAtRuleAboveHeading() throws {
        let rows = try firstRows("perm", 2)
        XCTAssertTrue(rows[0].hasPrefix("────"))
        XCTAssertEqual(rows[1], "Bash command")
        let all = try XCTUnwrap(LiveInput.region(screen("perm"))).rows.map(\.plain).joined(separator: "\n")
        XCTAssertTrue(all.contains("Esc to cancel"))
        XCTAssertFalse(all.contains("Run the shell command"), "текст ленты над диалогом не попадает")
    }

    func testNoRegionWithoutInputBox() {
        XCTAssertNil(LiveInput.start(SGRParser.parse("⏺ только вывод\n  ⎿ без поля ввода")))
        // Одна рамка (например, таблица ответа) — не строка ввода.
        XCTAssertNil(LiveInput.start(SGRParser.parse("текст\n────────────────────\nещё текст")))
    }

    func testTranscriptRuleFarAboveDoesNotExtendTheRegion() {
        let s = "⏺ Ответ\n────────────────────────\nчасть ответа\n\n\n────────────────────────\n❯ \n────────────────────────\n  [Opus]"
        let lines = SGRParser.parse(s)
        XCTAssertEqual(LiveInput.start(lines), 5)
    }

    func testSpinnerLineAboveInputIsIncluded() {
        let s = "⏺ Ответ\n\n✻ Stewing… (5s · ↓ 25 tokens · esc to interrupt)\n\n────────────────────\n❯ \n────────────────────\n  [Opus]"
        XCTAssertEqual(LiveInput.start(SGRParser.parse(s)), 2)
        // Старая строка хода далеко над рамкой не включается.
        let far = "✻ Stewing… (5s)\nа\nб\nв\nг\n────────────────────\n❯ \n────────────────────\n  [Opus]"
        XCTAssertEqual(LiveInput.start(SGRParser.parse(far)), 5)
    }

    func testSpinnerWithTipBetweenIsIncluded() {
        let s = "⏺ Ответ\n\n✻ Stewing… (5s · ↓ 25 tokens · esc to interrupt)\n  ⎿  Tip: Name your conversations with /rename\n\n────────────────────\n❯ \n────────────────────\n  [Opus]"
        XCTAssertEqual(LiveInput.start(SGRParser.parse(s)), 2)
    }

    func testFirstSecondSpinnerWithoutParenthesesIsIncluded() {
        let s = "❯ запрос\n\n✳ Doodling…\n  ⎿  Tip: Use /theme to change the color theme\n\n────────────────────\n❯ \n────────────────────\n  [Opus]"
        XCTAssertEqual(LiveInput.start(SGRParser.parse(s)), 2)
    }

    func testRewindMenuWithUpperBlockRuleStartsAtItsRule() throws {
        let r = try XCTUnwrap(LiveInput.region(screen("rewind")))
        let rows = r.rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(rows[0].hasPrefix("▔▔▔▔"), rows[0])
        XCTAssertEqual(rows[1], "Rewind")
        XCTAssertTrue(rows.last?.contains("Esc to cancel") ?? false)
        XCTAssertFalse(rows.joined().contains("Brewed"), "лента над меню не попадает")
    }

    func testEscHintInTranscriptAboveInputBoxDoesNotMakeADialog() {
        let s = "⏺ Нажмите Esc to cancel, если передумаете\n\n────────────────────\n❯ \n────────────────────\n  [Opus]"
        XCTAssertEqual(LiveInput.start(SGRParser.parse(s)), 2)
    }

    func testAskFormWithTrailingRuleIsADialog() {
        let r = String(repeating: "─", count: 30)
        let s = "⏺ Спрошу\n\n\(r)\n ☐ Color\nWhich color?\n❯ 1. Red\n     Red color\n  2. Blue\n     Blue color\n  3. Type something.\n\(r)\n  4. Chat about this\nEnter to select · ↑/↓ to navigate · Esc to cancel\n\(r)"
        let rows = LiveInput.region(SGRParser.parse(s))?.rows.map { $0.plain } ?? []
        XCTAssertTrue(rows.first?.hasPrefix("────") ?? false, "\(rows)")
        XCTAssertEqual(rows.count, 11, "замыкающая рамка под подсказкой не входит")
        XCTAssertTrue(rows[1].contains("Color"))
        XCTAssertTrue(rows.last?.contains("Esc to cancel") ?? false)
    }

    // MARK: Длинная форма AskUserQuestion
    // Экраны сняты с живого claude 2.1.295 на временном сокете tmux, панель 50 столбцов: «narrow» — 30 строк
    // (форма выше панели, Claude Code рисует только её низ), «tall» — 60 строк (форма видна целиком).

    private func formRows(_ name: String) throws -> [String] {
        let r = try XCTUnwrap(LiveInput.region(screen(name)), name)
        return r.rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
    }

    private func selected(_ rows: [String]) -> [Int] { rows.compactMap(LiveInput.selectedNumber) }

    func testTallFormIsShownWholeForAnySelection() throws {
        for sel in [1, 3, 6] {
            let rows = try formRows("longform-tall-sel\(sel)")
            XCTAssertTrue(rows[0].hasPrefix("────"), "sel\(sel): \(rows[0])")
            XCTAssertTrue(rows[1].hasPrefix("☐ Rollout"), "sel\(sel): \(rows[1])")
            XCTAssertTrue(rows.contains("Which rollout strategy should we use for the new"), "заголовок вопроса")
            XCTAssertTrue(rows.contains { $0.contains("Switch all customers") }, "пояснение к пункту 1 из середины формы")
            XCTAssertTrue(rows.contains { $0.contains("must be suppressed.") })
            XCTAssertTrue(rows.last?.contains("Esc to cancel") ?? false, "sel\(sel): подсказка в конце")
            XCTAssertEqual(selected(rows), [sel], "sel\(sel)")
            XCTAssertFalse(rows.joined().contains("Use the AskUserQuestion"), "строки ленты над формой не попадают")
        }
    }

    func testNarrowFormKeepsEverythingTheClaudeCodeDrew() throws {
        for sel in [3, 5, 6] {
            let rows = try formRows("longform-narrow-sel\(sel)")
            XCTAssertEqual(selected(rows), [sel], "sel\(sel)")
            XCTAssertTrue(rows.contains { $0.hasPrefix("2. Canary") }, "sel\(sel): граница не схлопнулась до «Chat about this»")
            XCTAssertTrue(rows.contains { $0.hasSuffix("6. Chat about this") })
            XCTAssertTrue(rows.last?.contains("Esc to cancel") ?? false)
        }
    }

    func testClippedFormWithHiddenCursorSaysWhere() throws {
        let rows = try formRows("longform-narrow-sel1")
        XCTAssertTrue(rows[0].hasPrefix("▲ курсор на скрытом пункте 1"), rows[0])
        XCTAssertEqual(selected(rows), [])
        XCTAssertTrue(rows.contains { $0.hasPrefix("2. Canary") })
    }

    func testWrappedHintStaysAFormDecision() throws {
        let lines = try screen("longform-narrow-sel5")        // курсор в «Type something»: подсказка на двух строках
        let plain = lines.map(\.plain)
        XCTAssertTrue(plain.contains { $0.contains("ctrl+g to edit") })
        XCTAssertTrue(AskForm.isOpen(lines))
        XCTAssertNil(PermissionPrompt.from(lines), "форма — не вопрос о праве")
        XCTAssertTrue(PaneTail.asksPermission(plain), "форма ждёт ответа владельца")
    }

    func testFitScrollsToTheSelectedItemAndKeepsTheFooter() throws {
        for name in ["longform-tall-sel1", "longform-tall-sel3", "longform-tall-sel6", "longform-narrow-sel1", "longform-narrow-sel3"] {
            let region = try XCTUnwrap(LiveInput.region(screen(name)), name)
            let fit = LiveInput.fit(region.rows, limit: 18)
            let rows = fit.rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
            XCTAssertLessThanOrEqual(rows.count, 18, name)
            XCTAssertTrue(rows.last?.contains("Esc to cancel") ?? false, "\(name): подсказка внизу")
            XCTAssertTrue(rows.contains { $0.hasSuffix("6. Chat about this") }, name)
            // Курсор в кадре, если он есть на экране панели.
            XCTAssertEqual(selected(rows), selected(region.rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }), name)
        }
        let sel3 = try XCTUnwrap(LiveInput.region(screen("longform-tall-sel3")))
        let shown = LiveInput.fit(sel3.rows, limit: 18).rows.map(\.plain).joined(separator: "\n")
        XCTAssertTrue(shown.contains("❯ 3. Blue green"))
        XCTAssertTrue(shown.contains("ещё"), "над и под окном — сколько строк скрыто")
        // Строки подписей не принадлежат части; строки формы ведут к своим строкам части (курсор встаёт на место).
        let f = LiveInput.fit(sel3.rows, limit: 18)
        for (i, src) in f.source.enumerated() {
            if let src { XCTAssertEqual(f.rows[i], sel3.rows[src]) } else { XCTAssertTrue(f.rows[i].plain.contains("ещё")) }
        }
    }

    func testFitLeavesAShortRegionAlone() throws {
        let r = try XCTUnwrap(LiveInput.region(screen("ask")))
        let fit = LiveInput.fit(r.rows, limit: 40)
        XCTAssertEqual(fit.rows, r.rows)
        XCTAssertEqual(fit.source, Array(r.rows.indices))
    }

    func testFitPinsHintWhenTallPaneHasBlankRowsAndSessionRuleBelow() throws {
        // Высокая панель: под подсказкой пустые строки и рамка с именем сессии, как в живом менеджере.
        let raw = String(decoding: try fixture("live-longform-tall-sel1.txt"), as: UTF8.self)
            + "\n\n\n\n\n" + String(repeating: "─", count: 39) + " Менеджер ─"
        let region = try XCTUnwrap(LiveInput.region(SGRParser.parse(raw)))
        XCTAssertTrue(region.rows.last?.plain.contains("Esc to cancel") ?? false)
        let rows = LiveInput.fit(region.rows, limit: 20).rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(rows.last?.contains("Esc to cancel") ?? false, "\(rows)")
        XCTAssertTrue(rows.contains("6. Chat about this"))
        XCTAssertTrue(rows.contains { $0.hasPrefix("❯ 1. Big bang") })
        XCTAssertFalse(rows.contains { $0.contains("Менеджер") })
    }
}
