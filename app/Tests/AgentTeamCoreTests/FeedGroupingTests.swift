import XCTest
@testable import AgentTeamCore

/// Группировка лент в Core должна давать ровно то же, что давали прежние группировки: ленту менеджера из `ChatPanel`
/// (`ChatGrouping`, цель приложения) и ленту агента (`ThreadGrouping`). Прежние версии лежат ниже дословными копиями —
/// `project` заменён на `FeedPeers`, тип элементов — на Core-тип. Они — эталон: новая группировка сверяется с ними на
/// случайных лентах при всех наборах показа.
final class FeedGroupingTests: XCTestCase {
    private let peers = FeedPeers(names: ["uds:/dev": "developer #1", "uds:/qa": "qa #2"], managerRole: "lead")

    private func e(_ id: String, _ kind: ChatKind) -> ChatEntry { ChatEntry(id: id, time: nil, kind: kind) }

    // MARK: явные случаи

    func testManagerGroupsActionsAndKeepsQuestionAndSend() {
        let entries = [
            e("1", .owner("задача")),
            e("2", .tool(name: "Bash", summary: "swift build")),
            e("3", .tool(name: "Bash", summary: "")),
            e("4", .tool(name: "Bash", summary: "swift test")),
            e("5", .tracker(action: "get_issue", summary: "TASK-1")),
            e("6", .tracker(action: "save_comment", summary: "")),
            e("7", .tracker(action: "get_issue", summary: "TASK-2")),
            e("8", .sendMessage(to: "uds:/dev", text: "возьми\nзадачу")),
            e("9", .tool(name: "AskUserQuestion", summary: "Сливать? — да / нет")),
            e("10", .reply("первый")),
            e("11", .reply("второй")),
            e("12", .incoming(fromName: "x", fromAddr: "uds:/qa", text: "готово")),
            e("13", .incoming(fromName: "", fromAddr: "uds:/unknown", text: "?")),
            e("14", .turnEnd(durationMs: 5000)),
            e("15", .compacted),
        ]
        let items = FeedGrouping.manager(entries, peers: peers)
        XCTAssertEqual(items, [
            .owner(entries[0], "задача"),
            .actions("2", [
                ManagerActionLine(id: "2", kind: .tool, title: "Bash ×3 · swift test", quote: nil, category: .bash),
                ManagerActionLine(id: "5", kind: .tracker, title: "трекер · 3 запроса · get_issue, save_comment · TASK-2", quote: nil, category: .tracker),
                ManagerActionLine(id: "8", kind: .send, title: "→ developer #1 · SendMessage", quote: "«возьми задачу»", category: .teamMessage),
                ManagerActionLine(id: "9", kind: .question, title: "вопрос менеджера", quote: "Сливать? — да / нет", category: nil),
            ]),
            .reply(entries[9], "первый", showWho: true),
            .reply(entries[10], "второй", showWho: false),
            .incoming(entries[11], from: "qa #2", to: "lead", "готово"),
            .incoming(entries[12], from: "uds:/unknown", to: "lead", "?"),
            .turnEnd(entries[13], 5000),
            .compacted(entries[14]),
        ])
    }

    func testManagerHidingEveryLineDropsTheBlockButNotTheQuestion() {
        let entries = [e("1", .tool(name: "Bash", summary: "a")), e("2", .tool(name: "Read", summary: "b")), e("3", .reply("r")),
                       e("4", .tool(name: "Bash", summary: "c")), e("5", .tool(name: "AskUserQuestion", summary: "q"))]
        var v = FeedVisibility()
        v.bash = false
        v.files = false
        v.otherTools = false
        let items = FeedGrouping.manager(entries, peers: peers, visibility: v)
        XCTAssertEqual(items.map(\.id), ["3", "act-4"])
        guard case let .actions(_, lines) = items[1] else { return XCTFail() }
        XCTAssertEqual(lines.map(\.kind), [.question])
    }

