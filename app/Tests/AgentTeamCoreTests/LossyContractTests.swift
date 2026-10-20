import XCTest
@testable import AgentTeamCore

/// CLI отдаёт поля front matter передач и ролей как есть, и значение YAML не того вида (`task: 554` без кавычек —
/// число) не должно обнулять весь список.
final class LossyContractTests: XCTestCase {
    func testHandoffWithNumericTaskAndBadItemKeepsList() throws {
        let json = #"""
        [
          {"id": "1-developer#1", "agent": "developer#1", "ts": 1792178000, "task": 554, "reason": null, "status": "waiting",
           "branch": true, "worktree": null, "sections": {"done": "Сделано", "next": 3}},
          {"agent": "writer#1", "ts": 1, "status": "used"},
          {"id": "2-writer#1", "agent": "writer#1", "ts": "1792179000", "task": "TASK-1", "status": "used", "sections": "не объект",
           "used_at": 1792179100.5}
        ]
        """#
        let list = try JSONDecoder().decode(LossyList<Handoff>.self, from: Data(json.utf8))
        XCTAssertEqual(list.items.map(\.id), ["1-developer#1", "2-writer#1"])
        XCTAssertEqual(list.skipped, 1, "передача без id пропущена, остальные на месте")
        let h = list.items[0]
        XCTAssertEqual(h.task, "554")
        XCTAssertEqual(h.branch, "true")
        XCTAssertNil(h.reason)
        XCTAssertEqual(h.sections.done, "Сделано")
        XCTAssertEqual(h.sections.next, "3")
        XCTAssertTrue(h.isWaiting)
        let w = list.items[1]
        XCTAssertEqual(w.ts, 1792179000)
        XCTAssertEqual(w.sections, Handoff.Sections())
        XCTAssertEqual(w.usedAt, 1792179100)
    }

    func testExistingHandoffsFixtureStillReads() throws {
        let list = try JSONDecoder().decode(LossyList<Handoff>.self, from: fixture("handoffs.json"))
        let strict = try JSONDecoder().decode([Handoff].self, from: fixture("handoffs.json"))
        XCTAssertEqual(list.items, strict)
        XCTAssertEqual(list.skipped, 0)
    }

    func testRoleWithNonStringFieldsKeepsList() throws {
        let json = #"""
        [
          {"role": "developer", "title": 42, "model": "sonnet", "extends": false, "tracker_zone": 7, "running": "2",
           "worktree": {"dir": "developer", "branch": 1, "repo": null}, "zone": ["app/"]},
          {"title": "без имени"},
          {"role": "reviewer", "worktree": "не объект", "zone": "app/"}
        ]
        """#
        let list = try JSONDecoder().decode(LossyList<RoleInfo>.self, from: Data(json.utf8))
        XCTAssertEqual(list.items.map(\.role), ["developer", "reviewer"])
        XCTAssertEqual(list.skipped, 1)
        let d = list.items[0]
        XCTAssertEqual(d.title, "42")
        XCTAssertEqual(d.extends, "false")
        XCTAssertEqual(d.trackerZone, "7")
        XCTAssertEqual(d.running, 2)
        XCTAssertEqual(d.worktree, RoleInfo.Worktree(dir: "developer", branch: "1", repo: nil))
        XCTAssertEqual(d.zone, ["app/"])
        XCTAssertNil(list.items[1].worktree)
        XCTAssertEqual(list.items[1].zone, [])
    }

    func testRolesFixtureStillReads() throws {
        let list = try JSONDecoder().decode(LossyList<RoleInfo>.self, from: fixture("roles.json"))
        XCTAssertEqual(list.items, try JSONDecoder().decode([RoleInfo].self, from: fixture("roles.json")))
        XCTAssertEqual(list.skipped, 0)
    }
}
