import XCTest
@testable import AgentTeamCore

/// Отправленное сообщение, которого ещё нет в транскрипте: показ и снятие отметки «в очереди».
final class PendingMessageTests: XCTestCase {
    private func owner(_ id: String, _ text: String, images: Int = 0) -> ChatEntry {
        ChatEntry(id: id, time: nil, kind: .owner(text),
                  images: (0..<images).map { ChatImage(id: "\(id)#\($0)", mediaType: "image/png", base64: "AA") })
    }

    @MainActor
    private func model() -> ProjectModel {
        ProjectModel(repo: NSTemporaryDirectory() + "agtest-pending", session: "team-pending", cli: nil)
    }

    func testMatchesIgnoresWhitespaceAndLayout() {
        let p = PendingMessage(text: "первая строка\n\nвторая   строка\tтретья", images: [])
        XCTAssertTrue(p.matches(owner("u1", "первая строка вторая строка третья")))
        XCTAssertFalse(p.matches(owner("u2", "другой текст")))
    }

    func testImageCountMustMatchAndImageOnlyMessageMatches() {
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let withText = PendingMessage(text: "смотри", images: [url])
        XCTAssertFalse(withText.matches(owner("u1", "смотри")))
        XCTAssertTrue(withText.matches(owner("u1", "смотри", images: 1)))
        let only = PendingMessage(text: "", images: [url, url])
        XCTAssertTrue(only.matches(owner("u2", "", images: 2)))
        XCTAssertFalse(only.matches(owner("u3", "", images: 1)))
    }

    /// Такое же «да» из прошлого хода не снимает отметку: совпадают только новые записи.
    @MainActor
    func testEarlierIdenticalMessageDoesNotClearPending() {
        let m = model()
        let old = owner("old", "да")
        m.reconcilePending(against: [old])
        let id = m.addPendingForTest(text: "да", seen: ["old"])
        m.reconcilePending(against: [old])
        XCTAssertEqual(m.pending.map(\.id), [id], "старая запись — не наша")
        m.reconcilePending(against: [old, owner("new", "да")])
        XCTAssertTrue(m.pending.isEmpty, "новая запись сняла отметку")
    }

    /// Два одинаковых сообщения подряд — две записи; каждая снимает одну отметку, дубля нет.
    @MainActor
    func testTwoIdenticalPendingMatchOneEntryEach() {
        let m = model()
        m.addPendingForTest(text: "продолжай", seen: [])
        m.addPendingForTest(text: "продолжай", seen: [])
        m.reconcilePending(against: [owner("a", "продолжай")])
        XCTAssertEqual(m.pending.count, 1)
        m.reconcilePending(against: [owner("a", "продолжай"), owner("b", "продолжай")])
        XCTAssertTrue(m.pending.isEmpty)
    }

    @MainActor
    func testDropPendingAndLongTextPrefix() {
        let m = model()
        let long = String(repeating: "слово ", count: 100)
        let id = m.addPending(text: long, images: [])
        XCTAssertTrue(m.pending[0].matches(owner("x", long + " хвост, который Claude Code мог переписать")))
        m.dropPending(id)
        XCTAssertTrue(m.pending.isEmpty)
    }
}

extension PendingMessageTests {
    /// «Не дошло»: срок две минуты идёт только пока менеджер без хода; в ходе он обнуляется и начинается заново после хода.
    @MainActor
    func testUndeliveredOnlyAfterQuietTimeout() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-pending", session: "team-pending", cli: nil)
        let t0 = Date()
        m.managerBusy = false
        let id = m.addPending(text: "привет", images: [])
        XCTAssertFalse(m.pending[0].isUndelivered(now: t0 + 60))
        XCTAssertTrue(m.pending[0].isUndelivered(now: Date().addingTimeInterval(PendingMessage.deliveryTimeout + 1)))

