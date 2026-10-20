import XCTest
@testable import AgentTeamCore

/// Разбор экрана один раз на захват: поля снимка на записанных экранах совпадают с прежним разбором по строкам.
final class PaneScreenTests: XCTestCase {
    private func screen(_ name: String) throws -> [StyledLine] {
        SGRParser.parse(String(decoding: try fixture("live-\(name).txt"), as: UTF8.self))
    }

    func testRecordedScreensMatchLineParsers() throws {
        for name in ["ask", "at", "multi", "perm", "rewind", "slash", "typed", "longform-narrow-sel3", "longform-tall-sel6"] {
            let lines = try screen(name)
            let s = PaneScreen.read(lines)
            let tail = lines.suffix(40).map(\.plain)
            XCTAssertEqual(s.turn, TurnStatus.from(lines), name)
            XCTAssertEqual(s.asksTrust, PaneTail.asksFolderTrust(tail), name)
            XCTAssertEqual(s.asksPermission, !s.asksTrust && PaneTail.asksPermission(tail), name)
            XCTAssertEqual(s.askFormOpen, AskForm.isOpen(lines), name)
            XCTAssertEqual(s.inputTyped, !(LiveInput.typedText(lines) ?? "").isEmpty, name)
            XCTAssertEqual(s.notice, WaitingNotice.from(lines: lines, asksTrust: s.asksTrust, asksPermission: s.asksPermission), name)
            XCTAssertEqual(s.reply, s.notice == nil ? LiveReply.extract(lines) : nil, name)
        }
    }

    func testDialogsAndTypedLine() throws {
        let perm = PaneScreen.read(try screen("perm"))
        XCTAssertTrue(perm.asksPermission)
        XCTAssertEqual(perm.notice?.kind, .permission)
        XCTAssertNil(perm.reply)
        let ask = PaneScreen.read(try screen("ask"))
        XCTAssertTrue(ask.askFormOpen)
        XCTAssertNotNil(ask.askQuestion)
        XCTAssertEqual(ask.notice?.kind, .ask)
        XCTAssertTrue(PaneScreen.read(try screen("typed")).inputTyped)
    }

    /// Менеджер пишет ответ: строка хода и черновик из одного разбора.
    func testTurnAndReplyWhileWriting() {
        let rule = String(repeating: "─", count: 40)
        let lines = SGRParser.parse("⏺ Разбор готов, вот что нашёл\n  в модуле экрана.\n\n✻ Stewing… (12s · ↓ 300 tokens)\n"
                                    + rule + "\n❯ \n" + rule + "\n  [Opus]")
        let s = PaneScreen.read(lines)
        XCTAssertEqual(s.turn?.seconds, 12)
        XCTAssertEqual(s.reply?.text, "Разбор готов, вот что нашёл в модуле экрана.")
        XCTAssertFalse(s.inputTyped)
        XCTAssertNil(s.notice)
    }
}
