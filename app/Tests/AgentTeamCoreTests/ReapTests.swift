import Foundation
import XCTest
@testable import AgentTeamCore

/// Автоостановка: сборка `team reap`, разбор его JSON и ключ idle_stop_minutes из team.yaml.
final class ReapTests: XCTestCase {
    func testArgumentsWithoutKeep() {
        XCTAssertEqual(Reap.arguments(keep: []), ["reap", "--json"])
    }

    func testArgumentsPassKeepAfterFlag() {
        XCTAssertEqual(Reap.arguments(keep: ["manager", "developer#2"]), ["reap", "--json", "--keep", "manager", "developer#2"])
    }

    func testKeepNamesOnlyWithUnsentState() {
        XCTAssertEqual(Reap.keepNames(manager: "manager", hasQueue: false, hasDraft: false), [])
        XCTAssertEqual(Reap.keepNames(manager: "manager", hasQueue: true, hasDraft: false), ["manager"])
        XCTAssertEqual(Reap.keepNames(manager: "manager", hasQueue: false, hasDraft: true), ["manager"])
        XCTAssertEqual(Reap.keepNames(manager: nil, hasQueue: true, hasDraft: true), [])
    }

    func testDecodesReapJSON() throws {
        let json = """
        [{"name":"developer#2","idle_s":780,"action":"stopped","reason":"простой 13 мин"},
         {"name":"tester#1","idle_s":null,"action":"kept","reason":"нет данных о простое"},
         {"name":"reviewer#1","idle_s":900,"action":"would_stop","reason":"простой 15 мин"},
         {"reason":"без имени пропускается"}]
        """
        let items = try JSONDecoder().decode(LossyList<ReapEntry>.self, from: Data(json.utf8)).items
        XCTAssertEqual(items.map(\.name), ["developer#2", "tester#1", "reviewer#1"])
        XCTAssertEqual(items.filter(\.stopped).map(\.name), ["developer#2"])
        XCTAssertNil(items[1].idleSeconds)
        XCTAssertEqual(Reap.journalLine(items[0]), "developer#2 остановлен: простой 13 мин")
    }

    func testIdleStopMinutesFromYAML() {
        XCTAssertEqual(TeamYAMLSummary.parse("project: x\nidle_stop_minutes: 10\nlayout: panes\n").idleStopMinutes, 10)
        XCTAssertEqual(TeamYAMLSummary.parse("project: x\nidle_stop_minutes: 10\n").idleStop, .minutes(10))
        // нет ключа или пусто — умолчание 15
        XCTAssertEqual(TeamYAMLSummary.parse("project: x\n").idleStop, .byDefault)
        XCTAssertEqual(TeamYAMLSummary.parse("project: x\n").idleStopMinutes, 15)
        XCTAssertEqual(TeamYAMLSummary.parse("idle_stop_minutes:\n").idleStopMinutes, 15)
        XCTAssertEqual(TeamYAMLSummary.parse("idle_stop_minutes: 0\n").idleStopMinutes, 15)
        // off / false — выключено, в любом регистре и с кавычками
        for v in ["off", "false", "Off", "FALSE", "\"off\"", "off  # выключено"] {
            let s = TeamYAMLSummary.parse("idle_stop_minutes: \(v)\nlayout: panes\n")
            XCTAssertEqual(s.idleStop, .off, v)
            XCTAssertNil(s.idleStopMinutes, v)
        }
        // ключ во вложенном блоке верхнего уровня не считается
        XCTAssertEqual(TeamYAMLSummary.parse("roles:\n  idle_stop_minutes: off\n").idleStop, .byDefault)
    }

    // MARK: вызов

    private func fakeTeam(output: String, exit: Int = 0) throws -> (TeamCLI, String) {
        let dir = NSTemporaryDirectory() + "agtest-reap-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/agents", withIntermediateDirectories: true)
        let script = dir + "/team"
        let body = """
        #!/bin/sh
        echo "$@" >> "\(dir)/calls.log"
        [ \(exit) -eq 0 ] || { echo 'boom' >&2; exit \(exit); }
        echo '\(output)'
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (TeamCLI(executable: script, environment: ProcessInfo.processInfo.environment), dir)
    }

    @MainActor
    private func model(_ cli: TeamCLI, dir: String, idle: Int?) -> ProjectModel {
        let yaml = idle.map { "project: x\nidle_stop_minutes: \($0)\n" } ?? "project: x\n"
        try? yaml.write(toFile: dir + "/agents/team.yaml", atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "agtest-reap-\(UUID().uuidString)")!
        return ProjectModel(repo: dir, session: "team-reap", cli: cli, defaults: defaults)
    }

    @MainActor
    func testTickWithoutKeyCallsReapWithDefault() async throws {
        let (cli, dir) = try fakeTeam(output: "[]")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir: dir, idle: nil)
        _ = await m.reapTick()
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "reap --json\n")
    }

    @MainActor
    func testTickCallsReapEvenWhenOff() async throws {
        for v in ["off", "false"] {
            let (cli, dir) = try fakeTeam(output: "[]")
            defer { try? FileManager.default.removeItem(atPath: dir) }
            try "project: x\nidle_stop_minutes: \(v)\n".write(toFile: dir + "/agents/team.yaml", atomically: true, encoding: .utf8)
            let m = ProjectModel(repo: dir, session: "team-reap", cli: cli, defaults: UserDefaults(suiteName: "agtest-reap-\(UUID().uuidString)")!)
            XCTAssertEqual(m.teamYAML.idleStop, .off)
            let r = await m.reapTick()
            XCTAssertTrue(r.isEmpty)
            XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "reap --json\n", v)
        }
    }

    @MainActor
    func testTickCallsReapAndReturnsStopped() async throws {
        let (cli, dir) = try fakeTeam(output: #"[{"name":"developer#2","idle_s":700,"action":"stopped","reason":"простой 11 мин"},{"name":"tester#1","idle_s":10,"action":"kept","reason":"работает"}]"#)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir: dir, idle: 10)
        let r = await m.reapTick()
        XCTAssertEqual(r.map(\.name), ["developer#2"])
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "reap --json\n")
    }

    @MainActor
    func testTickErrorIsSilent() async throws {
        let (cli, dir) = try fakeTeam(output: "", exit: 1)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir: dir, idle: 10)
        let r = await m.reapTick()
        XCTAssertTrue(r.isEmpty)
    }

    @MainActor
    func testTickKeepsManagerWithDraft() async throws {
        let (cli, dir) = try fakeTeam(output: "[]")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir: dir, idle: 10)
        m.draft = "недописанное сообщение"
        _ = await m.reapTick()
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "reap --json --keep manager\n")
    }
}