        // Менеджер взял ход: срок обнуляется и не идёт сколько бы ни длился ход.
        m.managerBusy = true
        m.trackQuiet(now: t0 + 300)
        XCTAssertNil(m.pending[0].quietSince)
        XCTAssertFalse(m.pending[0].isUndelivered(now: t0 + 3000))

        // Ход кончился, а сообщения нет: срок начинается с конца хода.
        m.managerBusy = false
        m.trackQuiet(now: t0 + 400)
        XCTAssertFalse(m.pending[0].isUndelivered(now: t0 + 400 + 119))
        XCTAssertTrue(m.pending[0].isUndelivered(now: t0 + 400 + 121))
        m.dropPending(id)
        XCTAssertTrue(m.pending.isEmpty)
    }

    /// Сообщение, отправленное во время хода, ждёт без срока.
    @MainActor
    func testPendingSentDuringTurnHasNoTimeout() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-pending", session: "team-pending", cli: nil)
        m.managerBusy = true
        m.addPending(text: "ещё", images: [])
        XCTAssertNil(m.pending[0].quietSince)
        XCTAssertFalse(m.pending[0].isUndelivered(now: Date().addingTimeInterval(10_000)))
    }
}

@MainActor
extension ProjectModel {
    /// Для тестов: ожидающее сообщение с заданным набором уже виденных записей.
    @discardableResult
    func addPendingForTest(text: String, seen: Set<String>) -> String {
        let id = addPending(text: text, images: [])
        setSeenForTest(id: id, seen: seen)
        return id
    }
}

/// Запись уже в показанной (постраничной) ленте, а `ProjectModel.chat` ещё отстаёт — карточка не дублирует запись.
extension PendingMessageTests {
    private func shown(_ id: String, _ text: String, images: Int = 0) -> ChatEntry { owner(id, text, images: images) }

    @MainActor
    func testCardHiddenOnceShownFeedHasEntryEvenIfChatLags() {
        let m = model()
        m.addPending(text: "Мне не нравится.\nДавай перенесем", images: [])      // менеджер свободен
        let feedEntries = [shown("old", "Мне не нравится."), shown("new", "Мне не нравится.\nДавай перенесем")]
        XCTAssertTrue(PendingMessage.undelivered(m.pending, shown: feedEntries).isEmpty)
        m.reconcilePending(against: feedEntries)
        XCTAssertTrue(m.pending.isEmpty, "сверка по показанной ленте снимает карточку, не дожидаясь chat")
    }

    @MainActor
    func testEarlierSameTextInShownFeedDoesNotHideCard() {
        let m = model()
        m.addPending(text: "да", images: [], alsoSeen: ["old"])
        let feedEntries = [shown("old", "да")]
        XCTAssertEqual(PendingMessage.undelivered(m.pending, shown: feedEntries).count, 1, "прежнее «да» не наше")
        XCTAssertEqual(PendingMessage.undelivered(m.pending, shown: feedEntries + [shown("new", "да")]).count, 0)
    }

    @MainActor
    func testMessageWithImageAndTwoIdenticalCards() {
        let m = model()
        m.addPending(text: "смотри", images: [URL(fileURLWithPath: "/tmp/a.png")])
        m.addPending(text: "ок", images: [])
        m.addPending(text: "ок", images: [])
        let one = [shown("i", "смотри", images: 1), shown("o1", "ок")]
        XCTAssertEqual(PendingMessage.undelivered(m.pending, shown: one).count, 1, "второе «ок» ещё ждёт")
        XCTAssertTrue(PendingMessage.undelivered(m.pending, shown: one + [shown("o2", "ок")]).isEmpty)
    }

    /// Удержанное (в очереди приложения) сообщение не сопоставляется с записями, пока не ушло.
    @MainActor
    func testHeldCardStaysUntilSent() {
        let m = model()
        m.addPending(text: "потом", images: [], held: true)
        XCTAssertEqual(PendingMessage.undelivered(m.pending, shown: [shown("x", "потом")]).count, 1)
    }
}
