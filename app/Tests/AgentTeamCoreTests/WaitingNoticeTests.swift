import XCTest
@testable import AgentTeamCore

/// Уведомление «менеджер ждёт ответа» и вопрос AskUserQuestion в ленте. Образцы экранов — с живого claude 2.1.295, пути обезличены.
final class WaitingNoticeTests: XCTestCase {
    private func fixture(_ name: String) throws -> [StyledLine] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return SGRParser.parse(try String(contentsOf: url, encoding: .utf8))
    }

    private let rule = String(repeating: "─", count: 40)

    func testPermissionDialogShowsQuestionAndCommand() throws {
        let n = try XCTUnwrap(WaitingNotice.from(lines: try fixture("live-perm.txt"), asksTrust: false, asksPermission: true))
        XCTAssertEqual(n.kind, .permission)
        XCTAssertEqual(n.text, "Менеджер ждёт ответа: Do you want to proceed? · touch marker.txt && ls -l marker.txt")
    }

    func testAskFormShowsQuestionAndOptions() throws {
        let screen = "⏺ Спрашиваю\n\(rule)\n ☐ Color\n\nWhich color?\n❯ 1. Red\n  2. Blue\n  3. Green\nEnter to select · ↑/↓ to navigate · Esc to cancel"
        let n = try XCTUnwrap(WaitingNotice.from(lines: SGRParser.parse(screen), asksTrust: false, asksPermission: true))
        XCTAssertEqual(n.kind, .ask)
        XCTAssertEqual(n.text, "Менеджер ждёт ответа: Which color? (Red / Blue / Green)")
    }

    func testTrustQuestion() {
        let screen = " Do you trust the files in this folder?\n ❯ 1. Yes, I trust this folder\n   2. No, exit\n Esc to cancel"
        XCTAssertEqual(WaitingNotice.from(lines: SGRParser.parse(screen), asksTrust: false, asksPermission: false)?.kind, .trust)
        XCTAssertEqual(WaitingNotice.from(lines: [], asksTrust: true, asksPermission: false)?.kind, .trust)
    }

    /// Без экрана (панель не стримится) — общий текст по признаку хаба; обычный экран и закрытый диалог уведомления не дают.
    func testGenericAndClosed() throws {
        XCTAssertEqual(WaitingNotice.from(lines: [], asksTrust: false, asksPermission: true)?.text, "Менеджер ждёт ответа: вопрос о праве вне allow")
        XCTAssertNil(WaitingNotice.from(lines: try fixture("live-typed.txt"), asksTrust: false, asksPermission: false))
        XCTAssertNil(WaitingNotice.from(lines: SGRParser.parse("⏺ Готово.\n\(rule)\n❯ \n\(rule)"), asksTrust: false, asksPermission: false), "диалог закрыт — уведомление снято")
    }

    func testEditDialogUsesFirstDetailLine() throws {
        let dashes = String(repeating: "╌", count: 40)
        let screen = "\(rule)\n Edit file\n src/dates.py\n\(dashes)\n 1 - old\n 1 + new\n\(dashes)\n Do you want to make this edit to dates.py?\n ❯ 1. Yes\n   2. No\n Esc to cancel"
        let n = try XCTUnwrap(WaitingNotice.from(lines: SGRParser.parse(screen), asksTrust: false, asksPermission: true))
        XCTAssertTrue(n.text.hasPrefix("Менеджер ждёт ответа: Do you want to make this edit to dates.py? · src/dates.py"), n.text)
    }

    /// AskUserQuestion в транскрипте: вопросы и варианты текстом.
    func testAskUserQuestionIsDescribedInFeed() throws {
        var p = TranscriptParser()
        let line = #"{"type":"assistant","uuid":"a1","message":{"id":"m1","model":"x","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[{"question":"Какую лицензию поставить?","header":"Лицензия","multiSelect":false,"options":[{"label":"MIT","description":"короткая"},{"label":"Apache-2.0","description":"с патентами"}]},{"question":"Убрать почту из истории?","options":[{"label":"Да"},{"label":"Нет"}]}]}}]}}"#
        p.feed(lines: [Substring(line)])
        let e = try XCTUnwrap(p.entries.last)
        XCTAssertEqual(e.kind, .tool(name: "AskUserQuestion", summary: "Какую лицензию поставить? — MIT / Apache-2.0\nУбрать почту из истории? — Да / Нет"))
    }
}

/// Диалог на экране панели не принимается за ответ менеджера, который тот пишет.
final class LiveReplyDialogTests: XCTestCase {
    func testAskFormAndPermissionAreNotDraftText() throws {
        let rule = String(repeating: "─", count: 40)
        let form = "⏺ Спрашиваю про лицензию\n\(rule)\n ☐ Лицензия\n\nКакую лицензию поставить?\n❯ 1. MIT\n  2. Apache-2.0\nEnter to select · ↑/↓ to navigate · Esc to cancel"
        XCTAssertNil(LiveReply.extract(SGRParser.parse(form)))
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/live-perm.txt")
        XCTAssertNil(LiveReply.extract(SGRParser.parse(try String(contentsOf: url, encoding: .utf8))))
    }
}
