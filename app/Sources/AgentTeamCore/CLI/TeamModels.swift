import Foundation

// Контракт `team … --json`. Поля, которых может не быть у старого CLI или у нечитаемой роли, — опциональные:
// приложение показывает пустое состояние, а не падает.

public struct TeamStatus: Codable, Equatable, Sendable {
    public var project: String
    public var repo: String
    public var session: String
    public var sessionAlive: Bool
    /// Трекер как отдал team: строка, объект (словарь из team.yaml) или ничего.
    public var trackerInfo: TrackerInfo?
    public var agents: [Agent]

    /// Имя трекера для показа: `kind` объекта или сама строка; иначе nil — не показывать.
    public var tracker: String? { trackerInfo?.name }

    enum CodingKeys: String, CodingKey {
        case project, repo, session, agents
        case trackerInfo = "tracker"
        case sessionAlive = "session_alive"
    }

    public init(project: String, repo: String, session: String, sessionAlive: Bool, tracker: String?, agents: [Agent]) {
        self.project = project
        self.repo = repo
        self.session = session
        self.sessionAlive = sessionAlive
        self.trackerInfo = tracker.flatMap { $0.isEmpty ? nil : TrackerInfo.name($0) }
        self.agents = agents
    }

    public var manager: Agent? { agents.first { $0.kind == "manager" } }
}