    func testTailAddsDraftAndUndeliveredOnly() {
        let shown = e("o1", .owner("привет"))
        let base: [ManagerFeedItem] = [.owner(shown, "привет")]
        let delivered = PendingMessage(text: "привет", images: [])
        let waiting = PendingMessage(text: "ещё", images: [], seen: ["o1"])
        let live = LiveReply(text: "пишу", startCut: false)
        XCTAssertEqual(FeedGrouping.tail(owners: FeedGrouping.owners(base), pending: [], live: nil), [])
        let tail = FeedGrouping.tail(owners: FeedGrouping.owners(base), pending: [delivered, waiting], live: live)
        XCTAssertEqual(tail.map(\.id), ["live-reply", "pending-" + waiting.id])
    }

    func testPeersFromStatusPrettyNameFirstAgentWins() {
        let a = Agent(name: "developer#1", role: "developer", n: 1, alive: true, paneID: nil, cwd: nil)
        var a1 = a; a1.addr = "uds:/a"
        var a2 = Agent(name: "qa#3", role: "qa", n: 3, alive: true, paneID: nil, cwd: nil); a2.addr = "uds:/a"
        let p = FeedPeers(agents: [a1, a2, a], managerRole: "manager")
        XCTAssertEqual(p.name(forAddress: "uds:/a"), "developer #1")
        XCTAssertEqual(p.name(forAddress: "uds:/b"), "uds:/b")
        XCTAssertEqual(p.sender(name: "лид", addr: "uds:/b"), "лид")
    }

    // MARK: сверка с прежними группировками

    func testManagerMatchesLegacyOnRandomFeedsForEveryVisibility() {
        var rng = SplitMix(seed: 7)
        for round in 0..<300 {
            let entries = randomFeed(&rng, count: Int.random(in: 0...40, using: &rng), prefix: "r\(round)-")
            let all = FeedGrouping.manager(entries, peers: peers)
            for v in Self.visibilities {
                XCTAssertEqual(FeedGrouping.visible(all, v), LegacyChatGrouping.items(entries, peers: peers, visibility: v),
                               "раунд \(round), показ \(v.key)")
            }
        }
    }

    func testAgentMatchesLegacyOnRandomFeedsForEveryVisibility() {
        var rng = SplitMix(seed: 11)
        for round in 0..<300 {
            let entries = randomFeed(&rng, count: Int.random(in: 0...40, using: &rng), prefix: "a\(round)-")
            let items = FeedGrouping.agent(entries)
            XCTAssertEqual(items, LegacyThreadGrouping.items(entries), "раунд \(round)")
            for v in Self.visibilities {
                XCTAssertEqual(FeedGrouping.visible(items, v), LegacyThreadGrouping.visible(items, v), "раунд \(round), показ \(v.key)")
            }
        }
    }

    func testManagerMatchesLegacyOnRecordedTranscript() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "transcript", withExtension: "jsonl", subdirectory: "Fixtures"))
        var parser = TranscriptParser()
        parser.feed(lines: try String(contentsOf: url, encoding: .utf8).split(separator: "\n"))
        XCTAssertFalse(parser.entries.isEmpty)
        for v in Self.visibilities {
            XCTAssertEqual(FeedGrouping.manager(parser.entries, peers: peers, visibility: v),
                           LegacyChatGrouping.items(parser.entries, peers: peers, visibility: v))
        }
    }

    /// Все сочетания переключателей, которые влияют на группировку (строка хода и черновик — нет).
    static let visibilities: [FeedVisibility] = (0..<128).map { mask in
        var v = FeedVisibility()
        v.bash = mask & 1 == 0
        v.files = mask & 2 == 0
        v.otherTools = mask & 4 == 0
        v.teamMessages = mask & 8 == 0
        v.tracker = mask & 16 == 0
        v.compacted = mask & 32 == 0
        v.turnDuration = mask & 64 == 0
        return v
    }

    private func randomFeed(_ rng: inout SplitMix, count: Int, prefix: String) -> [ChatEntry] {
        let tools = ["Bash", "Read", "Edit", "Grep", "AskUserQuestion", "Agent"]
        let addrs = ["uds:/dev", "uds:/qa", "uds:/other"]
        return (0..<count).map { i in
            let id = prefix + String(i)
            let s = ["", "a", "b\nc"].randomElement(using: &rng)!
            let kind: ChatKind
            switch Int.random(in: 0..<10, using: &rng) {
            case 0: kind = .owner("o" + s)
            case 1, 2, 3: kind = .tool(name: tools.randomElement(using: &rng)!, summary: s)
            case 4: kind = .tracker(action: ["get_issue", "save_comment", "list_issues", "get_issue"].randomElement(using: &rng)!, summary: s)
            case 5: kind = .sendMessage(to: addrs.randomElement(using: &rng)!, text: "t" + s)
            case 6: kind = .reply("r" + s)
            case 7: kind = .incoming(fromName: ["", "lead"].randomElement(using: &rng)!, fromAddr: addrs.randomElement(using: &rng)!, text: "i" + s)
            case 8: kind = .turnEnd(durationMs: i)
            default: kind = .compacted
            }
            return ChatEntry(id: id, time: nil, kind: kind)
        }
    }
}

