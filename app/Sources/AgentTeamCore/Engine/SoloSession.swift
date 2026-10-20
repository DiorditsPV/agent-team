import Foundation

/// Запись списка отдельных сессий Claude Code (без команды `team`).
public struct SoloSession: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var cwd: String
    public var title: String
    /// Имя tmux-сессии; задаётся при создании и не меняется.
    public var tmuxName: String
    /// Сессия Claude, с которой начата запись; к ней привязано закреплённое.
    public var launchSessionID: String
    /// Последняя известная текущая сессия (после `/clear`, продолжения, ухода в фон).
    public var sessionID: String
    public var created: Date
    public var lastStarted: Date

    public init(id: UUID = UUID(), cwd: String, title: String? = nil, tmuxName: String? = nil,
                launchSessionID: String? = nil, sessionID: String? = nil,
                created: Date = Date(), lastStarted: Date? = nil) {
        self.id = id
        self.cwd = cwd
        self.title = title ?? SoloNaming.defaultTitle(cwd: cwd)
        self.tmuxName = tmuxName ?? SoloNaming.tmuxName(cwd: cwd, id: id)
        let launch = launchSessionID ?? UUID().uuidString.lowercased()
        self.launchSessionID = launch
        self.sessionID = sessionID ?? launch
        self.created = created
        self.lastStarted = lastStarted ?? created
    }

    /// Старый формат без части полей читается с умолчаниями: список в defaults переживает обновления.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let id = try c.decode(UUID.self, forKey: .id)
        let cwd = try c.decode(String.self, forKey: .cwd)
        let launch = try c.decodeIfPresent(String.self, forKey: .launchSessionID) ?? ""
        let created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date(timeIntervalSince1970: 0)
        self.init(
            id: id, cwd: cwd, title: try c.decodeIfPresent(String.self, forKey: .title),
            tmuxName: try c.decodeIfPresent(String.self, forKey: .tmuxName), launchSessionID: launch,
            sessionID: try c.decodeIfPresent(String.self, forKey: .sessionID), created: created,
            lastStarted: try c.decodeIfPresent(Date.self, forKey: .lastStarted))
    }

    private enum Keys: String, CodingKey {
        case id, cwd, title, tmuxName, launchSessionID, sessionID, created, lastStarted
    }
}

/// Состояние отдельной сессии для боковой панели.
public enum SoloState: Equatable, Sendable {
    case running(ClaudeState)
    /// Панель мертва, tmux-сессия есть.
    case exited
    /// tmux-сессии нет.
    case stopped
    /// Каталога больше нет.
    case missingDir
}

/// Состояние Claude Code по записи процесса.
public enum ClaudeState: String, Equatable, Sendable {
    case busy, idle, waiting, unknown

    public init(record: ClaudeSessionRecord?) {
        self = record?.state.flatMap(ClaudeState.init(rawValue:)) ?? .unknown
    }
}

/// Команда запуска отдельной сессии: настройки владельца, без `--allowedTools`, `--permission-mode`, `--settings`.
public enum SoloLaunch {
    /// Та же строка, что `build.UNSET_CLAUDE_VARS` в CLI: иначе claude примет себя за дочернюю сессию той, что подняла сервер.
    public static let unsetClaudeVars =
        #"for v in $(env | sed -n "s/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p"); do [ "$v" = CLAUDE_CONFIG_DIR ] || unset "$v"; done"#

    /// Аргументы `sh -c <скрипт>`. `exec` оставляет pid панели pid'ом claude: по нему читается запись сессии.
    /// `resume` — продолжить сессию `sessionID`; иначе новая с этим id.
    public static func command(claude: String, sessionID: String, resume: Bool) -> [String] {
        let flag = resume ? "--resume" : "--session-id"
        return ["sh", "-c", "\(unsetClaudeVars); exec \(quote(claude)) \(flag) \(quote(sessionID))"]
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public enum SoloNaming {
    public static let prefix = "cc-"
    static let maxDirLength = 40

    public static func defaultTitle(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Каталог для имени tmux: только `[a-z0-9-]`, не длиннее 40 символов; пусто (например, кириллица) — `claude`.
    public static func sanitized(cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent.lowercased()
        var out = ""
        for u in name.unicodeScalars {
            let ok = (u.value >= 97 && u.value <= 122) || (u.value >= 48 && u.value <= 57)
            let ch: Character = ok ? Character(u) : "-"
            if ch == "-", out.last == "-" || out.isEmpty { continue }
            out.append(ch)
        }
        out = String(out.prefix(maxDirLength))
        while out.last == "-" { out.removeLast() }
        return out.isEmpty ? "claude" : out
    }

    /// `cc-<каталог>-<4 hex id>`, например `cc-agent-team-3f2a`.
    public static func tmuxName(cwd: String, id: UUID, hexLength: Int = 4) -> String {
        let hex = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)\(sanitized(cwd: cwd))-\(hex.prefix(hexLength))"
    }

    /// Имя, которого нет среди занятых: при совпадении первых 4 hex берётся больше символов id.
    public static func uniqueTmuxName(cwd: String, id: UUID, taken: Set<String>) -> String {
        for n in 4...32 {
            let name = tmuxName(cwd: cwd, id: id, hexLength: n)
            if !taken.contains(name) { return name }
        }
        return tmuxName(cwd: cwd, id: id, hexLength: 32)
    }
}

/// Хранение списка в defaults (`AppDefaults.store`), ключ `soloSessions`, JSON-массив.
public struct SoloStore {
    public static let key = "soloSessions"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppDefaults.store) { self.defaults = defaults }

    /// Запись, которая не разобралась, пропускается, остальные читаются.
    private struct Lossy: Decodable {
        let value: SoloSession?
        init(from decoder: Decoder) throws { value = try? SoloSession(from: decoder) }
    }

    public func load() -> [SoloSession] {
        guard let data = defaults.data(forKey: Self.key),
              let items = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return items.compactMap(\.value)
    }

    public func save(_ list: [SoloSession]) {
        // Сырые данные, которые не разобрались как массив, не затираются молча: копия остаётся под другим ключом.
        if let raw = defaults.data(forKey: Self.key), (try? JSONDecoder().decode([Lossy].self, from: raw)) == nil {
            defaults.set(raw, forKey: Self.key + ".unreadable")
        }
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: Self.key) }
    }

    /// Добавляет запись. Переданное имя tmux сохраняется, если его не занимает другая запись или живая сессия
    /// (`alsoTaken`); иначе подбирается уникальное.
    @discardableResult
    public func add(_ session: SoloSession, alsoTaken: Set<String> = []) -> SoloSession {
        var list = load()
        var s = session
        list.removeAll { $0.id == s.id }
        let taken = Set(list.map(\.tmuxName)).union(alsoTaken)
        if s.tmuxName.isEmpty || taken.contains(s.tmuxName) {
            s.tmuxName = SoloNaming.uniqueTmuxName(cwd: s.cwd, id: s.id, taken: taken)
        }
        list.append(s)
        save(list)
        return s
    }

    /// Новая текущая сессия Claude; пишется сразу — после выхода процесса записи по pid уже нет.
    public func setSessionID(_ sessionID: String, for id: UUID) {
        update(id) { $0.sessionID = sessionID }
    }

    public func rename(_ title: String, for id: UUID) { update(id) { $0.title = title } }

    public func remove(_ id: UUID) { save(load().filter { $0.id != id }) }

    private func update(_ id: UUID, _ change: (inout SoloSession) -> Void) {
        var list = load()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        save(list)
    }
}
