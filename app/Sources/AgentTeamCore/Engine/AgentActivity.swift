import Foundation

/// Что агент делал в последний раз — по его транскрипту, а не по шуму в панели: простаивающий Claude Code перерисовывает
/// экран (строка состояния, курсор), и «время вывода» ни о чём не говорит.
public struct AgentActivity: Equatable, Sendable {
    /// Время последнего действия: сообщение, ответ, инструмент, результат, конец хода. Служебные записи (сводка
    /// «пока вас не было», напоминания, вывод команд владельца вроде `/model`) действием агента не считаются.
    public var lastAction: Date?
    /// Ход идёт: после границы (конец хода, прерывание, сжатие) есть ответ агента или причина хода без ответа.
    public var inTurn: Bool
    /// Начало текущего хода: первая причина хода после границы (сообщение, плановый запуск, уведомление);
    /// без причины в окне — первый ответ после границы. Нет, если границу найти не удалось.
    public var turnStart: Date?
    /// Агент задал вопрос с вариантами (AskUserQuestion), и ответа в транскрипте ещё нет.
    public var pendingAsk: Bool
    /// Модель агента коротким именем («Opus 5.5»): последняя из ответа модели и вывода `/model`. Ответ несёт id модели,
    /// которая отвечала; после `/model` новая модель видна сразу, до следующего ответа.
    public var model: String?
    /// Вопросы AskUserQuestion без ответа (их tool_use_id): по ним дочитанные строки снимают `pendingAsk`.
    var openAsks: Set<String> = []

    public init(lastAction: Date? = nil, inTurn: Bool = false, turnStart: Date? = nil, pendingAsk: Bool = false, model: String? = nil) {
        self.lastAction = lastAction
        self.inTurn = inTurn
        self.turnStart = turnStart
        self.pendingAsk = pendingAsk
        self.model = model
    }

    /// Окна чтения с конца файла: начало хода может лежать за большими результатами инструментов, поэтому окно
    /// растёт, пока не найдётся граница хода. Полное чтение бывает только при первом взгляде на файл (дальше файл
    /// дочитывается по новым байтам, `continued`), поэтому окно ограничено 4 МБ: за ним лежит ход длиной в десятки
    /// больших результатов, у него будет «работает» без длительности, а не разбор 16 МБ.
    static let windows: [UInt64] = [256 << 10, 1 << 20, 4 << 20]

    public static func == (a: AgentActivity, b: AgentActivity) -> Bool {
        a.lastAction == b.lastAction && a.inTurn == b.inTurn && a.turnStart == b.turnStart && a.pendingAsk == b.pendingAsk
            && a.model == b.model
    }

    /// Дольше этого запись в транскрипте не появляется — ход считается оборванным, а не долгим инструментом.
    static let staleTurn: TimeInterval = 1800

    /// Ход идёт сейчас: транскрипт говорит о ходе и последняя запись свежая.
    public func isWorking(now: Date) -> Bool {
        guard inTurn, let last = lastAction else { return false }
        return now.timeIntervalSince(last) < Self.staleTurn
    }

