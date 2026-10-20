import XCTest
@testable import AgentTeamCore

/// Запуск и остановка отдельной сессии: команда, разбор листинга, живой tmux на своём сервере `-L`.
final class SoloLaunchTests: XCTestCase {
    // MARK: сборка команды

    func testNewSessionCommand() {
        let a = SoloLaunch.command(claude: "/usr/local/bin/claude", sessionID: "abc", resume: false)
        XCTAssertEqual(Array(a.prefix(2)), ["sh", "-c"])
        let script = a[2]
        XCTAssertTrue(script.contains("CLAUDE[A-Za-z0-9_]*"), "снятие CLAUDE_*")
        XCTAssertTrue(script.contains("CLAUDE_CONFIG_DIR"))
        XCTAssertTrue(script.hasSuffix("; exec '/usr/local/bin/claude' --session-id 'abc'"), script)
        XCTAssertFalse(script.contains("--resume"))
    }

    func testResumeCommand() {
        let script = SoloLaunch.command(claude: "claude", sessionID: "abc", resume: true)[2]
        XCTAssertTrue(script.hasSuffix("exec 'claude' --resume 'abc'"), script)
        XCTAssertFalse(script.contains("--session-id"))
    }

    func testNoPermissionFlags() {
        for resume in [false, true] {
            let script = SoloLaunch.command(claude: "claude", sessionID: "s", resume: resume).joined(separator: " ")
            for flag in ["--allowedTools", "--permission-mode", "--settings", "--dangerously-skip-permissions",
                         "--append-system-prompt-file"] {
                XCTAssertFalse(script.contains(flag), flag)
            }
        }
    }

    func testClaudePathWithQuoteAndSpace() {
        let script = SoloLaunch.command(claude: "/a b/it's/claude", sessionID: "s", resume: false)[2]
        XCTAssertTrue(script.contains(#"exec '/a b/it'\''s/claude' --session-id"#), script)
    }

    func testUnsetKeepsConfigDirAndRemovesOthers() throws {
        let script = SoloLaunch.command(claude: "env", sessionID: "s", resume: false)[2]
        let probe = script.replacingOccurrences(of: "exec 'env' --session-id 's'", with: "echo A=$CLAUDECODE B=$CLAUDE_CODE_X C=$CLAUDE_CONFIG_DIR D=$KEEP")
        let r = Process()
        r.executableURL = URL(fileURLWithPath: "/bin/sh")
        r.arguments = ["-c", probe]
        r.environment = ["CLAUDECODE": "1", "CLAUDE_CODE_X": "x", "CLAUDE_CONFIG_DIR": "/cfg", "KEEP": "k", "PATH": "/usr/bin:/bin"]
        let out = Pipe()
        r.standardOutput = out
        try r.run()
        r.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines), "A= B= C=/cfg D=k")
    }

    // MARK: листинг

    func testParsePanesReadsSoloID() {
        let lines = ["team-x\t%1\tboss#1\t0\t10\t/p\t", "cc-app-3f2a\t%7\t\t0\t99\t/q\tU-1", "old\t%2\t\t1\t5\t/z"]
        let p = TmuxListing.parsePanes(lines)
        XCTAssertEqual(p.map(\.soloID), ["", "U-1", ""])
        XCTAssertEqual(p[1].session, "cc-app-3f2a")
        XCTAssertEqual(p[1].pid, 99)
        XCTAssertTrue(TmuxListing.paneFormat.hasSuffix("#{@solo_id}"))
    }

    func testLiveAgentCountsIgnoreSolo() {
        let panes = [PaneInfo(session: "team-x", paneID: "%1", role: "boss", dead: false, pid: 1, path: "/"),
                     PaneInfo(session: "cc-app-3f2a", paneID: "%2", role: "", dead: false, pid: 2, path: "/", soloID: "U")]
        XCTAssertEqual(TmuxListing.liveAgentCounts(panes), ["team-x": 1])
        XCTAssertEqual(TmuxListing.teamSessions(["team-x", "cc-app-3f2a"]), ["team-x"])
        XCTAssertEqual(TmuxListing.soloSessions(["team-x", "cc-app-3f2a", "other"]), ["cc-app-3f2a"])
    }

    // MARK: живой tmux

    private var socket = ""
    private var tmux = ""
    private var dir = ""

