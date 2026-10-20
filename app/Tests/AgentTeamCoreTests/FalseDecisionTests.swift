import XCTest
@testable import AgentTeamCore

/// Экраны сняты с живого claude 2.1.295: меню /rewind, форма AskUserQuestion, диалог права; пути обезличены.
final class FalseDecisionTests: XCTestCase {
    private func lines(_ name: String) throws -> [StyledLine] {
        SGRParser.parse(String(decoding: try fixture(name), as: UTF8.self))
    }

    private let rule = String(repeating: "─", count: 30)

    private var askForm: String {
        "⏺ Спрошу\n\n\(rule)\n ☐ Color\nWhich color do you prefer?\n❯ 1. Red\n     Red color\n  2. Blue\n     Blue color\n  3. Type something.\n\(rule)\n  4. Chat about this\nEnter to select · ↑/↓ to navigate · Esc to cancel\n\(rule)"
    }

    func testRewindMenuIsNotADecision() throws {
        let screen = try lines("live-rewind.txt").map(\.plain)
        XCTAssertTrue(screen.contains { $0.contains("Esc to cancel") })
        XCTAssertFalse(PaneTail.asksPermission(screen), "меню открыл сам владелец: решения нет")
        XCTAssertNil(WaitingNotice.from(lines: try lines("live-rewind.txt"), asksTrust: false, asksPermission: false))
    }

    func testRealPermissionDialogStaysADecision() throws {
        XCTAssertTrue(PaneTail.asksPermission(try lines("live-perm.txt").map(\.plain)))
        let d = DecisionText.question(name: "Менеджер", lines: try lines("live-perm.txt"), asksTrust: false, dir: "proj")
        XCTAssertEqual(d.kind, .permission)
        XCTAssertEqual(d.text, "Менеджер просит право вне allow — ответ в его панели")
    }

    func testAskFormIsADecisionWithQuestionWording() {
        let screen = SGRParser.parse(askForm)
        XCTAssertTrue(PaneTail.asksPermission(screen.map(\.plain)), "форма ждёт ответа владельца")
        let d = DecisionText.question(name: "Менеджер", lines: screen, asksTrust: false, dir: "proj")
        XCTAssertEqual(d.kind, .ask)
        XCTAssertTrue(d.text.hasPrefix("Менеджер задал вопрос"), d.text)
        XCTAssertFalse(d.text.contains("право"), d.text)
        XCTAssertTrue(d.text.contains("Which color"), d.text)
    }

    func testFormOptionsAndQuestionSkipBuiltInsAndDescriptions() {
        let screen = SGRParser.parse(askForm)
        XCTAssertEqual(AskForm.options(screen), ["Red", "Blue"])
        XCTAssertEqual(AskForm.question(screen), "Which color do you prefer?")
    }

    /// Экран живой формы: подсказка не у самого низа (дальше пустые строки и замыкающая рамка).
    func testRealAskFormScreenIsADecision() throws {
        let screen = try lines("live-ask.txt")
        XCTAssertTrue(AskForm.isOpen(screen))
        XCTAssertTrue(PaneTail.asksPermission(screen.map(\.plain)), "хвост экрана: пустые строки, рамка, подсказка выше")
        XCTAssertEqual(DecisionText.question(name: "Менеджер", lines: screen, asksTrust: false, dir: "p").kind, .ask)
        XCTAssertEqual(AskForm.options(screen), ["Red", "Blue"])
        XCTAssertEqual(AskForm.question(screen), "Which color do you prefer?")
    }

    func testReviewScreenOfFormIsStillAsking() {
        let s = "Review your answers\n ● Which color?\n   → Red\nReady to submit your answers?\n❯ 1. Submit answers\n  2. Cancel"
        XCTAssertTrue(PaneTail.asksPermission(SGRParser.parse(s).map(\.plain)))
    }

    func testTrustStaysTrust() {
        let d = DecisionText.question(name: "Менеджер", lines: SGRParser.parse(" Quick safety check: Is this a project you trust?\n ❯ 1. Yes, I trust this folder"), asksTrust: false, dir: "proj")
        XCTAssertEqual(d.kind, .trust)
        XCTAssertEqual(d.text, "Менеджер спрашивает, доверяете ли вы папке proj")
    }
}
