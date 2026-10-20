import XCTest
@testable import AgentTeamCore

/// Сдвиг содержимого окна по кадрам: стенд истории мерит им то, что видит владелец, а не места строк.
final class ContentShiftTests: XCTestCase {
    /// «Лента»: строки текста (полосы с рисунком) через пустые промежутки, как блоки «Диалога».
    private func document(_ rows: Int, width: Int = 32, seed: UInt64 = 7) -> [[Float]] {
        var g = seed
        func next() -> Float { g = g &* 6364136223846793005 &+ 1442695040888963407; return Float(g >> 56) }
        return (0..<rows).map { i in i % 40 < 26 ? (0..<width).map { _ in next() } : Array(repeating: 20, count: width) }
    }
    private func window(_ doc: [[Float]], origin: Int, height: Int = 300) -> [[Float]] { Array(doc[origin..<(origin + height)]) }

    func testSameFrameIsZero() {
        let doc = document(2000)
        XCTAssertEqual(ContentShift.measure(before: window(doc, origin: 500), after: window(doc, origin: 500)).pixels, 0)
    }

    func testContentMovedDownAndUp() {
        let doc = document(2000)
        // Окно поднялось на 37 строк — содержимое уехало вниз на 37.
        XCTAssertEqual(ContentShift.measure(before: window(doc, origin: 500), after: window(doc, origin: 463)).pixels, 37)
        XCTAssertEqual(ContentShift.measure(before: window(doc, origin: 500), after: window(doc, origin: 620)).pixels, -120)
    }

    func testContentGoneBeyondWindowHasNoMatch() {
        let doc = document(4000)
        XCTAssertNil(ContentShift.measure(before: window(doc, origin: 500), after: window(doc, origin: 2500)).pixels)
    }

    /// Затемнение у верхнего края (другой рисунок в верхних строках) совпадению не мешает.
    func testTopShadeIgnored() {
        let doc = document(2000)
        var after = window(doc, origin: 490)
        for i in 0..<30 { after[i] = after[i].map { $0 * 0.5 } }
        XCTAssertEqual(ContentShift.measure(before: window(doc, origin: 500), after: after).pixels, 10)
    }
}