    /// `nil` — файла нет или в нём нет ни одной записи-действия (данных об агенте нет).
    public static func read(url: URL, windows: [UInt64]? = nil) -> AgentActivity? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        var result: AgentActivity?
        for window in windows ?? Self.windows {
            let offset = size > window ? size - window : 0
            try? fh.seek(toOffset: offset)
            guard var data = try? fh.readToEnd() else { return result }
            // Окно начинается где попало, в том числе посреди многобайтовой буквы: первая (обрезанная) строка
            // отбрасывается по байтам, до декодирования. Иначе String(data:) возвращал nil на кириллице,
            // и статус откатывался на прежний источник.
            if offset > 0 { data = data.drop { $0 != UInt8(ascii: "\n") }.dropFirst() }
            let text = String(decoding: data, as: UTF8.self)
            let (a, bounded) = parseWindow( text.split(separator: "\n", omittingEmptySubsequences: true))
            result = a.lastAction == nil ? nil : a
            if offset == 0 || bounded || a.turnStart != nil { break }
        }
        return result
    }

    static func parse(lines: [Substring]) -> AgentActivity { parseWindow(lines).0 }

    /// Идём с конца до границы хода. Ход определяется по структуре, а не по виду сообщения: ход идёт, если после
    /// границы есть ответ агента (он отвечает на любое — сообщение владельца, другой сессии, плановый запуск,
    /// уведомление о фоновой задаче) или пришла причина хода, на которую ответа ещё нет.
    /// Границы: `turn_duration`, запись о прерывании, сводка сжатия, ответ-ошибка API.
    static func parseWindow(_ lines: [Substring]) -> (AgentActivity, bounded: Bool) {
        let sc = scan(lines)
        return (sc.activity, sc.bounded)
    }

    /// Итог прохода по строкам с конца и то, что нужно для дочитывания (`continued`).
    struct Scan {
        var activity: AgentActivity
        var bounded: Bool
        /// Первая причина хода после границы и первый ответ после неё.
        var start: Date?
        var firstAnswer: Date?
        /// tool_use_id, на которые в строках есть результат.
        var answered: Set<String>
    }

    /// Запись — вывод команды владельца, а не сообщение, в котором такой вывод процитирован: текст с него начинается.
    static func isCommandOutput(_ text: String) -> Bool {
        text.drop { $0.isWhitespace }.hasPrefix("<local-command-stdout>")
    }

    /// Последняя модель в строках — с конца, без оглядки на границы хода: у простаивающего агента последняя запись —
    /// конец хода, а модель записана в ответе до него. JSON разбирается только у строк, где модель может быть.
    static func lastModel(_ lines: [Substring]) -> String? {
        for line in lines.reversed() {
            let maybeAnswer = line.contains("\"model\""), maybeCommand = line.contains("Set model to")
            guard maybeAnswer || maybeCommand,
                  let d = line.data(using: .utf8), let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  r["isSidechain"] as? Bool != true else { continue }
            let msg = r["message"] as? [String: Any]
            switch (r["type"] as? String, r["subtype"] as? String) {
            case ("assistant", _):
                if let id = msg?["model"] as? String, let name = ModelName.short(id) { return name }
            case ("user", _):
                if let text = msg?["content"] as? String, isCommandOutput(text),
                   let name = ModelName.fromModelCommand(text) { return name }
            case ("system", "local_command"):
                // Вывод команд владельца Claude Code пишет и записью system/local_command, текст — в content.
                if let text = r["content"] as? String, isCommandOutput(text),
                   let name = ModelName.fromModelCommand(text) { return name }
            default: break
            }
        }
        return nil
    }

    static func scan(_ lines: [Substring]) -> Scan {
        var last: Date?
        var start: Date?
        var firstAnswer: Date?
        var answered = Set<String>()     // tool_use_id, на которые результат уже есть (идём с конца: результаты видим раньше)
        var openAsks = Set<String>()
        var sawAnswer = false
        var bounded = false
        func touch(_ t: Date) { if last == nil { last = t } }
        scan: for line in lines.reversed() {
            guard let d = line.data(using: .utf8), let r = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  r["isSidechain"] as? Bool != true,
                  let ts = r["timestamp"] as? String, let t = TranscriptParser.iso.date(from: ts) else { continue }
            // Результат инструмента — действие, но ход не меняет; по нему снимаются вопросы AskUserQuestion.
            if r["type"] as? String == "user",
               let blocks = (r["message"] as? [String: Any])?["content"] as? [[String: Any]],
               blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                touch(t)
                for b in blocks { if let id = b["tool_use_id"] as? String { answered.insert(id) } }
                continue
            }
            // Ход — по общему правилу ленты и статуса (TranscriptParser.turnMark).
            switch TranscriptParser.turnMark(r) {
            case .end:
                // Ошибка API раньше уже виденного ответа — не граница: после неё модель ответила, ход продолжился.
                if r["isApiErrorMessage"] as? Bool == true, sawAnswer { fallthrough }
                touch(t); bounded = true; break scan
            case .answer:
                touch(t)
                sawAnswer = true
                firstAnswer = t
                for b in ((r["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                where b["type"] as? String == "tool_use" && b["name"] as? String == "AskUserQuestion" {
                    if let id = b["id"] as? String, !answered.contains(id) { openAsks.insert(id) }
                }
            case .start:
                touch(t)
                start = t
            case .none:
                // Ответ модели без хода не бывает; остальное без хода (служебное, команды владельца) — не действие.
                break
            }
        }
        let inTurn = sawAnswer || start != nil
        let begin = start ?? (bounded ? firstAnswer : nil)
        var a = AgentActivity(lastAction: last, inTurn: inTurn, turnStart: inTurn ? begin : nil, pendingAsk: !openAsks.isEmpty && inTurn,
                              model: lastModel(lines))
        a.openAsks = openAsks
        return Scan(activity: a, bounded: bounded, start: start, firstAnswer: firstAnswer, answered: answered)
    }

    /// Файл дописан: разбираются только новые строки, итог сливается с прежним. Совпадает с полным разбором (тест
    /// сверяет во всех точках разреза транскриптов): граница хода в новых строках решает всё сама; без неё ход
    /// продолжается — начало хода прежнее, а если прежний итог был вне хода (последней была граница), ход начался
    /// в новых строках.
    public static func continued(_ p: AgentActivity, with lines: [Substring]) -> AgentActivity {
        let c = scan(lines)
        let model = c.activity.model ?? p.model
        // Новые строки без действий (например, только вывод `/model`) меняют разве что модель.
        guard c.activity.lastAction != nil else { var a = p; a.model = model; return a }
        if c.bounded { var a = c.activity; a.model = model; return a }
        var a = AgentActivity(lastAction: c.activity.lastAction, inTurn: p.inTurn || c.activity.inTurn, model: model)
        if a.inTurn {
            // Прежний итог вне хода с действиями — значит, его разбор упёрся в границу: начало хода — в новых строках,
            // как у полного разбора (причина или, без неё, первый ответ). Пустой прежний итог границы не видел.
            a.turnStart = p.inTurn ? p.turnStart : (c.start ?? (p.lastAction != nil ? c.firstAnswer : nil))
        }
        a.openAsks = p.openAsks.subtracting(c.answered).union(c.activity.openAsks)
        a.pendingAsk = a.inTurn && !a.openAsks.isEmpty
        return a
    }

    /// Новые целые строки файла с позиции `from` (прежний конец разобранного) и сколько байт они занимают.
    /// Незаконченная последняя строка (запись идёт) не берётся: её дочитает следующий проход. `nil` — файл не читается.
    static func appended(url: URL, from: UInt64) -> (lines: [Substring], bytes: UInt64)? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        try? fh.seek(toOffset: from)
        guard let data = try? fh.readToEnd() else { return nil }
        guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let whole = data[data.startIndex...lastNL]
        let text = String(decoding: whole, as: UTF8.self)
        return (text.split(separator: "\n", omittingEmptySubsequences: true), UInt64(whole.count))
    }
}

