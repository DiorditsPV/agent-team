import XCTest
@testable import AgentTeamCore

final class PaneGridTests: XCTestCase {
    func testOneColumnSplitsHeightBetweenAgents() {
        // 3 панели в 1 столбец: 3 ряда, 2 промежутка по 4.
        XCTAssertEqual(SplitLayout.paneHeight(available: 1000, collapsedRows: 0, panes: 3, columns: 1, gap: 4), 330)
    }

    func testTwoColumnsSplitsHeightBetweenRows() {
        // 3 панели в 2 столбца: 2 ряда, один промежуток.
        XCTAssertEqual(SplitLayout.paneHeight(available: 1000, collapsedRows: 0, panes: 3, columns: 2, gap: 4), 498)
    }

    func testCollapsedRowsTakeTheirHeight() {
        XCTAssertEqual(SplitLayout.paneHeight(available: 1000, collapsedRows: 1, panes: 2, columns: 1, gap: 4), 474)
    }

    func testNeverBelowMinimumAndColumnScrolls() {
        XCTAssertEqual(SplitLayout.paneHeight(available: 300, collapsedRows: 0, panes: 4, columns: 1, gap: 4), SplitLayout.minPaneHeight)
    }
}