/// Поле `tracker` в `team status --json`: строка, словарь из team.yaml или null (пусто и `{}` тоже дают nil).
public enum TrackerInfo: Codable, Equatable, Sendable {
    case name(String)
    case object([String: String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .name(s); return }
        if let d = try? c.decode([String: LossyString].self) { self = .object(d.mapValues(\.text)); return }
        throw DecodingError.typeMismatch(TrackerInfo.self, .init(codingPath: decoder.codingPath, debugDescription: "tracker: ожидалась строка или объект"))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case let .name(s): try c.encode(s)
        case let .object(d): try c.encode(d)
        }
    }

    /// Имя трекера: `kind` объекта, если это непустая строка; строка как есть; иначе nil.
    public var name: String? {
        switch self {
        case let .name(s): return s.isEmpty ? nil : s
        case let .object(d): return d["kind"].flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

/// Список, в котором битый элемент пропускается, а не обнуляет весь список: одна шапка передачи или роли с полем
/// не того вида не должна оставлять экран пустым.
public struct LossyList<Element: Decodable>: Decodable {
    public var items: [Element]
    /// Сколько элементов пропущено.
    public var skipped: Int

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var items: [Element] = []
        var skipped = 0
        while !c.isAtEnd {
            if let x = try? c.decode(Element.self) {
                items.append(x)
            } else {
                // Неудачное чтение позицию не сдвигает: элемент проходится пустым чтением.
                _ = try? c.decode(Skip.self)
                skipped += 1
            }
        }
        self.items = items
        self.skipped = skipped
    }

    private struct Skip: Decodable { init(from decoder: Decoder) {} }
}

extension KeyedDecodingContainer {
    /// Поле шапки (front matter) как текст. CLI отдаёт значения YAML как есть: `task: 554` без кавычек приходит числом,
    /// `branch: true` — логическим. Число и логическое значение становятся текстом, null, список и объект — nil.
    func lossyString(_ key: Key) -> String? {
        guard contains(key), (try? decodeNil(forKey: key)) == false else { return nil }
        if let s = try? decode(String.self, forKey: key) { return s }
        if let i = try? decode(Int.self, forKey: key) { return String(i) }
        if let d = try? decode(Double.self, forKey: key) { return String(d) }
        if let b = try? decode(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    /// Целое из числа или строки с числом; иначе nil.
    func lossyInt(_ key: Key) -> Int? {
        if let i = try? decode(Int.self, forKey: key) { return i }
        if let d = try? decode(Double.self, forKey: key) { return Int(d) }
        return lossyString(key).flatMap { Int($0) }
    }
}

/// Значение объекта tracker любого скалярного вида — как текст (вложенное и null приложению не нужны).
struct LossyString: Decodable {
    var text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else if let i = try? c.decode(Int.self) { text = String(i) }
        else if let d = try? c.decode(Double.self) { text = String(d) }
        else if let b = try? c.decode(Bool.self) { text = String(b) }
        else { text = "" }
    }
}

/// Поле `role_check` агента в `team status --json`: ведёт ли разговор агента сессия его роли. null — агента нет.
/// Значения поля, которых приложение не знает, разбираются без сбоя: неизвестная причина остаётся текстом.
public struct RoleCheck: Codable, Equatable, Sendable {
    /// true — разговор ведёт процесс панели с файлом роли; false — в панели не сессия роли; nil — данных нет.
    public var ok: Bool?
    /// Причина при `ok == false`: `background`, `other_process`, `no_role_prompt`.
    public var reason: String?
    /// Процесс, который ведёт разговор, и процесс панели.
    public var pid: Int?
    public var panePID: Int?
    /// Фоновая задача Claude Code, в которую ушёл разговор.
    public var jobID: String?
    public var sessionID: String?

    enum CodingKeys: String, CodingKey {
        case ok, reason, pid
        case panePID = "pane_pid"
        case jobID = "job_id"
        case sessionID = "session_id"
    }

    public init(ok: Bool?, reason: String? = nil, pid: Int? = nil, panePID: Int? = nil, jobID: String? = nil, sessionID: String? = nil) {
        self.ok = ok
        self.reason = reason
        self.pid = pid
        self.panePID = panePID
        self.jobID = jobID
        self.sessionID = sessionID
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        reason = c.lossyString(.reason)
        pid = c.lossyInt(.pid)
        panePID = c.lossyInt(.panePID)
        jobID = c.lossyString(.jobID)
        sessionID = c.lossyString(.sessionID)
    }

    /// В панели не сессия роли: только явное `ok: false`. Нет данных (`ok: null`) — не тревога.
    public var notRole: Bool { ok == false }

    /// Причина словами для владельца, как у `team status`.
    public var reasonText: String {
        let pidText = pid.map { ", pid \($0)" } ?? ""
        switch reason {
        case "background":
            let job = jobID.map { "задача \($0)" } ?? "задача"
            return "разговор ушёл в фоновую задачу Claude Code (\(job)\(pidText)), у неё нет промпта роли"
        case "other_process": return "разговор ведёт другой процесс\(pidText), не запущенный team"
        case "no_role_prompt": return "процесс панели\(pidText) запущен без файла роли"
        case let r?: return "причина «\(r)»"
        case nil: return "причина не указана"
        }
    }

    /// Короткая метка для строки и шапки панели агента.
    public var mark: String {
        switch reason {
        case "background": return "в фоне"
        case "other_process": return "чужой процесс"
        case "no_role_prompt": return "без роли"
        default: return "не роль"
        }
    }
}

public struct Agent: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var role: String
    public var n: Int
    public var title: String?
    public var kind: String?
    public var model: String?
    public var alive: Bool
    public var paneID: String?
    /// Текущая сессия Claude Code: `team status` идёт по цепочке `continued-in` до конца.
    public var sessionID: String?
    /// Сессия, с которой агент был запущен (поле launch_session_id; у старого CLI его нет).
    public var launchSessionID: String?
    public var cwd: String?
    public var branch: String?
    public var started: Int?
    public var idleS: Int?
    public var waitingHuman: Bool
    public var addr: String?
    /// Задача из последнего события task (новое поле контракта; у старого CLI его нет).
    public var task: String?
    /// Название задачи и время её установки (поля task_title, task_ts; у старого CLI их нет).
    public var taskTitle: String?
    public var taskTS: Int?
    /// Незакоммиченные пути в worktree агента (новое поле контракта).
    public var dirty: [String]?
    /// Открытый вопрос `AskUserQuestion` агента целиком (новое поле контракта): null — вопроса нет, агент не жив
    /// или сессия сменилась.
    public var question: PendingQuestion?
    /// Ведёт ли разговор агента сессия его роли (поле role_check; у старого CLI его нет — nil).
    public var roleCheck: RoleCheck?

    /// Ключ вместо имени — только у второго из двух агентов с одинаковым именем в списке колонки
    /// (`ProjectModel.teamAgents`): запись status и посторонняя панель с той же подписью.
    public var keyOverride: String?

    /// Уникальный ключ агента в колонке — имя с номером. Имя не меняется, когда `team status` догоняет новую панель
    /// или панель после restart: агент из панели называется по её подписи тем же «роль#n». По ключу держатся
    /// свёрнутость, порядок и строки ForEach: два агента одной роли не делят состояние.
    public var key: String { keyOverride ?? name }
    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case name, role, n, title, kind, model, alive, cwd, branch, started, addr, task, dirty, question
        case taskTitle = "task_title"
        case taskTS = "task_ts"
        case paneID = "pane_id"
        case sessionID = "session_id"
        case launchSessionID = "launch_session_id"
        case idleS = "idle_s"
        case waitingHuman = "waiting_human"
        case roleCheck = "role_check"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? String(name.split(separator: "#").first ?? "")
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 1
        title = try c.decodeIfPresent(String.self, forKey: .title)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        alive = try c.decodeIfPresent(Bool.self, forKey: .alive) ?? false
        paneID = try c.decodeIfPresent(String.self, forKey: .paneID)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        launchSessionID = try? c.decodeIfPresent(String.self, forKey: .launchSessionID)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        started = try c.decodeIfPresent(Int.self, forKey: .started)
        idleS = try c.decodeIfPresent(Int.self, forKey: .idleS)
        waitingHuman = try c.decodeIfPresent(Bool.self, forKey: .waitingHuman) ?? false
        addr = try c.decodeIfPresent(String.self, forKey: .addr)
        task = try? c.decodeIfPresent(String.self, forKey: .task)
        taskTitle = try? c.decodeIfPresent(String.self, forKey: .taskTitle)
        taskTS = try? c.decodeIfPresent(Int.self, forKey: .taskTS)
        dirty = try? c.decodeIfPresent([String].self, forKey: .dirty)
        question = (try? c.decodeIfPresent(PendingQuestion.self, forKey: .question)).flatMap { $0?.isUsable == true ? $0 : nil }
        roleCheck = (try? c.decodeIfPresent(RoleCheck.self, forKey: .roleCheck)) ?? nil
    }

    public init(name: String, role: String, n: Int = 1, title: String? = nil, kind: String? = nil, model: String? = nil,
                alive: Bool = true, paneID: String? = nil, sessionID: String? = nil, cwd: String? = nil, branch: String? = nil,
                started: Int? = nil, idleS: Int? = nil, waitingHuman: Bool = false, addr: String? = nil, roleCheck: RoleCheck? = nil) {
        self.name = name
        self.role = role
        self.n = n
        self.title = title
        self.kind = kind
        self.model = model
        self.alive = alive
        self.paneID = paneID
        self.sessionID = sessionID
        self.cwd = cwd
        self.branch = branch
        self.started = started
        self.idleS = idleS
        self.waitingHuman = waitingHuman
        self.addr = addr
        self.roleCheck = roleCheck
    }

    /// В панели агента не сессия его роли (`role_check.ok == false`).
    public var notRole: Bool { roleCheck?.notRole == true }
}

