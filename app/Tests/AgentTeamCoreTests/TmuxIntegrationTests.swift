import XCTest
@testable import AgentTeamCore

/// Живой tmux на отдельном сервере `tmux -L agtest-<pid>`: пользовательские сессии не задеваются.
final class TmuxIntegrationTests: XCTestCase {
    var socket = ""
    var tmux = ""

    override func setUpWithError() throws {
        tmux = try XCTUnwrap(ToolLocator.find("tmux"), "нужен tmux")
        socket = "agtest-\(getpid())-\(Int.random(in: 0..<100_000))"
        try sh(["new-session", "-d", "-s", "team-x", "-x", "100", "-y", "30", "sh"])
        try sh(["split-window", "-t", "team-x", "sh"])
        try sh(["set-option", "-p", "-t", "team-x:0.0", "@team_role", "manager#1"])
        try sh(["set-option", "-p", "-t", "team-x:0.1", "@team_role", "dev#1"])
        try sh(["new-session", "-d", "-s", "team-y", "sh"])
    }

    override func tearDown() {
        _ = try? sh(["kill-server"])
        try? FileManager.default.removeItem(atPath: "/private/tmp/tmux-\(getuid())/\(socket)")
    }

    @discardableResult
    func sh(_ args: [String]) throws -> String {
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

    func paneIDs() throws -> [String] {
        try sh(["list-panes", "-t", "team-x", "-F", "#{pane_id}"]).split(separator: "\n").map(String.init)
    }

    func connect(events: EventLog) throws -> ControlClient {
        let c = ControlClient(tmuxPath: tmux, socketName: socket)
        try c.start(session: "team-x", onEvent: { events.add($0) }, onExit: {})
        return c
    }

    func waitFor(_ timeout: TimeInterval = 3, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    func pause(_ s: TimeInterval) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

    /// Ожидание условия, а не времени (тесты на главном акторе).
    @MainActor
    func waitMain(_ timeout: TimeInterval = 15, _ cond: @escaping @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return cond()
    }

    /// Программа в панели запускается, и тест ждёт её метки на экране, а не фиксированное время: под нагрузкой оболочка
    /// не всегда успевала за 0,3–0,5 с, и ввод уходил ей, а не программе (или до `stty raw`). `setup` идёт до метки,
    /// `program` — после. Метка печатается через восьмеричный код, чтобы не совпасть с эхом самой команды.
    @MainActor
    func runInPane(_ pane: String, setup: String = "", _ program: String) async throws {
        try sh(["send-keys", "-t", pane, "clear; \(setup) printf '\\101GT-RE\\101DY\\n'; \(program)", "Enter"])
        let ready = await waitMain(15) { (try? self.sh(["capture-pane", "-p", "-t", pane]))?.contains("AGT-READY") ?? false }
        XCTAssertTrue(ready, "программа в панели не запустилась: \(program)")
    }

    func screenOf(_ pane: String) -> String { (try? sh(["capture-pane", "-p", "-J", "-t", pane])) ?? "" }
    func fileText(_ url: URL) -> String { String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self) }

    /// Сессия проекта с точкой в имени (каталог из mktemp): клиент прикрепляется к ней и переключается на неё. С целью
    /// «=имя» без двоеточия tmux читал бы точку как разделитель окна и сессию не находил.
    func testSessionWithDotInName() async throws {
        XCTAssertEqual(TmuxTarget.session("team-tmp.ab12"), "=team-tmp.ab12:")
        try sh(["new-session", "-d", "-s", "team-tmp.ab12", "sh"])
        let c = ControlClient(tmuxPath: tmux, socketName: socket)
        try c.start(session: "team-tmp.ab12", onEvent: { _ in }, onExit: {})
        defer { c.stop() }
        let name = try await c.run("display-message -p '#{session_name}'")
        XCTAssertEqual(name, ["team-tmp.ab12"], "клиент прикреплён к сессии с точкой")

        _ = try await c.run("switch-client -t " + TmuxQuote.word(TmuxTarget.session("team-x")))
        let other = try await c.run("display-message -p '#{session_name}'")
        XCTAssertEqual(other, ["team-x"])
        _ = try await c.run("switch-client -t " + TmuxQuote.word(TmuxTarget.session("team-tmp.ab12")))
        let back = try await c.run("display-message -p '#{session_name}'")
        XCTAssertEqual(back, ["team-tmp.ab12"], "переключение на сессию с точкой")
    }

    func testListingOverControlChannel() async throws {
        let log = EventLog()
        let c = try connect(events: log)
        defer { c.stop() }
        let panes = TmuxListing.parsePanes(try await c.run(TmuxListing.listPanesCommand))
        XCTAssertEqual(Set(panes.map(\.session)), ["team-x", "team-y"])
        XCTAssertEqual(TmuxListing.liveAgentCounts(panes), ["team-x": 2, "team-y": 0])
        let sessions = try await c.run(TmuxListing.listSessionsCommand)
        XCTAssertEqual(TmuxListing.teamSessions(sessions), ["team-x", "team-y"])
        do {
            _ = try await c.run("no-such-command")
            XCTFail("ожидалась ошибка")
        } catch ControlError.commandFailed {}
    }

    func testOutputSignalAndOffSilencesPane() async throws {
        let log = EventLog()
        let c = try connect(events: log)
        defer { c.stop() }
        let ids = try paneIDs()
        let p0 = ids[0]
        try await c.run("send-keys -t \(p0) 'echo one' Enter")
        let ok1 = await waitFor { log.outputs(p0) > 0 }
        XCTAssertTrue(ok1, "вывод панели приходит сигналом")
        try await c.run("refresh-client -A '\(p0):off'")
        await pause(0.3)
        let before = log.outputs(p0)
        try await c.run("send-keys -t \(p0) 'echo two' Enter")
        await pause(0.8)
        XCTAssertEqual(log.outputs(p0), before, "-A off глушит панель")
        let screen = try await c.run("capture-pane -p -J -t \(p0)").joined(separator: "\n")
        XCTAssertTrue(screen.contains("one"))
    }

    /// `pause` глушит вывод, но не останавливает чтение панели: процесс в панели доходит до конца.
    /// `off` при единственном клиенте останавливает чтение — поэтому приложение для скрытых панелей берёт `pause`.
    func testPauseDoesNotBlockPaneButOffDoes() async throws {
        let log = EventLog()
        let c = try connect(events: log)
        defer { c.stop() }
        let ids = try paneIDs()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-\(socket)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pausedDone = dir.appendingPathComponent("paused").path
        let offDone = dir.appendingPathComponent("off").path
        try await c.run("refresh-client -A '\(ids[0]):pause'")
        try await c.run("refresh-client -A '\(ids[1]):off'")
        let flood = "head -c 20000000 /dev/zero | tr '\\\\0' a"
        try await c.run("send-keys -t \(ids[0]) " + TmuxQuote.word("\(flood); touch \(pausedDone)") + " Enter")
        try await c.run("send-keys -t \(ids[1]) " + TmuxQuote.word("\(flood); touch \(offDone)") + " Enter")
        let ok2 = await waitFor(15) { FileManager.default.fileExists(atPath: pausedDone) }
        XCTAssertTrue(ok2, "панель на паузе продолжает работать")
        XCTAssertFalse(FileManager.default.fileExists(atPath: offDone), "панель с off встала на записи")
        try await c.run("refresh-client -A '\(ids[1]):on'")
        let ok3 = await waitFor(15) { FileManager.default.fileExists(atPath: offDone) }
        XCTAssertTrue(ok3)
    }

    /// pause-after: отстали от панели — приходит %pause, после continue вывод идёт снова.
    func testPauseAfterAndContinue() async throws {
        let log = EventLog()
        let c = ControlClient(tmuxPath: tmux, socketName: socket)
        let gate = Gate()
        try c.start(session: "team-x", onEvent: { e in
            gate.waitIfClosed()
            log.add(e)
        }, onExit: {})
        defer { c.stop() }
        let p0 = try paneIDs()[0]
        try await c.run("refresh-client -f pause-after=1")
        // %pause приходит, только если у сервера к моменту записи клиенту накопился вывод старше секунды. Под нагрузкой
        // вывод панели мог не обогнать буфер сокета, поэтому попытка повторяется (до трёх раз): это свойство tmux, а не гонка кода.
        var ok4 = false
        for _ in 0..<3 where !ok4 {
            gate.close()        // перестаём читать поток: tmux копит вывод для клиента
            try sh(["send-keys", "-t", p0, "seq 1 30000000", "Enter"])
            await pause(2.5)
            gate.open()
            ok4 = await waitFor(8) { log.paused(p0) }
            try sh(["send-keys", "-t", p0, "C-c"])
            if !ok4 { await pause(0.5) }
        }
        XCTAssertTrue(ok4, "пришёл %pause")
        let before = log.outputs(p0)
        try await c.run("refresh-client -A '\(p0):continue'")
        try sh(["send-keys", "-t", p0, "echo after", "Enter"])
        let ok5 = await waitFor(10) { log.outputs(p0) > before }
        XCTAssertTrue(ok5, "после continue вывод панели идёт снова")
    }

    /// Отправка менеджеру: текст владельца через буфер tmux, затем Enter. В панели вместо claude — cat.
    @MainActor
    func testSendTextRoundTripWithCat() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        XCTAssertTrue(hub.connected)
        XCTAssertEqual(hub.attachedSession, "team-x")
        XCTAssertEqual(hub.agentCounts["team-x"], 2)
        let p1 = try paneIDs()[1]
        try await runInPane(p1, "cat")
        let text = "; $HOME ' \" \\ # ~ {} #{pane_id} кириллица 🙂"
        try await hub.sendMessage(text: text, images: [], to: p1, enterDelay: 0.2)
        _ = await waitMain(15) { self.screenOf(p1).split(separator: "\n").filter { $0.contains("кириллица") }.count >= 2 }
        let screen = screenOf(p1)
        let echoed = screen.split(separator: "\n").filter { $0.contains("кириллица") }
        XCTAssertGreaterThanOrEqual(echoed.count, 2, "cat повторил строку после Enter: \(screen)")
        XCTAssertTrue(echoed.allSatisfy { $0.trimmingCharacters(in: .whitespaces) == text }, screen)
    }

