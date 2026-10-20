import XCTest
@testable import AgentTeamCore

/// Решение владельца не должно висеть после ответа: кеш team status отстаёт до 15 с, свежий захват панели точнее.
@MainActor
final class StaleDecisionTests: XCTestCase {
    private func agent(waiting: Bool) throws -> Agent {
        let json = #"{"name":"manager#1","role":"manager","n":1,"alive":true,"pane_id":"%0","waiting_human":\#(waiting)}"#
        return try JSONDecoder().decode(Agent.self, from: Data(json.utf8))
    }

    private var project: ProjectModel { ProjectModel(repo: NSTemporaryDirectory() + "agtest-stale", session: "team-stale", cli: nil) }

    func testCachedWaitingHoldsOnlyWithoutLiveCapture() throws {
        let a = try agent(waiting: true)
        // Захвата нет — верим кешу status.
        XCTAssertEqual(project.state(of: a, asksTrust: false, asksPermission: false, liveKnown: false), .waiting("ждёт ответа"))
        // Панель захвачена только что и вопроса в ней нет (владелец отказал или согласился) — не ждёт.
        XCTAssertNotEqual(project.state(of: a, asksTrust: false, asksPermission: false, liveKnown: true), .waiting("ждёт ответа"))
        // Ни хода на экране, ни транскрипта — «работает» утверждать не на чем.
        XCTAssertEqual(project.state(of: a, asksTrust: false, asksPermission: false, liveKnown: true), .noData)
    }

    func testLiveQuestionStillWaits() throws {
        let a = try agent(waiting: false)
        XCTAssertEqual(project.state(of: a, asksTrust: false, asksPermission: true, liveKnown: true), .waiting("ждёт права"))
        XCTAssertEqual(project.state(of: a, asksTrust: true, asksPermission: false, liveKnown: true), .waiting("ждёт доверия"))
    }

    /// Захват панели дополняет экран пустыми строками, а диалог не всегда прижат к низу: вопрос находится и тогда.
    func testQuestionFoundWhenScreenIsPaddedWithBlankLines() throws {
        let screen = SGRParser.parse(String(decoding: try fixture("live-perm.txt"), as: UTF8.self)).map(\.plain)
        XCTAssertTrue(screen.suffix(15).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }, "образец дополнен пустыми строками")
        XCTAssertTrue(PaneTail.asksPermission(screen))
        XCTAssertFalse(PaneTail.asksFolderTrust(screen))
        // Обычный экран без вопроса — не вопрос, с любым числом пустых строк внизу.
        XCTAssertFalse(PaneTail.asksPermission(["⏺ Готово", "", "❯ ", "", "", ""]))
        // Вопрос о доверии каталогу.
        XCTAssertTrue(PaneTail.asksFolderTrust([" Quick safety check: Is this a project you trust?", " ❯ 1. Yes", "", "", ""]))
    }
}
