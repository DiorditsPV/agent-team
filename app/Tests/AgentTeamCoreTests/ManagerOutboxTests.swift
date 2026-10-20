import XCTest
@testable import AgentTeamCore

/// Подставная панель менеджера: записывает, что в неё ушло, и отдаёт заданное состояние экрана.
@MainActor
private final class FakePane: ManagerPaneWriter {
    var messages: [String] = []
    var keys: [[String]] = []
    var literals: [String] = []
    var state = ManagerPaneState()
    var failNext = false
    var failAll = false
    /// Команда («/…») открывает свой экран, как в Claude Code: признак `commandScreen` до закрытия.
    var commandsOpenScreens = false

    func writeMessage(text: String, images: [URL], to pane: String) async throws {
        if failNext || failAll { failNext = false; throw ControlError.notConnected }
        messages.append(text)
        if commandsOpenScreens, text.hasPrefix("/") { state.commandScreen = true }
    }
    func sendKeys(_ keys: [String], to pane: String) async throws { self.keys.append(keys) }
    func sendLiteral(_ text: String, to pane: String) async throws { literals.append(text) }
    func paneState(_ pane: String) -> ManagerPaneState { state }
    /// Свежий захват, если отличается от последнего (`state`).
    var fresh: ManagerPaneState?
    func freshPaneState(_ pane: String) async -> ManagerPaneState { fresh ?? state }
}

/// Один путь записи в панель менеджера (Ш8): очередь, удержание, Esc и «Передать» идут через `ManagerOutbox`.
@MainActor
final class ManagerOutboxTests: XCTestCase {
    private var pane: FakePane!
    private var live = false

    private func model(defaults: UserDefaults = AppDefaults.store) -> ProjectModel {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-outbox", session: "team-outbox", cli: nil, defaults: defaults)
        m.livePanes = { [PaneInfo(session: "team-outbox", paneID: "%1", role: "manager", dead: false, pid: 1, path: "/tmp")] }
        pane = FakePane()
        m.outbox.writer = pane
        m.outbox.liveLineOn = { [unowned self] in self.live }
        m.outbox.commandSettle = 0
        m.outbox.commandPoll = 0.01
        return m
    }

    private func settle() async { for _ in 0..<5 { await Task.yield() }; try? await Task.sleep(nanoseconds: 50_000_000) }

    private func owner(_ id: String, _ text: String) -> ChatEntry { ChatEntry(id: id, time: nil, kind: .owner(text)) }