public struct TeamEvent: Codable, Equatable, Sendable, Identifiable {
    public var ts: Int
    public var type: String
    public var agent: String
    public var text: String
    public var task: String?
    /// Название задачи у события `task` (null — задача снята; у старого CLI ключа нет).
    public var title: String?

    public var id: String { "\(ts)-\(type)-\(agent)-\(text.hashValue)" }

    public init(ts: Int, type: String, agent: String, text: String, task: String? = nil) {
        self.ts = ts
        self.type = type
        self.agent = agent
        self.text = text
        self.task = task
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(Int.self, forKey: .ts) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        agent = try c.decodeIfPresent(String.self, forKey: .agent) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
    }
}

public struct Handoff: Codable, Equatable, Sendable, Identifiable {
    public struct Sections: Codable, Equatable, Sendable {
        public var done: String
        public var verified: String
        public var inProgress: String
        public var pitfalls: String
        public var next: String

        enum CodingKeys: String, CodingKey {
            case done, verified, pitfalls, next
            case inProgress = "in_progress"
        }

        public init(done: String = "", verified: String = "", inProgress: String = "", pitfalls: String = "", next: String = "") {
            self.done = done
            self.verified = verified
            self.inProgress = inProgress
            self.pitfalls = pitfalls
            self.next = next
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            done = c.lossyString(.done) ?? ""
            verified = c.lossyString(.verified) ?? ""
            inProgress = c.lossyString(.inProgress) ?? ""
            pitfalls = c.lossyString(.pitfalls) ?? ""
            next = c.lossyString(.next) ?? ""
        }
    }

    public var id: String
    public var agent: String
    public var ts: Int
    public var task: String?
    public var reason: String?
    public var status: String
    public var branch: String?
    public var worktree: String?
    public var sections: Sections
    /// Когда передачей воспользовались (новое поле контракта).
    public var usedAt: Int?

