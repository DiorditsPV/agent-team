import XCTest
@testable import AgentTeamCore

final class KeyedCacheTests: XCTestCase {
    func testRebuildsOnlyWhenKeyChanges() {
        let cache = KeyedCache<[Int]>()
        var calls = 0
        func build() -> [Int] { calls += 1; return [calls] }
        XCTAssertEqual(cache.value(key: "a", build: build), [1])
        XCTAssertEqual(cache.value(key: "a", build: build), [1], "тот же ключ — из кеша")
        XCTAssertEqual(cache.value(key: "a", build: build), [1])
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cache.value(key: "b", build: build), [2], "ключ сменился — пересчёт")
        XCTAssertEqual(cache.value(key: "a", build: build), [3], "возврат к прежнему ключу — снова пересчёт: хранится одно значение")
        XCTAssertEqual(cache.rebuilds, 3)
    }
}

@MainActor
final class ChatRevisionTests: XCTestCase {
    /// Ревизия меняется при каждой замене записей чата и больше ни при чём: по ней кеш группировки узнаёт, что пора пересчитать.
    func testRevisionGrowsOnlyWhenChatIsReplaced() {
        let project = ProjectModel(repo: "/tmp/none", session: "team-none", cli: nil)
        let r0 = project.chatRevision
        _ = project.chat.count
        XCTAssertEqual(project.chatRevision, r0, "чтение ревизию не меняет")
        project.benchFreezeChat([ChatEntry(id: "1", time: nil, kind: .reply("a"))])
        XCTAssertNotEqual(project.chatRevision, r0)
        let r1 = project.chatRevision
        project.benchFreezeChat([])
        XCTAssertNotEqual(project.chatRevision, r1)
    }
}
