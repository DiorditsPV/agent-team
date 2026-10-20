import Foundation
import Observation

/// Состояние панели менеджера, от которого зависит запись в неё.
public struct ManagerPaneState: Equatable, Sendable {
    /// На экране строка хода: Esc прервёт ход.
    public var turnRunning: Bool
    /// Вопрос о праве (или другой вопрос с выбором) и вопрос о доверии к каталогу: Esc там означал бы отказ.
    public var asksPermission: Bool
    public var asksTrust: Bool
    /// Открыта форма вопроса с вариантами (AskUserQuestion): её признак входит и в `asksPermission`.
    public var askFormOpen: Bool
    /// В строке ввода Claude Code набран текст (по захвату; бледная подсказка-заглушка — не текст).
    public var inputTyped: Bool
    /// Открыт экран встроенной команды Claude Code (`/mcp`, `/resume`…): строки ввода нет, текст с Enter стал бы вводом
    /// в экран.
    public var commandScreen: Bool
    /// Строка ввода Claude Code на экране.
    public var inputLine: Bool

    public init(turnRunning: Bool = false, asksPermission: Bool = false, asksTrust: Bool = false, askFormOpen: Bool = false,
                inputTyped: Bool = false, commandScreen: Bool = false, inputLine: Bool = true) {
        self.turnRunning = turnRunning
        self.asksPermission = asksPermission
        self.asksTrust = asksTrust
        self.askFormOpen = askFormOpen
        self.inputTyped = inputTyped
        self.commandScreen = commandScreen
        self.inputLine = inputLine
    }

    /// Панель приняла бы новое сообщение: экрана команды нет, строка ввода видна и пуста, хода нет.
    public var readyForInput: Bool { !commandScreen && inputLine && !inputTyped && !turnRunning }

    /// Esc из поля приложения (прервать ход): не уходит, пока панель ждёт ответа на вопрос о праве, форму вопроса
    /// или доверие — Esc там означал бы отказ.
    public var escapeAllowed: Bool { !asksPermission && !asksTrust }

    /// Esc из строки Claude Code: тот же признак вопроса о праве, что у поля, но форму вопроса владелец в строке
    /// отменяет сам — там Esc проходит.
    public var lineEscapeAllowed: Bool { !asksTrust && (!asksPermission || askFormOpen) }
}

/// Запись в панель менеджера (в тестах — подставная).
@MainActor
public protocol ManagerPaneWriter: AnyObject {
    func writeMessage(text: String, images: [URL], to pane: String) async throws
    func sendKeys(_ keys: [String], to pane: String) async throws
    func sendLiteral(_ text: String, to pane: String) async throws
    func paneState(_ pane: String) -> ManagerPaneState
    /// Состояние по захвату, снятому сейчас: у менеджера без хода панель не подписана, и последний захват мог устареть.
    func freshPaneState(_ pane: String) async -> ManagerPaneState
}

extension ManagerPaneWriter {
    public func freshPaneState(_ pane: String) async -> ManagerPaneState { paneState(pane) }
}

