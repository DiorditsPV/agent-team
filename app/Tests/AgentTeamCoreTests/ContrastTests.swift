import XCTest
@testable import AgentTeamCore

/// Минимальный контраст RGB-цветов программы к фону темы терминала.
final class ContrastTests: XCTestCase {
    private let white: UInt32 = 0xFFFFFF
    private let darkBg: UInt32 = 0x1E1E1E

    func testRatioBounds() {
        XCTAssertEqual(Contrast.ratio(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(Contrast.ratio(0x808080, 0x808080), 1, accuracy: 0.001)
    }

    /// Голубой и оранжевый на белом (Claude Code) доводятся до 4,5:1, оттенок сохраняется.
    func testCyanAndOrangeOnWhite() {
        for c: UInt32 in [0x00BFFF, 0xFFA500, 0x7FDBFF] {
            XCTAssertLessThan(Contrast.ratio(c, white), 4.5, "исходный цвет должен быть нечитаем")
            let fixed = Contrast.ensure(c, on: white)
            XCTAssertGreaterThanOrEqual(Contrast.ratio(fixed, white), 4.5, String(c, radix: 16))
            XCTAssertLessThan(Contrast.luminance(fixed), Contrast.luminance(c), "на светлом фоне цвет темнеет")
            XCTAssertEqual(Contrast.hsl(fixed).0, Contrast.hsl(c).0, accuracy: 0.02, "оттенок сохранён")
        }
    }

    func testReadableColorUnchanged() {
        XCTAssertEqual(Contrast.ensure(0x1A4D8C, on: white), 0x1A4D8C)
        XCTAssertEqual(Contrast.ensure(0xC8F169, on: darkBg), 0xC8F169)        // привычный светлый на тёмном — как был
    }

    /// На тёмном фоне тёмный цвет, наоборот, светлеет.
    func testDarkColorOnDarkBackgroundLightens() {
        let fixed = Contrast.ensure(0x1F3A93, on: darkBg)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(fixed, darkBg), 4.5)
        XCTAssertGreaterThan(Contrast.luminance(fixed), Contrast.luminance(0x1F3A93))
    }

    /// Серые тоже: оттенка нет, сдвигается только яркость.
    func testGrayOnWhite() {
        let fixed = Contrast.ensure(0xCCCCCC, on: white)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(fixed, white), 4.5)
        XCTAssertEqual(fixed >> 16 & 0xFF, fixed & 0xFF)
    }
}
