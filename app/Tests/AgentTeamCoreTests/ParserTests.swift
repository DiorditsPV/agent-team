import XCTest
@testable import AgentTeamCore

final class ControlParserTests: XCTestCase {
    func testResponseBlocksAndNotifications() {
        var p = ControlParser()
        let input = """
        %begin 1792186460 294 0
        %end 1792186460 294 0
        %session-changed $0 team-x
        %begin 1792186460 301 1
        team-x %0\t
        %end 1792186460 301 1
        %extended-output %1 0 : echo hello\\015
        %output %2 hi
        %pause %3
        %continue %3
        %layout-change @0 abc def *
        %exit

        """
        let ev = p.feed(Data(input.utf8))
        XCTAssertEqual(ev, [
            .response(number: 294, flags: 0, ok: true, lines: []),
            .notification(name: "session-changed", args: ["$0", "team-x"]),
            .response(number: 301, flags: 1, ok: true, lines: ["team-x %0\t"]),
            .output(pane: "%1"),
            .output(pane: "%2"),
            .pause(pane: "%3"),
            .resumed(pane: "%3"),
            .notification(name: "layout-change", args: ["@0", "abc", "def", "*"]),
            .exit(reason: nil),
        ])
    }

    func testBlockEndsOnlyOnMatchingNumber() {
        var p = ControlParser()
        let input = "%begin 1 7 1\n%end 1 3 1\n%end of line\n%error 1 7 1\n"
        XCTAssertEqual(p.feed(Data(input.utf8)), [.response(number: 7, flags: 1, ok: false, lines: ["%end 1 3 1", "%end of line"])])
    }

    func testChunkedInputAndCRLF() {
        var p = ControlParser()
        XCTAssertEqual(p.feed(Data("%begin 1 2 1\r\nab".utf8)), [])
        XCTAssertEqual(p.feed(Data("c\n%en".utf8)), [])
        XCTAssertEqual(p.feed(Data("d 1 2 1\n".utf8)), [.response(number: 2, flags: 1, ok: true, lines: ["abc"])])
    }

    func testInvalidUTF8DoesNotBreakStream() {
        var p = ControlParser()
        var d = Data("%begin 1 2 1\n".utf8)
        d.append(contentsOf: [0xFF, 0xFE, 0x0A])
        d.append(Data("%end 1 2 1\n".utf8))
        let ev = p.feed(d)
        XCTAssertEqual(ev.count, 1)
    }

    func testQuoteAndUnescape() {
        XCTAssertEqual(TmuxQuote.word("a'b; $X"), "'a'\\''b; $X'")
        XCTAssertEqual(TmuxQuote.unescapeOutput("a\\015\\012\\134z"), Data([0x61, 0x0D, 0x0A, 0x5C, 0x7A]))
        XCTAssertEqual(TmuxQuote.unescapeOutput("\\01"), Data("\\01".utf8))
    }

    func testWordFlattensNewlines() {
        XCTAssertEqual(TmuxQuote.word("a\nb\rc"), "'a b c'")
    }

    @MainActor
    func testSanitizeOwnerText() {
        XCTAssertEqual(TmuxHub.sanitize("строка\u{1B}[201~ и\tтаб\nвторая\u{7}"), "строка[201~ и\tтаб\nвторая")
    }

    func testSocketDirectoryHonoursTmuxTmpdir() {
        XCTAssertEqual(TmuxHub.socketDirectory(environment: ["TMUX_TMPDIR": "/var/empty"]), "/var/empty/tmux-\(getuid())")
        XCTAssertEqual(TmuxHub.socketDirectory(environment: [:]), "/tmp/tmux-\(getuid())")
    }

    func testPermissionPrompt() {
        XCTAssertTrue(PaneTail.asksPermission([" Do you want to proceed?", " ❯ 1. Yes", "   2. No"]))
        XCTAssertFalse(PaneTail.asksPermission(["❯ ", "npm test"]))
    }

    func testPaneListing() {
        let lines = ["team-a\t%1\tmanager#1\t0\t100\t/repo", "team-a\t%2\t\t0\t101\t/repo", "team-a\t%3\tdev#1\t1\t102\t/wt",
                     "team-b\t%4\tmanager#1\t0\t103\t/b", "other\t%5\tx\t0\t1\t/"]
        let panes = TmuxListing.parsePanes(lines)
        XCTAssertEqual(panes.count, 5)
        XCTAssertEqual(TmuxListing.liveAgentCounts(panes), ["team-a": 1, "team-b": 1])
        XCTAssertEqual(TmuxListing.teamSessions(["team-b", "x", "team-a"]), ["team-a", "team-b"])
    }
}

final class SGRTests: XCTestCase {
    func testColorsAndReset() {
        let lines = SGRParser.parse("\u{1B}[1;32mok\u{1B}[0m plain \u{1B}[38;5;208mo\u{1B}[38;2;1;2;3mr\u{1B}[39m\nnext")
        XCTAssertEqual(lines.count, 2)
        let runs = lines[0].runs
        XCTAssertEqual(runs.map(\.text), ["ok", " plain ", "o", "r"])
        XCTAssertTrue(runs[0].style.bold)
        XCTAssertEqual(runs[0].style.fg, .indexed(2))
        XCTAssertEqual(runs[1].style, TermStyle())
        XCTAssertEqual(runs[2].style.fg, .indexed(208))
        XCTAssertEqual(runs[3].style.fg, .rgb(1, 2, 3))
        XCTAssertEqual(lines[1].plain, "next")
    }

