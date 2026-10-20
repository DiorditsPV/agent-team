import XCTest
@testable import AgentTeamCore

/// Время агента — формулировки и источник (транскрипт, а не шум панели).
final class AgentTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSpan() {
        XCTAssertEqual(AgentTime.span(20), "<1 мин")
        XCTAssertEqual(AgentTime.span(7 * 60), "7 мин")
        XCTAssertEqual(AgentTime.span(3 * 3600 + 10 * 60), "3 ч 10 мин")
        XCTAssertEqual(AgentTime.span(3 * 3600), "3 ч")
        XCTAssertEqual(AgentTime.span(51 * 3600), "2 дн 3 ч")
    }

    func testLabels() {
        let turn = AgentActivity(lastAction: now - 5, inTurn: true, turnStart: now - 130)
        XCTAssertEqual(AgentTime.label(.working, activity: turn, now: now), "работает · 2 мин")
        let idle = AgentActivity(lastAction: now - (3 * 3600 + 10 * 60), inTurn: false)
        XCTAssertEqual(AgentTime.label(.quiet(minutes: 190), activity: idle, now: now), "простаивает · 3 ч 10 мин",
                       "потолка в 10 минут нет")
        let wait = AgentActivity(lastAction: now - 300, inTurn: true)
        XCTAssertEqual(AgentTime.label(.waiting("ждёт ответа"), activity: wait, now: now), "ждёт ответа · 5 мин")
        XCTAssertEqual(AgentTime.label(.working, activity: nil, now: now), "работает")
        XCTAssertEqual(AgentTime.label(.noData, activity: nil, now: now), "нет данных")
        XCTAssertEqual(AgentTime.label(.stopped, activity: nil, now: now), "остановлен")
    }

    func testSessionLabelAndTooltip() {
        let started = Int(now.timeIntervalSince1970) - (7 * 3600 + 6 * 60)
        XCTAssertEqual(AgentTime.session(started: started, now: now), "сессия 7 ч")
        XCTAssertEqual(AgentTime.session(started: Int(now.timeIntervalSince1970) - 25 * 60, now: now), "сессия 25 мин")
        let act = AgentActivity(lastAction: now - 600, inTurn: true, turnStart: now - 120)
        let tip = AgentTime.tooltip(started: started, activity: act, now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(tip.contains("сессия 7 ч 6 мин"), tip)
        XCTAssertTrue(tip.contains("Последнее действие") && tip.contains("10 мин назад"), tip)
        XCTAssertTrue(tip.contains("Текущий ход: 2 мин"), tip)
    }

    /// Источник — запись транскрипта: перерисовка панели вывода не сбрасывает простой.
    @MainActor
    func testStateUsesTranscriptNotPaneNoise() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-time", session: "team-time", cli: nil)
        let a = Agent(name: "developer#1", role: "developer", alive: true, idleS: 5)
        let idle = AgentActivity(lastAction: now - 3 * 3600, inTurn: false)
        // Панель шумит, а `idle_s` из status мал, но последняя запись транскрипта — три часа назад.
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: idle, now: now), .quiet(minutes: 180))
        // Долгий инструмент: ход идёт, записей нет несколько минут — не простой.
        let longTool = AgentActivity(lastAction: now - 600, inTurn: true, turnStart: now - 900)
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: longTool, now: now), .working)
        // Без транскрипта «простаивает» и «работает» утверждать не на чем.
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: nil, now: now), .noData)
    }

    func testReadsTranscriptTail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("s.jsonl")
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-10-17T10:00:00.000Z","message":{"role":"user","content":"раньше"}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":1000,"uuid":"e1","timestamp":"2026-10-17T10:01:00.000Z"}"#,
            #"{"type":"user","uuid":"u2","timestamp":"2026-10-17T11:00:00.000Z","message":{"role":"user","content":"сделай"}}"#,
            #"{"type":"user","uuid":"r1","timestamp":"2026-10-17T11:05:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(AgentActivity.read(url: url))
        XCTAssertTrue(a.inTurn)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(a.turnStart, iso.date(from: "2026-10-17T11:00:00.000Z"), "ход начался с последнего сообщения")
        XCTAssertEqual(a.lastAction, iso.date(from: "2026-10-17T11:05:00.000Z"), "последняя запись — результат инструмента")
    }

    /// Сообщение другой сессии — служебная запись (isMeta), но ход начинает оно; прочие служебные внутри хода — нет.
    func testTurnStartsFromCrossSessionMessage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agtime-" + UUID().uuidString + ".jsonl")
        let lines = [
            #"{"type":"system","subtype":"turn_duration","durationMs":1,"uuid":"e","timestamp":"2026-10-17T10:00:00.000Z"}"#,
            #"{"type":"user","isMeta":true,"uuid":"m","timestamp":"2026-10-17T11:00:00.000Z","message":{"role":"user","content":"Another Claude session sent a message:\n<cross-session-message from=\"x\">привет</cross-session-message>"}}"#,
            #"{"type":"user","isMeta":true,"uuid":"r","timestamp":"2026-10-17T11:03:00.000Z","message":{"role":"user","content":"<system-reminder>напоминание</system-reminder>"}}"#,
            #"{"type":"assistant","uuid":"a","timestamp":"2026-10-17T11:04:00.000Z","message":{"id":"i","role":"assistant","content":[{"type":"text","text":"ок"}]}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(AgentActivity.read(url: url))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertTrue(a.inTurn)
        XCTAssertEqual(a.turnStart, iso.date(from: "2026-10-17T11:00:00.000Z"))
    }

    /// Ход закончился записью turn_duration: хода нет, простой считается от последней записи.
    func testFinishedTurnHasNoStart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agtime-" + UUID().uuidString + ".jsonl")
        let lines = [
            #"{"type":"user","uuid":"u","timestamp":"2026-10-17T11:00:00.000Z","message":{"role":"user","content":"сделай"}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":1,"uuid":"e","timestamp":"2026-10-17T11:02:00.000Z"}"#,
        ]
        try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        let a = try XCTUnwrap(AgentActivity.read(url: url))
        XCTAssertFalse(a.inTurn)
        XCTAssertNil(a.turnStart)
    }
}
