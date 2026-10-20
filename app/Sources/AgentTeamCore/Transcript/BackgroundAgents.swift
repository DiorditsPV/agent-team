import Foundation

/// Субагент, которого сессия Claude Code запустила и который ещё работает.
public struct BackgroundAgent: Equatable, Sendable, Identifiable {
    /// agentId Claude Code («aec04116428155bdc»).
    public var id: String
    /// Вид субагента: «Explore», «general-purpose».
    public var type: String
    /// Краткая задача — `description` вызова Agent.
    public var task: String
    /// Что делает сейчас: последний вызов инструмента («Read · docs/SPEC.md») или начало последнего текста.
    public var action: String?
    /// Когда запущен.
    public var started: Date
    /// Запущен в фоне (`run_in_background`): ход сессии может закончиться раньше него.
    public var background: Bool

    public init(id: String, type: String, task: String, action: String? = nil, started: Date, background: Bool = true) {
        self.id = id
        self.type = type
        self.task = task
        self.action = action
        self.started = started
        self.background = background
    }

    /// «12 с», «3 мин 05 с».
    public func elapsedText(now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(started)))
        return s >= 60 ? String(format: "%d мин %02d с", s / 60, s % 60) : "\(s) с"
    }
}

/// Запущенные субагенты сессии и ждёт ли их ход. Источник — файлы Claude Code, а не экран: экран показывает список
/// только под строкой ввода и только у панели на экране, а файлы есть у любой сессии.
/// - `<сессия>/subagents/agent-<id>.meta.json` — вид, задача (`description`), `toolUseId`, фоновый ли запуск;
/// - `<сессия>/subagents/agent-<id>.jsonl` — транскрипт субагента: по последнему вызову — текущее действие;
/// - `<сессия>.jsonl` — завершение: у фонового `<task-notification>` с его `<task-id>`, у обычного — результат его
///   `tool_use_id`; ход, который кончился с незавершёнными фоновыми, пишет `pendingBackgroundAgentCount` в `turn_duration`.
public struct BackgroundAgents: Equatable, Sendable {
    public var running: [BackgroundAgent]
    /// Ход сессии кончился, а фоновые ещё работают: Claude Code показывает «Waiting for N background agents to finish».
    public var turnWaits: Bool

    public init(running: [BackgroundAgent] = [], turnWaits: Bool = false) {
        self.running = running
        self.turnWaits = turnWaits
    }

    public static let none = BackgroundAgents()

    /// Окно хвоста транскрипта сессии, в котором ищется завершение. Субагент, запущенный раньше окна и не писавший
    /// дольше `stale`, считается оборванным.
    static let window: UInt64 = 4 << 20
    /// Окна хвоста транскрипта субагента для текущего действия: за вызовом может лежать большой результат (целый
    /// прочитанный файл), поэтому окно растёт, пока вызов не найдётся.
    static let actionWindows: [UInt64] = [128 << 10, 1 << 20, 4 << 20]
    /// Дольше этого субагент не пишет в свой транскрипт — он не работает (оборван, сессия закрыта).
    public static let stale: TimeInterval = 1800

    /// Каталог субагентов сессии: рядом с `<сессия>.jsonl` — `<сессия>/subagents`.
    public static func directory(transcript url: URL) -> URL {
        url.deletingPathExtension().appendingPathComponent("subagents")
    }