    /// Кеш status сказал «ждёт человека» — один захват сверяет с экраном; дальше признаки считает приложение.
    @MainActor
    func testConfirmWaitingCapturesOnceForUnseenPane() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        XCTAssertFalse(hub.hasCapture(p1))
        hub.confirmWaiting(p1)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(hub.hasCapture(p1))
        XCTAssertFalse(hub.hasLiveCapture(p1), "панель не подписана: просто один захват")
        XCTAssertFalse(hub.output(for: p1).needsHuman, "обычный экран не вопрос")
    }

    /// Панель считается захваченной вживую, только пока она на экране и захват уже был.
    @MainActor
    func testLiveCaptureOnlyWhileShown() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        XCTAssertFalse(hub.hasLiveCapture(p1))
        hub.show(p1, detail: .grid)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(hub.hasLiveCapture(p1))
        hub.hide(p1, detail: .grid)
        XCTAssertFalse(hub.hasLiveCapture(p1))
    }

    /// Клавиши уходят в панель как с клавиатуры: Escape — байт 0x1B, цифра и стрелка — свои коды.
    @MainActor
    func testSendKeysDeliverEscapeDigitAndArrow() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        try await runInPane(p1, "cat -v")
        try await hub.sendKeys(["Escape", "1", "Down", "Enter"], to: p1)
        _ = await waitMain(15) { self.screenOf(p1).contains("^[1^[") }
        let screen = screenOf(p1)
        XCTAssertTrue(screen.contains("^[1^[[B") || screen.contains("^[1^[OB"), "Escape, 1, Down: \(screen)")
    }

    /// Текст, который нельзя набрать («#» и «!» в начале — режимы ввода Claude Code), уходит одной вставкой (bracketed paste)
    /// с переносами и пустой строкой, а Enter один раз, после закрывающей последовательности: по первой строке не отправляется.
    /// В панели приложение, включившее режим вставки (как Claude Code), пишет всё, что получило, в файл.
    @MainActor
    func testMultilineSendArrivesAsOnePaste() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-paste-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try await runInPane(p1, setup: "printf '\\033[?2004h';", "cat > '\(file.path)'")
        let text = "# первая строка\nвторая\n\nтретья\tс табуляцией"
        try await hub.sendMessage(text: text, images: [], to: p1, enterDelay: 0.2)
        _ = await waitMain(15) { self.fileText(file).hasSuffix("\u{1b}[201~\n") }
        try sh(["send-keys", "-t", p1, "C-d"])
        let got = fileText(file)
        let start = "\u{1b}[200~", end = "\u{1b}[201~"
        let a = try XCTUnwrap(got.range(of: start), "нет начала вставки: \(got.debugDescription)")
        let b = try XCTUnwrap(got.range(of: end), "нет конца вставки: \(got.debugDescription)")
        XCTAssertEqual(String(got[a.upperBound..<b.lowerBound]), text, "текст вставки: \(got.debugDescription)")
        XCTAssertEqual(String(got[b.upperBound...]), "\n", "после вставки ровно один Enter")
        XCTAssertEqual(got.components(separatedBy: start).count, 2, "одна вставка, а не по строке")
    }

    /// Сообщение с картинками: каждый путь — своя вставка целиком, затем текст набирается клавишами; Enter только при `submit`.
    @MainActor
    func testSendMessageWithImagesPastesEachPathSeparately() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-img-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try await runInPane(p1, setup: "printf '\\033[?2004h';", "cat > '\(file.path)'")
        let a = URL(fileURLWithPath: "/tmp/agt-cache/a1.png"), b = URL(fileURLWithPath: "/tmp/agt-cache/b2.jpg")
        try await hub.sendMessage(text: "что на снимках", images: [a, b], to: p1, imageDelay: 0.1, enterDelay: 0.2)
        _ = await waitMain(15) { self.fileText(file).hasSuffix("что на снимках\n") }
        try sh(["send-keys", "-t", p1, "C-d"])
        let got = fileText(file)
        let start = "\u{1b}[200~", end = "\u{1b}[201~"
        XCTAssertEqual(got, start + a.path + end + start + b.path + end + " что на снимках" + "\n", got.debugDescription)
    }

    /// Сообщение владельца набирается клавишами, без вставки: переносы — Meta-Enter, текст целиком, спецсимволы и
    /// длинный текст доходят, Enter один. Панель в сыром режиме пишет всё, что получила, в файл.
    @MainActor
    func testOwnerMessageIsTypedNotPasted() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-type-\(UUID().uuidString.prefix(8)).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try await runInPane(p1, setup: "stty raw -echo;", "cat > '\(file.path)'")
        let long = (0..<700).map { "слово\($0)" }.joined(separator: " ")
        let text = "первая строка\n\nвторая; 'в кавычках' \"двойные\" $HOME `cmd` \\ #{x} ~\tтаб 🙂\n\(long)"
        let started = Date()
        try await hub.sendMessage(text: text, images: [], to: p1, enterDelay: 0.1)
        let sendTime = Date().timeIntervalSince(started)
        let expected = text.replacingOccurrences(of: "\t", with: "    ").replacingOccurrences(of: "\n", with: "\u{1b}\r") + "\r" + "\u{04}"   // Enter и наш же C-d
        _ = await waitMain(15) { self.fileText(file).count >= expected.count - 1 }
        try sh(["send-keys", "-t", p1, "C-d"])
        _ = await waitMain(15) { self.fileText(file).hasSuffix("\u{04}") }
        let got = fileText(file)
        XCTAssertFalse(got.contains("\u{1b}[200~"), "вставки (bracketed paste) нет")
        let diff = zip(got, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        XCTAssertTrue(got == expected, "длины \(got.count)/\(expected.count), первое расхождение: \(diff.map(String.init) ?? "нет"), вокруг: \(diff.map { String(got.dropFirst(max(0, $0 - 20)).prefix(60)).debugDescription } ?? "")")
        XCTAssertLessThan(sendTime, 3, "набор 5 тысяч знаков занял \(sendTime) с")
        print("TYPE-TIME \(text.count) знаков: \(String(format: "%.3f", sendTime)) с")
    }

    /// Хаб: видимая панель получает вывод и захват; скрытая — на паузе; смена сессии по тому же каналу.
    @MainActor
    func testHubStreamsOnlyVisiblePanes() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let ids = try paneIDs()
        hub.show(ids[0], detail: .grid)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(hub.streamingPanes, [ids[0]])
        try sh(["send-keys", "-t", ids[0], "printf '\\033[32mGREEN\\033[0m\\n'", "Enter"])
        var ok = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if hub.output(for: ids[0]).lines.contains(where: { $0.plain == "GREEN" }) { ok = true; break }
        }
        XCTAssertTrue(ok, "захват видимой панели обновился")
        let green = hub.output(for: ids[0]).lines.first { $0.plain == "GREEN" }
        XCTAssertEqual(green?.runs.first?.style.fg, .indexed(2))
        XCTAssertNotNil(hub.output(for: ids[0]).lastOutput)
        hub.hide(ids[0], detail: .grid)
        XCTAssertTrue(hub.streamingPanes.isEmpty)
        await hub.connect(preferring: "team-y")
        XCTAssertEqual(hub.attachedSession, "team-y")
    }
}

