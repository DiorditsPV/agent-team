import Foundation
import XCTest
@testable import AgentTeamCore

/// Автоостановка для всех проектов с живой сессией команды: открыт проект в приложении или нет.
final class ReapAllTests: XCTestCase {
    func testTargetsAreRunningProjectsWithRepo() {
        let entries = [
            ProjectEntry(session: "team-a", name: "a", repo: "/r/a", liveAgents: 1, running: true),
            ProjectEntry(session: "team-b", name: "b", repo: "/r/b", liveAgents: 0, running: false),
            ProjectEntry(session: "team-c", name: "c", repo: nil, liveAgents: 0, running: true),
        ]
        XCTAssertEqual(Reap.targets(entries).map(\.session), ["team-a"])
        XCTAssertEqual(Reap.targets(entries).map(\.repo), ["/r/a"])
    }

    /// Живой tmux на своём сервере, подставной team: reap зовётся для неоткрытого проекта с сессией
    /// и не зовётся для проекта без сессии.
    @MainActor
    func testReapAllCoversUnopenedLiveProjectOnly() async throws {
        let tmux = try XCTUnwrap(ToolLocator.find("tmux"), "нужен tmux")
        let socket = "agtest-reapall-\(getpid())-\(Int.random(in: 0..<100_000))"
        let tmp = NSTemporaryDirectory() + "agtest-reapall-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tmux)
            p.arguments = ["-L", socket, "kill-server"]; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            try? fm.removeItem(atPath: tmp)
            try? fm.removeItem(atPath: "/private/tmp/tmux-\(getuid())/\(socket)")
        }
        func tmuxRun(_ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: tmux)
            p.arguments = ["-L", socket, "-f", "/dev/null"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        // open — открыт приложением; unopened — сессия жива, проект не открывали; idle — сессии нет.
        var repos: [String: String] = [:]
        for n in ["rpopen", "rpunopened", "rpidle"] {
            let repo = tmp + "/" + n
            try fm.createDirectory(atPath: repo + "/agents", withIntermediateDirectories: true)
            try "project: \(n)\nmanager: manager\n".write(toFile: repo + "/agents/team.yaml", atomically: true, encoding: .utf8)
            repos[n] = repo
        }
        let team = tmp + "/team"
        try "#!/bin/sh\necho \"$(basename \"$PWD\") $@\" >> \"\(tmp)/calls.log\"\necho '[]'\n".write(toFile: team, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: team)
        try tmuxRun(["new-session", "-d", "-s", "team-rpopen", "-x", "100", "-y", "30", "sh"])
        try tmuxRun(["new-session", "-d", "-s", "team-rpunopened", "-x", "100", "-y", "30", "sh"])

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-reapall-\(UUID().uuidString)"))
        defaults.set(team, forKey: "toolPath")
        defaults.set(repos.values.sorted(), forKey: "projects")
        let app = AppModel(defaults: defaults, socketName: socket, loginEnvironment: false)
        await app.start(preferredProject: "rpopen")
        defer { app.hub.disconnect() }
        let ready = await waitFor(10) {
            app.projects.first { $0.session == "team-rpunopened" }?.repo != nil
                && app.projects.first { $0.session == "team-rpopen" }?.repo != nil
        }
        XCTAssertTrue(ready, "проекты: \(app.projects)")
        XCTAssertEqual(app.openModels.map(\.session), ["team-rpopen"])

        _ = await app.reapAll()
        let log = (try? String(contentsOfFile: tmp + "/calls.log", encoding: .utf8)) ?? ""
        let calls = Set(log.split(separator: "\n").map { String($0.split(separator: " ")[0]) })
        XCTAssertEqual(calls, ["rpopen", "rpunopened"], log)
        XCTAssertEqual(app.openModels.map(\.session), ["team-rpopen"], "модель неоткрытого проекта не создаётся")
    }

    @MainActor
    private func waitFor(_ timeout: TimeInterval, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }
}
