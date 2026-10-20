import Foundation
import XCTest
@testable import AgentTeamCore

/// `team roles --json --library`: старый team не знает флага — приложение перезапрашивает без него.
final class RolesLibraryFallbackTests: XCTestCase {
    private func fakeTeam(acceptsLibrary: Bool) throws -> (TeamCLI, String) {
        let dir = NSTemporaryDirectory() + "agtest-fake-team-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let log = dir + "/calls.log"
        let script = dir + "/team"
        let body = """
        #!/bin/sh
        echo "$@" >> "\(log)"
        case "$*" in
          *--library*) \(acceptsLibrary ? "" : "echo 'team: error: unrecognized arguments: --library' >&2; exit 2;") echo '[{"role":"developer","source":"project"},{"role":"judge","source":"library"}]'; exit 0;;
        esac
        echo '[{"role":"developer"}]'
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (TeamCLI(executable: script, environment: ProcessInfo.processInfo.environment), dir)
    }

    func testNewTeamReturnsLibraryRolesInOneCall() async throws {
        let (cli, dir) = try fakeTeam(acceptsLibrary: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let roles = try await cli.roles(cwd: dir)
        XCTAssertEqual(roles.map(\.role), ["developer", "judge"])
        XCTAssertTrue(roles[1].isShared)
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "roles --json --library\n")
    }

    func testOldTeamFallsBackToRolesWithoutLibrary() async throws {
        let (cli, dir) = try fakeTeam(acceptsLibrary: false)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let roles = try await cli.roles(cwd: dir)
        XCTAssertEqual(roles.map(\.role), ["developer"])
        XCTAssertTrue(roles.allSatisfy { !$0.isShared })      // блок общих ролей пуст
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "roles --json --library\nroles --json\n")
    }

    private func fakeRoleNew(exitCode: Int) throws -> (TeamCLI, String) {
        let dir = NSTemporaryDirectory() + "agtest-fake-team-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let script = dir + "/team"
        let body = """
        #!/bin/sh
        echo "$@" >> "\(dir)/calls.log"
        if [ \(exitCode) -ne 0 ]; then echo 'team: роль уже есть' >&2; exit 1; fi
        echo '{"role":"judge","source":"project","extends":"judge","title":"Судья"}'
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        return (TeamCLI(executable: script, environment: ProcessInfo.processInfo.environment), dir)
    }

    func testRoleNewExtendsCallsCLIAndDecodesRole() async throws {
        let (cli, dir) = try fakeRoleNew(exitCode: 0)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let role = try await cli.roleNew("judge", extends: "judge", cwd: dir)
        XCTAssertEqual(role.extends, "judge")
        XCTAssertTrue(role.isInheriting)
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "role new judge --extends judge\n")
    }

    func testRoleNewErrorCarriesStderr() async throws {
        let (cli, dir) = try fakeRoleNew(exitCode: 1)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        do {
            _ = try await cli.roleNew("judge", extends: "judge", cwd: dir)
            XCTFail("ожидалась ошибка")
        } catch let TeamCLIError.failed(status, message) {
            XCTAssertEqual(status, 1)
            XCTAssertEqual(message, "team: роль уже есть")
        }
    }

    func testRoleSetExtendsFlag() async throws {
        let (cli, dir) = try fakeRoleNew(exitCode: 0)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = try await cli.roleSet("judge", title: nil, model: nil, description: nil, start: nil, extends: "", cwd: dir)
        XCTAssertEqual(try String(contentsOfFile: dir + "/calls.log", encoding: .utf8), "role set judge --extends \n")
    }
}
