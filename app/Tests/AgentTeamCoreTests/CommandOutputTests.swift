import XCTest
@testable import AgentTeamCore

/// Вывод встроенных команд Claude Code в ленте. Фикстура `local-commands.jsonl` собрана по записям транскрипта
/// claude 2.1.292 (вид записей тот же, текст сокращён, путь и ID сессии обезличены): вывод лежит в
/// `<local-command-stdout>` и в записи `system/local_command` (у `/context` — с цветами ANSI, рядом `commandRun`), и в записи
/// `user` (`/export`). Имя команды — из `commandRun` или из записи `<command-name>` перед выводом.
final class CommandOutputTests: XCTestCase {
    private func entries() throws -> [ChatEntry] {
        var p = TranscriptParser()
        p.feed(lines: String(decoding: try fixture("local-commands.jsonl"), as: UTF8.self).split(separator: "\n"))
        return p.entries
    }

    private func outputs() throws -> [(name: String, text: String)] {
        try entries().compactMap { if case let .command(name, text) = $0.kind { return (name, text) } else { return nil } }
    }

    func testCommandOutputFromBothRecordKinds() throws {
        let o = try outputs()
        XCTAssertEqual(o.map(\.name), ["/context", "/resume", "/agents", "/export"], "пустой вывод (/model) не показывается")
        XCTAssertEqual(o[1].text, "Resume cancelled")
        XCTAssertEqual(o[3].text, "Export cancelled", "вывод из записи user")
        XCTAssertTrue(o[2].text.hasPrefix("The /agents wizard has been removed."))
        XCTAssertTrue(o[2].text.contains("• ~/.claude/agents/     (all projects)"), "строки и отступы вывода сохраняются")
    }

    /// Цвета ANSI снимаются: в ленте моноширинный текст.
    func testAnsiStripped() throws {
        let ctx = try XCTUnwrap(outputs().first)
        XCTAssertFalse(ctx.text.contains("\u{1b}"))
        XCTAssertTrue(ctx.text.hasPrefix("Context Usage"))
        XCTAssertTrue(ctx.text.contains("⛁ ⛁ ⛁ ⛁   Sonnet 5.5 · 39.2k/1m tokens (4%)"))
        XCTAssertTrue(ctx.text.contains("Free space: 960.8k (96.1%)"))
    }

    /// Служебное вокруг команды в ленту не идёт: имя команды, предупреждение caveat, Markdown-копия вывода (isMeta);
    /// сообщение владельца после команд — на месте.
    func testServiceRecordsStayHidden() throws {
        let e = try entries()
        let shown = e.filter { if case .invoked = $0.kind { return false } else { return true } }
        XCTAssertEqual(shown.count, 5)
        XCTAssertEqual(e.last?.kind, .owner("Привет"))
        XCTAssertTrue(ThreadGrouping.items(e).allSatisfy { if case .input = $0 { return true }; if case .command = $0 { return true }; return false },
                      "вызов команды в ленте не показывается")
    }

    /// Вызов команды — запись <command-name> у встроенных (в начале) и у скиллов и команд плагинов (после
    /// <command-message>), и в записи user, и в записи system: имя и аргументы. Вывод команды берёт имя вызова.
    func testInvocationRecords() throws {
        var p = TranscriptParser()
        p.feed(lines: String(decoding: try fixture("command-invocations.jsonl"), as: UTF8.self).split(separator: "\n"))
        let calls = p.entries.compactMap { if case let .invoked(name, args, prompt) = $0.kind { return name + "|" + args + (prompt ? "|prompt" : "") } else { return nil } }
        XCTAssertEqual(calls, ["/superpowers:brainstorming|тема|prompt", "/effort|high", "/vercel:deploy||prompt", "/context|"],
                       "скилл и команда плагина начинаются с <command-message> — раскрываются в текст для модели")
        XCTAssertTrue(p.entries.contains { $0.kind == .command(name: "/effort", output: "Set effort level to high") })
        XCTAssertFalse(p.turnInProgress, "вызов команды хода не начинает")
    }

    /// Вывод команды хода не начинает и не кончает: команды владелец запускает и в простое.
    func testCommandOutputDoesNotChangeTurn() throws {
        var p = TranscriptParser()
        let lines = String(decoding: try fixture("local-commands.jsonl"), as: UTF8.self).split(separator: "\n")
        p.feed(lines: Array(lines.dropLast()))
        XCTAssertFalse(p.turnInProgress)
    }

