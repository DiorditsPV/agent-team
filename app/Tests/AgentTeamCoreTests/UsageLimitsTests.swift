import XCTest
@testable import AgentTeamCore

/// Лимиты подписки Claude в боковой панели. Форматы — как у claude 2.1.292: JSON строки состояния
/// (`rate_limits.five_hour|seven_day` с `used_percentage` и `resets_at` в unix-секундах) и кеш `/usage` в `~/.claude.json`
/// (`cachedUsageUtilization`, `resets_at` в ISO 8601 с микросекундами, `fetchedAtMs`).
final class UsageLimitsTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    // 2026-10-19 15:00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_792_422_000)

    private func statusJSON(five: Double = 61.6, fiveReset: Int = 1_792_435_200, week: Double = 41, weekReset: Int = 1_792_850_000,
                            available: Bool = true) -> Data {
        let s = """
        {"session_id":"S1","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"rate_limits_available":\(available),
         "rate_limits":{"five_hour":{"used_percentage":\(five),"resets_at":\(fiveReset)},
                        "seven_day":{"used_percentage":\(week),"resets_at":\(weekReset)}}}
        """
        return Data(s.utf8)
    }

    private let cacheJSON = Data("""
    {"numStartups":12,"cachedUsageUtilization":{"fetchedAtMs":1792355808804,"accountUuid":"00000000-0000-0000-0000-000000000000",
     "utilization":{"five_hour":{"utilization":2,"resets_at":"2026-10-19T01:19:59.602755+00:00","limit_dollars":null},
                    "seven_day":{"utilization":94,"resets_at":"2026-10-19T13:59:59.602777+00:00","limit_dollars":null},
                    "seven_day_opus":null,"extra_usage":{"is_enabled":false}}}}
    """.utf8)

    func testStatusLineJSON() throws {
        let l = try XCTUnwrap(UsageLimits.statusLine(statusJSON(), observedAt: now))
        XCTAssertEqual(l.fiveHour, .init(percent: 62, resetsAt: Date(timeIntervalSince1970: 1_792_435_200)))
        XCTAssertEqual(l.sevenDay?.percent, 41)
        XCTAssertEqual(l.source, .statusLine)
        XCTAssertEqual(l.lines(now: now, calendar: utc).map(\.text), ["5 ч: 62 % · сброс 18:40", "неделя: 41 %"])
        XCTAssertNil(UsageLimits.statusLine(Data(#"{"rate_limits":null}"#.utf8), observedAt: now), "ответа API ещё не было")
        XCTAssertNil(UsageLimits.statusLine(Data("не JSON".utf8), observedAt: now))
    }

    /// Ключ API, Bedrock, Vertex: лимитов подписки нет — строки нет.
    func testUnavailableHidesLines() throws {
        let l = try XCTUnwrap(UsageLimits.statusLine(Data(#"{"rate_limits_available":false,"rate_limits":null}"#.utf8), observedAt: now))
        XCTAssertFalse(l.available)
        XCTAssertEqual(l.lines(now: now), [])
    }

    func testWarningFrom80AndResetPassed() throws {
        let l = try XCTUnwrap(UsageLimits.statusLine(statusJSON(five: 80, week: 79.4), observedAt: now))
        XCTAssertEqual(l.lines(now: now, calendar: utc).map(\.warning), [true, false])
        let past = try XCTUnwrap(UsageLimits.statusLine(statusJSON(five: 95, fiveReset: 1_792_421_000), observedAt: now))
        XCTAssertEqual(past.lines(now: now, calendar: utc).first, .init(text: "5 ч: окно сброшено", warning: false),
                       "числа относятся к прошлому окну")
    }

    func testUsageCache() throws {
        let l = try XCTUnwrap(UsageLimits.usageCache(cacheJSON))
        XCTAssertEqual(l.source, .usageCache)
        XCTAssertEqual(l.observedAt.timeIntervalSince1970, 1_792_355_808.804, accuracy: 0.001)
        XCTAssertEqual(l.fiveHour?.percent, 2)
        XCTAssertEqual(try XCTUnwrap(l.sevenDay?.resetsAt).timeIntervalSince1970, 1_792_418_399.602, accuracy: 0.01)
        XCTAssertEqual(l.lines(now: now, calendar: utc).map(\.text), ["5 ч: окно сброшено", "неделя: окно сброшено"])
        XCTAssertEqual(l.details(now: now, calendar: utc),
                       "Текущее окно (5 ч): 2 % · сброшено сегодня 01:19\nНеделя: 94 % · сброшено сегодня 13:59\nпо кешу /usage Claude Code, 18 ч назад")
        XCTAssertNil(UsageLimits.usageCache(Data(#"{"numStartups":1}"#.utf8)))
    }

    /// Берётся самое свежее: файл строки состояния (по времени записи) или кеш `/usage` (по `fetchedAtMs`).
    func testLoadPicksFreshest() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("limits-\(UUID().uuidString)")
        let fm = FileManager.default
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b"), home = root.appendingPathComponent("home")
        for d in [a, b] { try fm.createDirectory(at: d.appendingPathComponent(".team"), withIntermediateDirectories: true) }
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let fa = a.appendingPathComponent(".team/statusline.json"), fb = b.appendingPathComponent(".team/statusline.json")
        try statusJSON(five: 10).write(to: fa)
        try statusJSON(five: 20).write(to: fb)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_792_400_000)], ofItemAtPath: fa.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_792_410_000)], ofItemAtPath: fb.path)
        try cacheJSON.write(to: home.appendingPathComponent(".claude.json"))
        let l = try XCTUnwrap(UsageLimits.load(repos: [a.path, b.path, root.appendingPathComponent("нет").path], home: home.path))
        XCTAssertEqual(l.fiveHour?.percent, 20)
        XCTAssertEqual(l.source, .statusLine)
        try fm.removeItem(at: fa); try fm.removeItem(at: fb)
        XCTAssertEqual(UsageLimits.load(repos: [a.path, b.path], home: home.path)?.source, .usageCache, "запасной источник")
        try fm.removeItem(at: home.appendingPathComponent(".claude.json"))
        XCTAssertNil(UsageLimits.load(repos: [a.path], home: home.path))
    }

    func testDetailsFromStatusLine() throws {
        let l = try XCTUnwrap(UsageLimits.statusLine(statusJSON(), observedAt: now.addingTimeInterval(-180)))
        XCTAssertEqual(l.details(now: now, calendar: utc),
                       "Текущее окно (5 ч): 62 % · сброс сегодня 18:40\nНеделя: 41 % · сброс 24 октября 13:53\nпо строке состояния роли, 3 мин назад")
    }
}