    func testIdleSendsAtOnceBusyHoldsUntilTurnEnds() async {
        let m = model()
        XCTAssertTrue(m.outbox.send(text: "первое", images: []))
        await settle()
        XCTAssertEqual(pane.messages, ["первое"])
        m.reconcilePending(against: [owner("o1", "первое")])

        m.managerBusy = true
        m.outbox.send(text: "в ходе", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["первое"], "в ходе менеджера сообщение ждёт")
        XCTAssertTrue(m.pending.first?.held == true)
        m.managerBusy = false
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["первое", "в ходе"])
    }

    /// Команда Claude Code из поля в транскрипт сообщением владельца не пишется — её карточка снимается после
    /// записи в панель. Но очередь за ней не идёт, пока свежий захват не покажет панель без экрана команды: иначе текст
    /// с Enter попал бы в экран (поиск и возобновление чужой сессии в /resume, буфер обмена в /export, настройка в
    /// /config), а само сообщение до модели не дошло бы.
    func testQueueWaitsUntilCommandScreenCloses() async {
        let m = model()
        pane.commandsOpenScreens = true
        m.outbox.send(text: "/model", images: [])
        await settle()
        m.outbox.send(text: "текст", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["/model"], "пока экран команды открыт, следующее ждёт")
        XCTAssertEqual(m.pending.map(\.text), ["текст"], "карточки команды нет, карточка текста — в очереди")
        XCTAssertTrue(m.pending.first?.held == true)
        pane.state.commandScreen = false
        await settle()
        XCTAssertEqual(pane.messages, ["/model", "текст"], "экран закрыт — очередь пошла")
    }

    /// Ход кончился, в очереди «/resume» и следом текст: текст уходит, только когда экран /resume закрыт.
    func testHeldCommandThenTextAfterTurn() async {
        let m = model()
        pane.commandsOpenScreens = true
        m.managerBusy = true
        m.outbox.send(text: "/resume", images: [])
        m.outbox.send(text: "после хода", images: [])
        await settle()
        XCTAssertTrue(pane.messages.isEmpty)
        m.managerBusy = false
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["/resume"])
        pane.state.commandScreen = false
        await settle()
        XCTAssertEqual(pane.messages, ["/resume", "после хода"])
    }

    /// Команда с экраном (/mcp): экран снимает её карточку — такие команды транскрипт не пишет.
    func testScreenClosesCommandCard() async {
        let m = model()
        pane.commandsOpenScreens = true
        m.outbox.send(text: "/mcp", images: [])
        await settle()
        XCTAssertTrue(m.pending.isEmpty, "экран открылся — карточки нет")
        pane.state.commandScreen = false
        m.outbox.send(text: "дальше", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["/mcp", "дальше"])
    }

    /// Экран команды открыт из терминала: сообщение из поля ждёт, пока его не закроют.
    func testScreenOpenedInTerminalHoldsQueue() async {
        let m = model()
        pane.state.commandScreen = true
        m.outbox.send(text: "привет", images: [])
        await settle()
        XCTAssertTrue(pane.messages.isEmpty)
        pane.state.commandScreen = false
        await settle()
        XCTAssertEqual(pane.messages, ["привет"])
    }

    /// Похожим на команду считается текст с «/имени» без картинок; станет ли он командой, решает Claude Code.
    func testLooksLikeCommand() {
        for t in ["/mcp", "/model opus", "/superpowers:brainstorming тема", "  /context  ", "/add-dir ~/work", "/tmp не чистится"] {
            XCTAssertTrue(PendingMessage.looksLikeCommand(t, images: []), t)
        }
        for t in ["/Users/owner/file.txt не открывается", "посмотри /mcp", "/", "/ 1", "//x"] {
            XCTAssertFalse(PendingMessage.looksLikeCommand(t, images: []), t)
        }
        XCTAssertFalse(PendingMessage.looksLikeCommand("/mcp", images: [URL(fileURLWithPath: "/tmp/a.png")]), "с картинкой — сообщение")
    }

    private func invocations() throws -> [ChatEntry] {
        var p = TranscriptParser()
        p.feed(lines: String(decoding: try fixture("command-invocations.jsonl"), as: UTF8.self).split(separator: "\n"))
        return p.entries
    }

    /// Н1 (второе ревью): скилл, встроенная команда без экрана и команда плагина экрана не открывают — их карточку
    /// снимает запись вызова <command-name> в транскрипте, и очередь идёт дальше, а не ждёт срока «не дошло».
    func testCommandCardClosedByInvocationRecord() async throws {
        let entries = try invocations()
        for (text, name) in [("/superpowers:brainstorming тема", "skill"), ("/effort high", "встроенная"), ("/vercel:deploy", "плагин")] {
            let m = model()
            m.outbox.send(text: text, images: [])
            await settle()
            XCTAssertEqual(m.pending.map(\.text), [text], "\(name): карточка ждёт записи вызова")
            m.outbox.send(text: "дальше", images: [])
            await settle()
            XCTAssertEqual(pane.messages, [text], "\(name): следующее ждёт")
            m.reconcilePending(against: entries)
            m.outbox.flush()
            await settle()
            XCTAssertEqual(pane.messages, [text, "дальше"], "\(name): вызов в транскрипте — очередь пошла")
            XCTAssertEqual(m.pending.map(\.text), ["дальше"])
        }
    }

    /// Команду, которой Claude Code не знает, он записывает только ответом «Unknown command»
    /// (`system/informational`). Этот ответ снимает карточку: очередь идёт дальше, без «не дошло» и без повтора команды.
    func testUnknownCommandClosesCard() async throws {
        var p = TranscriptParser()
        p.feed(lines: String(decoding: try fixture("unknown-command.jsonl"), as: UTF8.self).split(separator: "\n"))
        let m = model()
        m.outbox.send(text: "/rsume", images: [])
        await settle()
        m.outbox.send(text: "дальше", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["/rsume"])
        m.reconcilePending(against: p.entries)
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["/rsume", "дальше"], "команда не повторяется")
        XCTAssertEqual(m.pending.map(\.text), ["дальше"])
        // Лента опередила сверку: ответ уже на экране — карточки рядом с ним нет.
        let card = PendingMessage(text: "/todos", images: [])
        let base = FeedGrouping.manager(p.entries, peers: FeedPeers())
        XCTAssertFalse(FeedGrouping.tail(owners: FeedGrouping.owners(base), pending: [card], live: nil).contains { if case .queued = $0 { return true } else { return false } })
    }

    /// Старый вызов той же команды карточку не снимает: сверка — только с записями после отправки.
    func testEarlierInvocationDoesNotCloseCard() async throws {
        let m = model()
        m.benchFreezeChat(try invocations())
        m.outbox.send(text: "/effort high", images: [])
        await settle()
        m.reconcilePending(against: try invocations())
        XCTAssertEqual(m.pending.map(\.text), ["/effort high"])
    }

    /// Н2: гейт снимается, только когда строка ввода видна и пуста — не просто «экрана нет».
    func testGateWaitsForEmptyInputLine() async {
        let m = model()
        m.outbox.send(text: "/model", images: [])
        pane.state.inputTyped = true                      // Claude Code ещё не принял ввод: «/model» в строке
        await settle()
        m.reconcilePending(against: [ChatEntry(id: "i1", time: nil, kind: .invoked(name: "/model", args: ""))])
        m.outbox.send(text: "дальше", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["/model"])
        XCTAssertEqual(m.outbox.holdReason(m.pending[0]), "ждёт, пока Claude Code примет команду")
        pane.state.inputTyped = false
        await settle()
        XCTAssertEqual(pane.messages, ["/model", "дальше"])
    }

    /// Н3: перед записью — свежий захват. Последний захват говорит «экрана нет», а в терминале экран уже открыт: текст
    /// не уходит в экран, а ждёт его закрытия.
    func testFreshCaptureBeforeWrite() async {
        let m = model()
        pane.fresh = ManagerPaneState(commandScreen: true)
        m.outbox.send(text: "привет", images: [])
        await settle()
        XCTAssertTrue(pane.messages.isEmpty)
        XCTAssertTrue(m.pending.first?.held == true, "снова в очереди")
        pane.fresh = nil
        await settle()
        XCTAssertEqual(pane.messages, ["привет"])
    }

    /// Н4: время для фокуса — момент записи команды из поля в панель, а не отправки: удержанная в ходе команда
    /// откроет экран позже.
    func testFieldCommandWriteTime() async {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "/model", images: [], fromField: true)
        await settle()
        XCTAssertNil(m.outbox.fieldCommandWrittenAt)
        m.managerBusy = false
        m.outbox.flush()
        await settle()
        XCTAssertNotNil(m.outbox.fieldCommandWrittenAt)
    }

    /// Н5: удержание из-за экрана команды подписано и у сообщения из поля.
    func testHoldReasonForCommandScreen() async {
        let m = model()
        pane.state.commandScreen = true
        m.outbox.send(text: "привет", images: [], fromField: true)
        await settle()
        XCTAssertEqual(m.outbox.holdReason(m.pending[0]), "в панели менеджера открыт экран команды — закройте его Esc")
    }

    /// Второе сообщение не обгоняет первое: пока первого нет в транскрипте, второе стоит в очереди приложения (М26).
    func testSecondWaitsUntilFirstReachesTranscript() async {
        let m = model()
        m.outbox.send(text: "раз", images: [])
        await settle()
        m.outbox.send(text: "два", images: [])
        await settle()
        XCTAssertEqual(pane.messages, ["раз"])
        m.reconcilePending(against: [owner("o1", "раз")])
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["раз", "два"])
    }

    /// Первое потерялось (срок «не дошло» истёк) — очередь продолжается (М27).
    func testUndeliveredFirstReleasesQueue() async {
        let m = model()
        m.outbox.send(text: "раз", images: [])
        await settle()
        m.outbox.send(text: "два", images: [])
        await settle()
        m.backdatePending(PendingMessage.deliveryTimeout + 5)
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["раз", "два"])
    }

    /// Пока включена строка Claude Code, очередь сама не пишет; вернулись к полю — продолжает.
    func testLiveLineHoldsQueue() async {
        let m = model()
        live = true
        m.outbox.send(text: "из поля", images: [], fromField: true)
        await settle()
        XCTAssertEqual(pane.messages, [])
        live = false
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["из поля"])
    }

    /// Esc: одно правило — не во время вопроса о праве или доверии; «Стоп» останавливает очередь.
    func testInterruptRespectsPromptAndStopsQueue() async {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "ждёт", images: [])
        pane.state = ManagerPaneState(turnRunning: true, asksPermission: true)
        XCTAssertFalse(m.outbox.interrupt(requireTurn: true))
        XCTAssertFalse(m.outbox.escapeAllowed)
        pane.state = ManagerPaneState(turnRunning: false)
        XCTAssertFalse(m.outbox.interrupt(requireTurn: true), "Esc в пустом поле — только в ходе")
        pane.state = ManagerPaneState(turnRunning: true)
        XCTAssertTrue(m.outbox.interrupt(requireTurn: true))
        await settle()
        XCTAssertEqual(pane.keys, [["Escape"]])
        XCTAssertTrue(m.pending.first?.stopped == true, "после «Стоп» очередь сама не уходит")
    }

    /// «↑ сейчас»: Esc, затем это сообщение; при вопросе о праве — ничего.
    func testSendNow() async {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "срочно", images: [])
        let id = m.pending[0].id
        pane.state = ManagerPaneState(turnRunning: true, asksTrust: true)
        m.outbox.sendNow(id)
        await settle()
        XCTAssertEqual(pane.keys, [])
        pane.state = ManagerPaneState(turnRunning: true)
        m.outbox.sendNow(id)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(pane.keys, [["Escape"]])
        XCTAssertEqual(pane.messages, ["срочно"])
    }

    /// Не ушло — карточка снимается, текст возвращается в поле, причина понятна.
    func testFailureReturnsTextAndExplains() async {
        let m = model()
        var returned: String?
        m.outbox.onFailure = { text, _ in returned = text }
        pane.failNext = true
        m.outbox.send(text: "не уйдёт", images: [], fromField: true)
        await settle()
        XCTAssertEqual(returned, "не уйдёт")
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.outbox.error, "Не отправлено: нет соединения с tmux")
    }

    /// Не ушло, пока владелец набирает следующее: поле на экране получает текст и картинки, сохранённый черновик
    /// не трогается — путь возврата один, текст не задваивается.
    func testFailureGoesToShownFieldOnly() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let m = model(defaults: defaults)
        m.draft = "набираю"
        var returned: [(String, [URL])] = []
        m.outbox.onFailure = { returned.append(($0, $1)) }
        pane.failNext = true
        m.outbox.send(text: "не уйдёт", images: [URL(fileURLWithPath: "/tmp/a.png")], fromField: true)
        await settle()
        XCTAssertEqual(returned.map(\.0), ["не уйдёт"])
        XCTAssertEqual(returned.first?.1, [URL(fileURLWithPath: "/tmp/a.png")])
        XCTAssertEqual(m.draft, "набираю")
        XCTAssertTrue(m.pending.isEmpty)
    }

    /// Не ушло, когда поля на экране нет (удержанное ушло после хода, владелец на экране агента): текст встаёт перед
    /// сохранённым черновиком, картинки — перед его картинками. Иначе сообщение пропадало.
    func testFailureWithoutFieldKeepsTextInDraft() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "agtest-\(UUID().uuidString)"))
        let m = model(defaults: defaults)
        m.managerBusy = true
        m.outbox.send(text: "в очереди", images: [URL(fileURLWithPath: "/tmp/a.png")], fromField: true)
        m.draft = "набираю следующее"
        m.draftImages = [URL(fileURLWithPath: "/tmp/b.png")]
        pane.failNext = true
        m.managerBusy = false
        m.outbox.flush()
        await settle()
        XCTAssertTrue(pane.messages.isEmpty)
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.draft, "в очереди\nнабираю следующее")
        XCTAssertEqual(m.draftImages, [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        XCTAssertEqual(m.outbox.error, "Не отправлено: нет соединения с tmux")
    }

    /// Менеджера нет — сообщение не принято, понятная причина.
    func testNoManagerPane() {
        let m = model()
        m.livePanes = { [] }
        XCTAssertFalse(m.outbox.send(text: "куда", images: []))
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertEqual(m.outbox.error, "Менеджер не запущен — сообщение некуда отправить")
    }

    /// «Отправить ещё раз» и перенос команды в строку Claude Code — через ту же очередь.
    func testResendAndTypeIntoLine() async {
        let m = model()
        m.outbox.send(text: "раз", images: [])
        await settle()
        m.backdatePending(PendingMessage.deliveryTimeout + 5)
        m.outbox.resend(m.pending[0].id)
        await settle()
        XCTAssertEqual(pane.messages, ["раз", "раз"])
        m.outbox.typeIntoLine("/rewind")
        await settle()
        XCTAssertEqual(pane.literals, ["/rewind"])
    }

    /// Повтор не дошедшего, когда в строке Claude Code остался набранный текст: не набирает текст второй раз (иначе
    /// он склеился бы с оставшимся в одно сообщение с двойным текстом), сообщение остаётся, владелец видит причину (М10).
    func testResendDoesNotDoubleTextLeftInLine() async {
        let m = model()
        m.outbox.send(text: "раз", images: [])
        await settle()
        m.backdatePending(PendingMessage.deliveryTimeout + 5)
        pane.state = ManagerPaneState(inputTyped: true)
        m.outbox.resend(m.pending[0].id)
        await settle()
        XCTAssertEqual(pane.messages, ["раз"])
        XCTAssertEqual(m.pending.count, 1, "не дошедшее остаётся с «Отправить ещё раз»")
        XCTAssertNotNil(m.outbox.error)
        pane.state = ManagerPaneState()
        m.outbox.resend(m.pending[0].id)
        await settle()
        XCTAssertEqual(pane.messages, ["раз", "раз"], "строку очистили — повтор уходит")
        XCTAssertNil(m.outbox.error)
    }

    /// Вне хода панель не подписана, и последний захват может показывать строку хода: Esc по нему не уходит, очередь не
    /// останавливается, «↑ сейчас» не шлёт лишний Esc.
    func testStaleTurnCaptureDoesNotSendEscape() async {
        let m = model()
        m.managerBusy = false
        pane.state = ManagerPaneState(turnRunning: true)
        XCTAssertFalse(m.outbox.interrupt(requireTurn: true))
        live = true                     // удержать сообщение, чтобы проверить «↑ сейчас»
        m.outbox.send(text: "срочно", images: [], fromField: true)
        live = false
        m.outbox.sendNow(m.pending[0].id)
        try? await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(pane.keys, [], "Esc в свободный Claude Code не уходит")
        XCTAssertEqual(pane.messages, ["срочно"])
    }

    /// Обрыв связи: первое не ушло — очередь останавливается, остальные удержанные не уходят по одному в никуда.
    func testPersistentFailureStopsQueue() async {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "раз", images: [])
        m.outbox.send(text: "два", images: [])
        pane.failAll = true
        m.managerBusy = false
        m.outbox.flush()
        await settle()
        XCTAssertEqual(m.pending.map(\.text), ["два"], "второе осталось")
        XCTAssertTrue(m.pending[0].stopped, "очередь остановлена")
    }

    /// «Передать» не удалась — текст не попадает в поле ввода, причина — итогом действия.
    func testFailureOutsideFieldIsReported() async {
        let m = model()
        var returned: String?
        m.outbox.onFailure = { text, _ in returned = text }
        pane.failNext = true
        m.outbox.send(text: ProjectModel.handoffRequest(for: "dev#1"), images: [])
        await settle()
        XCTAssertNil(returned)
        XCTAssertEqual(m.lastActionMessage, "Не отправлено: нет соединения с tmux")
    }

    /// Esc из строки Claude Code: на экранах живого claude то же решение, что у прежнего правила строки, — кроме вопроса
    /// о праве, который строгий разбор не узнаёт (там теперь Esc не уходит, как и из поля).
    func testLineEscapeRuleOnRecordedScreens() throws {
        for name in ["ask", "at", "multi", "perm", "rewind", "slash", "typed"] {
            let lines = SGRParser.parse(String(decoding: try fixture("live-\(name).txt"), as: UTF8.self))
            let plain = lines.map(\.plain)
            let trust = PaneTail.asksFolderTrust(plain)
            let state = ManagerPaneState(turnRunning: false, asksPermission: !trust && PaneTail.asksPermission(plain),
                                         asksTrust: trust, askFormOpen: AskForm.isOpen(lines))
            let old = PermissionPrompt.from(lines) == nil && !trust
            XCTAssertEqual(state.lineEscapeAllowed, old, name)
        }
    }

    // MARK: «Передать» при строке Claude Code

    /// Менеджер без хода и строка ввода пуста — явная просьба уходит сразу, не дожидаясь возврата к полю.
    func testExplicitSendGoesWhenLineEmptyAndManagerIdle() async {
        let m = model()
        live = true
        pane.state = ManagerPaneState(inputTyped: false)
        m.outbox.send(text: ProjectModel.handoffRequest(for: "dev#1"), images: [])
        await settle()
        XCTAssertEqual(pane.messages, [ProjectModel.handoffRequest(for: "dev#1")])
        m.outbox.send(text: "из поля", images: [], fromField: true)
        XCTAssertEqual(m.outbox.holdReason(m.pending.last!), "ждёт поля приложения", "сообщение из поля по-прежнему ждёт поля")
    }

    /// В строке набран текст или менеджер в ходе — ждёт и говорит, чего; строку очистили — уходит.
    func testExplicitSendWaitsAndNamesReason() async {
        let m = model()
        live = true
        pane.state = ManagerPaneState(inputTyped: true)
        m.outbox.send(text: "передача", images: [])
        await settle()
        XCTAssertEqual(pane.messages, [])
        XCTAssertEqual(m.outbox.holdReason(m.pending[0]), "в строке Claude Code набран текст")
        m.managerBusy = true
        XCTAssertEqual(m.outbox.holdReason(m.pending[0]), "менеджер в ходе")
        m.managerBusy = false
        pane.state = ManagerPaneState(inputTyped: false)
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["передача"])
    }

    /// Обычное сообщение без строки Claude Code — подписи причины нет, как раньше.
    func testPlainQueueHasNoReason() {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "в ходе", images: [], fromField: true)
        XCTAssertNil(m.outbox.holdReason(m.pending[0]))
    }

    /// «Передать» не застревает за сообщением из поля, которое ждёт возврата к полю (М1 цикла 2).
    func testExplicitPassesFieldMessageUnderLiveLine() async {
        let m = model()
        live = true
        m.managerBusy = true
        m.outbox.send(text: "из поля", images: [], fromField: true)
        m.outbox.send(text: "передача", images: [])
        m.managerBusy = false
        m.outbox.flush()
        await settle()
        XCTAssertEqual(pane.messages, ["передача"])
        XCTAssertEqual(m.outbox.holdReason(m.pending.first { $0.held }!), "ждёт поля приложения")
    }

    /// Выход с очередью, «Отправить и выйти»: удержанные уходят по порядку, даже если менеджер в ходе.
    func testSendAllHeldOnQuit() async {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "первое", images: [], fromField: true)
        m.outbox.send(text: "второе", images: [])
        XCTAssertEqual(m.heldCount, 2)
        let ok = await m.outbox.sendAllHeld()
        XCTAssertTrue(ok)
        XCTAssertEqual(pane.messages, ["первое", "второе"])
        XCTAssertEqual(m.heldCount, 0)
    }

    /// Запись не удалась — выход отменяется, неотправленное остаётся в очереди.
    func testSendAllHeldKeepsQueueOnFailure() async {
        let m = model()
        m.managerBusy = true
        m.outbox.send(text: "первое", images: [], fromField: true)
        pane.failAll = true
        let ok = await m.outbox.sendAllHeld()
        XCTAssertFalse(ok)
        XCTAssertEqual(m.heldCount, 1)
        XCTAssertNotNil(m.outbox.error)
    }
}

/// Набранное в строке ввода Claude Code: бледная подсказка-заглушка пустой строки — не текст.
final class LiveInputTypedTests: XCTestCase {
    private func screen(_ name: String) throws -> [StyledLine] {
        SGRParser.parse(String(decoding: try fixture("live-\(name).txt"), as: UTF8.self))
    }

    func testTypedTextOnRecordedScreens() throws {
        XCTAssertEqual(LiveInput.typedText(try screen("typed")), "привет")
        XCTAssertEqual(LiveInput.typedText(try screen("slash")), "/")
        XCTAssertEqual(LiveInput.typedText(try screen("at")), "@")
    }

    func testPlaceholderIsNotTyped() {
        let rule = String(repeating: "─", count: 40)
        let lines = SGRParser.parse("ответ\n" + rule + "\n\u{1b}[39m❯\u{a0}\u{1b}[2mпереписывай инструкцию\u{1b}[0m\n" + rule + "\n  [Opus]")
        XCTAssertEqual(LiveInput.typedText(lines), "")
        let typed = SGRParser.parse("ответ\n" + rule + "\n❯\u{a0}да\n" + rule + "\n  [Opus]")
        XCTAssertEqual(LiveInput.typedText(typed), "да")
    }
}