/// Единственный путь записи сообщений владельца в панель менеджера: поле приложения, «↑ сейчас», повтор, «Стоп»,
/// «Передать» на экране агента и перенос команды в строку Claude Code идут через него.
///
/// Правила:
/// - менеджер в ходе — сообщение стоит в очереди приложения и уходит, когда ход кончится;
/// - прежнее отправленное ещё не попало в транскрипт — следующее ждёт его: иначе второе обогнало бы первое
///   в очереди самого Claude Code;
/// - срок «не дошло» истёк — очередь продолжается без нового события;
/// - пока включена строка Claude Code, очередь сама в панель не пишет: владелец печатает прямо в неё;
/// - Esc не уходит, пока панель ждёт ответа на вопрос о праве или доверии;
/// - команда Claude Code («/mcp») в транскрипт сообщением владельца не пишется: её карточка снимается после записи, а
///   очередь стоит, пока свежий захват не покажет панель без экрана команды; так же — пока экран открыт из терминала.
///   Иначе текст с Enter стал бы вводом в экран (поиск в /resume, выбор в /export, фильтр в /config);
/// - в панели менеджера не сессия его роли (`role_check.ok == false`: разговор ушёл в фоновую задачу, чужой процесс,
///   процесс без файла роли) — ничего не пишется: ни сообщения, ни Esc, ни очередь при выходе. Сообщение получил бы
///   разговор без роли. Так же — до первого ответа status: проверки ещё не было. Очередь трогается, когда status покажет
///   сессию роли или ответит ошибкой (`ProjectModel.statusArrived`, `loadStatus`). Перед каждой записью сообщения роль
///   подтверждается свежим status (`ProjectModel.confirmManagerRole`): опрос мог не застать уход разговора в фон.
@MainActor
@Observable
public final class ManagerOutbox {
    @ObservationIgnored weak var project: ProjectModel?
    @ObservationIgnored public weak var writer: ManagerPaneWriter?
    /// Включена ли строка Claude Code (настройка живёт в приложении).
    @ObservationIgnored public var liveLineOn: () -> Bool = { false }
    /// Отправка сообщения из поля ввода не удалась: текст и картинки возвращаются в поле. Задаёт поле, пока оно на экране;
    /// без него возврат идёт в сохранённый черновик (`returnToDraft`). Прочие сообщения («Передать») при неудаче — итог
    /// действия проекта.
    @ObservationIgnored public var onFailure: ((String, [URL]) -> Void)?
    /// Сообщения из поля ввода: им при неудаче — `onFailure`.
    @ObservationIgnored private var fromField: Set<String> = []
    /// Сообщения, отправленные явным действием не из поля («Передать»): при строке Claude Code они не ждут возврата к
    /// полю — владелец может к нему не вернуться, — а уходят, как только менеджер без хода и строка ввода пуста.
    private var explicit: Set<String> = []
    @ObservationIgnored private var lineCheck: Task<Void, Never>?

    /// Сообщение уходит в панель сейчас.
    public private(set) var sending = false
    /// Почему последняя отправка не удалась; `nil` — удалась.
    public private(set) var error: String?
    /// Отправленное в этом запуске приложения: история ввода по ↑, пока транскрипт его не вернул.
    public private(set) var sentTexts: [String] = []

    @ObservationIgnored private var expiryCheck: Task<Void, Never>?

    /// Через сколько после записи команды снимать свежий захват (Claude Code рисует экран не сразу) и как часто
    /// проверять, готова ли панель.
    @ObservationIgnored public var commandSettle: TimeInterval = 0.6
    @ObservationIgnored public var commandPoll: TimeInterval = 0.5
    /// Текст с «/имени» ушёл в панель, а панель ещё не показала пустую строку ввода: очередь стоит.
    @ObservationIgnored private var commandGate = false
    /// Карточка команды, ушедшей в панель: снимается, когда команда открыла свой экран (такие команды транскрипт не
    /// пишет); иначе — записью вызова `<command-name>` или ответом «Unknown command» в транскрипте (`PendingMessage.matches`).
    @ObservationIgnored private var commandCard: String?
    @ObservationIgnored private var commandWatch: Task<Void, Never>?
    /// Когда команда из поля ушла в панель: её экран, открытый вскоре, берёт фокус клавиатуры (`ChatPanel`).
    public private(set) var fieldCommandWrittenAt: Date?

    init() {}

    /// Очередь стоит из-за команды: текст с «/имени» только что ушёл в панель или в панели открыт экран команды.
    private var commandHold: Bool {
        guard let writer, let pane else { return false }
        return commandGate || writer.paneState(pane).commandScreen
    }