/// Опрос активности живых агентов. Каждый проход — `stat` транскрипта:
/// - файл не изменился (размер и время те же) — прежний итог, без поиска файла и чтения;
/// - дописан не больше чем на `maxAppend` — разбираются только новые строки (`AgentActivity.continued`);
/// - иначе (первый взгляд, другая сессия, файл укоротился, большой прирост, запись `continued-in`) — поиск файла по
///   цепочке продолжений и чтение хвоста окнами.
/// Так простаивающий агент стоит один `stat` за проход, а работающий — разбор того, что он дописал за 5 с.
public struct ActivityTracker: Sendable {
    struct Entry: Sendable {
        var sessionID: String
        var url: URL
        /// Сколько байт файла разобрано и время изменения на тот момент.
        var size: UInt64
        var modified: Date
        var activity: AgentActivity?
    }

    var entries: [String: Entry] = [:]
    /// Счётчики чтений (для проверки цены опроса).
    public private(set) var stats = 0, appends = 0, fullReads = 0

    /// Больше этого прироста за проход — полное чтение окнами, а не дочитывание.
    public static let maxAppend: UInt64 = 4 << 20

    public init() {}

    /// `keepOthers` — записи агентов не из `targets` остаются (частичное обновление: по событию ленты, по таймеру для
    /// агентов без ленты); иначе список агентов полный и записи ушедших выбрасываются.
    public mutating func refresh(_ targets: [(name: String, sessionID: String, cwd: String?)],
                                 home: String = TranscriptParser.claudeHome, keepOthers: Bool = false) -> [String: AgentActivity] {
        var out: [String: AgentActivity] = [:]
        var next: [String: Entry] = keepOthers ? entries : [:]
        for t in targets {
            next[t.name] = nil
            if let e = entries[t.name], e.sessionID == t.sessionID, let cur = Self.stamp(e.url) {
                stats += 1
                if cur.size == e.size, cur.modified == e.modified {
                    next[t.name] = e
                    if let a = e.activity { out[t.name] = a }
                    continue
                }
                if cur.size > e.size, cur.size - e.size <= Self.maxAppend, let prev = e.activity,
                   let add = AgentActivity.appended(url: e.url, from: e.size),
                   !add.lines.contains(where: { $0.contains("\"type\":\"continued-in\"") }) {
                    appends += 1
                    let a = AgentActivity.continued(prev, with: add.lines)
                    next[t.name] = Entry(sessionID: t.sessionID, url: e.url, size: e.size + add.bytes, modified: cur.modified, activity: a)
                    out[t.name] = a
                    continue
                }
            }
            guard let url = TranscriptParser.locate(cwd: t.cwd, sessionID: t.sessionID, home: home),
                  let cur = Self.stamp(url) else { continue }
            fullReads += 1
            let a = AgentActivity.read(url: url)
            // Разобранное кончается на последней целой строке: недописанную запись дочитает следующий проход.
            next[t.name] = Entry(sessionID: t.sessionID, url: url, size: Self.wholeLinesEnd(url, size: cur.size), modified: cur.modified, activity: a)
            if let a { out[t.name] = a }
        }
        entries = next
        return out
    }

