import XCTest
@testable import AgentTeamCore

/// Сообщения команды в выводе агента: распознавание, подписи по составу, выделение и дайджест. Образцы обезличены.
final class TeamMessagesTests: XCTestCase {
    private func line(_ text: String) -> StyledLine { StyledLine(runs: [StyledRun(text: text, style: TermStyle())]) }

    private let roster = TeamRoster([
        .init(name: "boss#1", role: "boss", title: "Менеджер", address: "uds:/tmp/cc-socks/11.sock", color: .rgb(200, 241, 105)),
        .init(name: "shop-dev#1", role: "shop-dev", title: "Разработчик магазина", address: "uds:/tmp/cc-socks/22.sock", color: .rgb(159, 180, 245)),
    ])

    func testParseIncoming() {
        XCTAssertEqual(TeamMessages.parse("› Message from @Менеджер: Менеджер: TASK-7 — собрать отчёт (ctrl+o to expand)"),
                       .incoming(from: "Менеджер", text: "Менеджер: TASK-7 — собрать отчёт"))
        XCTAssertEqual(TeamMessages.parse("  › Message from @Разработчик-магази…: готово"),
                       .incoming(from: "Разработчик-магази…", text: "готово"))
        XCTAssertNil(TeamMessages.parse("Message from @кто-то: без маркера строки"))
        XCTAssertNil(TeamMessages.parse("❯ Message from @x: ввод владельца"))
    }

    func testParseOutgoing() {
        XCTAssertEqual(TeamMessages.parse("  ⎿  “TASK-7: отчёт готов” → uds:/tmp/cc-socks/22.sock"),
                       .outgoing(to: "uds:/tmp/cc-socks/22.sock", summary: "TASK-7: отчёт готов"))
        XCTAssertNil(TeamMessages.parse("  ⎿  Allowed by auto mode classifier"))
        XCTAssertNil(TeamMessages.parse("  ⎿  $ echo “a” → b c"))
    }

    func testRosterMatchesTruncatedTitleAndAddress() {
        XCTAssertEqual(roster.entry(displayName: "Разработчик-магази…")?.name, "shop-dev#1")
        XCTAssertEqual(roster.entry(displayName: "менеджер")?.name, "boss#1")
        XCTAssertEqual(roster.entry(displayName: "shop dev")?.name, "shop-dev#1")
        XCTAssertNil(roster.entry(displayName: "Кто-то ещё"))
        XCTAssertEqual(roster.entry(address: "uds:/tmp/cc-socks/11.sock")?.name, "boss#1")
    }

    func testDecorateStripeNameAndTint() {
        let d = TeamMessages.decorate(line("› Message from @Менеджер: Менеджер: TASK-7 (ctrl+o to expand)"), roster: roster)
        XCTAssertEqual(d.plain, "▌ ← boss#1  Менеджер: TASK-7")
        XCTAssertEqual(d.runs[0].style.fg, .rgb(200, 241, 105))                       // полоса цвета роли
        XCTAssertTrue(d.runs[2].style.bold)                                           // имя жирным
        XCTAssertEqual(d.runs[2].text, "boss#1")
        XCTAssertTrue(d.runs[3].style.soft)                                           // бледная подложка…
        XCTAssertEqual(d.runs[3].style.bg, .rgb(200, 241, 105))
        XCTAssertNil(d.runs[3].style.fg, "…а текст остаётся цветом темы")
        let out = TeamMessages.decorate(line("  ⎿  “готово” → uds:/tmp/cc-socks/22.sock"), roster: roster)
        XCTAssertEqual(out.plain, "▌ → shop-dev#1  готово")
        let unknown = TeamMessages.decorate(line("  ⎿  “привет” → uds:/tmp/cc-socks/99.sock"), roster: roster)
        XCTAssertEqual(unknown.plain, "▌ → 99  привет")
        XCTAssertEqual(TeamMessages.decorate(line("обычная строка"), roster: roster).plain, "обычная строка")
    }

    /// Свежее последнего текста агента сообщение — одной строкой под заголовком; старше текста — остаётся в тексте.
    func testDigestShowsFreshMessage() {
        let fresh = [
            line("⏺ Собираю отчёт по задаче."),
            line("  Осталось проверить таблицу."),
            line("› Message from @Менеджер: Менеджер: срочно, TASK-8 (ctrl+o to expand)"),
            line("✻ Работаю… (12s · ↓ 1.0k tokens)"),
        ]
        let d = PaneDigest.make(fresh, roster: roster)
        XCTAssertEqual(d.message?.plain, "▌ ← boss#1  Менеджер: срочно, TASK-8")
        XCTAssertEqual(d.body.map(\.plain), ["Собираю отчёт по задаче.", "Осталось проверить таблицу."])
        XCTAssertEqual(d.rows.count, 4)

        let stale = [
            line("› Message from @Менеджер: Менеджер: TASK-8 (ctrl+o to expand)"),
            line("⏺ Принято, делаю."),
            line("  Начинаю с отчёта."),
        ]
        let s = PaneDigest.make(stale, roster: roster)
        XCTAssertNil(s.message)
        XCTAssertEqual(s.body.map(\.plain), ["Принято, делаю.", "Начинаю с отчёта."])
    }

    func testDigestMessageTakesOneBodyRow() {
        let lines = (1...7).map { line($0 == 1 ? "⏺ строка \($0)" : "  строка \($0)") }
            + [line("  ⎿  “итог” → uds:/tmp/cc-socks/11.sock")]
        let d = PaneDigest.make(lines, bodyLines: 5, roster: roster)
        XCTAssertEqual(d.message?.plain, "▌ → boss#1  итог")
        XCTAssertEqual(d.body.count, 4)
        XCTAssertEqual(d.rows.count, 5)
    }
}
