import XCTest
@testable import AgentTeamCore

/// Черновик «пишет…» вне тела чата: накопление с экрана, удержание до прихода блока, сверка с лентой в кадре.
@MainActor
final class LiveDraftTests: XCTestCase {
    private var delayed: [() -> Void] = []

    private func make() -> LiveDraft {
        let d = LiveDraft()
        d.after = { [weak self] _, work in self?.delayed.append(work) }
        return d
    }

    private func reply(_ id: String, _ text: String) -> ChatEntry {
        ChatEntry(id: id, time: Date(timeIntervalSince1970: 1_760_000_000), kind: .reply(text))
    }

    func testScreenTextShownUntilBlockArrivesInSameFeed() {
        let d = make()
        var grew = 0
        d.onGrew = { grew += 1 }
        d.screen = LiveReply(text: "Сборка прошла, тесты зелёные", startCut: false)
        d.screen = LiveReply(text: "Сборка прошла, тесты зелёные: 591 из 591", startCut: false)
        XCTAssertEqual(grew, 2)
        XCTAssertEqual(d.shown(feed: [], key: "1")?.text, "Сборка прошла, тесты зелёные: 591 из 591")
        // Блок пришёл в ленту: в кадре с ним черновика уже нет, хотя экран его ещё показывает.
        let feed = [reply("a", "Сборка прошла, **тесты зелёные**: 591 из 591")]
        XCTAssertNil(d.shown(feed: feed, key: "2"))
    }

    func testHeldAfterScreenClearsThenDropsAfterHold() {
        let d = make()
        d.screen = LiveReply(text: "Прерванный ответ, блок не придёт", startCut: false)
        d.screen = nil
        XCTAssertNotNil(d.shown(feed: [], key: "1"), "ушедший с экрана держится")
        XCTAssertEqual(delayed.count, 1)
        delayed.forEach { $0() }
        XCTAssertNil(d.shown(feed: [], key: "1"), "после срока снят")
    }

    func testNewScreenCancelsHold() {
        let d = make()
        d.screen = LiveReply(text: "Первый ответ на экране", startCut: false)
        d.screen = nil
        d.screen = LiveReply(text: "Второй ответ на экране", startCut: false)
        delayed.forEach { $0() }
        XCTAssertEqual(d.shown(feed: [], key: "1")?.text, "Второй ответ на экране")
    }

    func testCutScreenTailJoinsHeldText() {
        let d = make()
        d.screen = LiveReply(text: "Начало ответа. Середина ответа, которая уйдёт за край экрана.", startCut: false)
        d.screen = LiveReply(text: "Середина ответа, которая уйдёт за край экрана. Конец.", startCut: true)
        XCTAssertEqual(d.shown(feed: [], key: "1")?.text, "Начало ответа. Середина ответа, которая уйдёт за край экрана. Конец.")
    }

    func testWrittenKeysMatchOldCheck() {
        let chat = [reply("a", "Ход 1. Сборка прошла, **тесты зелёные**: 246 прошли")]
        let r = LiveReply(text: "Ход 1. Сборка прошла, тесты зелёные: 246 прошли", startCut: false)
        XCTAssertTrue(LiveReply.isWritten(r, in: chat))
        XCTAssertTrue(LiveReply.isWritten(r, keys: LiveReply.writtenKeys(chat)))
        XCTAssertFalse(LiveReply.isWritten(LiveReply(text: "Совсем другой текст ответа", startCut: false), in: chat))
    }
}
