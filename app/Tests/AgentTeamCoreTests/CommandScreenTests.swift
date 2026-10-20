import XCTest
@testable import AgentTeamCore

/// Экраны встроенных команд Claude Code. Сняты с живого claude 2.1.292 на временном сокете tmux (панель 120×40):
/// команда отправлена в строку ввода, экран захвачен `capture-pane -p -e`. Личное заменено нейтральным той же ширины,
/// прокрутка сессии над панелью — пустыми строками.
final class CommandScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [StyledLine] {
        SGRParser.parse(String(decoding: try fixture("live-\(name).txt"), as: UTF8.self))
    }

    /// Экраны команд: заголовок панели — первая строка после верхней рамки, последняя показанная строка — её низ.
    private let panels: [(name: String, title: String, last: String)] = [
        ("cmd-mcp", "MCP config diagnostics", "plugin:deploy:deploy"),
        ("cmd-config", "Settings  Status   Config", "Esc to clear"),
        ("cmd-status", "Settings  Status   Config", "Esc to cancel"),
        ("cmd-cost", "Settings  Status   Config", "not a breakdown"),
        ("cmd-model", "Select model", "Esc to cancel"),
        ("cmd-help", "Help  General   Commands", "Esc to cancel"),
        ("cmd-permissions", "Permissions  Recently denied", "Esc to cancel"),
        ("cmd-add-dir", "Add directory to workspace", "Esc to cancel"),
        ("cmd-rewind-empty", "Rewind", "Esc to cancel"),
        ("cmd-export", "Export conversation", "Esc to cancel"),
        ("cmd-memory", "Memory", "Esc to cancel"),
    ]

    private func trimmed(_ l: StyledLine) -> String { l.plain.trimmingCharacters(in: .whitespaces) }

    /// Панель команды целиком: от верхней рамки до последней непустой строки, без предела высоты строки ввода.
    func testCommandPanelsAreShownWhole() throws {
        for p in panels {
            let lines = try screen(p.name)
            guard let r = LiveInput.region(lines) else { XCTFail("\(p.name): экран команды не найден"); continue }
            XCTAssertTrue(trimmed(r.rows[0]).hasPrefix("▔▔▔▔"), "\(p.name): первая строка — верхняя рамка")
            XCTAssertTrue(trimmed(r.rows[1]).hasPrefix(p.title) || trimmed(r.rows[2]).hasPrefix(p.title) || r.rows.prefix(4).contains { trimmed($0).hasPrefix(p.title) },
                          "\(p.name): заголовок панели сразу под рамкой")
            let tail = r.rows.reversed().first { !trimmed($0).isEmpty }.map(trimmed) ?? ""
            XCTAssertTrue(tail.contains(p.last) || r.rows.suffix(3).contains { trimmed($0).contains(p.last) }, "\(p.name): низ панели — «\(p.last)», а не «\(tail)»")
            XCTAssertEqual(r.offset, lines.firstIndex { trimmed($0).hasPrefix("▔▔▔▔") }, p.name)
        }
    }

    /// Признак экрана команды на каждом захвате: открыт у всех панелей, закрыт после Esc, у строки ввода во время хода
    /// (`/context` пишет вывод после строки хода), у диалога доверия и у прежних экранов строки ввода, права и формы.
    func testCommandScreenFlag() throws {
        for p in panels { XCTAssertTrue(PaneScreen.read(try screen(p.name), reply: false).commandScreen, p.name) }
        for name in ["cmd-closed", "cmd-context-turn", "trust", "typed", "slash", "at", "multi", "perm", "ask", "askcard-review"] {
            XCTAssertFalse(PaneScreen.read(try screen(name), reply: false).commandScreen, name)
        }
    }

    /// Рамка экрана команды с отступом — цитата (кто-то вывел фикстуру экрана в ленту), а не экран: над диалогом права и
    /// над строкой ввода в режиме «!» признак экрана ложен, живая часть — диалог и строка ввода, как без цитаты.
    func testIndentedRuleIsNotACommandScreen() throws {
        let perm = try screen("perm-quoted-rule")
        XCTAssertFalse(PaneScreen.read(perm, reply: false).commandScreen)
        XCTAssertTrue(PaneScreen.read(perm, reply: false).asksPermission, "вопрос о праве — по-прежнему вопрос")
        let pr = try XCTUnwrap(LiveInput.region(perm))
        XCTAssertEqual(pr.offset, try XCTUnwrap(LiveInput.region(screen("perm"))).offset, "часть — с диалога, как без цитаты")
        XCTAssertFalse(pr.rows.contains { $0.plain.contains("▔▔▔▔") })
        let shell = try screen("shell-quoted-rule")
        XCTAssertFalse(PaneScreen.read(shell, reply: false).commandScreen)
        let sr = try XCTUnwrap(LiveInput.region(shell))
        XCTAssertFalse(sr.rows.contains { $0.plain.contains("▔▔▔▔") }, "строка «!» — без цитаты над ней")
        XCTAssertTrue(sr.rows.contains { $0.plain.hasPrefix("!") })
    }

    /// Текст панели — не черновик ответа менеджера («пишет…»).
    func testCommandPanelIsNotAReplyDraft() throws {
        for p in panels { XCTAssertNil(PaneScreen.read(try screen(p.name), reply: true).reply, p.name) }
    }

    /// Закрытый экран и ход со строкой ввода — прежняя строка ввода, а не панель.
    func testClosedScreenShowsInputLine() throws {
        for name in ["cmd-closed", "cmd-context-turn"] {
            let r = try XCTUnwrap(LiveInput.region(try screen(name)), name)
            XCTAssertFalse(r.rows.contains { trimmed($0).hasPrefix("▔▔▔▔") }, name)
            XCTAssertTrue(r.rows.contains { trimmed($0).hasPrefix("❯") }, "\(name): строка ввода в части")
        }
    }

    /// Экран, которого приложение не знает (нет ни строки ввода, ни диалога, ни панели), показывается своим низом.
    func testUnknownScreenTail() throws {
        let lines = (0..<60).map { i in StyledLine(runs: [StyledRun(text: i < 50 ? "строка \(i)" : "", style: TermStyle())]) }
        XCTAssertNil(LiveInput.region(lines))
        let t = try XCTUnwrap(LiveInput.tail(lines))
        XCTAssertEqual(t.offset, 50 - LiveInput.maxRows)
        XCTAssertEqual(t.rows.count, LiveInput.maxRows)
        XCTAssertEqual(t.rows.last?.plain, "строка 49", "пустые строки под экраном не показываются")
        XCTAssertNil(LiveInput.tail([StyledLine(runs: [])]), "пустой экран — нечего показывать")
    }

    /// Экран команды — не вопрос владельцу: ни права, ни подписи «ждёт ответа», и текст строки ввода не набран.
    func testCommandPanelIsNotAQuestion() throws {
        for p in panels {
            let s = PaneScreen.read(try screen(p.name), reply: false)
            XCTAssertFalse(s.asksPermission, "\(p.name): не запрос права")
            XCTAssertFalse(s.asksTrust, p.name)
            XCTAssertFalse(s.askFormOpen, p.name)
            XCTAssertNil(s.notice, "\(p.name): подписи «ждёт ответа» нет")
        }
    }
}