    func testStyleCarriesAcrossLinesAndOSCDropped() {
        let lines = SGRParser.parse("\u{1B}[31mred\nstill\u{1B}]2;title\u{07}\u{1B}[m!")
        XCTAssertEqual(lines[1].runs.first?.style.fg, .indexed(1))
        XCTAssertEqual(lines[1].plain, "still!")
        XCTAssertEqual(lines[1].runs.last?.style, TermStyle())
    }

    func testBrightAndBackground() {
        let s = SGRParser.parse("\u{1B}[91;44mx").first!.runs.first!.style
        XCTAssertEqual(s.fg, .indexed(9))
        XCTAssertEqual(s.bg, .indexed(4))
    }
}

final class PaneTailTests: XCTestCase {
    func testCutsClaudeInputBox() {
        let screen = """
        ⏺ Работа
          ⎿ готово

        ✻ Jitterbugging… (5m)

        ────────────────────────────
        ❯\u{a0}
        ────────────────────────────
          [Sonnet 5.5] ctx 14%
        """
        let tail = PaneTail.content(SGRParser.parse(screen)).map(\.plain)
        XCTAssertEqual(tail, ["⏺ Работа", "  ⎿ готово", "", "✻ Jitterbugging… (5m)"])
        XCTAssertEqual(PaneTail.tail(SGRParser.parse(screen), count: 1).map(\.plain), ["✻ Jitterbugging… (5m)"])
    }

    func testRuleWithSessionTitle() {
        let screen = "вывод\n──────────── Разработчик ─\n❯ \n────────────\n статус"
        XCTAssertEqual(PaneTail.content(SGRParser.parse(screen)).map(\.plain), ["вывод"])
    }

    func testTailCollapsesBlankRuns() {
        XCTAssertEqual(PaneTail.tail(SGRParser.parse("a\n\n\n\nb\nc"), count: 3).map(\.plain), ["", "b", "c"])
    }

    func testNoPromptKeepsAll() {
        XCTAssertEqual(PaneTail.content(SGRParser.parse("a\nb\n\n")).map(\.plain), ["a", "b"])
    }

    func testTrust() {
        XCTAssertTrue(PaneTail.asksFolderTrust(["", " Do you trust the files in this folder?", " 1. Yes"]))
        XCTAssertTrue(PaneTail.asksFolderTrust(["Quick safety check"]))
        XCTAssertFalse(PaneTail.asksFolderTrust(["npm test"]))
    }
}

/// Запись с уже виденным id заменяется на месте; соседние блоки одного ответа склеиваются (М36: поиск по словарю).
final class ParserChangeTests: XCTestCase {
    func testReplaceByIDAndMerge() {
        var p = TranscriptParser()
        p.maxEntries = .max
        p.feed(lines: [#"{"type":"user","uuid":"u1","message":{"role":"user","content":"a"}}"#,
                       #"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"раз"}]}}"#,
                       #"{"type":"assistant","uuid":"a2","message":{"id":"m1","content":[{"type":"text","text":"два"}]}}"#,
                       #"{"type":"user","uuid":"u2","message":{"role":"user","content":"b"}}"#,
                       #"{"type":"user","uuid":"u1","message":{"role":"user","content":"a2"}}"#].map { Substring($0) })
        XCTAssertEqual(p.entries.map(\.kind), [.owner("a2"), .reply("раз\n\nдва"), .owner("b")])
    }

    /// После обрезки по `maxEntries` замена по id находит запись на её новом месте.
    func testReplaceAfterTrim() {
        var p = TranscriptParser()
        p.maxEntries = 2
        p.feed(lines: ["u1", "u2", "u3"].map { Substring(#"{"type":"user","uuid":"\#($0)","message":{"role":"user","content":"\#($0)"}}"#) })
        p.feed(lines: [Substring(#"{"type":"user","uuid":"u3","message":{"role":"user","content":"новый"}}"#)])
        XCTAssertEqual(p.entries.map(\.kind), [.owner("u2"), .owner("новый")])
    }
}

extension ParserChangeTests {
    /// Разборщик помнит самую раннюю изменённую запись: читатель ленты сверяет с неё, а не с начала (М36).
    func testChangedFromMarksAppendMergeAndReplace() {
        var p = TranscriptParser()
        p.maxEntries = .max
        p.feed(lines: [#"{"type":"user","uuid":"u1","message":{"role":"user","content":"a"}}"#,
                       #"{"type":"assistant","uuid":"a1","message":{"id":"m1","content":[{"type":"text","text":"раз"}]}}"#].map { Substring($0) })
        XCTAssertEqual(p.takeChangedFrom(), 0)
        XCTAssertNil(p.takeChangedFrom(), "отметка сбрасывается")
        p.feed(lines: [Substring(#"{"type":"assistant","uuid":"a2","message":{"id":"m1","content":[{"type":"text","text":"два"}]}}"#)])
        XCTAssertEqual(p.takeChangedFrom(), 1, "склейка блоков ответа меняет последнюю запись")
        p.feed(lines: [#"{"type":"user","uuid":"u2","message":{"role":"user","content":"b"}}"#,
                       #"{"type":"user","uuid":"u1","message":{"role":"user","content":"a2"}}"#].map { Substring($0) })
        XCTAssertEqual(p.takeChangedFrom(), 0, "замена записи по id отмечает её место")
    }
}
