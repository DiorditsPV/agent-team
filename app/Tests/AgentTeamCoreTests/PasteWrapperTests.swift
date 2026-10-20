import XCTest
@testable import AgentTeamCore

/// Сообщения владельца в транскрипте менеджера: обёртка `pasted_content`, очередь с картинкой списком блоков.
/// Образцы — по настоящим записям транскрипта менеджера (прочитаны только на чтение), текст обезличен.
final class PasteWrapperTests: XCTestCase {
    private let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="

    /// Запись `attachment/queued_command`: prompt — список блоков; в тексте обрывок закрывающего тега с косой чертой.
    private var queued: Substring {
        Substring(#"{"type":"attachment","uuid":"q1","timestamp":"2026-10-17T11:05:00.000Z","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"[Image #12] <\/pasted_content id=\"d147\">\nТакже я вижу, что в сообщениях появляются блоки."},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(png)"}}],"imagePasteIds":[12],"commandMode":"prompt","origin":{"kind":"human"}}}"#)
    }

    func testQueuedCommandWithImageIsParsedWithoutWrapper() throws {
        var p = TranscriptParser()
        p.feed(lines: [queued])
        let e = try XCTUnwrap(p.entries.last)
        XCTAssertEqual(e.kind, .owner("Также я вижу, что в сообщениях появляются блоки."))
        XCTAssertEqual(e.images.count, 1)
    }

    func testWrapperTagsAreRemovedFromUserText() throws {
        var p = TranscriptParser()
        let text = "\\n\\n<pasted_content id=\\\"d147\\\">\\nПервая строка\\nвторая\\n</pasted_content id=\\\"d147\\\">\\n"
        p.feed(lines: [Substring(#"{"type":"user","uuid":"u1","message":{"role":"user","content":"\#(text)"}}"#)])
        XCTAssertEqual(p.entries.last?.kind, .owner("Первая строка\nвторая"))
    }

    /// Ошибка прежней версии: сообщение с картинкой висело «в очереди», хотя менеджер его уже получил.
    @MainActor
    func testPendingWithImageIsClearedByQueuedRecordEvenIfTextChanged() throws {
        var p = TranscriptParser()
        p.feed(lines: [queued])
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-paste", session: "team-paste", cli: nil)
        m.addPending(text: "Также я вижу то, что в сообщениях регулярно появляются вот такие вот блоки.",
                     images: [URL(fileURLWithPath: "/tmp/a.png")])
        m.reconcilePending(against: p.entries)
        XCTAssertTrue(m.pending.isEmpty, "по порядку: первая новая запись владельца с тем же числом картинок")
    }

    /// Текстовое совпадение важнее порядка: чужая запись раньше не забирает отметку у сообщения, которое совпало по тексту.
    @MainActor
    func testTextMatchBeatsOrder() {
        let m = ProjectModel(repo: NSTemporaryDirectory() + "agtest-paste", session: "team-paste", cli: nil)
        m.addPending(text: "второе сообщение", images: [])
        let typed = ChatEntry(id: "t", time: nil, kind: .owner("напечатано в терминале"))
        let mine = ChatEntry(id: "m", time: nil, kind: .owner("второе сообщение"))
        m.reconcilePending(against: [typed, mine])
        XCTAssertTrue(m.pending.isEmpty)
    }

    func testNormalizeIgnoresMarkersAndWrappers() {
        let a = PendingMessage.normalize("[Image #3] <\\/pasted_content id=\"x\">\nтекст  сообщения")
        XCTAssertEqual(a, "текст сообщения")
        XCTAssertEqual(PendingMessage.normalize("<pasted_content id=\"d\">текст</pasted_content id=\"d\">"), "текст")
    }
}