    /// Конец последней целой строки файла (позиция за последним переводом строки в хвосте до 1 МБ).
    static func wholeLinesEnd(_ url: URL, size: UInt64) -> UInt64 {
        guard size > 0, let fh = try? FileHandle(forReadingFrom: url) else { return size }
        defer { try? fh.close() }
        let window = min(size, 1 << 20)
        try? fh.seek(toOffset: size - window)
        guard let data = try? fh.read(upToCount: Int(window)), let nl = data.lastIndex(of: UInt8(ascii: "\n")) else { return size }
        return size - window + UInt64(nl - data.startIndex + 1)
    }

    static func stamp(_ url: URL) -> (size: UInt64, modified: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return ((attrs[.size] as? NSNumber)?.uint64Value ?? 0, attrs[.modificationDate] as? Date ?? .distantPast)
    }
}

/// Формулировки времени агента: статус с длительностью и подсказка.
public enum AgentTime {
    /// «<1 мин», «7 мин», «3 ч 10 мин», «3 ч», «2 дн 3 ч».
    public static func span(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60
        if m < 1 { return "<1 мин" }
        if m < 60 { return "\(m) мин" }
        let h = m / 60
        if h < 48 { return m % 60 == 0 ? "\(h) ч" : "\(h) ч \(m % 60) мин" }
        let d = h / 24
        return h % 24 == 0 ? "\(d) дн" : "\(d) дн \(h % 24) ч"
    }

    /// Подпись состояния с длительностью: «работает · 2 мин», «простаивает · 3 ч 10 мин», «ждёт ответа · 5 мин».
    /// Длительность хода — с экрана панели, если на нём видна строка хода, иначе по транскрипту. Без данных
    /// длительности нет: время простоя по выводу панели не берётся (перерисовка экрана — не работа).
    public static func label(_ state: AgentState, activity: AgentActivity?, screenTurn: TurnStatus? = nil, now: Date = Date()) -> String {
        switch state {
        case .stopped: return "остановлен"
        case .noData: return "нет данных"
        case .working:
            if let screenTurn { return "работает · " + span(screenTurn.seconds) }
            guard let s = activity?.turnStart else { return "работает" }
            return "работает · " + span(Int(now.timeIntervalSince(s)))
        case let .waiting(why):
            guard let idle = idle(activity, now) else { return why }
            return why + " · " + span(idle)
        case let .quiet(minutes):
            return "простаивает · " + span(idle(activity, now) ?? minutes * 60)
        }
    }

    static func idle(_ a: AgentActivity?, _ now: Date) -> Int? {
        a?.lastAction.map { Int(now.timeIntervalSince($0)) }
    }

    /// Подсказка: запуск, последнее действие, текущий ход.
    public static func tooltip(started: Int?, activity: AgentActivity?, screenTurn: TurnStatus? = nil, now: Date = Date(),
                               timeZone: TimeZone = .current) -> String {
        func stamp(_ d: Date) -> String { DateFormats.string(d, "d MMM HH:mm", timeZone: timeZone) }
        var lines: [String] = []
        if let started {
            let d = Date(timeIntervalSince1970: TimeInterval(started))
            lines.append("Запуск: \(stamp(d)) · сессия \(span(Int(now.timeIntervalSince(d))))")
        }
        if let t = activity?.lastAction {
            lines.append("Последнее действие: \(stamp(t)) · \(span(Int(now.timeIntervalSince(t)))) назад")
        } else {
            lines.append("Последнее действие: нет данных (транскрипт сессии не найден или пуст)")
        }
        if let screenTurn {
            lines.append("Текущий ход: \(span(screenTurn.seconds)) (по экрану)")
        } else if let a = activity, a.isWorking(now: now), let s = a.turnStart {
            lines.append("Текущий ход: \(span(Int(now.timeIntervalSince(s))))")
        } else if activity != nil {
            lines.append("Текущий ход: нет")
        }
        return lines.joined(separator: "\n")
    }

    /// «сессия 7 ч», «сессия 25 мин» — подпись длительности жизни сессии.
    public static func session(started: Int?, now: Date = Date()) -> String {
        guard let started else { return "сессия —" }
        let s = max(0, Int(now.timeIntervalSince1970) - started)
        let h = s / 3600
        return h >= 1 ? "сессия \(h) ч" : "сессия \(max(1, s / 60)) мин"
    }
}
