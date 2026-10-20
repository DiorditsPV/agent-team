import XCTest
@testable import AgentTeamCore

/// Ответ менеджера с экрана панели: образцы обезличены, строки держат ширину панели и отступ в два пробела.
final class LiveReplyTests: XCTestCase {
    private func screen(_ body: String) -> [StyledLine] {
        SGRParser.parse(body + """

        ✻ Stewing… (14s · ↓ 1.2k tokens · esc to interrupt)
        ────────────────────────────
        ❯\u{a0}
        ────────────────────────────
          [Opus] high ctx 32% · main
          ⏵⏵ auto mode on (shift+tab to cycle)
        """)
    }

    func testWrappedParagraphsAreJoinedAndListsKept() throws {
        let r = try XCTUnwrap(LiveReply.extract(screen("""
        ⏺ Первый абзац ответа переносится по ширине панели
          и продолжается на второй строке.

          Второй абзац.
          - пункт один
          - пункт два
        """)))
        XCTAssertEqual(r.text, "Первый абзац ответа переносится по ширине панели и продолжается на второй строке.\n\nВторой абзац.\n- пункт один\n- пункт два")
        XCTAssertFalse(r.startCut)
    }

    func testTextAfterToolCallIsTheDraft() throws {
        let r = try XCTUnwrap(LiveReply.extract(screen("""
        ⏺ Read(src/dates.py)
          ⎿  Read 10 lines (ctrl+o to expand)

        ⏺ Разбор дат вынесен в модуль, тесты
          проходят.
        """)))
        XCTAssertEqual(r.text, "Разбор дат вынесен в модуль, тесты проходят.")
    }

    /// Вызов инструмента после текста — текст уже записан в транскрипт, черновика нет.
    func testToolCallAfterTextMeansNoDraft() {
        XCTAssertNil(LiveReply.extract(screen("""
        ⏺ Сейчас посмотрю файл.

        ⏺ Read(src/dates.py)
          ⎿  Read 10 lines
        """)))
    }

    func testUserEchoAndPermissionAreNotDrafts() {
        XCTAssertNil(LiveReply.extract(screen("⏺ Ответ\n\n❯ вопрос владельца")))
        XCTAssertNil(LiveReply.extract(screen("⏺ Хочу запустить\n  Do you want to proceed?\n  ❯ 1. Yes\n    2. No")))
    }

    /// Ответ длиннее экрана: начало прокручено, остался хвост без «⏺».
    func testLongReplyScrolledPastTopKeepsTail() throws {
        let rows = (1...30).map { "  строка \($0) длинного ответа" }.joined(separator: "\n")
        let r = try XCTUnwrap(LiveReply.extract(screen(rows)))
        XCTAssertTrue(r.startCut)
        XCTAssertTrue(r.text.hasSuffix("строка 30 длинного ответа"))
        XCTAssertNil(LiveReply.extract(screen("  вывод\n  инструмента")), "короткий хвост без границ — не ответ")
    }

    func testDraftHiddenWhenBlockAlreadyInTranscriptOrIdle() throws {
        let lines = screen("⏺ **Итог:** тесты проходят,\n  ветка готова к слиянию.")
        let reply = ChatEntry(id: "r1", time: nil, kind: .reply("**Итог:** тесты проходят, ветка готова к слиянию."))
        XCTAssertNotNil(LiveReply.draft(lines: lines, chat: [], busy: true))
        XCTAssertNil(LiveReply.draft(lines: lines, chat: [reply], busy: true), "блок уже в ленте")
        XCTAssertNil(LiveReply.draft(lines: lines, chat: [], busy: false), "менеджер не в ходе")
    }
}

final class LiveReplyMergeTests: XCTestCase {
    func testScrolledTailIsAppendedToAccumulatedText() {
        let full = LiveReply(text: "Начало ответа про замер.\n\nВторой абзац, который ещё влезал на экран.", startCut: false)
        let tail = LiveReply(text: "Второй абзац, который ещё влезал на экран.\n\nТретий абзац появился позже.", startCut: true)
        let m = LiveReply.merged(previous: full, new: tail)
        XCTAssertEqual(m?.text, "Начало ответа про замер.\n\nВторой абзац, который ещё влезал на экран.\n\nТретий абзац появился позже.")
        XCTAssertEqual(m?.startCut, false)
    }

    func testNoOverlapOrFreshBlockTakesNewText() {
        let prev = LiveReply(text: "Старый текст целиком.", startCut: false)
        XCTAssertEqual(LiveReply.merged(previous: prev, new: LiveReply(text: "Совсем другой хвост", startCut: true))?.text, "Совсем другой хвост")
        let fresh = LiveReply(text: "Новый блок", startCut: false)
        XCTAssertEqual(LiveReply.merged(previous: prev, new: fresh), fresh)
        XCTAssertNil(LiveReply.merged(previous: prev, new: nil))
    }

    func testRepeatedTailKeepsLength() {
        let full = LiveReply(text: "Абзац один.\n\nАбзац два, достаточно длинный для сравнения по началу.", startCut: false)
        let tail = LiveReply(text: "Абзац два, достаточно длинный для сравнения по началу.", startCut: true)
        XCTAssertEqual(LiveReply.merged(previous: full, new: tail)?.text, full.text)
    }
}

/// Смена черновика блоком транскрипта: черновик, стёртый с экрана, стоит до прихода блока в ту же ленту.
final class LiveReplyShownTests: XCTestCase {
    private let draft = LiveReply(text: "Итог: тесты проходят, ветка готова к слиянию.", startCut: false)
    private let block = ChatEntry(id: "r1", time: nil, kind: .reply("**Итог:** тесты проходят, ветка готова к слиянию."))
    private let other = ChatEntry(id: "r0", time: nil, kind: .reply("Прошлый ответ про другое."))

    func testScreenClearedBeforeBlockArrivedKeepsDraft() {
        XCTAssertEqual(LiveReply.shown(screen: nil, held: draft, feed: [other]), draft, "экран стёрт, блока в ленте нет — черновик стоит")
    }

    func testBlockInFeedReplacesDraftInSameFrame() {
        XCTAssertNil(LiveReply.shown(screen: nil, held: draft, feed: [other, block]), "блок пришёл — черновик снят")
        XCTAssertNil(LiveReply.shown(screen: draft, held: nil, feed: [other, block]), "блок в ленте, экран ещё показывает текст — без двойного")
    }

    func testScreenTakesPrecedenceOverHeld() {
        let next = LiveReply(text: "Следующий блок ответа, уже другой текст.", startCut: false)
        XCTAssertEqual(LiveReply.shown(screen: next, held: draft, feed: []), next)
        XCTAssertNil(LiveReply.shown(screen: nil, held: nil, feed: [block]))
    }
}
