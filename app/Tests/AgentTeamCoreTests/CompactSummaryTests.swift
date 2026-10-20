import XCTest
@testable import AgentTeamCore

final class CompactSummaryTests: XCTestCase {
    private func line(_ o: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }

    private var summary: [String: Any] {
        ["type": "user", "uuid": "u-sum", "timestamp": "2026-10-17T07:20:00.000Z",
         "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
         "message": ["role": "user", "content": "This session is being continued from a previous conversation that ran out of context.\nSummary:\n1. Пример сводки."]]
    }

    func testCompactSummaryBecomesDividerNotOwnerMessage() {
        var p = TranscriptParser()
        p.feed(lines: [
            line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": "Сделай отчёт"]]),
            line(summary),
            line(["type": "assistant", "uuid": "a1", "message": ["id": "m1", "content": [["type": "text", "text": "Продолжаю."]]]]),
        ].map { Substring($0) })
        XCTAssertEqual(p.entries.map(\.kind), [.owner("Сделай отчёт"), .compacted, .reply("Продолжаю.")])
        XCTAssertNotNil(p.entries[1].time)
        XCTAssertFalse(p.entries.contains { if case let .owner(t) = $0.kind { return t.contains("continued") } else { return false } })
    }

    func testSummaryDoesNotStartATurn() {
        var p = TranscriptParser()
        p.feed(lines: [Substring(line(summary))])
        XCTAssertEqual(p.entries.map(\.kind), [.compacted])
        XCTAssertFalse(p.turnInProgress)
    }

    func testBothFeedsGroupDividerAsBoundary() {
        var p = TranscriptParser()
        p.feed(lines: [line(summary), line(["type": "assistant", "uuid": "a1", "message": ["id": "m1", "content": [["type": "text", "text": "Да."]]]])].map { Substring($0) })
        let items = ThreadGrouping.items(p.entries)
        guard case .compacted = items[0], case let .reply(_, _, showWho) = items[1] else { return XCTFail("\(items)") }
        XCTAssertTrue(showWho)
    }
}