    override func setUpWithError() throws {
        tmux = try XCTUnwrap(ToolLocator.find("tmux"), "нужен tmux")
        socket = "agsolo-\(getpid())-\(Int.random(in: 0..<100_000))"
        dir = try {
            let d = FileManager.default.temporaryDirectory.appendingPathComponent("solo-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d.path
        }()
    }

    override func tearDown() {
        _ = try? sh(["kill-server"])
        try? FileManager.default.removeItem(atPath: "/private/tmp/tmux-\(getuid())/\(socket)")
        try? FileManager.default.removeItem(atPath: dir)
    }

    @discardableResult
    private func sh(_ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["-L", socket, "-f", "/dev/null"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Заглушка claude: игнорирует аргументы и делает `exec cat` (голый `cat --session-id` сразу вышел бы).
    private func stub() throws -> String {
        let path = dir + "/claude-stub"
        try "#!/bin/sh\nexec cat\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    @MainActor
    private func waitMain(_ timeout: TimeInterval = 15, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    @MainActor
    func testStartAttachStopOnlyOwn() async throws {
        // Чужая сессия того же сервера: остановка её не касается.
        try sh(["new-session", "-d", "-s", "other", "sh"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        let s = SoloSession(cwd: dir, launchSessionID: UUID().uuidString.lowercased())
        let pane = try await hub.startSolo(s, claude: try stub(), resume: false)
        defer { hub.disconnect() }
        XCTAssertTrue(pane.hasPrefix("%"))

        let line = try sh(["list-panes", "-t", "=\(s.tmuxName):", "-F", "#{pane_id} #{pane_pid} #{@solo_id} #{pane_dead} #{@team_role}"])
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(f[0], pane)
        XCTAssertEqual(f[2], s.id.uuidString)
        XCTAssertEqual(f[3], "0")
        // pid панели после exec — pid cat: запись сессии читается по нему.
        let pid = try XCTUnwrap(Int(f[1]))
        func comm() -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-o", "comm=", "-p", "\(pid)"]
            let o = Pipe()
            p.standardOutput = o
            try? p.run()
            p.waitUntilExit()
            return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        // exec идёт после снятия CLAUDE_* и заглушки: pid тот же, имя процесса меняется на cat не сразу.
        let isCat = await waitMain(5) { comm().contains("cat") }
        XCTAssertTrue(isCat, comm())

        // Хаб прикрепился к cc-* без единой team-*.
        let attached = await waitMain { hub.attachedAppSession == s.tmuxName }
        XCTAssertTrue(attached, "attachedSession=\(String(describing: hub.attachedSession))")
        XCTAssertNil(hub.attachedTeamSession)
        XCTAssertTrue(hub.sessions.isEmpty)
        XCTAssertEqual(hub.soloLive, [s.tmuxName])
        XCTAssertTrue(hub.agentCounts.isEmpty)

        // Захват панели: то, что ушло в cat, видно на экране.
        try sh(["send-keys", "-t", pane, "-l", "привет-solo"])
        try sh(["send-keys", "-t", pane, "Enter"])
        hub.captureNow(pane)
        let seen = await waitMain { hub.output(for: pane).lines.contains { $0.plain.contains("привет-solo") } }
        XCTAssertTrue(seen, "захват должен содержать текст, отправленный после прикрепления")

        // Остановка убирает только свою сессию.
        await hub.stopSolo(s)
        let names = try sh(["list-sessions", "-F", "#{session_name}"]).split(separator: "\n").map(String.init)
        XCTAssertEqual(names, ["other"])
    }

    @MainActor
    func testResumeRespawnsDeadPaneAndKeepsLivePane() async throws {
        try sh(["new-session", "-d", "-s", "keep", "sh"])   // сервер поднимает тест с -f /dev/null, не хаб
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        let s = SoloSession(cwd: dir, launchSessionID: "L1", sessionID: "L2")
        let bin = try stub()
        let pane = try await hub.startSolo(s, claude: bin, resume: false)
        // Живая панель при продолжении не перезапускается.
        let again = try await hub.startSolo(s, claude: bin, resume: true)
        XCTAssertEqual(again, pane)
        let pid1 = try sh(["display-message", "-p", "-t", pane, "#{pane_pid}"])
        // Панель умерла (claude вышел) — продолжение запускает заново в той же tmux-сессии.
        try sh(["send-keys", "-t", pane, "C-d"])
        let dead = await waitMain { (try? self.sh(["display-message", "-p", "-t", pane, "#{pane_dead}"]))?.hasPrefix("1") == true }
        XCTAssertTrue(dead)
        let back = try await hub.startSolo(s, claude: bin, resume: true)
        XCTAssertEqual(back, pane)
        let pid2 = try sh(["display-message", "-p", "-t", pane, "#{pane_pid}"])
        XCTAssertNotEqual(pid1, pid2)
        XCTAssertEqual(try sh(["display-message", "-p", "-t", pane, "#{pane_dead}"]).trimmingCharacters(in: .whitespacesAndNewlines), "0")
        let cmd = try sh(["display-message", "-p", "-t", pane, "#{pane_start_command}"])
        XCTAssertTrue(cmd.contains("--resume") && cmd.contains("L2") && !cmd.contains("--session-id"), cmd)
    }

    @MainActor
    func testMissingDirectoryThrowsAndStartsNothing() async {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        let s = SoloSession(cwd: "/nonexistent-\(UUID().uuidString)", launchSessionID: "x")
        do {
            _ = try await hub.startSolo(s, claude: "/bin/cat", resume: false)
            XCTFail("каталога нет — запуск должен упасть")
        } catch { XCTAssertEqual(error as? TmuxHub.SoloError, .missingDir) }
        XCTAssertEqual((try? sh(["list-sessions", "-F", "#{session_name}"]))?.contains(s.tmuxName) ?? false, false)
    }

    private func startCommand(_ pane: String) throws -> String {
        try sh(["display-message", "-p", "-t", pane, "#{pane_start_command}"])
    }

    private func sessions() throws -> [String] {
        try sh(["list-sessions", "-F", "#{session_name}"]).split(separator: "\n").map(String.init).sorted()
    }

    /// `#` в каталоге: tmux раскрывает формат в `-c`, без удвоения сессия уходила в домашний каталог.
    @MainActor
    func testDirectoriesWithHashStartInThatDirectory() async throws {
        try sh(["new-session", "-d", "-s", "keep", "sh"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        let bin = try stub()
        for name in ["c#", "a#Sb", "x##y", "#notes", "a#{session_name}b"] {
            let d = dir + "/" + name
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            let s = SoloSession(cwd: d)
            let pane = try await hub.startSolo(s, claude: bin, resume: false)
            let path = try sh(["display-message", "-p", "-t", pane, "#{pane_current_path}"]).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                           URL(fileURLWithPath: d).resolvingSymlinksInPath().path, "каталог \(name)")
        }
    }

    @MainActor
    func testTrailingSemicolonAndEmptySessionIDAreClearErrors() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        let semi = dir + "/semi;"
        try FileManager.default.createDirectory(atPath: semi, withIntermediateDirectories: true)
        do {
            _ = try await hub.startSolo(SoloSession(cwd: semi), claude: try stub(), resume: false)
            XCTFail("каталог на «;» должен дать ошибку")
        } catch { XCTAssertEqual(error as? TmuxHub.SoloError, .badDirectory(semi)) }
        var empty = SoloSession(cwd: dir)
        empty.launchSessionID = ""
        empty.sessionID = ""
        for resume in [false, true] {
            do {
                _ = try await hub.startSolo(empty, claude: try stub(), resume: resume)
                XCTFail("пустой id сессии Claude")
            } catch { XCTAssertEqual(error as? TmuxHub.SoloError, .noSessionID) }
        }
        XCTAssertEqual((try? sh(["list-sessions", "-F", "#{session_name}"])) ?? "", "", "сервер не поднимался")
    }

    /// Остаток прерванного старта — живая оболочка без запуска: «Продолжить» запускает claude в ней, а не возвращает её.
    @MainActor
    func testBareShellLeftoverGetsLaunched() async throws {
        let s = SoloSession(cwd: dir, launchSessionID: "L1")
        try sh(["new-session", "-d", "-s", s.tmuxName, "-c", dir])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        XCTAssertFalse(try startCommand("=\(s.tmuxName):").contains("exec "))
        let pane = try await hub.startSolo(s, claude: try stub(), resume: true)
        let cmd = try startCommand(pane)
        XCTAssertTrue(cmd.contains("exec ") && cmd.contains("--resume"), cmd)
        XCTAssertEqual(try sh(["display-message", "-p", "-t", pane, "#{@solo_id}"]).trimmingCharacters(in: .whitespacesAndNewlines),
                       s.id.uuidString)
    }

    /// Ошибка после `new-session` не оставляет сессию с голой оболочкой: нельзя запустить `respawn-pane` без claude.
    @MainActor
    func testFailedLaunchRemovesCreatedSession() async throws {
        try sh(["new-session", "-d", "-s", "keep", "sh"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        let s = SoloSession(cwd: dir, launchSessionID: "L1")
        hub.failTmux = { $0.first == "respawn-pane" }
        do {
            _ = try await hub.startSolo(s, claude: try stub(), resume: false)
            XCTFail("respawn должен был упасть")
        } catch {}
        XCTAssertEqual(try sessions(), ["keep"])
    }

    /// Сессия с чужим `@solo_id` под тем же именем: ни запуск, ни остановка её не трогают.
    @MainActor
    func testForeignSoloIDIsNeitherReusedNorStopped() async throws {
        let s = SoloSession(cwd: dir, launchSessionID: "L1")
        try sh(["new-session", "-d", "-s", s.tmuxName, "-c", dir, "sh"])
        let other = UUID().uuidString
        try sh(["set-option", "-p", "-t", "=\(s.tmuxName):", "@solo_id", other])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        do {
            _ = try await hub.startSolo(s, claude: try stub(), resume: false)
            XCTFail("чужая сессия")
        } catch { XCTAssertEqual(error as? TmuxHub.SoloError, .nameTaken(other)) }
        await hub.stopSolo(s)
        XCTAssertEqual(try sessions(), [s.tmuxName])
    }

    /// Остановка по точному имени: соседи с тем же началом имени живы.
    @MainActor
    func testStopKeepsNeighborsWithSamePrefix() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        let s = SoloSession(cwd: dir, launchSessionID: "L1")
        for n in [s.tmuxName + "X", s.tmuxName + "-2"] { try sh(["new-session", "-d", "-s", n, "sh"]) }
        try await hub.startSolo(s, claude: try stub(), resume: false)
        await hub.stopSolo(s)
        XCTAssertEqual(try sessions(), [s.tmuxName + "-2", s.tmuxName + "X"].sorted())
    }

    func testLiveSoloNamesListsOnlyCC() async throws {
        try sh(["new-session", "-d", "-s", "team-x", "sh"])
        try sh(["new-session", "-d", "-s", "cc-a-0001", "sh"])
        try sh(["new-session", "-d", "-s", "other", "sh"])
        let hub = await TmuxHub(tmuxPath: tmux, socketName: socket)
        let names = await hub.liveSoloSessionNames()
        XCTAssertEqual(names, ["cc-a-0001"])
    }

    // MARK: изоляция хаба

    @MainActor
    private func teamSetup() throws {
        try sh(["new-session", "-d", "-s", "team-x", "-x", "100", "-y", "30", "sh"])
        try sh(["set-option", "-p", "-t", "=team-x:", "@team_role", "manager#1"])
    }

    /// team → solo → team: прикреплённая сессия меняется только по запросу, запуск выбор не переключает.
    @MainActor
    func testSwitchTeamSoloTeamAndStartDoesNotSwitch() async throws {
        try teamSetup()
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        let s = SoloSession(cwd: dir, launchSessionID: "L1")
        await hub.connect(preferring: "team-x")
        XCTAssertEqual(hub.attachedSession, "team-x")
        try await hub.startSolo(s, claude: try stub(), resume: false)
        XCTAssertEqual(hub.attachedSession, "team-x", "запуск не уводит хаб с проекта")
        XCTAssertEqual(hub.soloLive, [s.tmuxName])

        await hub.connect(preferring: s.tmuxName)
        XCTAssertEqual(hub.attachedSession, s.tmuxName)
        XCTAssertNil(hub.attachedTeamSession)
        XCTAssertEqual(hub.attachedAppSession, s.tmuxName)
        XCTAssertEqual(hub.sessions, ["team-x"])

        await hub.connect(preferring: "team-x")
        XCTAssertEqual(hub.attachedSession, "team-x")
        XCTAssertEqual(hub.attachedTeamSession, "team-x")
        XCTAssertEqual(hub.agentCounts, ["team-x": 1])
    }

    /// `cc-*` вне `soloNames` — чужая сессия: хаб к ней не прикрепляется.
    @MainActor
    func testCCOutsideSoloNamesIsForeign() async throws {
        try teamSetup()
        try sh(["new-session", "-d", "-s", "cc-foreign-0000", "sh"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        await hub.connect(preferring: "cc-foreign-0000")
        XCTAssertEqual(hub.attachedSession, "team-x")
        XCTAssertTrue(hub.soloLive.isEmpty)
        XCTAssertNil(hub.attachedAppSession.flatMap { $0 == "cc-foreign-0000" ? $0 : nil })
    }

    /// Остановка прикреплённой сессии: хаб уходит на проект, состояние не залипает.
    @MainActor
    func testStopAttachedSoloReturnsToProject() async throws {
        try teamSetup()
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        defer { hub.disconnect() }
        let s = SoloSession(cwd: dir, launchSessionID: "L1")
        await hub.connect(preferring: "team-x")
        try await hub.startSolo(s, claude: try stub(), resume: false)
        await hub.connect(preferring: s.tmuxName)
        XCTAssertEqual(hub.attachedSession, s.tmuxName)
        await hub.stopSolo(s)
        let back = await waitMain { hub.attachedSession == "team-x" && hub.soloLive.isEmpty }
        XCTAssertTrue(back, "attached=\(String(describing: hub.attachedSession)) live=\(hub.soloLive)")
        XCTAssertEqual(try sessions(), ["team-x"])
    }
}
