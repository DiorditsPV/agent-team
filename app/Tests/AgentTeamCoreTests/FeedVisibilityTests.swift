import XCTest
@testable import AgentTeamCore

final class FeedVisibilityTests: XCTestCase {
    private func entry(_ id: String, _ kind: ChatKind) -> ChatEntry { ChatEntry(id: id, time: nil, kind: kind) }

    private var entries: [ChatEntry] {
        [
            entry("1", .owner("задача")),
            entry("2", .tool(name: "Bash", summary: "swift test")),
            entry("3", .tool(name: "Bash", summary: "ls")),
            entry("4", .tool(name: "Read", summary: "a.swift")),
            entry("5", .tracker(action: "get_issue", summary: "TASK-1")),
            entry("6", .sendMessage(to: "uds:/x", text: "готово")),
            entry("7", .reply("ответ")),
            entry("8", .incoming(fromName: "manager", fromAddr: "uds:/m", text: "привет")),
            entry("9", .compacted),
            entry("10", .turnEnd(durationMs: 12_000)),
        ]
    }

    func testEverythingShownByDefaultAndOldSettingsDecodeAsShown() throws {
        let v = FeedVisibility()
        for c in FeedCategory.allCases { XCTAssertTrue(v.shows(c)) }
        XCTAssertTrue(v.turnStatus && v.draft)
        let old = try JSONDecoder().decode(DisplaySettings.self, from: Data(#"{"chat":{"family":"Onest","size":14,"spacing":5}}"#.utf8))
        XCTAssertEqual(old.feedManager, FeedVisibility())
        XCTAssertEqual(old.feedAgents, FeedVisibility())
        let broken = try JSONDecoder().decode(FeedVisibility.self, from: Data(#"{"bash":false,"files":"нет","draft":null}"#.utf8))
        XCTAssertFalse(broken.bash)
        XCTAssertTrue(broken.files && broken.draft, "испорченное значение — показывать")
    }

    func testSettingsRoundTripKeepsManagerAndAgentsSeparate() throws {
        var s = DisplaySettings()
        s.feedManager.bash = false
        s.feedAgents.tracker = false
        s.feedAgents.turnStatus = false
        let back = try JSONDecoder().decode(DisplaySettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertFalse(back.feedManager.bash)
        XCTAssertTrue(back.feedAgents.bash)
        XCTAssertFalse(back.feedAgents.tracker)
        XCTAssertTrue(back.feedManager.tracker)
    }

    func testToolCategories() {
        XCTAssertEqual(FeedVisibility.category(ofTool: "Bash"), .bash)
        for t in ["Read", "Edit", "MultiEdit", "Write", "NotebookEdit"] { XCTAssertEqual(FeedVisibility.category(ofTool: t), .files, t) }
        for t in ["Grep", "Glob", "Task", "WebFetch", "mcp__x__y"] { XCTAssertEqual(FeedVisibility.category(ofTool: t), .otherTool, t) }
    }

    func testHidingBashDropsOnlyBashLinesAndKeepsTheRestOfTheBlock() {
        let items = ThreadGrouping.items(entries)
        var v = FeedVisibility()
        v.bash = false
        let shown = ThreadGrouping.visible(items, v)
        guard case let .actions(_, lines)? = shown.first(where: { if case .actions = $0 { return true } else { return false } }) else { return XCTFail("блок действий пропал") }
        XCTAssertEqual(lines.map(\.category), [.files, .tracker])
        XCTAssertEqual(shown.count, items.count, "блок не пустой — остаётся")
    }

    func testBlockWithNothingLeftDisappearsWithoutGap() {
        let only = ThreadGrouping.items([entry("1", .tool(name: "Bash", summary: "ls")), entry("2", .reply("текст"))])
        var v = FeedVisibility()
        v.bash = false
        let shown = ThreadGrouping.visible(only, v)
        XCTAssertEqual(shown.count, 1)
        if case .reply = shown[0] {} else { XCTFail("остался не ответ") }
    }

    func testTeamMessagesCompactedAndTurnEndHiddenIndependently() {
        let items = ThreadGrouping.items(entries)
        func kinds(_ v: FeedVisibility) -> [String] {
            ThreadGrouping.visible(items, v).map {
                switch $0 {
                case .input: return "input"
                case .incoming: return "incoming"
                case .send: return "send"
                case .actions: return "actions"
                case .reply: return "reply"
                case .turnEnd: return "turnEnd"
                case .compacted: return "compacted"
                case .command: return "command"
                case .commandCall: return "commandCall"
                }
            }
        }
        XCTAssertEqual(kinds(FeedVisibility()), ["input", "actions", "send", "reply", "incoming", "compacted", "turnEnd"])
        var v = FeedVisibility(); v.teamMessages = false
        XCTAssertEqual(kinds(v), ["input", "actions", "reply", "compacted", "turnEnd"], "и входящие, и SendMessage")
        v = FeedVisibility(); v.compacted = false
        XCTAssertFalse(kinds(v).contains("compacted"))
        v = FeedVisibility(); v.turnDuration = false
        XCTAssertFalse(kinds(v).contains("turnEnd"))
        v = FeedVisibility(); v.turnStatus = false; v.draft = false
        XCTAssertEqual(kinds(v), kinds(FeedVisibility()), "строка хода и черновик не входят в элементы транскрипта")
    }

    func testOwnerInputAndRepliesAreNeverHidden() {
        var v = FeedVisibility()
        v.bash = false; v.files = false; v.otherTools = false; v.teamMessages = false; v.tracker = false; v.compacted = false; v.turnDuration = false
        let shown = ThreadGrouping.visible(ThreadGrouping.items(entries), v)
        XCTAssertEqual(shown.count, 2)
    }
}