/// Детерминированный генератор для повторяемых случайных лент.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: эталоны — прежние группировки дословно

/// `ChatGrouping.items` из `ChatPanel.swift` (dev 39f6921): `project.displayName` и имена из status — через `FeedPeers`.
private enum LegacyChatGrouping {
    static func items(_ entries: [ChatEntry], peers: FeedPeers, visibility v: FeedVisibility = FeedVisibility()) -> [ManagerFeedItem] {
        var out: [ManagerFeedItem] = []
        var pending: [ChatEntry] = []
        var replyOpen = false

        func flushActions() {
            guard let first = pending.first else { return }
            var lines: [ManagerActionLine] = []
            var i = 0
            while i < pending.count {
                let e = pending[i]
                switch e.kind {
                case let .sendMessage(to, text):
                    if !v.teamMessages { i += 1; continue }
                    lines.append(ManagerActionLine(id: e.id, kind: .send, title: "→ \(peers.name(forAddress: to)) · SendMessage",
                                                   quote: "«" + text.replacingOccurrences(of: "\n", with: " ") + "»", category: .teamMessage))
                    i += 1
                case .tracker:
                    if !v.tracker {
                        var j = i
                        while j < pending.count, case .tracker = pending[j].kind { j += 1 }
                        i = j
                        continue
                    }
                    var j = i
                    var actions: [String] = []
                    var subject = ""
                    while j < pending.count, case let .tracker(a, s) = pending[j].kind {
                        actions.append(a)
                        if !s.isEmpty { subject = s }
                        j += 1
                    }
                    let n = j - i
                    let uniq = Array(NSOrderedSet(array: actions)) as? [String] ?? actions
                    let title = "трекер · " + (n == 1 ? uniq[0] : plural(n, "запрос", "запроса", "запросов") + " · " + uniq.prefix(3).joined(separator: ", "))
                    lines.append(ManagerActionLine(id: e.id, kind: .tracker, title: title + (subject.isEmpty ? "" : " · " + subject), quote: nil, category: .tracker))
                    i = j
                case let .tool(name, summary) where name == "AskUserQuestion":
                    lines.append(ManagerActionLine(id: e.id, kind: .question, title: "вопрос менеджера", quote: summary.isEmpty ? nil : summary, category: nil))
                    i += 1
                case let .tool(name, summary):
                    var j = i + 1
                    var last = summary
                    while j < pending.count, case let .tool(n2, s2) = pending[j].kind, n2 == name {
                        if !s2.isEmpty { last = s2 }
                        j += 1
                    }
                    if !v.shows(FeedVisibility.category(ofTool: name)) { i = j; continue }
                    let n = j - i
                    let title = name + (n > 1 ? " ×\(n)" : "") + (last.isEmpty ? "" : " · " + last)
                    lines.append(ManagerActionLine(id: e.id, kind: .tool, title: title, quote: nil, category: FeedVisibility.category(ofTool: name)))
                    i = j
                default:
                    i += 1
                }
            }
            if !lines.isEmpty { out.append(.actions(first.id, lines)) }
            pending = []
        }

        for e in entries {
            switch e.kind {
            case .sendMessage, .tracker, .tool:
                pending.append(e)
            case let .owner(t):
                flushActions()
                out.append(.owner(e, t))
                replyOpen = false
            case let .reply(t):
                flushActions()
                out.append(.reply(e, t, showWho: !replyOpen))
                replyOpen = true
            case let .incoming(name, addr, text):
                flushActions()
                let from = peers.names[addr] ?? (name.isEmpty ? addr : name)
                if v.teamMessages { out.append(.incoming(e, from: from, to: peers.managerRole, text)) }
                replyOpen = false
            case let .turnEnd(ms):
                flushActions()
                if v.turnDuration { out.append(.turnEnd(e, ms)) }
                replyOpen = false
            case .compacted:
                flushActions()
                if v.compacted { out.append(.compacted(e)) }
                replyOpen = false
            case let .command(name, output):
                flushActions()
                out.append(.command(e, name: name, output))
                replyOpen = false
            case let .unknownCommand(name, suggestion):
                flushActions()
                out.append(.command(e, name: name, FeedGrouping.unknownCommandText(name, suggestion: suggestion)))
                replyOpen = false
            case let .invoked(name, args, prompt):
                guard prompt else { continue }
                flushActions()
                out.append(.commandCall(e, FeedGrouping.commandCallText(name, args: args)))
                replyOpen = false
            }
        }
        flushActions()
        return out
    }

