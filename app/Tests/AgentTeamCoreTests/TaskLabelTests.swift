import Foundation
import XCTest
@testable import AgentTeamCore

final class TaskLabelTests: XCTestCase {
    private func agent(_ extra: String) throws -> Agent {
        try JSONDecoder().decode(Agent.self, from: Data(#"{"name":"dev#1","role":"dev","n":1\#(extra)}"#.utf8))
    }

    func testAgentWithTitleOnlyNumberAndNull() throws {
        let full = TaskLabel(agent: try agent(#","task":"TASK-510","task_title":"Названия задач","task_ts":1792235381"#))
        XCTAssertEqual(full.text, "Названия задач")
        XCTAssertEqual(full.number, "TASK-510")
        XCTAssertEqual(full.ts, 1792235381)

        let numberOnly = TaskLabel(agent: try agent(#","task":"TASK-510","task_title":null,"task_ts":null"#))
        XCTAssertEqual(numberOnly.text, "TASK-510")          // старое событие: только номер

        let none = TaskLabel(agent: try agent(#","task":null,"task_title":null,"task_ts":null"#))
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.text)

        let old = TaskLabel(agent: try agent(""))          // старый team без новых ключей
        XCTAssertTrue(old.isEmpty)
    }

    func testBadTypesDoNotBreakAgent() throws {
        let a = try agent(#","task_title":5,"task_ts":"x""#)
        XCTAssertNil(a.taskTitle)
        XCTAssertNil(a.taskTS)
    }

    func testEmptyTitleFallsBackToNumber() {
        XCTAssertEqual(TaskLabel(number: "TASK-1", title: "  ").text, "TASK-1")
    }

    func testTooltipHasTitleNumberAndTime() {
        let t = TaskLabel(number: "TASK-510", title: "Длинное название задачи", ts: 1792235381).tooltip(timeZone: TimeZone(identifier: "UTC")!)
        let lines = t.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "Длинное название задачи")
        XCTAssertEqual(lines[1], "Задача TASK-510")
        XCTAssertTrue(lines[2].hasPrefix("Установлена "))
        XCTAssertEqual(TaskLabel(number: "TASK-1").tooltip(), "Задача TASK-1")
    }

    func testEventTitleAndFromEvents() throws {
        let json = #"[{"ts":30,"type":"report","agent":"dev#1","text":"готово","task":"TASK-1"},{"ts":20,"type":"task","agent":"dev#1","text":"Название","task":"TASK-1","title":"Название"},{"ts":10,"type":"task","agent":"dev#1","text":"Старое","task":"TASK-0","title":null}]"#
        let events = try JSONDecoder().decode([TeamEvent].self, from: Data(json.utf8))
        XCTAssertEqual(events[1].title, "Название")
        let l = try XCTUnwrap(TaskLabel.fromEvents(events, agent: "dev#1"))
        XCTAssertEqual(l.number, "TASK-1")
        XCTAssertEqual(l.title, "Название")        // название берётся из события task, а не из позднего report
        XCTAssertEqual(l.ts, 20)
        XCTAssertNil(TaskLabel.fromEvents(events, agent: "other#1"))
    }

    func testTaskRemovedEventClearsLabel() throws {
        let json = #"[{"ts":30,"type":"task","agent":"dev#1","text":"","task":null,"title":null},{"ts":20,"type":"task","agent":"dev#1","text":"Х","task":"TASK-1","title":"Х"}]"#
        let events = try JSONDecoder().decode([TeamEvent].self, from: Data(json.utf8))
        XCTAssertNil(TaskLabel.fromEvents(events, agent: "dev#1"))
    }

    func testJournalTitleIsPerAgentForSharedNumber() throws {
        let json = #"[{"ts":30,"type":"report","agent":"b#1","text":"ок","task":"TASK-510"},{"ts":20,"type":"task","agent":"b#1","text":"Часть B","task":"TASK-510","title":"Часть B"},{"ts":10,"type":"task","agent":"a#1","text":"Часть A","task":"TASK-510","title":"Часть A"}]"#
        let events = try JSONDecoder().decode([TeamEvent].self, from: Data(json.utf8))
        XCTAssertEqual(TaskLabel.eventTitle(events[0], in: events), "Часть B")   // отчёт B берёт название B, а не A
        XCTAssertEqual(TaskLabel.eventTitle(events[2], in: events), "Часть A")
        let noTask = TeamEvent(ts: 1, type: "report", agent: "b#1", text: "x")
        XCTAssertNil(TaskLabel.eventTitle(noTask, in: events))
    }
}