    public static func read(transcript url: URL, now: Date = Date()) -> BackgroundAgents {
        let fm = FileManager.default
        let dir = directory(transcript: url)
        // Даты всех файлов каталога — одним чтением вместе со списком: по stat на файл каталог из сотен субагентов
        // стоил около 20 мс.
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return .none }
        var dates: [String: (modified: Date, created: Date?)] = [:]
        for f in files where f.pathExtension == "jsonl" {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), let m = v.contentModificationDate else { continue }
            dates[f.lastPathComponent] = (m, v.creationDate)
        }
        // Кандидаты — субагенты, писавшие недавно: в долгой сессии их сотни, старые не читаются.
        var candidates: [(meta: Meta, file: URL, started: Date)] = []
        for f in files {
            let n = f.lastPathComponent
            guard n.hasPrefix("agent-"), n.hasSuffix(".meta.json") else { continue }
            let id = String(n.dropFirst("agent-".count).dropLast(".meta.json".count))
            let file = dir.appendingPathComponent("agent-\(id).jsonl")
            guard let d = dates[file.lastPathComponent], now.timeIntervalSince(d.modified) < stale,
                  let data = fm.contents(atPath: f.path),
                  let meta = Meta(id: id, json: data) else { continue }
            candidates.append((meta, file, d.created ?? d.modified))
        }
        // Без недавних субагентов хвост сессии не нужен: в долгой сессии он 4 МБ.
        guard !candidates.isEmpty else { return .none }
        let tail = Self.tailData(url, window) ?? Data()
        let waits = turnWaits(tail)
        var running: [BackgroundAgent] = []
        for c in candidates where !finished(c.meta, in: tail) {
            running.append(BackgroundAgent(id: c.meta.id, type: c.meta.type, task: c.meta.task,
                                           action: action(file: c.file),
                                           started: c.started, background: c.meta.background))
        }
        running.sort { $0.started < $1.started }
        return BackgroundAgents(running: running, turnWaits: waits && running.contains(where: \.background))
    }

    struct Meta {
        var id: String
        var type: String
        var task: String
        var toolUseID: String?
        var background: Bool

        init?(id: String, json: Data) {
            guard let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
            self.id = id
            type = o["agentType"] as? String ?? "agent"
            task = o["description"] as? String ?? ""
            toolUseID = o["toolUseId"] as? String
            background = (o["requestShape"] as? String) == "background"
        }
    }

    /// Субагент завершён: фоновый — уведомление с его `<task-id>`, обычный — результат его вызова Agent. Поиск по
    /// байтам: `String.contains` по хвосту в 4 МБ стоил около 70 мс на каждого субагента.
    static func finished(_ m: Meta, in tail: Data) -> Bool {
        if tail.range(of: Data("<task-id>\(m.id)</task-id>".utf8)) != nil { return true }
        if !m.background, let t = m.toolUseID {
            // Запуск фонового тоже даёт результат (async_launched), поэтому этот признак — только для обычного.
            return tail.range(of: Data("\"tool_use_id\":\"\(t)\"".utf8)) != nil
        }
        return false
    }

    /// Последняя запись хода — `turn_duration` с незавершёнными фоновыми, после неё ответа модели нет. Строки
    /// просматриваются с конца до первой подходящей: разбивка всего хвоста на строки стоила около 50 мс.
    static func turnWaits(_ tail: Data) -> Bool {
        let duration = Data("\"subtype\":\"turn_duration\"".utf8)
        for line in linesFromEnd(tail) {
            if line.range(of: assistantMark) != nil { return false }
            if line.range(of: duration) != nil {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { return false }
                return (o["pendingBackgroundAgentCount"] as? Int ?? 0) > 0
            }
        }
        return false
    }

    private static let assistantMark = Data("\"type\":\"assistant\"".utf8)

    /// Строки данных с конца, лениво: просмотр обычно кончается на последних строках.
    static func linesFromEnd(_ data: Data) -> UnfoldSequence<Data.SubSequence, Data.Index> {
        sequence(state: data.endIndex) { end in
            guard end > data.startIndex else { return nil }
            let start = data[..<end].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? data.startIndex
            defer { end = start > data.startIndex ? start - 1 : data.startIndex }
            return data[start..<end]
        }
    }

    static func action(file: URL) -> String? {
        for w in actionWindows {
            if let a = action(Self.tailData(file, w) ?? Data()) { return a }
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber, size.uint64Value <= w { break }
        }
        return nil
    }

    /// Последний вызов инструмента или текст ответа в хвосте транскрипта субагента. Строки — с конца, по байтам.
    static func action(_ tail: Data) -> String? {
        for line in linesFromEnd(tail) where line.range(of: assistantMark) != nil {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let msg = o["message"] as? [String: Any],
                  let blocks = msg["content"] as? [[String: Any]] else { continue }
            for b in blocks.reversed() {
                switch b["type"] as? String {
                case "tool_use":
                    let kind = TranscriptParser.toolKind(name: b["name"] as? String ?? "?", input: b["input"] as? [String: Any] ?? [:])
                    switch kind {
                    case let .tool(name, summary): return summary.isEmpty ? name : name + " · " + summary
                    case let .tracker(a, s): return "трекер · " + a + (s.isEmpty ? "" : " · " + s)
                    case let .sendMessage(to, _): return "SendMessage · " + to
                    default: return nil
                    }
                case "text":
                    let t = (b["text"] as? String ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
                    if let t { return t.count > 120 ? String(t.prefix(120)) + "…" : t }
                default:
                    continue
                }
            }
        }
        return nil
    }

    /// Хвост файла; первая (обрезанная) строка окна отбрасывается по байтам, до декодирования.
    static func tailData(_ url: URL, _ window: UInt64) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let offset = size > window ? size - window : 0
        try? fh.seek(toOffset: offset)
        guard var data = try? fh.readToEnd() else { return nil }
        if offset > 0 { data = Data(data.drop { $0 != UInt8(ascii: "\n") }.dropFirst()) }
        return data
    }
}
