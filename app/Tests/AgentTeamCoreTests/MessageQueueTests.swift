import XCTest
@testable import AgentTeamCore

/// Очередь сообщений владельца, которую держит приложение, пока менеджер в ходе.
@MainActor
final class MessageQueueTests: XCTestCase {
    private func model() -> ProjectModel {
        ProjectModel(repo: NSTemporaryDirectory() + "agtest-queue", session: "team-queue", cli: nil)
    }

    private func owner(_ id: String, _ text: String) -> ChatEntry { ChatEntry(id: id, time: nil, kind: .owner(text)) }

    /// Пока менеджер в ходе, ничего не уходит; ход кончился — по одному, по порядку.
    func testHeldMessagesGoOneByOneInOrderAfterTurn() {
        let m = model()
        m.managerBusy = true
        let a = m.addPending(text: "первое", images: [], held: true)
        let b = m.addPending(text: "второе", images: [], held: true)
        XCTAssertNil(m.nextHeldToSend(), "менеджер в ходе")
        m.managerBusy = false
        XCTAssertEqual(m.nextHeldToSend()?.id, a)
        m.markSent(a)
        XCTAssertNil(m.nextHeldToSend(), "первое ещё не в транскрипте: второе ждёт")
        m.reconcilePending(against: [owner("u1", "первое")])
        XCTAssertEqual(m.nextHeldToSend()?.id, b)
    }

    /// Удержанное не снимается записью транскрипта, пока в панель не ушло.
    func testHeldIsNotMatchedByTranscript() {
        let m = model()
        m.managerBusy = true
        m.addPending(text: "жду", images: [], held: true)
        m.reconcilePending(against: [owner("x", "жду")])
        XCTAssertEqual(m.pending.count, 1)
        XCTAssertFalse(m.pending[0].isUndelivered(now: Date().addingTimeInterval(10_000)), "«не дошло» — только для ушедшего")
    }

    /// «Стоп»: очередь не уходит сама и остаётся «остановлено»; «↑ сейчас» одного возвращает остальным обычное ожидание.
    func testStopHoldsQueueAndSendNowReleasesOthers() {
        let m = model()
        m.managerBusy = true
        let a = m.addPending(text: "а", images: [], held: true)
        let b = m.addPending(text: "б", images: [], held: true)
        m.stopQueue()
        m.managerBusy = false
        XCTAssertNil(m.nextHeldToSend())
        XCTAssertTrue(m.pending.allSatisfy(\.stopped))
        m.releaseOthers(except: a)
        m.markSent(a)
        XCTAssertFalse(m.pending.first { $0.id == b }!.stopped)
        m.reconcilePending(against: [owner("u", "а")])
        XCTAssertEqual(m.nextHeldToSend()?.id, b, "после следующего конца хода уйдёт и оно")
    }

    func testEditReturnsMessageAndRemovesItFromQueue() throws {
        let m = model()
        m.managerBusy = true
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let id = m.addPending(text: "поправить", images: [url], held: true)
        let taken = try XCTUnwrap(m.takeForEdit(id))
        XCTAssertEqual(taken.text, "поправить")
        XCTAssertEqual(taken.images, [url])
        XCTAssertTrue(m.pending.isEmpty)
        XCTAssertNil(m.takeForEdit(id))
    }

    /// Ушедшее и потерянное (две минуты без хода) не блокирует остальную очередь.
    func testLostSentMessageDoesNotBlockQueue() {
        let m = model()
        m.managerBusy = false
        let sent = m.addPending(text: "потеряно", images: [])
        m.managerBusy = true
        let held = m.addPending(text: "следующее", images: [], held: true)
        m.managerBusy = false
        m.trackQuiet(now: Date())
        XCTAssertNil(m.nextHeldToSend(now: Date().addingTimeInterval(10)), "отправленное ещё ждёт")
        XCTAssertEqual(m.nextHeldToSend(now: Date().addingTimeInterval(PendingMessage.deliveryTimeout + 5))?.id, held)
        XCTAssertNotNil(m.pending.first { $0.id == sent })
    }
}