extension TmuxIntegrationTests {
    /// Сервер tmux пропал — соединения нет, хаб ждёт сервер, а не крутится в переподключениях.
    @MainActor
    func testHubSurvivesServerExit() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        XCTAssertTrue(hub.connected)
        try sh(["kill-server"])
        var gone = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if !hub.connected { gone = true; break }
        }
        XCTAssertTrue(gone)
        XCTAssertNil(hub.attachedSession)
        hub.disconnect()
    }
}

extension TmuxIntegrationTests {
    /// Панель не на экране (pause): %output нет, но подписка сообщает об активности — по ней обновляется status.
    @MainActor
    func testActivityOfPausedPane() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        var active: [String] = []
        hub.onPaneActivity = { active.append($0) }
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let p1 = try paneIDs()[1]
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(hub.streamingPanes.contains(p1))
        XCTAssertTrue(active.isEmpty, "первое значение подписки — не активность")
        try sh(["send-keys", "-t", p1, "seq 1 60", "Enter"])
        var ok = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if active.contains(p1) { ok = true; break }
        }
        XCTAssertTrue(ok, "активность скрытой панели пришла событием")
        XCTAssertNotNil(hub.output(for: p1).lastOutput)
    }
}

extension TmuxIntegrationTests {
    func clientPIDs() throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "tmux -u -L \(socket) -N -C attach-session"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
    }

    func leftoverProcesses() throws -> Int {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "tmux( -u)? -L \(socket) "]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").count
    }

    @MainActor
    func waitUntil(_ timeout: TimeInterval = 8, _ cond: @escaping () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return cond()
    }

    /// После выхода сервера и disconnect не остаётся ни клиентов, ни сервера, поднятого attach-session.
    @MainActor
    func testNoLeftoverProcessesAfterServerExit() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        try sh(["kill-server"])
        let gone = await waitUntil { !hub.connected }
        XCTAssertTrue(gone)
        hub.disconnect()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(try leftoverProcesses(), 0)
    }

    /// Новый клиент после %exit ничего не знает о прежних паузах: скрытая панель снова получает pause.
    @MainActor
    func testReconnectPausesHiddenPanesAgain() async throws {
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let ids = try paneIDs()
        let paused1 = await waitUntil { hub.pausedPanes.isSuperset(of: Set(ids)) }
        XCTAssertTrue(paused1)
        // Убить только клиент: сервер жив, хаб переподключается сам новым процессом.
        let before = try clientPIDs()
        XCTAssertEqual(before.count, 1)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/kill")
        p.arguments = before
        try p.run()
        p.waitUntilExit()
        let replaced = await waitUntil(6) { ((try? self.clientPIDs()) ?? []).first.map { !before.contains($0) } ?? false }
        XCTAssertTrue(replaced, "поднят новый клиент")
        let back = await waitUntil(6) { hub.connected && hub.pausedPanes.isSuperset(of: Set(ids)) }
        XCTAssertTrue(back, "после переподключения скрытые панели снова на паузе")
        // Проверка самого tmux, а не учёта приложения: сырые %output от скрытой панели не приходят.
        let hidden = ids[1]
        try await Task.sleep(nanoseconds: 500_000_000)
        let before2 = hub.rawOutputCount[hidden] ?? 0
        try sh(["send-keys", "-t", hidden, "seq 1 300", "Enter"])
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(hub.rawOutputCount[hidden] ?? 0, before2, "скрытая панель после переподключения на паузе в tmux")
        let flags = try await hub.run("display-message -p '#{client_flags}'").joined()
        XCTAssertTrue(flags.contains("pause-after=5"), flags)
        XCTAssertFalse(flags.contains("no-output"), flags)
    }

    /// Сессий team-* нет — к чужой сессии владельца клиент не прикрепляется (tmux без -t бил бы в неё);
    /// проект появился — проверка list-sessions его видит, и хаб прикрепляется к нему.
    @MainActor
    func testNeverAttachesToForeignSession() async throws {
        try sh(["kill-session", "-t", "team-x"])
        try sh(["kill-session", "-t", "team-y"])
        try sh(["new-session", "-d", "-s", "user-work", "sh"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        hub.pollInterval = 0.5
        await hub.connect(preferring: "team-z")
        defer { hub.disconnect() }
        XCTAssertFalse(hub.connected)
        XCTAssertNil(hub.attachedSession)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(try sh(["list-clients", "-t", "user-work", "-F", "#{client_name}"]).trimmingCharacters(in: .whitespacesAndNewlines), "",
                       "в чужой сессии нет нашего клиента")
        try sh(["new-session", "-d", "-s", "team-z", "sh"])
        let attached = await waitUntil(4) { hub.attachedSession == "team-z" }
        XCTAssertTrue(attached, "проект найден проверкой и подключён")
        let flags = try await hub.run("display-message -p '#{client_flags}'").joined()
        XCTAssertTrue(flags.contains("pause-after=5"), flags)
        XCTAssertEqual(try sh(["list-clients", "-t", "user-work", "-F", "#{client_name}"]).trimmingCharacters(in: .whitespacesAndNewlines), "")
        // Видимая панель обновляется по %output.
        let pane = try sh(["list-panes", "-t", "team-z", "-F", "#{pane_id}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        hub.show(pane, detail: .grid)
        try await Task.sleep(nanoseconds: 500_000_000)
        try sh(["send-keys", "-t", pane, "echo AFTER-SWITCH", "Enter"])
        let fresh = await waitUntil { hub.output(for: pane).lines.contains { $0.plain == "AFTER-SWITCH" } }
        XCTAssertTrue(fresh)
    }

    /// Закрыли последнюю сессию проекта — tmux переводит клиент в чужую сессию; хаб сразу уходит из неё.
    @MainActor
    func testLeavesForeignSessionWhenProjectCloses() async throws {
        try sh(["kill-session", "-t", "team-y"])
        try sh(["new-session", "-d", "-s", "user-work", "sh"])
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        hub.pollInterval = 0.5
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        XCTAssertEqual(hub.attachedSession, "team-x")
        try sh(["kill-session", "-t", "team-x"])
        let left = await waitUntil(4) { !hub.connected }
        XCTAssertTrue(left)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(try sh(["list-clients", "-t", "user-work", "-F", "#{client_name}"]).trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// Агент уже стоит на вопросе о доверии до подключения и молчит: разовый захват при открытии проекта
    /// находит вопрос, хотя панель не на экране; новая панель проверяется так же.
    @MainActor
    func testSilentTrustPromptFoundOnOpen() async throws {
        let ids = try paneIDs()
        try sh(["send-keys", "-t", ids[1], "clear; printf ' Do you trust the files in this folder?\\n 1. Yes\\n'", "Enter"])
        _ = await waitMain(15) { self.screenOf(ids[1]).split(separator: "\n").contains { $0 == " 1. Yes" } }
        let hub = TmuxHub(tmuxPath: tmux, socketName: socket)
        await hub.connect(preferring: "team-x")
        defer { hub.disconnect() }
        let found = await waitUntil { hub.output(for: ids[1]).asksTrust }
        XCTAssertTrue(found, "вопрос о доверии у скрытой молчащей панели")
        XCTAssertFalse(hub.streamingPanes.contains(ids[1]))
        let fresh = try sh(["split-window", "-t", "team-x", "-P", "-F", "#{pane_id}",
                            "printf ' Do you want to proceed?\\n ❯ 1. Yes\\n'; sleep 30"]).trimmingCharacters(in: .whitespacesAndNewlines)
        try sh(["set-option", "-p", "-t", fresh, "@team_role", "dev#2"])
        let asked = await waitUntil(5) { hub.output(for: fresh).asksPermission }
        XCTAssertTrue(asked, "запрос права у новой панели")
    }

    /// Выбран проект, которого ещё нет в tmux; после team up приложение прикрепляется к нему, а не к прежнему.
    @MainActor
    func testSelectedStoppedProjectAttachesAfterTeamUp() async throws {
        let defaults = UserDefaults(suiteName: "agtest-app-\(getpid())")!
        defer { defaults.removePersistentDomain(forName: "agtest-app-\(getpid())") }
        let app = AppModel(defaults: defaults, socketName: socket)
        await app.start(preferredProject: "x")
        defer { app.hub.disconnect() }
        XCTAssertEqual(app.hub.attachedSession, "team-x")
        app.select("team-z")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(app.hub.attachedSession, "team-x", "пока проекта нет — прежнее прикрепление")
        try sh(["new-session", "-d", "-s", "team-z", "sh"])
        let attached = await waitUntil { app.hub.attachedSession == "team-z" }
        XCTAssertTrue(attached)
    }

    /// Запись в умерший tmux -C не убивает процесс (SIGPIPE игнорируется), команды получают ошибку.
    func testWriteToDeadClientDoesNotCrash() async throws {
        let c = ControlClient(tmuxPath: tmux, socketName: socket)
        try c.start(session: "team-x", onEvent: { _ in }, onExit: {})
        try sh(["kill-server"])
        try await Task.sleep(nanoseconds: 500_000_000)
        for _ in 0..<20 { c.fire("list-panes") }
        do {
            _ = try await c.run("list-panes")
            XCTFail("ожидалась ошибка")
        } catch {}
        c.stop()
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ControlEvent] = []
    func add(_ e: ControlEvent) { lock.withLock { events.append(e) } }
    func outputs(_ pane: String) -> Int { lock.withLock { events.filter { $0 == .output(pane: pane) }.count } }
    func paused(_ pane: String) -> Bool { lock.withLock { events.contains(.pause(pane: pane)) } }
    func resumed(_ pane: String) -> Bool { lock.withLock { events.contains(.resumed(pane: pane)) } }
}

/// Задержка обработчика событий: имитирует клиента, который не успевает читать поток.
final class Gate: @unchecked Sendable {
    private let cond = NSCondition()
    private var closed = false
    func close() { cond.lock(); closed = true; cond.unlock() }
    func open() { cond.lock(); closed = false; cond.broadcast(); cond.unlock() }
    func waitIfClosed() { cond.lock(); while closed { cond.wait() }; cond.unlock() }
}