    /// `plural` из `Theme.swift`.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "\(n) \(one)" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "\(n) \(few)" }
        return "\(n) \(many)"
    }
}

/// `ThreadGrouping.actions` и `ThreadGrouping.visible` из `AgentThread.swift` (dev 39f6921).
private enum LegacyThreadGrouping {
    static func items(_ entries: [ChatEntry]) -> [ThreadItem] {
        var out: [ThreadItem] = []
        var pending: [ChatEntry] = []
        var replyOpen = false
        func flush() {
            guard let first = pending.first else { return }
            out.append(.actions(first.id, actions(pending)))
            pending = []
        }
        for e in entries {
            switch e.kind {
            case .tracker, .tool: pending.append(e)
            case let .sendMessage(to, text): flush(); out.append(.send(e, to: to, text)); replyOpen = false
            case let .owner(t): flush(); out.append(.input(e, t)); replyOpen = false
            case let .reply(t): flush(); out.append(.reply(e, t, showWho: !replyOpen)); replyOpen = true
            case let .incoming(from, addr, text): flush(); out.append(.incoming(e, from: from, addr: addr, text)); replyOpen = false
            case let .turnEnd(ms): flush(); out.append(.turnEnd(e, ms)); replyOpen = false
            case .compacted: flush(); out.append(.compacted(e)); replyOpen = false
            case let .command(name, output): flush(); out.append(.command(e, name: name, output)); replyOpen = false
            case let .unknownCommand(name, suggestion):
                flush(); out.append(.command(e, name: name, FeedGrouping.unknownCommandText(name, suggestion: suggestion))); replyOpen = false
            case let .invoked(name, args, prompt):
                guard prompt else { continue }
                flush(); out.append(.commandCall(e, FeedGrouping.commandCallText(name, args: args))); replyOpen = false
            }
        }
        flush()
        return out
    }

    static func visible(_ items: [ThreadItem], _ v: FeedVisibility) -> [ThreadItem] {
        guard v != FeedVisibility() else { return items }
        var out: [ThreadItem] = []
        for item in items {
            switch item {
            case .incoming, .send: if v.teamMessages { out.append(item) }
            case .compacted: if v.compacted { out.append(item) }
            case .turnEnd: if v.turnDuration { out.append(item) }
            case let .actions(id, lines):
                let shown = lines.filter { v.shows($0.category) }
                if shown.count == lines.count { out.append(item) } else if !shown.isEmpty { out.append(.actions(id, shown)) }
            case .input, .reply, .command, .commandCall: out.append(item)
            }
        }
        return out
    }

