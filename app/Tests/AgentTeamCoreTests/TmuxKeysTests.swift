import AppKit
import XCTest
@testable import AgentTeamCore

final class TmuxKeysTests: XCTestCase {
    func testPlainAndShiftedKeys() {
        XCTAssertEqual(TmuxKeys.keys(.enter), ["Enter"])
        XCTAssertEqual(TmuxKeys.keys(.enter, .shift), ["\\", "Enter"])
        XCTAssertEqual(TmuxKeys.keys(.escape), ["Escape"])
        XCTAssertEqual(TmuxKeys.keys(.tab), ["Tab"])
        XCTAssertEqual(TmuxKeys.keys(.tab, .shift), ["BTab"])
        XCTAssertEqual(TmuxKeys.keys(.backspace), ["BSpace"])
        XCTAssertEqual(TmuxKeys.keys(.up), ["Up"])
        XCTAssertEqual(TmuxKeys.keys(.left, .option), ["M-Left"])
        XCTAssertEqual(TmuxKeys.keys(.deleteForward), ["DC"])
    }

    func testControlLetters() {
        XCTAssertEqual(TmuxKeys.control("a"), "C-a")
        XCTAssertEqual(TmuxKeys.control("R"), "C-r")
        XCTAssertNil(TmuxKeys.control("1"))
        XCTAssertNil(TmuxKeys.control("я"), "по одной кириллической букве клавиша не угадывается: нужен keyCode")
    }

    /// Нажатие таким, каким его отдаёт AppKit: на русской раскладке Ctrl+C приходит с «с», клавиша — та же.
    private func ctrl(_ chars: String, _ keyCode: UInt16) -> String? {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0, windowNumber: 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)
        return TmuxKeys.control(characters: e?.charactersIgnoringModifiers, keyCode: e?.keyCode ?? 0)
    }

    func testControlLetterOnRussianLayoutComesFromKeyCode() {
        XCTAssertEqual(ctrl("с", 8), "C-c", "Ctrl+C на русской раскладке")
        XCTAssertEqual(ctrl("к", 15), "C-r")
        XCTAssertEqual(ctrl("щ", 31), "C-o")
        XCTAssertEqual(ctrl("я", 6), "C-z")
        XCTAssertEqual(ctrl("c", 8), "C-c")
        XCTAssertEqual(ctrl("j", 8), "C-j", "латинская раскладка (Dvorak): буква раскладки, а не ANSI-клавиши")
        XCTAssertNil(ctrl("1", 18), "цифра с Ctrl не передаётся")
        XCTAssertNil(ctrl("ё", 50), "клавиша без латинской буквы")
        XCTAssertNil(ctrl(",", 46), "AZERTY: Ctrl+, не уходит как C-m (Enter)")
        XCTAssertNil(ctrl(";", 6), "Dvorak: Ctrl+; не уходит как C-z")
        XCTAssertNil(ctrl("", 8))
    }
}
