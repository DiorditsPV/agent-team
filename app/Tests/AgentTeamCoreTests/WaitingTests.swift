import XCTest
@testable import AgentTeamCore

/// «Ждёт ли агент» — одна функция для плашки решений, фильтра «Ждут» и рамки панели; совпадает со статусом «ждёт…».
@MainActor
final class WaitingTests: XCTestCase {
    private func model() -> ProjectModel { ProjectModel(repo: NSTemporaryDirectory() + "agtest-wait", session: "team-wait", cli: nil) }

    func testUnansweredQuestionInTranscriptWaitsWithoutCapture() {
        let m = model()
        let a = Agent(name: "dev#1", role: "dev", alive: true, paneID: "%2")
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: false))
        m.setActivityForTest("dev#1", AgentActivity(lastAction: Date(), inTurn: true, pendingAsk: true))
        XCTAssertTrue(m.isWaiting(a, pane: nil, captured: false), "неотвеченный вопрос в транскрипте — ждёт, как и статус")
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: true), "захват панели без вопроса вернее транскрипта и кеша")
    }

    /// Одиночный вопрос: без хука Claude Code пишет его в транскрипт только вместе с ответом, `pendingAsk` молчит.
    /// Ждёт агент по полю `question` из team status.
    func testSingleQuestionWaitsByStatusQuestion() {
        let m = model()
        var a = Agent(name: "dev#1", role: "dev", alive: true, paneID: "%2")
        m.setActivityForTest("dev#1", AgentActivity(lastAction: Date(), inTurn: true, pendingAsk: false))
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: false))
        a.question = PendingQuestion(id: "toolu_1", questions: [.init(header: "Выпуск", text: "Как выкатываем?",
                                                                       options: [.init(label: "Сразу"), .init(label: "Отложить")])])
        XCTAssertTrue(m.isWaiting(a, pane: nil, captured: false), "вопрос из status — ждёт, хотя транскрипт молчит")
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: true), "захват панели без формы вернее кеша status")
        a.alive = false
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: false), "у неживого агента вопроса нет")
    }

    func testStatusFlagAndDeadAgent() {
        let m = model()
        var a = Agent(name: "dev#1", role: "dev", alive: true, paneID: "%2", waitingHuman: true)
        XCTAssertTrue(m.isWaiting(a, pane: nil, captured: false))
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: true))
        a.alive = false
        XCTAssertFalse(m.isWaiting(a, pane: nil, captured: false))
    }
}
