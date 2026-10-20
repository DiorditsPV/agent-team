import XCTest
@testable import AgentTeamCore

/// Окна проверочного запуска уходят с основного экрана владельца на неосновной.
final class CheckPlacementTests: XCTestCase {
    // Основной 5K (как у владельца: 2560×1440 в точках) со строкой меню и второй 1600×1000 справа.
    private let main = CheckPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                                             visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415))
    private let second = CheckPlacement.Screen(frame: CGRect(x: 2560, y: 0, width: 1600, height: 1000),
                                               visibleFrame: CGRect(x: 2560, y: 0, width: 1600, height: 975))

    func testWindowFromMainMovesToSecondCentered() throws {
        let r = try XCTUnwrap(CheckPlacement.place(window: CGRect(x: 300, y: 200, width: 1200, height: 800), screens: [main, second]))
        XCTAssertEqual(r.screen, 1)
        XCTAssertEqual(r.frame.size, CGSize(width: 1200, height: 800))
        XCTAssertEqual(r.frame.midX, second.visibleFrame.midX)
        XCTAssertEqual(r.frame.midY, second.visibleFrame.midY)
        XCTAssertTrue(second.visibleFrame.contains(r.frame))
    }

    func testWindowAlreadyOnSecondKeepsFrame() throws {
        let w = CGRect(x: 2700, y: 100, width: 1000, height: 700)
        let r = try XCTUnwrap(CheckPlacement.place(window: w, screens: [main, second]))
        XCTAssertEqual(r.screen, 1)
        XCTAssertEqual(r.frame, w, "повторный вывод не двигает окно")
    }

    func testWindowBiggerThanSecondIsShrunkToVisibleFrame() throws {
        let r = try XCTUnwrap(CheckPlacement.place(window: CGRect(x: 100, y: 100, width: 2000, height: 1300), screens: [main, second]))
        XCTAssertEqual(r.frame, second.visibleFrame)
    }

    func testWindowSticksOutOfSecondIsPulledInside() throws {
        let r = try XCTUnwrap(CheckPlacement.place(window: CGRect(x: 3500, y: 700, width: 1000, height: 600), screens: [main, second]))
        XCTAssertEqual(r.screen, 1)
        XCTAssertTrue(second.visibleFrame.contains(r.frame), "\(r.frame)")
        XCTAssertEqual(r.frame.size, CGSize(width: 1000, height: 600))
    }

    func testSingleScreenLeavesWindowAlone() {
        XCTAssertNil(CheckPlacement.place(window: CGRect(x: 10, y: 10, width: 500, height: 400), screens: [main]))
        XCTAssertNil(CheckPlacement.place(window: .zero, screens: []))
    }

    func testThreeScreensKeepsWindowOnItsOwnNonMainScreen() throws {
        let third = CheckPlacement.Screen(frame: CGRect(x: -1200, y: 0, width: 1200, height: 900),
                                          visibleFrame: CGRect(x: -1200, y: 0, width: 1200, height: 875))
        let w = CGRect(x: -1100, y: 50, width: 800, height: 600)
        XCTAssertEqual(CheckPlacement.place(window: w, screens: [main, second, third])?.screen, 2)
        XCTAssertEqual(CheckPlacement.place(window: CGRect(x: 10, y: 10, width: 800, height: 600), screens: [main, second, third])?.screen, 1,
                       "с основного экрана — на первый неосновной")
    }
}
