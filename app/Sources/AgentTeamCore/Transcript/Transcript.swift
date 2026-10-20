import Foundation

/// Запись чата с менеджером, разложенная по видам из functionality.md.
public enum ChatKind: Equatable, Sendable {
    /// Сообщение владельца.
    case owner(String)
    /// Сообщение агенту через SendMessage: адресат (адрес или имя) и цитата.
    case sendMessage(to: String, text: String)
    /// Обращение к трекеру (`mcp__<трекер>__*`): короткое имя действия и суть.
    case tracker(action: String, summary: String)
    /// Прочий инструмент: имя и суть одной строкой.
    case tool(name: String, summary: String)
    /// Ответ менеджера (markdown).
    case reply(String)
    /// Входящее сообщение другой сессии.
    case incoming(fromName: String, fromAddr: String, text: String)
    /// Конец хода: длительность.
    case turnEnd(durationMs: Int)
    /// Контекст сжат: на месте сводки («This session is being continued…») в ленте стоит разделитель.
    case compacted
    /// Вывод встроенной команды Claude Code, которую владелец запустил в панели (`/context`, `/agents`, итог закрытого
    /// экрана вроде «Resume cancelled»): имя команды («/context») и текст без цветов ANSI.
    case command(name: String, output: String)
    /// Вызов команды Claude Code — встроенной, команды пользователя или проекта, скилла, команды плагина
    /// (`<command-name>/имя</command-name>`): имя («/model») и аргументы. По ней снимается карточка «отправлено» команды
    /// из поля — сообщением владельца Claude Code её не пишет. `prompt` — команда раскрывается в текст для модели (скилл,
    /// команда плагина или пользователя, запись начинается с `<command-message>`): она остаётся в ленте строкой
    /// «/имя аргументы». Встроенная команда в ленте видна только своим выводом (`.command`).
    case invoked(name: String, args: String, prompt: Bool = false)
    /// Claude Code не знает набранную команду (`system/informational` «Unknown command: /rsume. Did you mean /resume?»):
    /// имя и предложенная им замена. Снимает карточку команды из поля: другой записи о ней не будет.
    case unknownCommand(name: String, suggestion: String?)
}

/// Картинка из сообщения владельца: блок `type:image` транскрипта, base64.
public struct ChatImage: Equatable, Sendable, Identifiable {
    public var id: String
    public var mediaType: String
    public var base64: String

    public init(id: String, mediaType: String, base64: String) {
        self.id = id
        self.mediaType = mediaType
        self.base64 = base64
    }

    public var data: Data? { Data(base64Encoded: base64) }
}

public struct ChatEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var time: Date?
    public var kind: ChatKind
    /// Картинки сообщения владельца, в порядке «[Image #N]».
    public var images: [ChatImage]

    public init(id: String, time: Date?, kind: ChatKind, images: [ChatImage] = []) {
        self.id = id
        self.time = time
        self.kind = kind
        self.images = images
    }
}

public struct UsageInfo: Equatable, Sendable {
    public var model: String
    public var contextTokens: Int

    /// Окно контекста по модели. В транскрипте его нет; размер сверен со строкой статуса Claude Code
    /// (у Opus 5.5 179 679 токенов = 18 %, то есть окно 1 000 000).
    public var contextWindow: Int {
        if model.contains("haiku") { return 200_000 }
        return 1_000_000
    }

    public var contextPercent: Int { Int((Double(contextTokens) * 100 / Double(contextWindow)).rounded()) }

    /// «Opus 5.5» из «claude-opus-5-5»; разбор общий со строкой состояния агентов (`ModelName`).
    public var displayModel: String { ModelName.short(model) ?? model }
}

/// Разбор транскрипта Claude Code (`~/.claude/projects/<slug>/<session_id>.jsonl`).
public struct TranscriptParser: Sendable {
    public private(set) var entries: [ChatEntry] = []
    public private(set) var usage: UsageInfo?
    /// Ход идёт. Границы те же, что у хода агента (`AgentActivity.parse`): ход начинают сообщение владельца, входящее,
    /// сообщение в очереди, уведомление харнесса и ответ; заканчивают `turn_duration`, прерывание («[Request interrupted»),
    /// ошибка API и сводка сжатия. После прерывания Claude Code `turn_duration` не пишет.
    public private(set) var turnInProgress = false
    /// Вопрос `AskUserQuestion`, на который в транскрипте ещё нет результата. Снимается результатом с его id и концом хода.
    public private(set) var openQuestion: PendingQuestion?
    /// Имя команды из записи `<command-name>`, вывод которой ещё не пришёл.
    private var commandName: String?

    nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init() {}

    /// Путь к каталогу транскриптов: в cwd «/», «.» и прочие не буквенно-цифровые символы заменяются на «-».
    public static func projectSlug(cwd: String) -> String {
        String(cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    /// Домашний каталог Claude Code. Переменная `AGENT_TEAM_CLAUDE_HOME` подменяет его для снимков и проверок
    /// на заготовленных транскриптах, не трогая настоящие. Считается один раз за запуск: это параметр по умолчанию в
    /// опросах, а `ProcessInfo.environment` собирает словарь всего окружения при каждом обращении.
    public static let claudeHome: String =
        ProcessInfo.processInfo.environment["AGENT_TEAM_CLAUDE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()

    public static func transcriptURL(cwd: String, sessionID: String, home: String = claudeHome) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
            .appendingPathComponent(projectSlug(cwd: cwd)).appendingPathComponent(sessionID + ".jsonl")
    }

    /// Транскрипт живой сессии. Если по slug файла нет — ищем `<session_id>.jsonl` во всех каталогах проектов.
    /// Claude Code, продолжив работу в новой сессии (`/clear`, `/resume`, продолжение после сжатия), дописывает в
    /// старый файл запись `continued-in` и пишет дальше в новый; `team status` помнит сессию запуска, поэтому за
    /// такими записями идём до конца цепочки: иначе статус агента читался бы по файлу, в который давно не пишут.
    public static func locate(cwd: String?, sessionID: String, home: String = claudeHome) -> URL? {
        var url = locateFile(cwd: cwd, sessionID: sessionID, home: home)
        var seen: Set<String> = [sessionID]
        for _ in 0..<8 {
            guard let u = url, let next = continuation(of: u), seen.insert(next).inserted else { break }
            guard let n = locateFile(cwd: cwd, sessionID: next, home: home) else { break }
            url = n
        }
        return url
    }

    static func locateFile(cwd: String?, sessionID: String, home: String) -> URL? {
        let fm = FileManager.default
        if let cwd {
            let u = transcriptURL(cwd: cwd, sessionID: sessionID, home: home)
            if fm.fileExists(atPath: u.path) { return u }
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects")
        guard let dirs = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        for d in dirs {
            let u = root.appendingPathComponent(d).appendingPathComponent(sessionID + ".jsonl")
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// Сессия, в которую продолжена эта: запись `continued-in` в конце файла.
    static func continuation(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard let data = try? fh.readToEnd() else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() where line.count < 4096 {
            guard line.starts(with: Array(#"{"type":"continued-in""#.utf8)),
                  let r = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let id = r["continuedInSessionId"] as? String else { continue }
            return id
        }
        return nil
    }

    /// Самый свежий транскрипт каталога (для старого CLI, который не отдаёт session_id).
    public static func newest(cwd: String, home: String = claudeHome) -> URL? {
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".claude/projects").appendingPathComponent(projectSlug(cwd: cwd))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    /// Ограничение ленты: старые записи отбрасываются, чтобы память не росла с сессией.
    public var maxEntries = 600

    /// Номер записи по id: запись с уже виденным id заменяется на месте, без прохода по всей ленте.
    private var indexByID: [String: Int] = [:]
    /// Самая ранняя запись, изменённая с последнего `takeChangedFrom()`: читатель сверяет ленту только с неё.
    private var changedFrom: Int?

    /// Самая ранняя изменённая запись с прошлого вызова (`nil` — изменений не было); сбрасывает отметку.
    public mutating func takeChangedFrom() -> Int? {
        defer { changedFrom = nil }
        return changedFrom
    }

    private mutating func touched(_ i: Int) { changedFrom = min(changedFrom ?? i, i) }

    public mutating func feed(lines: [Substring]) {
        for line in lines where !line.isEmpty {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            ingest(obj)
        }
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
            indexByID = Dictionary(entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })
            changedFrom = 0
        }
    }

    mutating func ingest(_ r: [String: Any]) {
        if r["isSidechain"] as? Bool == true { return }
        switch Self.turnMark(r) {
        case .start, .answer: turnInProgress = true
        case .end: turnInProgress = false; openQuestion = nil
        case .none: break
        }
        let type = r["type"] as? String
        let uuid = r["uuid"] as? String ?? UUID().uuidString
        let time = (r["timestamp"] as? String).flatMap { Self.iso.date(from: $0) }
        switch type {
        case "user":
            if r["isCompactSummary"] as? Bool == true {
                append(ChatEntry(id: uuid, time: time, kind: .compacted))
                return
            }
            guard let msg = r["message"] as? [String: Any] else { return }
            var text: String?
            var images: [ChatImage] = []
            if let s = msg["content"] as? String {
                text = s
            } else if let blocks = msg["content"] as? [[String: Any]] {
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    if let q = openQuestion, blocks.contains(where: { $0["tool_use_id"] as? String == q.id }) { openQuestion = nil }
                    return
                }
                let t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                text = t.isEmpty ? nil : t
                images = Self.images(in: blocks, uuid: uuid)
                if !images.isEmpty { text = Self.strippingImageMarkers(text ?? "") }
            }
            guard let text else { return }
            if r["isMeta"] as? Bool != true, localCommand(text, run: nil, uuid: uuid, time: time) { return }
            // Сообщение другой сессии, пришедшее вне хода, Claude Code пишет служебной записью (isMeta): в ленту оно
            // идёт, прочие служебные — нет.
            let inc = Self.parseCrossSession(text)
            if r["isMeta"] as? Bool == true, inc == nil { return }
            if let inc {
                append(ChatEntry(id: uuid, time: time, kind: .incoming(fromName: inc.name, fromAddr: inc.addr, text: inc.body)))
                return
            }
            let trimmed = Self.strippingPasteWrapper(text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && images.isEmpty { return }
            if let service = Self.serviceLine(trimmed) {
                append(ChatEntry(id: uuid, time: time, kind: service))
                return
            }
            if trimmed.hasPrefix("[Request interrupted") { return }
            if Self.isServiceText(trimmed) { return }
            append(ChatEntry(id: uuid, time: time, kind: .owner(trimmed), images: images))
        case "assistant":
            guard let msg = r["message"] as? [String: Any] else { return }
            if let model = msg["model"] as? String, let u = msg["usage"] as? [String: Any], model != "<synthetic>" {
                let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                    .reduce(0) { $0 + ((u[$1] as? Int) ?? 0) }
                if tokens > 0 { usage = UsageInfo(model: model, contextTokens: tokens) }
            }
            let msgID = msg["id"] as? String ?? uuid
            for (i, b) in ((msg["content"] as? [[String: Any]]) ?? []).enumerated() {
                switch b["type"] as? String {
                case "text":
                    let t = (b["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { continue }
                    // Один ответ разбит на несколько строк файла: соседние текстовые блоки сообщения склеиваются.
                    if let last = entries.last, last.id.hasPrefix(msgID + ":text"), case let .reply(prev) = last.kind {
                        entries[entries.count - 1].kind = .reply(prev + "\n\n" + t)
                        touched(entries.count - 1)
                    } else {
                        append(ChatEntry(id: "\(msgID):text:\(uuid):\(i)", time: time, kind: .reply(t)))
                    }
                case "tool_use":
                    let name = b["name"] as? String ?? "?"
                    let input = b["input"] as? [String: Any] ?? [:]
                    if name == "AskUserQuestion", let id = b["id"] as? String { openQuestion = PendingQuestion.parse(id: id, input: input) }
                    append(ChatEntry(id: (b["id"] as? String) ?? "\(uuid):\(i)", time: time, kind: Self.toolKind(name: name, input: input)))
                default:
                    continue
                }
            }
        case "attachment":
            // Сообщение, пришедшее во время хода (другая сессия или владелец), лежит как queued_command.
            guard let a = r["attachment"] as? [String: Any], a["type"] as? String == "queued_command" else { return }
            // Сообщение с картинкой лежит списком блоков (текст и image), без картинок — строкой.
            var queuedImages: [ChatImage] = []
            var prompt: String
            if let s = a["prompt"] as? String {
                prompt = s
            } else if let blocks = a["prompt"] as? [[String: Any]] {
                prompt = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                queuedImages = Self.images(in: blocks, uuid: uuid)
                if !queuedImages.isEmpty { prompt = Self.strippingImageMarkers(prompt) }
            } else {
                return
            }
            if let inc = Self.parseCrossSession(prompt) {
                append(ChatEntry(id: uuid, time: time, kind: .incoming(fromName: inc.name, fromAddr: inc.addr, text: inc.body)))
                return
            }
            let trimmed = Self.strippingPasteWrapper(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
            if a["isMeta"] as? Bool == true || (trimmed.isEmpty && queuedImages.isEmpty) || Self.isServiceText(trimmed) { return }
            append(ChatEntry(id: uuid, time: time, kind: .owner(trimmed), images: queuedImages))
        case "system":
            if r["subtype"] as? String == "turn_duration" {
                let ms = r["durationMs"] as? Int ?? 0
                append(ChatEntry(id: uuid, time: time, kind: .turnEnd(durationMs: ms)))
            } else if r["subtype"] as? String == "local_command", let text = r["content"] as? String {
                _ = localCommand(text, run: (r["commandRun"] as? [String: Any])?["command"] as? String, uuid: uuid, time: time)
            } else if r["subtype"] as? String == "informational", let text = r["content"] as? String,
                      let unknown = Self.unknownCommand(text) {
                append(ChatEntry(id: uuid, time: time, kind: .unknownCommand(name: unknown.name, suggestion: unknown.suggestion)))
            }
        default:
            return
        }
    }

    /// Как запись транскрипта меняет ход — одно правило для ленты (`turnInProgress`) и статуса агента
    /// (`AgentActivity.scan`):
    /// - начинают ход: сообщение владельца или другой сессии, служебная строка с ответом модели (уведомление о фоновой
    ///   задаче, напоминание), сообщение в очереди Claude Code (`queued_command`), плановый запуск
    ///   (`scheduled_task_fire`);
    /// - ответ модели: ход идёт;
    /// - кончают ход: `turn_duration`, запись о прерывании, сводка сжатия, ответ-ошибка API;
    /// - не меняют: результаты инструментов, служебные записи (`isMeta`, кроме сообщения другой сессии), команды владельца в самом Claude Code
    ///   (`/model`, `!ls`) и их вывод, пустые сообщения.
    public enum TurnMark: Equatable, Sendable { case start, answer, end, none }

    public static func turnMark(_ r: [String: Any]) -> TurnMark {
        if r["isSidechain"] as? Bool == true { return .none }
        switch r["type"] as? String {
        case "user":
            if r["isCompactSummary"] as? Bool == true { return .end }
            let content = (r["message"] as? [String: Any])?["content"]
            var text: String
            var hasImages = false
            if let s = content as? String {
                text = s
            } else if let blocks = content as? [[String: Any]] {
                if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return .none }
                text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
                hasImages = blocks.contains { $0["type"] as? String == "image" }
            } else {
                return .none
            }
            if parseCrossSession(text) != nil { return .start }
            // Служебные записи, кроме сообщения другой сессии (оно вне хода тоже isMeta), ход не меняют.
            if r["isMeta"] as? Bool == true { return .none }
            let trimmed = strippingPasteWrapper(hasImages ? strippingImageMarkers(text) : text).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty && !hasImages { return .none }
            if serviceLine(trimmed) != nil { return .start }
            if trimmed.hasPrefix("[Request interrupted") { return .end }
            if isServiceText(trimmed) { return .none }
            return .start
        case "assistant":
            guard r["message"] is [String: Any] else { return .none }
            // Ошибка API заканчивает ход: Claude Code больше ничего не напишет до следующего сообщения.
            return r["isApiErrorMessage"] as? Bool == true ? .end : .answer
        case "attachment":
            return (r["attachment"] as? [String: Any])?["type"] as? String == "queued_command" ? .start : .none
        case "system":
            switch r["subtype"] as? String {
            case "turn_duration": return .end
            case "scheduled_task_fire": return .start
            default: return .none
            }
        default:
            return .none
        }
    }

    /// Блоки `type:image` с base64-источником, по порядку.
    static func images(in blocks: [[String: Any]], uuid: String) -> [ChatImage] {
        var out: [ChatImage] = []
        for b in blocks where b["type"] as? String == "image" {
            guard let src = b["source"] as? [String: Any], src["type"] as? String == "base64",
                  let data = src["data"] as? String, !data.isEmpty else { continue }
            out.append(ChatImage(id: "\(uuid)#\(out.count + 1)", mediaType: src["media_type"] as? String ?? "image/png", base64: data))
        }
        return out
    }

    /// Claude Code оборачивает вставленный текст в `<pasted_content id="…">…</pasted_content id="…">`, а в очереди
    /// от обёртки остаётся обрывок, иногда с экранированной косой чертой: `<\/pasted_content id="…">`. Владельцу теги не нужны.
    static func strippingPasteWrapper(_ s: String) -> String {
        guard s.contains("pasted_content") else { return s }
        return s.replacingOccurrences(of: #"<\\?/?pasted_content[^>]*>"#, with: "", options: .regularExpression)
    }

    /// «[Image #1]» — подпись Claude Code к вложению; когда картинка показана миниатюрой, подпись лишняя.
    static func strippingImageMarkers(_ s: String) -> String {
        s.replacingOccurrences(of: #"\[Image #\d+\]"#, with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func append(_ e: ChatEntry) {
        if let i = indexByID[e.id] {
            entries[i] = e
            touched(i)
        } else {
            indexByID[e.id] = entries.count
            touched(entries.count)
            entries.append(e)
        }
    }

    /// Напоминания и уведомления харнесса — компактной строкой, а не молча и не как слова владельца.
    static func serviceLine(_ s: String) -> ChatKind? {
        func inner(_ tag: String) -> String? {
            guard let a = s.range(of: "<\(tag)>") else { return nil }
            let rest = s[a.upperBound...]
            let body = rest.range(of: "</\(tag)>").map { rest[..<$0.lowerBound] } ?? rest
            return String(body)
        }
        func firstLine(_ t: String) -> String {
            let line = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("<") } ?? ""
            return line.count > 120 ? String(line.prefix(120)) + "…" : line
        }
        if s.hasPrefix("<task-notification>") {
            let summary = inner("summary").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? firstLine(inner("task-notification") ?? "")
            return .tool(name: "уведомление", summary: summary)
        }
        if s.hasPrefix("<system-reminder>") {
            return .tool(name: "напоминание", summary: firstLine(inner("system-reminder") ?? ""))
        }
        return nil
    }

    /// Запись встроенной команды Claude Code: имя (`<command-name>`) запоминается, вывод (`<local-command-stdout>`,
    /// `<local-command-stderr>`) идёт в ленту записью `.command` с этим именем или с `run` (`commandRun.command`). Claude Code
    /// пишет их и записью `system/local_command`, и записью `user`. Пустой вывод не показывается. `true` — запись команды.
    private mutating func localCommand(_ text: String, run: String?, uuid: String, time: Date?) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Вызов: у встроенных команд запись начинается с <command-name>, у скиллов и команд плагинов — с <command-message>.
        let prompt = t.hasPrefix("<command-message>") && t.contains("<command-name>")
        if t.hasPrefix("<command-name>") || prompt {
            let name = Self.inner(t, "command-name")?.trimmingCharacters(in: .whitespaces) ?? ""
            commandName = name.isEmpty ? nil : name
            if !name.isEmpty {
                let args = Self.inner(t, "command-args")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                append(ChatEntry(id: uuid, time: time, kind: .invoked(name: name, args: args, prompt: prompt)))
            }
            return true
        }
        guard let tag = ["local-command-stdout", "local-command-stderr"].first(where: { t.hasPrefix("<\($0)>") }) else { return false }
        let output = Self.strippingANSI(Self.inner(t, tag) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = run.map { $0.hasPrefix("/") ? $0 : "/" + $0 } ?? commandName ?? "команда"
        commandName = nil
        if !output.isEmpty { append(ChatEntry(id: uuid, time: time, kind: .command(name: name, output: output))) }
        return true
    }

    /// «Unknown command: /rsume. Did you mean /resume?» → имя и замена; другой текст `system/informational` — `nil`.
    static func unknownCommand(_ s: String) -> (name: String, suggestion: String?)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = t.firstMatch(of: #/^Unknown command: (/[^\s.]+(?:\.[^\s.]+)*)\.?(?:\s+Did you mean (/[^\s?]+)\?)?/#) else { return nil }
        return (String(m.1), m.2.map(String.init))
    }

    /// Текст между `<tag>` и `</tag>` (до конца, если закрывающего нет).
    static func inner(_ s: String, _ tag: String) -> String? {
        guard let a = s.range(of: "<\(tag)>") else { return nil }
        let rest = s[a.upperBound...]
        return String(rest.range(of: "</\(tag)>").map { rest[..<$0.lowerBound] } ?? rest)
    }

    /// Текст без управляющих последовательностей терминала: цвета и стили (`ESC[…m`), прочие CSI и ссылки OSC 8.
    static func strippingANSI(_ s: String) -> String {
        guard s.contains("\u{1b}") else { return s }
        return s.replacingOccurrences(of: #"\x{1b}\][^\x{07}\x{1b}]*(\x{07}|\x{1b}\\)|\x{1b}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    static func isServiceText(_ s: String) -> Bool {
        let prefixes = ["<system-reminder>", "<task-notification>", "<command-name>", "<command-message>", "<command-args>",
                        "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>", "<bash-input>",
                        "<bash-stdout>", "<bash-stderr>", "<user-memory-input>", "[Request interrupted", "Caveat:"]
        return prefixes.contains { s.hasPrefix($0) }
    }

    static func parseCrossSession(_ text: String) -> (name: String, addr: String, body: String)? {
        guard let open = text.range(of: "<cross-session-message") else { return nil }
        guard let tagEnd = text.range(of: ">", range: open.upperBound..<text.endIndex) else { return nil }
        let attrs = String(text[open.upperBound..<tagEnd.lowerBound])
        func attr(_ name: String) -> String {
            guard let r = attrs.range(of: name + "=\"") else { return "" }
            let rest = attrs[r.upperBound...]
            return String(rest.prefix { $0 != "\"" })
        }
        let close = text.range(of: "</cross-session-message>", range: tagEnd.upperBound..<text.endIndex)
        let body = String(text[tagEnd.upperBound..<(close?.lowerBound ?? text.endIndex)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (attr("from-name"), attr("from"), body)
    }

    static func toolKind(name: String, input: [String: Any]) -> ChatKind {
        if name == "CronDelete" {
            return .tool(name: "напоминание снято", summary: input["id"] as? String ?? "")
        }
        if name == "AskUserQuestion" {
            return .tool(name: name, summary: askSummary(input))
        }
        if name == "SendMessage" {
            return .sendMessage(to: input["to"] as? String ?? "?", text: input["message"] as? String ?? input["summary"] as? String ?? "")
        }
        if name.hasPrefix("mcp__") {
            // mcp__<сервер>__<действие>. Трекер узнаётся по действию над задачами, а не по имени сервиса:
            // приложение не знает, какой трекер у проекта.
            let comps = name.components(separatedBy: "__")
            let server = comps.count > 1 ? comps[1] : name
            let action = comps.count > 2 ? comps[2...].joined(separator: "__") : name
            let trackerWords = ["issue", "comment", "ticket", "cycle", "milestone"]
            if trackerWords.contains(where: { action.lowercased().contains($0) }) {
                return .tracker(action: action, summary: summarize(input, keys: ["issueId", "id", "title", "query", "state", "project"]))
            }
            return .tool(name: "\(server) · \(action)", summary: summarize(input, keys: ["query", "title", "path"]))
        }
        let keys: [String]
        switch name {
        case "Bash": keys = ["description", "command"]
        case "Read", "Write", "Edit": keys = ["file_path"]
        case "Grep", "Glob": keys = ["pattern"]
        case "Agent", "Task": keys = ["description"]
        default: keys = ["description", "summary", "query", "file_path", "command", "label"]
        }
        return .tool(name: name, summary: summarize(input, keys: keys))
    }

    /// Вопрос менеджера владельцу (`AskUserQuestion`): текст вопроса и варианты, по одному вопросу на строку.
    /// Ответ владельца в транскрипте лежит отдельной записью; здесь только то, о чём спросили.
    static func askSummary(_ input: [String: Any]) -> String {
        let questions = (input["questions"] as? [[String: Any]]) ?? []
        let rows = questions.compactMap { q -> String? in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let labels = ((q["options"] as? [[String: Any]]) ?? []).compactMap { $0["label"] as? String }
            return labels.isEmpty ? text : text + " — " + labels.joined(separator: " / ")
        }
        let joined = rows.joined(separator: "\n")
        return joined.count > 800 ? String(joined.prefix(800)) + "…" : joined
    }

    static func summarize(_ input: [String: Any], keys: [String]) -> String {
        for k in keys {
            if let v = input[k] as? String, !v.isEmpty {
                let line = v.split(separator: "\n").first.map(String.init) ?? v
                return line.count > 140 ? String(line.prefix(140)) + "…" : line
            }
        }
        return ""
    }
}
