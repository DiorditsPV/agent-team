import XCTest
@testable import AgentTeamCore

/// Статус агента совпадает с тем, что он делает. Образцы — структура реальных транскриптов Claude Code
/// (типы и подтипы записей, служебные признаки, время), без текстов переписки и имён проектов.
final class HonestStatusTests: XCTestCase {
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func at(_ hms: String) -> Date { iso.date(from: "2026-10-17T\(hms).000Z")! }

    private func rec(_ type: String, _ hms: String, _ extra: String = "") -> String {
        #"{"type":"\#(type)","uuid":"u\#(hms)","timestamp":"2026-10-17T\#(hms).000Z"\#(extra.isEmpty ? "" : "," + extra)}"#
    }
    private func user(_ hms: String, _ text: String, meta: Bool = false, extra: String = "") -> String {
        rec("user", hms, #""isMeta":\#(meta),"message":{"role":"user","content":"\#(text)"}"# + (extra.isEmpty ? "" : "," + extra))
    }
    private func result(_ hms: String, id: String = "t1") -> String {
        rec("user", hms, #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}"#)
    }
    private func assistant(_ hms: String, tool: String? = nil, id: String = "t1", extra: String = "") -> String {
        let block = tool.map { #"{"type":"tool_use","id":"\#(id)","name":"\#($0)","input":{}}"# } ?? #"{"type":"text","text":"ответ"}"#
        return rec("assistant", hms, #""message":{"role":"assistant","content":[\#(block)]}"# + (extra.isEmpty ? "" : "," + extra))
    }
    private func turnEnd(_ hms: String) -> String { rec("system", hms, #""subtype":"turn_duration","durationMs":1"#) }

    private func read(_ lines: [String], windows: [UInt64]? = nil) throws -> AgentActivity? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("honest-" + UUID().uuidString + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return AgentActivity.read(url: url, windows: windows)
    }

    // MARK: чтение файла

    /// Окно чтения начинается посреди многобайтовой буквы: раньше String(data:) возвращал nil, и статус откатывался
    /// на «работает» по перерисовке панели (агент простаивал с конца хода).
    func testWindowCutInsideCyrillicLetterStillReads() throws {
        for pad in 0..<4 {
            // Хвост файла — длинная служебная запись по-русски: окно в 150 байт режет её посреди буквы (буква — 2 байта).
            let tail = rec("system", "09:40:00", #""subtype":"away_summary","content":"\#(String(repeating: "я", count: 200 + pad))""#)
            let lines = [user("09:30:00", "задача"), assistant("09:31:00"), turnEnd("09:32:00"), tail]
            let a = try XCTUnwrap(read(lines, windows: [150, 1 << 20]), "pad \(pad)")
            XCTAssertFalse(a.inTurn, "pad \(pad)")
            XCTAssertEqual(a.lastAction, at("09:32:00"), "pad \(pad)")
        }
    }

    /// Начало хода лежит дальше первого окна: окно растёт, а результат прежнего окна без начала не выдаётся.
    func testWindowGrowsUntilTurnBoundary() throws {
        let big = result("10:01:00").replacingOccurrences(of: #""content":"ok""#, with: #""content":"\#(String(repeating: "ы", count: 600))""#)
        let lines = [turnEnd("09:00:00"), user("10:00:00", "долгая задача"), big, assistant("10:02:00", tool: "Bash", id: "t2")]
        let a = try XCTUnwrap(read(lines, windows: [300, 1 << 20]))
        XCTAssertTrue(a.inTurn)
        XCTAssertEqual(a.turnStart, at("10:00:00"))
    }

    func testNoActionRecordsMeansNoData() throws {
        XCTAssertNil(try read([#"{"type":"last-prompt"}"#, #"{"type":"custom-title","customTitle":"x"}"#]))
    }

    // MARK: что считается ходом

    /// Плановый запуск: system scheduled_task_fire и служебный (isMeta) промпт после turn_duration. Раньше ход
    /// «заканчивался» на прежнем turn_duration, и долгий плановый ход выглядел простоем.
    func testScheduledTaskStartsTurn() throws {
        let a = try XCTUnwrap(read([
            turnEnd("10:00:00"),
            rec("system", "10:30:00", #""subtype":"scheduled_task_fire""#),
            user("10:30:00", "плановая сверка", meta: true),
            assistant("10:30:05", tool: "Bash"),
        ]))
        XCTAssertTrue(a.inTurn)
        XCTAssertEqual(a.turnStart, at("10:30:00"))
    }

    /// Сводка сжатия — не сообщение: агент, сжавший контекст в простое, не в ходе (раньше «ход» длился часами).
    func testCompactSummaryIsNotATurn() throws {
        let a = try XCTUnwrap(read([
            user("10:00:00", "задача"), assistant("10:01:00"),
            user("10:05:00", "This session is being continued", extra: #""isCompactSummary":true"#),
            rec("attachment", "10:05:00", #""attachment":{"type":"file"}"#),
            rec("system", "10:05:00", #""subtype":"informational""#),
        ]))
        XCTAssertFalse(a.inTurn)
        XCTAssertNil(a.turnStart)
    }

    /// Сжатие посреди хода: агент продолжил отвечать — ход идёт.
    func testAnswersAfterCompactionStayInTurn() throws {
        let a = try XCTUnwrap(read([
            user("10:00:00", "задача"),
            user("10:05:00", "This session is being continued", extra: #""isCompactSummary":true"#),
            assistant("10:05:10", tool: "Bash"),
        ]))
        XCTAssertTrue(a.inTurn)
        XCTAssertEqual(a.turnStart, at("10:05:10"))
    }

    func testInterruptEndsTurn() throws {
        let a = try XCTUnwrap(read([
            user("10:00:00", "задача"), assistant("10:01:00", tool: "Bash"),
            rec("user", "10:02:00", #""message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}"#),
        ]))
        XCTAssertFalse(a.inTurn)
        XCTAssertEqual(a.lastAction, at("10:02:00"))
    }

    func testApiErrorAnswerEndsTurn() throws {
        let a = try XCTUnwrap(read([user("10:00:00", "задача"), assistant("10:01:00", extra: #""isApiErrorMessage":true"#)]))
        XCTAssertFalse(a.inTurn)
    }

    /// Команды владельца в самом Claude Code (`/model`, `!ls`) и их вывод — не ход агента и не его действие.
    func testOwnerCommandsAreNotTurnsOrActions() throws {
        let a = try XCTUnwrap(read([
            user("10:00:00", "задача"), assistant("10:01:00"), turnEnd("10:01:05"),
            rec("system", "10:30:00", #""subtype":"local_command""#),
            user("10:30:00", "<local-command-caveat>The command below</local-command-caveat>", meta: true),
            user("10:30:01", "<command-name>/model</command-name>"),
            user("10:30:01", "<local-command-stdout>Set model</local-command-stdout>"),
            user("10:31:00", "<bash-stdout>ok</bash-stdout>"),
        ]))
        XCTAssertFalse(a.inTurn)
        XCTAssertEqual(a.lastAction, at("10:01:05"), "простой считается от конца хода, а не от команды владельца")
    }

    /// Служебные записи после конца хода (сводка «пока вас не было», напоминание о токенах) действием не считаются.
    func testServiceRecordsDoNotRefreshLastAction() throws {
        let a = try XCTUnwrap(read([
            user("10:00:00", "задача"), assistant("10:01:00"), turnEnd("10:01:05"),
            rec("system", "10:20:00", #""subtype":"away_summary""#),
            rec("attachment", "10:20:01", #""attachment":{"type":"total_tokens_reminder"}"#),
            rec("queue-operation", "10:25:00", #""operation":"enqueue""#),
        ]))
        XCTAssertFalse(a.inTurn)
        XCTAssertEqual(a.lastAction, at("10:01:05"))
    }

    /// Уведомление о фоновой задаче после конца хода: агент получил его и работает (ответ уже есть) либо вот-вот начнёт.
    func testTaskNotificationAfterTurnStartsTurn() throws {
        let pending = try XCTUnwrap(read([turnEnd("10:00:00"), user("10:10:00", "<task-notification><task-id>x</task-id></task-notification>")]))
        XCTAssertTrue(pending.inTurn)
        XCTAssertEqual(pending.turnStart, at("10:10:00"))
        let answered = try XCTUnwrap(read([turnEnd("10:00:00"), user("10:10:00", "<task-notification></task-notification>"),
                                           assistant("10:10:03", tool: "Bash"), turnEnd("10:10:30")]))
        XCTAssertFalse(answered.inTurn)
    }

    /// Сообщение, пришедшее в идущий ход (queued_command), не сдвигает его начало.
    func testQueuedCommandDoesNotShortenTurn() throws {
        let a = try XCTUnwrap(read([
            turnEnd("09:00:00"), user("10:00:00", "задача"), assistant("10:00:10", tool: "Bash"), result("10:01:00"),
            rec("attachment", "10:02:00", #""attachment":{"type":"queued_command"}"#),
            assistant("10:02:05", tool: "Bash", id: "t2"),
        ]))
        XCTAssertTrue(a.inTurn)
        XCTAssertEqual(a.turnStart, at("10:00:00"))
    }

    func testPendingAskUntilAnswered() throws {
        let open = try XCTUnwrap(read([user("10:00:00", "задача"), assistant("10:01:00", tool: "AskUserQuestion", id: "q1")]))
        XCTAssertTrue(open.pendingAsk)
        let answered = try XCTUnwrap(read([user("10:00:00", "задача"), assistant("10:01:00", tool: "AskUserQuestion", id: "q1"),
                                           result("10:05:00", id: "q1"), assistant("10:05:10")]))
        XCTAssertFalse(answered.pendingAsk)
    }

    // MARK: сессия продолжена в новой

    func testLocateFollowsContinuedInChain() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("honest-home-" + UUID().uuidString).path
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects/" + TranscriptParser.projectSlug(cwd: "/work/p"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ id: String, _ lines: [String]) throws {
            try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent(id + ".jsonl"), atomically: true, encoding: .utf8)
        }
        try write("s1", [user("09:00:00", "a"), #"{"type":"continued-in","timestamp":"2026-10-17T09:01:00.000Z","sessionId":"s1","continuedInSessionId":"s2"}"#])
        try write("s2", [user("10:00:00", "b"), #"{"type":"continued-in","timestamp":"2026-10-17T10:01:00.000Z","sessionId":"s2","continuedInSessionId":"s3"}"#])
        try write("s3", [user("11:00:00", "c")])
        XCTAssertEqual(TranscriptParser.locate(cwd: "/work/p", sessionID: "s1", home: home)?.lastPathComponent, "s3.jsonl")
        // Цепочка в кольцо не зацикливает.
        try write("s3", [user("11:00:00", "c"), #"{"type":"continued-in","timestamp":"2026-10-17T11:01:00.000Z","sessionId":"s3","continuedInSessionId":"s1"}"#])
        XCTAssertNotNil(TranscriptParser.locate(cwd: "/work/p", sessionID: "s1", home: home))
        // Нового файла нет — остаёмся на найденном.
        try write("s4", [#"{"type":"continued-in","timestamp":"2026-10-17T11:01:00.000Z","sessionId":"s4","continuedInSessionId":"gone"}"#])
        XCTAssertEqual(TranscriptParser.locate(cwd: "/work/p", sessionID: "s4", home: home)?.lastPathComponent, "s4.jsonl")
    }

    // MARK: состояние

    @MainActor
    func testStateNeverClaimsWorkWithoutEvidence() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-honest", session: "team-honest", cli: nil)
        let a = Agent(name: "optimizer#1", role: "optimizer", alive: true, idleS: 21)   // idle_s один на всю сессию tmux
        let now = at("12:00:00")
        // Нет транскрипта и нет хода на экране.
        XCTAssertEqual(m.state(of: a, asksTrust: false, now: now), .noData)
        // Ход закончен минуту назад: «простаивает», а не «работает» до порога в две минуты.
        let justEnded = AgentActivity(lastAction: now - 50, inTurn: false)
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: justEnded, now: now), .quiet(minutes: 0))
        XCTAssertEqual(AgentTime.label(.quiet(minutes: 0), activity: justEnded, now: now), "простаивает · <1 мин")
        // Ход «идёт» по транскрипту, но записей нет полчаса и больше (прерван или сжатие): не работает.
        let stale = AgentActivity(lastAction: now - 3 * 3600, inTurn: true, turnStart: now - 3 * 3600)
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: stale, now: now), .quiet(minutes: 180))
        XCTAssertFalse(AgentTime.tooltip(started: nil, activity: stale, now: now).contains("Текущий ход: 3"), "давний ход в подсказке не показывается")
        // Строка хода на экране — свидетельство работы и источник длительности, даже когда транскрипта нет.
        let turn = TurnStatus(verb: "Vibing", seconds: 206)
        XCTAssertEqual(m.state(of: a, asksTrust: false, screenTurn: turn, activity: nil, now: now), .working)
        XCTAssertEqual(AgentTime.label(.working, activity: nil, screenTurn: turn, now: now), "работает · 3 мин")
        // Долгий инструмент: транскрипт молчит, но на экране ход идёт.
        XCTAssertEqual(m.state(of: a, asksTrust: false, screenTurn: turn, activity: stale, now: now), .working)
    }

    @MainActor
    func testPendingAskWaitsUnlessScreenIsLive() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-honest2", session: "team-honest2", cli: nil)
        let a = Agent(name: "manager#1", role: "manager", alive: true)
        let now = at("12:00:00")
        let ask = AgentActivity(lastAction: now - 600, inTurn: true, turnStart: now - 900, pendingAsk: true)
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: ask, now: now), .waiting("ждёт ответа"))
        XCTAssertEqual(AgentTime.label(.waiting("ждёт ответа"), activity: ask, now: now), "ждёт ответа · 10 мин")
        // Вопрос на экране: подпись по транскрипту — вопрос, а не запрос права.
        XCTAssertEqual(m.state(of: a, asksTrust: false, asksPermission: true, liveKnown: true, activity: ask, now: now), .waiting("ждёт ответа"))
        XCTAssertEqual(m.state(of: a, asksTrust: false, asksPermission: true, liveKnown: true, activity: nil, now: now), .waiting("ждёт права"))
        // Экран снят только что и вопроса на нём нет — владелец уже ответил, транскрипт отстаёт.
        XCTAssertNotEqual(m.state(of: a, asksTrust: false, liveKnown: true, activity: ask, now: now), .waiting("ждёт ответа"))
    }

    @MainActor
    func testSingleQuestionFromStatusIsAnAnswerNotAPermission() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-honest3", session: "team-honest3", cli: nil)
        var a = Agent(name: "manager#1", role: "manager", alive: true)
        let now = at("12:00:00")
        // Одиночный вопрос: в транскрипте вызова ещё нет, ход идёт.
        let silent = AgentActivity(lastAction: now - 30, inTurn: true, turnStart: now - 60, pendingAsk: false)
        XCTAssertEqual(m.state(of: a, asksTrust: false, asksPermission: true, liveKnown: true, activity: silent, now: now), .waiting("ждёт права"),
                       "без хука форма на экране неотличима от вопроса о праве")
        a.question = PendingQuestion(id: "toolu_1", questions: [.init(header: "", text: "Как выкатываем?",
                                                                       options: [.init(label: "Сразу"), .init(label: "Отложить")])])
        XCTAssertEqual(m.state(of: a, asksTrust: false, asksPermission: true, liveKnown: true, activity: silent, now: now), .waiting("ждёт ответа"))
        XCTAssertEqual(m.state(of: a, asksTrust: false, activity: silent, now: now), .waiting("ждёт ответа"), "панель не захвачена")
        // Свежий захват без формы: владелец уже ответил, кеш status отстаёт.
        XCTAssertEqual(m.state(of: a, asksTrust: false, liveKnown: true, activity: silent, now: now), .working)
    }

    /// Подсказка «Enter to select · … · Esc to cancel» в узкой панели переносится на вторую строку.
    func testWrappedAskHintIsFound() {
        let narrow = ["  5. Type something.", "  6. Chat about this", "", "Enter to select · ↑/↓ to navigate · Esc", "to cancel", ""]
        XCTAssertTrue(PaneTail.asksPermission(narrow))
        XCTAssertFalse(PaneTail.asksPermission(["обычный вывод", "Esc to cancel"]))
    }
}

/// Единый расчёт статуса: экран панели учитывается только на свежем снимке.
final class AgentStatusCalcTests: XCTestCase {
    @MainActor
    func testScreenTurnCountsOnlyOnLiveCapture() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-calc", session: "team-calc", cli: nil)
        let a = Agent(name: "developer#1", role: "developer", alive: true)
        let pane = PaneOutput(paneID: "%1")
        pane.turn = TurnStatus(verb: "Vibing", seconds: 125)
        let now = Date()
        pane.lastOutput = now - 1
        let live = m.agentStatus(a, pane: pane, liveKnown: true, now: now)
        XCTAssertEqual(live.state, .working)
        XCTAssertEqual(live.label, "работает · 2 мин")
        XCTAssertTrue(live.tooltip.contains("(по экрану)"), live.tooltip)
        // Снимок не свежий — строке хода не верим, транскрипта нет.
        XCTAssertEqual(m.agentStatus(a, pane: pane, liveKnown: false, now: now).state, .noData)
        // Панель давно ничего не выводит, а спиннер анимирован: замерший кадр — не работа.
        pane.lastOutput = now - 300
        XCTAssertEqual(m.agentStatus(a, pane: pane, liveKnown: true, now: now).state, .noData)
        XCTAssertEqual(m.agentStatus(a, now: now).label, "нет данных")
    }

    @MainActor
    func testActivityPollStopsWhenSuspended() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-poll-" + UUID().uuidString, session: "team-poll", cli: nil)
        m.start()
        XCTAssertTrue(m.hasLiveWatchers)
        m.suspend()
        XCTAssertFalse(m.hasLiveWatchers, "невыбранный проект не опрашивает транскрипты")
        m.stop()
    }
}
