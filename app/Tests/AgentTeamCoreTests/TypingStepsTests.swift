import XCTest
@testable import AgentTeamCore

/// Набор сообщения клавишами: шаги, перенос, табуляция, подсказки и режимы Claude Code.
final class TypingStepsTests: XCTestCase {
    func testLinesBecomeTextAndMetaEnter() {
        XCTAssertEqual(TmuxHub.typingSteps("раз\n\nдва"), [.text("раз"), .newline, .newline, .text("два")])
        XCTAssertEqual(TmuxHub.typingSteps("a\r\nb"), [.text("a"), .newline, .text("b")])
    }

    func testTabsBecomeSpacesAndLongLinesAreChunked() {
        XCTAssertEqual(TmuxHub.typingSteps("до\tпосле"), [.text("до    после")])
        let long = String(repeating: "ж", count: 3200)
        let steps = TmuxHub.typingSteps(long, chunk: 1500)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined(), long)
    }

    /// Хвост «@файл» или «/команда» открывает список подсказок: пробел закрывает его, и Enter отправляет.
    func testTrailingMentionGetsClosingSpace() {
        XCTAssertEqual(TmuxHub.typingSteps("смотри @README.md").last, .text(" "))
        XCTAssertEqual(TmuxHub.typingSteps("/compact").last, .text(" "))
        XCTAssertEqual(TmuxHub.typingSteps("смотри README").last, .text("смотри README"))
    }

    func testModesThatChangeInputGoByPaste() {
        XCTAssertFalse(TmuxHub.canType("!rm -rf x"))
        XCTAssertFalse(TmuxHub.canType("  # заметка в память"))
        XCTAssertTrue(TmuxHub.canType("/compact"))
        XCTAssertTrue(TmuxHub.canType("обычный текст! с # внутри"))
    }
}