    /// Вывод команды — отдельный блок в обеих лентах: и у менеджера, и у агента, со своей строкой, без склейки с ответом.
    func testCommandOutputInFeeds() throws {
        let e = try entries()
        let thread = ThreadGrouping.items(e)
        XCTAssertEqual(thread.compactMap { if case let .command(_, name, _) = $0 { return name } else { return nil } },
                       ["/context", "/resume", "/agents", "/export"])
        XCTAssertTrue(ThreadFeed.isBoundary(.command(name: "/x", output: "y")))
        let manager = FeedGrouping.manager(e, peers: FeedPeers())
        XCTAssertEqual(manager.compactMap { if case let .command(_, name, _) = $0 { return name } else { return nil } },
                       ["/context", "/resume", "/agents", "/export"])
    }

    // MARK: хвосты команд Claude Code

    private func invocations() throws -> [ChatEntry] {
        var p = TranscriptParser()
        p.feed(lines: String(decoding: try fixture("command-invocations.jsonl"), as: UTF8.self).split(separator: "\n"))
        return p.entries
    }

    /// Вызов скилла и команды плагина остаётся в обеих лентах строкой «/имя аргументы»; встроенная команда видна
    /// только выводом. Строка вызова начинает отрезок ленты, как вывод команды.
    func testPromptCommandCallLineInFeeds() throws {
        let e = try invocations()
        let manager = FeedGrouping.manager(e, peers: FeedPeers())
        XCTAssertEqual(manager.compactMap { if case let .commandCall(_, line) = $0 { return line } else { return nil } },
                       ["/superpowers:brainstorming тема", "/vercel:deploy"])
        XCTAssertEqual(manager.compactMap { if case let .command(_, name, _) = $0 { return name } else { return nil } }, ["/effort"])
        let thread = ThreadGrouping.items(e)
        XCTAssertEqual(thread.compactMap { if case let .commandCall(_, line) = $0 { return line } else { return nil } },
                       ["/superpowers:brainstorming тема", "/vercel:deploy"])
        XCTAssertTrue(ThreadFeed.isBoundary(.invoked(name: "/x", args: "", prompt: true)))
        XCTAssertFalse(ThreadFeed.isBoundary(.invoked(name: "/x", args: "")))
        var hidden = FeedVisibility()
        hidden.teamMessages = false; hidden.compacted = false; hidden.turnDuration = false; hidden.otherTools = false
        XCTAssertEqual(FeedGrouping.visible(manager, hidden).filter { if case .commandCall = $0 { return true } else { return false } }.count, 2,
                       "строка вызова видна при любом наборе показа, как вывод команды")
        XCTAssertEqual(FeedGrouping.commandCallText("/x", args: "a\nb "), "/x a b")
    }

    /// «Unknown command» (`system/informational`, claude 2.1.292) — запись ленты с именем и подсказкой Claude Code;
    /// другой текст informational в ленту не идёт, хода запись не начинает.
    func testUnknownCommandRecord() throws {
        var p = TranscriptParser()
        p.feed(lines: String(decoding: try fixture("unknown-command.jsonl"), as: UTF8.self).split(separator: "\n"))
        XCTAssertEqual(p.entries.map(\.kind), [.unknownCommand(name: "/rsume", suggestion: "/resume"),
                                               .unknownCommand(name: "/todos", suggestion: nil), .owner("Привет")])
        let manager = FeedGrouping.manager(Array(p.entries.prefix(2)), peers: FeedPeers())
        XCTAssertEqual(manager.compactMap { if case let .command(_, name, text) = $0 { return name + " — " + text } else { return nil } },
                       ["/rsume — Claude Code не знает команду /rsume. Возможно, имелась в виду /resume",
                        "/todos — Claude Code не знает команду /todos"])
        let thread = ThreadGrouping.items(Array(p.entries.prefix(1)))
        XCTAssertEqual(thread.count, 1)
        let lines = String(decoding: try fixture("unknown-command.jsonl"), as: UTF8.self).split(separator: "\n")
        let rec = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual(TranscriptParser.turnMark(rec), .none)
        XCTAssertNil(TranscriptParser.unknownCommand("Compacted while idle, before the prompt cache expired"))
        XCTAssertEqual(TranscriptParser.unknownCommand("Unknown command: /superpowers:x-y")?.name, "/superpowers:x-y")
    }
}