    /// Ждать, пока свежий захват не покажет панель, готовую к вводу (`ManagerPaneState.readyForInput`: экрана команды
    /// нет, строка ввода видна и пуста, хода нет), затем двинуть очередь. Экран команды на свежем захвате снимает
    /// карточку команды: её Claude Code в транскрипт не запишет. Одно ожидание за раз.
    private func watchCommandScreen() {
        guard commandWatch == nil else { return }
        commandWatch = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.commandSettle * 1_000_000_000))
            var polls = 0
            let started = Date()
            while !Task.isCancelled {
                guard let writer = self.writer, let pane = self.pane, let project = self.project else { break }
                // Только свежий захват: последний захват панели без подписки (менеджер в простое) может быть старым.
                let s = await writer.freshPaneState(pane)
                if s.commandScreen, let card = self.commandCard {
                    project.removePending(card)
                    self.commandCard = nil
                }
                if s.readyForInput { break }
                // Экран, где строку ввода не узнать, держит очередь не дольше срока «не дошло»: дальше — без экрана
                // команды — очередь идёт, как шла бы без команды.
                if !s.commandScreen, Date().timeIntervalSince(started) > PendingMessage.deliveryTimeout { break }
                polls += 1
                // Долгий ход после команды (скилл) — реже: менеджер в ходе, очередь и так ждёт.
                let wait = polls > 20 ? max(self.commandPoll, 2) : self.commandPoll
                try? await Task.sleep(nanoseconds: UInt64(max(wait, 0.001) * 1_000_000_000))
            }
            self.commandGate = false
            self.commandCard = nil
            self.commandWatch = nil
            self.flush()
        }
    }

    private var pane: String? { project?.managerPaneID }

    /// В панели менеджера не сессия роли или первого status ещё нет: запись в панель стоит.
    private var roleHold: Bool { project?.managerWriteHeld == true }

    /// Подпись удержания и ошибки, пока в панели менеджера не сессия роли.
    public static let roleHoldReason = "в панели менеджера не сессия роли — сначала «Восстановить роль»"
    public static let statusHoldReason = "ждёт первой проверки роли менеджера (team status)"
    private var roleHoldText: String { project?.managerNotRole == true ? Self.roleHoldReason : Self.statusHoldReason }

    /// Есть отправленное, которого ещё нет в транскрипте и срок которого не истёк.
    private var awaitingTranscript: Bool {
        project?.pending.contains { !$0.held && !$0.isUndelivered() } ?? false
    }

    // MARK: действия владельца

    /// Новое сообщение. `false` — менеджера нет, сообщение не принято.
    @discardableResult
    public func send(text: String, images: [URL], fromField: Bool = false) -> Bool {
        guard let project, pane != nil else {
            error = "Менеджер не запущен — сообщение некуда отправить"
            return false
        }
        let line = liveLineOn() && (fromField || lineTyped)
        let command = commandHold
        if command { watchCommandScreen() }
        let hold = project.managerBusy || awaitingTranscript || sending || line || command || roleHold
        let id = project.addPending(text: text, images: images, held: hold)
        if fromField { self.fromField.insert(id) } else { explicit.insert(id) }
        if hold, !fromField, liveLineOn() { scheduleLineCheck() }
        if !hold { deliver(text: text, images: images, pendingID: id) }
        return true
    }

    /// Удержанные уходят по одному, когда можно: ход кончился и не прерван, прежнее в транскрипте или потеряно,
    /// строка Claude Code выключена.
    public func flush() {
        guard !sending, pane != nil, let project, !roleHold else { return }
        if commandHold { watchCommandScreen(); return }
        // При строке Claude Code сами уходят только явные действия, и только в пустую строку; сообщения из поля, что
        // стоят раньше, их не задерживают. Строку включили, когда явное уже ждало, — проверка строки запускается здесь.
        let line = liveLineOn()
        if line, project.pending.contains(where: { $0.held && explicit.contains($0.id) }) { scheduleLineCheck() }
        if line, lineTyped { return }
        guard let next = project.nextHeldToSend(where: { [explicit] in !line || explicit.contains($0.id) }) else { return }
        project.markSent(next.id)
        deliver(text: next.text, images: next.images, pendingID: next.id)
    }

    /// «↑ сейчас»: Esc прерывает ход, затем уходит это сообщение; остальные снова ждут конца хода.
    public func sendNow(_ id: String) {
        guard let project, let writer, let pane, !sending, !roleHold, let p = project.pending.first(where: { $0.id == id }) else { return }
        let state = writer.paneState(pane)
        guard state.escapeAllowed else { return }
        project.releaseOthers(except: id)
        project.markSent(id)
        sending = true
        Task {
            // Esc и сообщение уходят только в сессию роли: свежая проверка до Esc.
            guard await project.confirmManagerRole() else {
                project.holdAgain(id)
                sending = false
                return
            }
            // Ход — по транскрипту: вне хода панель не подписана, и захват со строкой хода мог устареть.
            if project.managerBusy {
                try? await writer.sendKeys(["Escape"], to: pane)
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            sending = false
            deliver(text: p.text, images: p.images, pendingID: id)
        }
    }

    /// «Отправить ещё раз» у не дошедшего: то же сообщение заново, по общим правилам очереди. Если в строке ввода
    /// Claude Code остался текст — скорее всего, это и есть не дошедшее (текст набран, Enter не сработал): повтор
    /// склеил бы его с ним в одно сообщение с двойным текстом. Тогда повтора нет, а владелец получает объяснение.
    public func resend(_ id: String) {
        guard let project, let writer, let pane, !sending, project.pending.contains(where: { $0.id == id }) else { return }
        Task {
            let state = await writer.freshPaneState(pane)
            guard let p = project.pending.first(where: { $0.id == id }), !sending else { return }
            if state.inputTyped {
                error = "В строке Claude Code остался набранный текст — возможно, это и есть это сообщение. "
                    + "Отправьте его там (Enter) или очистите строку, затем повторите"
                return
            }
            error = nil
            // Снятие без продвижения очереди: иначе следующее удержанное ушло бы раньше повторяемого.
            project.removePending(id)
            send(text: p.text, images: p.images, fromField: fromField.remove(id) != nil)
        }
    }

    /// Можно ли сейчас прервать ход Esc.
    public var escapeAllowed: Bool {
        guard let writer, let pane, !roleHold else { return false }
        return writer.paneState(pane).escapeAllowed
    }

    /// «Стоп» или Esc в пустом поле: Esc в панель, очередь сама не уходит. `requireTurn` — только если на экране идёт ход.
    /// `false` — Esc не отправлен (вопрос о праве, нет хода, нет панели).
    @discardableResult
    public func interrupt(requireTurn: Bool) -> Bool {
        guard let project, let writer, let pane, !roleHold else { return false }
        let state = writer.paneState(pane)
        // «Ход идёт» — и по экрану, и по транскрипту: вне хода панель не подписана, захват со строкой хода мог устареть,
        // а Esc в свободный Claude Code открыл бы его меню.
        guard state.escapeAllowed, !requireTurn || (state.turnRunning && project.managerBusy) else { return false }
        project.stopQueue()
        Task { try? await writer.sendKeys(["Escape"], to: pane) }
        return true
    }

    /// Выход из приложения: все удержанные уходят в панель сейчас, по порядку и без Esc — если менеджер в ходе, Claude
    /// Code поставит их в свою очередь. `false` — менеджера нет или запись не удалась: неотправленное остаётся в очереди.
    /// `freshRole` — подтвердить роль свежим status; без него (выход по сигналу со сроком) — по последнему ответу.
    public func sendAllHeld(freshRole: Bool = true) async -> Bool {
        guard let project, project.heldCount > 0 else { return true }
        guard let writer, let pane else {
            error = "Менеджер \(project.session) не запущен — очередь некуда отправить"
            return false
        }
        // Роль — по свежему status; запись, начатая очередью за это время, дожидается ниже.
        if freshRole ? !(await project.confirmManagerRole()) : roleHold {
            error = "Очередь \(project.session) не отправлена: " + roleHoldText
            return false
        }
        while sending { try? await Task.sleep(nanoseconds: 50_000_000) }
        for p in project.pending where p.held {
            do {
                try await writer.writeMessage(text: p.text, images: p.images, to: pane)
            } catch {
                self.error = "Не отправлено: " + Self.describe(error)
                return false
            }
            project.markSent(p.id)
            project.logOwnerMessage(p.text.isEmpty ? "[картинка]" : p.text)
            fromField.remove(p.id)
            explicit.remove(p.id)
        }
        return true
    }

    /// Команда с собственным меню Claude Code переносится в строку ввода панели без Enter.
    public func typeIntoLine(_ text: String) {
        guard let writer, let pane, !text.isEmpty, !roleHold else { return }
        Task { try? await writer.sendLiteral(text, to: pane) }
    }

    /// Почему ждёт явное сообщение («Передать») или любое при строке Claude Code: «менеджер в ходе», «в строке Claude
    /// Code набран текст», «ждёт поля приложения», «ждёт предыдущее». `nil` — не удержано или подписи не нужно.
    public func holdReason(_ p: PendingMessage) -> String? {
        guard p.held, let project else { return nil }
        if roleHold { return roleHoldText }
        // Экран команды держит всё: подпись — и у сообщений из поля, а с другого экрана приложения экран не виден.
        if let writer, let pane, writer.paneState(pane).commandScreen { return "в панели менеджера открыт экран команды — закройте его Esc" }
        if commandGate { return "ждёт, пока Claude Code примет команду" }
        // Обычные сообщения из поля без строки Claude Code подписаны просто «в очереди».
        if p.stopped || (!explicit.contains(p.id) && !liveLineOn()) { return nil }
        if project.managerBusy { return "менеджер в ходе" }
        if liveLineOn() {
            return explicit.contains(p.id) ? (lineTyped ? "в строке Claude Code набран текст" : nil) : "ждёт поля приложения"
        }
        return awaitingTranscript ? "ждёт предыдущее" : nil
    }

    private var lineTyped: Bool {
        guard let writer, let pane else { return false }
        return writer.paneState(pane).inputTyped
    }

    /// Явное сообщение ждёт пустой строки Claude Code: строка меняется без событий для очереди, поэтому — проверка раз
    /// в 2 с, пока такое сообщение есть.
    private func scheduleLineCheck() {
        guard lineCheck == nil else { return }
        lineCheck = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let project = self.project,
                      project.pending.contains(where: { $0.held && self.explicit.contains($0.id) }) else { break }
                self.flush()
            }
            self?.lineCheck = nil
        }
    }

    // MARK: доставка

    private func deliver(text: String, images: [URL], pendingID: String) {
        guard let project, let writer, let pane else { return }
        sending = true
        error = nil
        Task {
            // Перед записью — свежий захват: последний захват панели без подписки мог не застать экран команды,
            // открытый в терминале, и текст с Enter ушёл бы в экран.
            if (await writer.freshPaneState(pane)).commandScreen {
                project.holdAgain(pendingID)
                sending = false
                watchCommandScreen()
                return
            }
            // Роль — по свежему status, а не по последнему опросу: разговор мог уйти в фон между опросами. Чужая сессия —
            // сообщение снова ждёт.
            if !(await project.confirmManagerRole()) {
                project.holdAgain(pendingID)
                sending = false
                return
            }
            do {
                try await writer.writeMessage(text: text, images: images, to: pane)
                project.logOwnerMessage(text.isEmpty ? "[картинка]" : text)
                if !text.isEmpty { sentTexts.append(text) }
                let field = fromField.remove(pendingID) != nil
                explicit.remove(pendingID)
                // Текст с «/имени» может открыть экран команды: следующее ждёт пустой строки ввода. Карточка снимается
                // экраном или записью вызова в транскрипте.
                if PendingMessage.looksLikeCommand(text, images: images) {
                    if field { fieldCommandWrittenAt = Date() }
                    commandGate = true
                    commandCard = pendingID
                    watchCommandScreen()
                }
            } catch {
                // Очередь останавливается, а не идёт дальше: при обрыве связи каждое удержанное ушло бы, упало и пропало.
                project.removePending(pendingID)
                project.stopQueue()
                let message = "Не отправлено: " + Self.describe(error)
                self.error = message
                if fromField.remove(pendingID) != nil { returnToDraft(text, images) } else { project.report(message) }
            }
            sending = false
            scheduleExpiryCheck()
            flush()
        }
    }

    /// Не ушедшее сообщение из поля возвращается владельцу перед уже набранным, как «✎ изменить»: поле на экране
    /// (`onFailure`) склеивает его с тем, что в нём сейчас; поля нет (владелец на другом экране) — склеивается
    /// сохранённый черновик проекта, и поле покажет его, когда откроется.
    private func returnToDraft(_ text: String, _ images: [URL]) {
        if let onFailure { onFailure(text, images) } else { project?.returnToDraft(text, images: images) }
    }

    /// Срок «не дошло» истекает без события: проверка по таймеру, пока есть отправленное без записи в транскрипте.
    private func scheduleExpiryCheck() {
        expiryCheck?.cancel()
        guard awaitingTranscript else { return }
        expiryCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((PendingMessage.deliveryTimeout + 1) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.flush()
            self.scheduleExpiryCheck()
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ControlError.notConnected, ControlError.exited: return "нет соединения с tmux"
        case let ControlError.commandFailed(lines): return "tmux отказал: " + lines.joined(separator: " ")
        default: return "\(error)"
        }
    }
}
