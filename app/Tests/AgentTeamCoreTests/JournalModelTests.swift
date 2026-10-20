import Foundation
import XCTest
@testable import AgentTeamCore

final class JournalModelTests: XCTestCase {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Moscow")!
        return c
    }

    /// 2026-10-16 19:58 МСК.
    var now: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 19, minute: 58))! }

    func ts(_ day: Int, _ h: Int, _ m: Int, month: Int = 10, year: Int = 2026) -> Int {
        Int(cal.date(from: DateComponents(year: year, month: month, day: day, hour: h, minute: m))!.timeIntervalSince1970)
    }

    var events: [TeamEvent] {
        [
            TeamEvent(ts: ts(16, 19, 58), type: "owner", agent: "owner", text: "Сколько ещё до выпуска?"),
            TeamEvent(ts: ts(16, 19, 54), type: "waiting", agent: "tester#1", text: "Ждёт ответа: доверяете ли вы папке", task: "TASK-435"),
            TeamEvent(ts: ts(16, 19, 40), type: "commit", agent: "engine#1", text: "291ec40 · память долгот", task: "TASK-453"),
            TeamEvent(ts: ts(16, 0, 10), type: "restart", agent: "engine#1", text: "продолжена прежняя сессия"),
            TeamEvent(ts: ts(15, 23, 40), type: "spawn", agent: "support#1", text: "новая сессия"),
            TeamEvent(ts: ts(10, 12, 0), type: "task", agent: "manager#1", text: "→ engine #1: вход device", task: "TASK-453"),
            TeamEvent(ts: ts(30, 9, 0, month: 12, year: 2025), type: "down", agent: "support#1", text: "остановлена"),
        ]
    }

    func testKindGroupsLifecycle() {
        XCTAssert(JournalKind(type: "spawn") == .life)
        XCTAssert(JournalKind(type: "restart") == .life)
        XCTAssert(JournalKind(type: "down") == .life)
        XCTAssert(JournalKind(type: "что-то") == .other)
        XCTAssert(JournalKind.rowLabel(type: "restart") == "Перезапуск")
        XCTAssert(JournalKind.rowLabel(type: "waiting") == "Ждёт вас")
    }

    func testFilterByKindAgentQueryPeriod() {
        XCTAssert(JournalFilter().apply(events, now: now, calendar: cal).count == events.count)
        XCTAssert(JournalFilter(kinds: [.life]).apply(events, now: now, calendar: cal).map(\.type) == ["restart", "spawn", "down"])
        XCTAssert(JournalFilter(agent: "engine#1").apply(events, now: now, calendar: cal).count == 2)
        // Поиск по задаче, по хешу коммита и без учёта регистра.
        XCTAssert(JournalFilter(query: "task-453").apply(events, now: now, calendar: cal).count == 2)
        XCTAssert(JournalFilter(query: "291ec40").apply(events, now: now, calendar: cal).map(\.type) == ["commit"])
        // «Сегодня» — с полуночи, «7 дней» — шесть прошлых дней и сегодня.
        XCTAssert(JournalFilter(period: .today).apply(events, now: now, calendar: cal).count == 4)
        XCTAssert(JournalFilter(period: .week).apply(events, now: now, calendar: cal).count == 6)
        XCTAssert(JournalFilter(kinds: [.task, .commit], period: .today).apply(events, now: now, calendar: cal).map(\.type) == ["commit"])
        XCTAssert(JournalFilter(period: .today).isDefault == false)
        XCTAssert(JournalFilter(query: "  ").isDefault)
    }

    func testGroupByDay() {
        let days = JournalDay.group(events, now: now, calendar: cal)
        XCTAssert(days.map(\.title) == ["Сегодня, 16 октября", "Вчера, 15 октября", "10 октября", "30 декабря 2025"])
        XCTAssert(days.map(\.events.count) == [4, 1, 1, 1])
        XCTAssert(JournalDay.group([], now: now, calendar: cal).isEmpty)
    }

    func testShortTime() {
        XCTAssert(ShortTime.label(ts(16, 19, 50), now: now, calendar: cal) == "19:50")
        XCTAssert(ShortTime.label(ts(15, 23, 40), now: now, calendar: cal) == "вчера, 23:40")
        XCTAssert(ShortTime.label(ts(10, 9, 5), now: now, calendar: cal) == "10 окт, 09:05")
        XCTAssert(ShortTime.ago(now.addingTimeInterval(-30), now: now) == "только что")
        XCTAssert(ShortTime.ago(now.addingTimeInterval(-125), now: now) == "2 мин назад")
    }
}
