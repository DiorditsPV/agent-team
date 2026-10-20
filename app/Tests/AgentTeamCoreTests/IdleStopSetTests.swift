import Foundation
import XCTest
@testable import AgentTeamCore

/// Правка автоостановки в приложении: ввод, аргументы `team set`, разбор ответа, перечитывание team.yaml, ошибка.
final class IdleStopSetTests: XCTestCase {
    func testParseInput() {
        XCTAssertEqual(IdleStopInput.parse("15"), .minutes(15))
        XCTAssertEqual(IdleStopInput.parse(" 7 "), .minutes(7))
        XCTAssertEqual(IdleStopInput.parse(""), .minutes(15))   // пусто — вернуть умолчание
        XCTAssertEqual(IdleStopInput.parse("Выкл"), .off)
        XCTAssertEqual(IdleStopInput.parse("off"), .off)
        XCTAssertEqual(IdleStopInput.parse("false"), .off)
        XCTAssertEqual(IdleStopInput.parse("0"), .invalid)
        XCTAssertEqual(IdleStopInput.parse("-3"), .invalid)
        XCTAssertEqual(IdleStopInput.parse("2.5"), .invalid)
        XCTAssertEqual(IdleStopInput.parse("abc"), .invalid)
    }

    func testArguments() {
        XCTAssertEqual(IdleStopInput.minutes(10).argument, "10")
        XCTAssertEqual(IdleStopInput.off.argument, "off")
        XCTAssertNil(IdleStopInput.invalid.argument)
    }

    func testDecodesSetResult() throws {
        let on = try JSONDecoder().decode(SetResult.self, from: Data(#"{"key": "idle_stop_minutes", "value": 10}"#.utf8))
        XCTAssertEqual(on, SetResult(key: "idle_stop_minutes", value: 10))
        let off = try JSONDecoder().decode(SetResult.self, from: Data(#"{"key": "idle_stop_minutes", "value": null}"#.utf8))
        XCTAssertNil(off.value)
    }

    /// Подставной team: `set` пишет ключ в team.yaml так же, как настоящий (или убирает его), с кодом 1 — отказ.
    private func fakeTeam(fail: Bool = false) throws -> (TeamCLI, String) {
        let dir = NSTemporaryDirectory() + "agtest-set-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/agents", withIntermediateDirectories: true)
        try "project: x\n".write(toFile: dir + "/agents/team.yaml", atomically: true, encoding: .utf8)
        let script = dir + "/team"
        let body = """
        #!/bin/sh
        echo "$@" >> "\(dir)/calls.log"
        \(fail ? "echo 'idle_stop_minutes в team.yaml: целое число минут больше нуля' >&2; exit 1" : "")
        if [ "$3" = off ]; then printf 'project: x\\nidle_stop_minutes: off\\n' > "\(dir)/agents/team.yaml"; echo '{"key": "idle_stop_minutes", "value": null}'
        else printf 'project: x\\nidle_stop_minutes: %s\\n' "$3" > "\(dir)/agents/team.yaml"; echo "{\\"key\\": \\"idle_stop_minutes\\", \\"value\\": $3}"; fi
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (TeamCLI(executable: script, environment: ProcessInfo.processInfo.environment), dir)
    }

    @MainActor
    private func model(_ cli: TeamCLI, _ dir: String) -> ProjectModel {
        ProjectModel(repo: dir, session: "team-set", cli: cli, defaults: UserDefaults(suiteName: "agtest-set-\(UUID().uuidString)")!)
    }

    @MainActor
    func testSetRereadsTeamYAML() async throws {
        let (cli, dir) = try fakeTeam()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir)
        XCTAssertEqual(m.teamYAML.idleStop, .byDefault)
        XCTAssertEqual(m.teamYAML.idleStopMinutes, 15)
        let ok = await m.setIdleStop(.minutes(12))
        XCTAssertTrue(ok)
        XCTAssertEqual(m.teamYAML.idleStopMinutes, 12)
        XCTAssertNil(m.idleStopError)
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "set idle_stop_minutes 12 --json\n")
        let off = await m.setIdleStop(.off)
        XCTAssertTrue(off)
        XCTAssertEqual(m.teamYAML.idleStop, .off)
        XCTAssertNil(m.teamYAML.idleStopMinutes)
    }

    @MainActor
    func testErrorShownNextToField() async throws {
        let (cli, dir) = try fakeTeam(fail: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir)
        let ok = await m.setIdleStop(.minutes(5))
        XCTAssertFalse(ok)
        XCTAssertEqual(m.idleStopError, "idle_stop_minutes в team.yaml: целое число минут больше нуля")
        m.clearIdleStopError()
        XCTAssertNil(m.idleStopError)
    }

    @MainActor
    func testInvalidInputDoesNotCallTeam() async throws {
        let (cli, dir) = try fakeTeam()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let m = model(cli, dir)
        let ok = await m.setIdleStop(.invalid)
        XCTAssertFalse(ok)
        XCTAssertNotNil(m.idleStopError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/calls.log"))
    }
}