    static func actions(_ pending: [ChatEntry]) -> [ThreadAction] {
        var lines: [ThreadAction] = []
        var i = 0
        while i < pending.count {
            let e = pending[i]
            switch e.kind {
            case .tracker:
                var j = i
                var acts: [String] = []
                var subject = ""
                while j < pending.count, case let .tracker(a, s) = pending[j].kind {
                    if !acts.contains(a) { acts.append(a) }
                    if !s.isEmpty { subject = s }
                    j += 1
                }
                let n = j - i
                let title = "трекер · " + (n == 1 ? acts[0] : "\(n) \(requests(n)) · " + acts.prefix(3).joined(separator: ", "))
                lines.append(ThreadAction(id: e.id, kind: .tracker, title: title + (subject.isEmpty ? "" : " · " + subject)))
                i = j
            case let .tool(tool, summary):
                var j = i + 1
                var last = summary
                while j < pending.count, case let .tool(t2, s2) = pending[j].kind, t2 == tool {
                    if !s2.isEmpty { last = s2 }
                    j += 1
                }
                let n = j - i
                lines.append(ThreadAction(id: e.id, kind: .tool, title: tool + (n > 1 ? " ×\(n)" : "") + (last.isEmpty ? "" : " · " + last), tool: tool))
                i = j
            default:
                i += 1
            }
        }
        return lines
    }

    static func requests(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1, m100 != 11 { return "запрос" }
        if (2...4).contains(m10), !(12...14).contains(m100) { return "запроса" }
        return "запросов"
    }
}

// MARK: лента менеджера по отрезкам (Ш5)

extension FeedGroupingTests {
    /// Группировка по отрезкам `ThreadFeed` даёт ровно ту же ленту, что группировка всех записей подряд.
    func testSegmentsGroupLikeWholeFeed() {
        var rng = SplitMix(seed: 23)
        let cache = ManagerFeedCache()
        for round in 0..<300 {
            let entries = randomFeedForSegments(&rng, count: Int.random(in: 0...60, using: &rng), prefix: "g\(round)-")
            XCTAssertEqual(cache.items(ThreadFeed.split(entries), peers: peers), FeedGrouping.manager(entries, peers: peers), "раунд \(round)")
        }
    }

    /// Новое в конце ленты пересобирает только последние отрезки; остальные берутся из кеша.
    func testOnlyRebuiltSegmentsAreRegrouped() {
        var feed = ThreadFeed((0..<50).flatMap { i in
            [ChatEntry(id: "o\(i)", time: nil, kind: .owner("задача \(i)")),
             ChatEntry(id: "b\(i)", time: nil, kind: .tool(name: "Bash", summary: "ls")),
             ChatEntry(id: "r\(i)", time: nil, kind: .reply("готово \(i)"))]
        })
        let cache = ManagerFeedCache()
        _ = cache.items(feed.segments, peers: peers)
        XCTAssertEqual(cache.regrouped, 50)
        feed.replaceTail(from: feed.count, with: [ChatEntry(id: "b-new", time: nil, kind: .tool(name: "Read", summary: "a.swift"))])
        let after = cache.items(feed.segments, peers: peers)
        XCTAssertEqual(cache.regrouped, 51, "пересобран только последний отрезок")
        XCTAssertEqual(after, FeedGrouping.manager(feed.entries, peers: peers))
        _ = cache.items(feed.segments, peers: FeedPeers(names: [:], managerRole: "другой"))
        XCTAssertEqual(cache.regrouped, 101, "смена участников пересчитывает все 50 отрезков")
    }

    private func randomFeedForSegments(_ rng: inout SplitMix, count: Int, prefix: String) -> [ChatEntry] {
        let kinds: [ChatKind] = [.owner("о"), .tool(name: "Bash", summary: "a"), .tool(name: "Bash", summary: ""), .tool(name: "Read", summary: "f"),
                                 .tracker(action: "get_issue", summary: "P"), .sendMessage(to: "uds:/dev", text: "t"), .reply("r"),
                                 .incoming(fromName: "x", fromAddr: "uds:/qa", text: "i"), .turnEnd(durationMs: 1), .compacted,
                                 .tool(name: "AskUserQuestion", summary: "q")]
        return (0..<count).map { ChatEntry(id: prefix + String($0), time: nil, kind: kinds.randomElement(using: &rng)!) }
    }
}