    enum CodingKeys: String, CodingKey {
        case id, agent, ts, task, reason, status, branch, worktree, sections
        case usedAt = "used_at"
    }

    public init(id: String, agent: String, ts: Int, task: String? = nil, reason: String? = nil, status: String,
                branch: String? = nil, worktree: String? = nil, sections: Sections = Sections(), usedAt: Int? = nil) {
        self.id = id; self.agent = agent; self.ts = ts; self.task = task; self.reason = reason; self.status = status
        self.branch = branch; self.worktree = worktree; self.sections = sections; self.usedAt = usedAt
    }

    /// Поля шапки передачи — мягко: `task: 554` без кавычек — число в YAML, оно становится текстом «554».
    /// Без `id` передача не читается (её не открыть и не отметить).
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyString(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: d.codingPath, debugDescription: "передача без id"))
        }
        self.id = id
        agent = c.lossyString(.agent) ?? ""
        ts = c.lossyInt(.ts) ?? 0
        task = c.lossyString(.task)
        reason = c.lossyString(.reason)
        status = c.lossyString(.status) ?? ""
        branch = c.lossyString(.branch)
        worktree = c.lossyString(.worktree)
        sections = (try? c.decodeIfPresent(Sections.self, forKey: .sections)) ?? Sections()
        usedAt = c.lossyInt(.usedAt)
    }

    public var isWaiting: Bool { status == "waiting" }
}

public struct RoleInfo: Codable, Equatable, Sendable, Identifiable {
    public struct Worktree: Codable, Equatable, Sendable {
        public var dir: String?
        public var branch: String?
        public var repo: String?

        enum CodingKeys: String, CodingKey { case dir, branch, repo }

        public init(dir: String? = nil, branch: String? = nil, repo: String? = nil) {
            self.dir = dir; self.branch = branch; self.repo = repo
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            dir = c.lossyString(.dir)
            branch = c.lossyString(.branch)
            repo = c.lossyString(.repo)
        }
    }

    public var role: String
    public var title: String?
    public var kind: String?
    public var model: String?
    public var description: String?
    public var start: String?
    public var file: String?
    public var worktree: Worktree?
    public var zone: [String]
    public var includes: [String]
    public var allow: [String]
    public var trackerZone: String?
    public var effectiveAllow: [String]
    public var running: Int
    public var body: String?
    public var instruction: String?
    public var error: String?
    /// Откуда роль: «project» (agents/roles проекта) или «library» (общая библиотека инструмента); пусто — роль проекта.
    public var source: String?
    /// Общая роль, которую эта наследует (поле `extends` файла роли проекта).
    public var extends: String?

    public var id: String { role }

    public init(role: String, title: String? = nil, kind: String? = nil, model: String? = nil, description: String? = nil,
                start: String? = nil, source: String? = nil, extends: String? = nil,
                body: String? = nil, instruction: String? = nil) {
        self.role = role; self.title = title; self.kind = kind; self.model = model; self.description = description
        self.start = start; self.source = source; self.extends = extends
        self.body = body; self.instruction = instruction
        zone = []; includes = []; allow = []; effectiveAllow = []; running = 0
    }

    enum CodingKeys: String, CodingKey {
        case role, title, kind, model, description, start, file, worktree, zone, includes, allow, running, body, instruction, error, source, extends
        case trackerZone = "tracker_zone"
        case effectiveAllow = "effective_allow"
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        // Поля файла роли — мягко: значение YAML не того вида (число, логическое) не должно ронять весь список ролей.
        guard let role = c.lossyString(.role), !role.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.role, .init(codingPath: d.codingPath, debugDescription: "роль без имени"))
        }
        self.role = role
        title = c.lossyString(.title)
        kind = c.lossyString(.kind)
        model = c.lossyString(.model)
        description = c.lossyString(.description)
        start = c.lossyString(.start)
        file = c.lossyString(.file)
        worktree = try? c.decodeIfPresent(Worktree.self, forKey: .worktree)
        zone = (try? c.decodeIfPresent([String].self, forKey: .zone)) ?? []
        includes = (try? c.decodeIfPresent([String].self, forKey: .includes)) ?? []
        allow = (try? c.decodeIfPresent([String].self, forKey: .allow)) ?? []
        trackerZone = c.lossyString(.trackerZone)
        effectiveAllow = (try? c.decodeIfPresent([String].self, forKey: .effectiveAllow)) ?? []
        running = c.lossyInt(.running) ?? 0
        body = c.lossyString(.body)
        instruction = c.lossyString(.instruction)
        error = c.lossyString(.error)
        source = c.lossyString(.source)
        extends = c.lossyString(.extends)
    }

    /// Роль общей библиотеки: в проекте только читается.
    public var isShared: Bool { source == "library" }
    public var isInheriting: Bool { !isShared && !(extends ?? "").isEmpty }
}

