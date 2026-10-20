import AppKit
import XCTest
@testable import AgentTeamCore

/// Незавершённый набор в поле ввода: Option+e ставит «´» отмеченным текстом, и до следующей буквы он не в привязке.
/// Обновление поля из привязки (в ходе менеджера — несколько раз в секунду) не должно его стирать.
@MainActor
final class ComposerMarkedTextTests: XCTestCase {
    private func field(_ text: String) -> ComposerTextView {
        let tv = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        tv.isRichText = false
        tv.string = text
        tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return tv
    }

    func testDeadKeyCompositionSurvivesSyncAndCommitsIntoText() {
        let tv = field("caf")
        tv.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tv.hasMarkedText())
        XCTAssertFalse(tv.syncText("caf"), "привязка ещё без «´»: поле занято набором и не перезаписывается")
        XCTAssertEqual(tv.string, "caf´")
        XCTAssertTrue(tv.hasMarkedText(), "набор не сброшен")
        XCTAssertEqual(tv.selectedRange().location, 4, "курсор остался в наборе")

        tv.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))   // вторая клавиша мёртвого «´»
        XCTAssertFalse(tv.hasMarkedText())
        XCTAssertEqual(tv.string, "café")
        XCTAssertTrue(tv.syncText("café"))
        XCTAssertEqual(tv.string, "café")
    }

    func testWithoutCompositionSyncReplacesText() {
        let tv = field("черновик")
        XCTAssertTrue(tv.syncText(""), "очистка после отправки")
        XCTAssertEqual(tv.string, "")
        XCTAssertTrue(tv.syncText("другой проект"))
        XCTAssertEqual(tv.string, "другой проект")
    }
}