public struct CheckReport: Codable, Equatable, Sendable {
    public struct Issue: Codable, Equatable, Sendable, Identifiable {
        public var level: String
        public var title: String
        public var detail: String
        public var id: String { level + title + detail }
    }

    public var passed: Int
    public var issues: [Issue]

    public var problems: [Issue] { issues.filter { $0.level != "ok" } }
}

/// Шапка agents/team.yaml для блока настроек проекта на экране «Роли». Читается приложением напрямую: CLI её не отдаёт,
/// а нужны только четыре скалярных поля. YAML-библиотеку ради них не тянем.
public struct TeamYAMLSummary: Equatable, Sendable {
    public var layout: String?
    public var manager: String?
    public var tracker: String?
    public var worktreeRoot: String?
    public var starts: [String: String]
    /// Ключ `idle_stop_minutes`: нет ключа — порог по умолчанию, число — порог, `off`/`false` — выключено.
    public var idleStop: IdleStopSetting = .byDefault
    /// Через сколько минут простоя `team reap` гасит агентов «по требованию»; nil — автоостановка выключена.
    public var idleStopMinutes: Int? { idleStop.effectiveMinutes }

    /// Имя трекера из значения `tracker:`: строка как есть, а объект во flow-виде `{kind: linear, project: X}` — его `kind`
    /// (как в боковой панели, где имя берётся из `team status --json`).
    static func trackerName(_ value: String) -> String? {
        guard value.hasPrefix("{"), value.hasSuffix("}") else { return value }
        for part in value.dropFirst().dropLast().split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if kv.count == 2, kv[0] == "kind", !kv[1].isEmpty { return kv[1] }
        }
        return nil
    }

    public static func parse(_ text: String) -> TeamYAMLSummary {
        var s = TeamYAMLSummary(layout: nil, manager: nil, tracker: nil, worktreeRoot: nil, starts: [:])
        var currentRole: String?
        var inTracker = false           // `tracker:` без значения: имя трекера в строке `kind:` ниже
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = noComment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let topLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-")
            func value(_ key: String) -> String? {
                guard trimmed.hasPrefix(key + ":") else { return nil }
                let v = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            if topLevel {
                inTracker = trimmed == "tracker:"
                if let v = value("layout") { s.layout = v }
                if let v = value("manager") { s.manager = v }
                if let v = value("tracker") { s.tracker = trackerName(v) }
                if let v = value("worktree_root") { s.worktreeRoot = v }
                if trimmed.hasPrefix("idle_stop_minutes:") { s.idleStop = IdleStopSetting.parse(value("idle_stop_minutes")) }
                continue
            }
            if inTracker, trimmed.hasPrefix("kind:") {
                let v = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { s.tracker = v }
                continue
            }
            var item = trimmed
            if item.hasPrefix("- ") { item = String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            // Строка роли во flow-стиле: `- {role: tester, start: on_demand}` — так её пишет team role new.
            if item.hasPrefix("{"), item.hasSuffix("}") {
                var fields: [String: String] = [:]
                for part in item.dropFirst().dropLast().split(separator: ",") {
                    let kv = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
                    if kv.count == 2 { fields[kv[0]] = kv[1] }
                }
                if let r = fields["role"] {
                    currentRole = r
                    if let st = fields["start"] { s.starts[r] = st }
                }
                continue
            }
            if item.hasPrefix("role:") {
                currentRole = item.dropFirst(5).trimmingCharacters(in: .whitespaces)
            } else if item.hasPrefix("start:"), let r = currentRole {
                s.starts[r] = item.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }
        return s
    }
}

/// Строка ответа `team reap --json`: агент, простой и что с ним сделано (`stopped`, `would_stop`, `kept`).
public struct ReapEntry: Decodable, Equatable, Sendable {
    public var name: String
    public var idleSeconds: Int?
    public var action: String
    public var reason: String

    enum CodingKeys: String, CodingKey { case name, idleSeconds = "idle_s", action, reason }

    public init(name: String, idleSeconds: Int? = nil, action: String, reason: String = "") {
        self.name = name; self.idleSeconds = idleSeconds; self.action = action; self.reason = reason
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        idleSeconds = try? c.decodeIfPresent(Int.self, forKey: .idleSeconds)
        action = try c.decodeIfPresent(String.self, forKey: .action) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }

    public var stopped: Bool { action == "stopped" }
}

/// Сборка вызова `team reap` и разбор его ответа.
public enum Reap {
    /// Агенты, которых нельзя гасить, пока в приложении у них есть неотправленное: очередь или черновик в поле ввода.
    /// Приложение пишет только менеджеру, поэтому очередь и черновик — у него; менеджера reap и так не трогает,
    /// но имя передаётся, чтобы защита не зависела от этого правила.
    public static func keepNames(manager: String?, hasQueue: Bool, hasDraft: Bool) -> [String] {
        guard let manager, !manager.isEmpty, hasQueue || hasDraft else { return [] }
        return [manager]
    }

    /// Проекты, которым нужен reap: с живой сессией команды и известным каталогом. Открыт проект в приложении или нет — не важно.
    public static func targets(_ entries: [ProjectEntry]) -> [(session: String, repo: String)] {
        entries.compactMap { e in
            guard e.running, let repo = e.repo, !repo.isEmpty else { return nil }
            return (e.session, repo)
        }
    }

    /// Один вызов `team reap --json`: ошибка — в журнал приложения без показа. Возвращает остановленных.
    public static func run(cli: TeamCLI, repo: String, session: String, keep: [String]) async -> [ReapEntry] {
        do {
            return try await cli.reap(keep: keep, cwd: repo).filter(\.stopped)
        } catch {
            NSLog("agent-team: team reap (%@): %@", session, "\(error)")
            return []
        }
    }

    public static func arguments(keep: [String]) -> [String] {
        var a = ["reap", "--json"]
        if !keep.isEmpty { a += ["--keep"] + keep }
        return a
    }

    /// Строка для журнала: «developer#2 остановлен: простой 12 мин».
    public static func journalLine(_ e: ReapEntry) -> String { "\(e.name) остановлен: \(e.reason)" }
}

/// Значение `idle_stop_minutes` в team.yaml. Автоостановка включена всегда, пока не выключена явно.
public enum IdleStopSetting: Equatable, Sendable {
    case byDefault
    case minutes(Int)
    case off

    /// Порог без ключа в team.yaml.
    public static let defaultMinutes = 15

    /// Пусто, нераспознанное и неположительное — по умолчанию (как у CLI: пусто = нет ключа).
    public static func parse(_ raw: String?) -> IdleStopSetting {
        guard let t = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !t.isEmpty else { return .byDefault }
        if t == "off" || t == "false" { return .off }
        if let n = Int(t), n > 0 { return .minutes(n) }
        return .byDefault
    }

    public var effectiveMinutes: Int? {
        switch self {
        case .byDefault: return Self.defaultMinutes
        case let .minutes(n): return n
        case .off: return nil
        }
    }
}

/// Поле автоостановки: что владелец ввёл в ячейке настроек и что из этого пойдёт в `team set idle_stop_minutes`.
public enum IdleStopInput: Equatable, Sendable {
    case off
    case minutes(Int)
    case invalid

    public static func parse(_ text: String) -> IdleStopInput {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return .minutes(IdleStopSetting.defaultMinutes) }   // пусто — вернуть умолчание: `team set` ключ не удаляет
        if t == "выкл" || t == "off" || t == "false" { return .off }
        if let n = Int(t), n > 0 { return .minutes(n) }
        return .invalid
    }

    /// Значение аргумента `team set idle_stop_minutes <значение>`.
    public var argument: String? {
        switch self {
        case .off: return "off"
        case let .minutes(n): return String(n)
        case .invalid: return nil
        }
    }

    public static let hint = "целое число минут больше нуля или «выкл»"
}

/// Ответ `team set <ключ> <значение> --json`: значение `null` — ключ убран из team.yaml.
public struct SetResult: Decodable, Equatable, Sendable {
    public var key: String
    public var value: Int?
}
