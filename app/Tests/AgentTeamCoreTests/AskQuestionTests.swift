import XCTest
@testable import AgentTeamCore

/// Вопрос менеджера целиком: вход `AskUserQuestion` из транскрипта и из `team status`, форма на экране панели и клавиши.
///
/// Экраны сняты с живого claude 2.1.295 на временном сокете tmux, панель 50×25: форма с длинными пояснениями выше
/// панели, Claude Code рисует только её низ (вкладки, вопрос и строка «1.» срезаны). Транскрипт — записи вызовов
/// и ответов той же сессии: 1) один вопрос с четырьмя вариантами, 2–3) короткие, 4) два вопроса, 5) множественный выбор,
/// 6) два вопроса, первый с длинными пояснениями (форма выше панели).
final class AskQuestionTests: XCTestCase {
    private func screen(_ name: String) throws -> AskFormScreen {
        let lines = SGRParser.parse(String(decoding: try fixture("live-askcard-\(name).txt"), as: UTF8.self))
        let region = try XCTUnwrap(LiveInput.region(lines), name)
        return try XCTUnwrap(AskFormScreen.read(region.rows.map(\.plain)), name)
    }

    private func transcriptLines() throws -> [Substring] {
        String(decoding: try fixture("ask-transcript.jsonl"), as: UTF8.self).split(separator: "\n")
    }

    /// Вопрос из записи транскрипта с номером `k` (0 — первая запись).
    private func question(_ k: Int) throws -> PendingQuestion {
        var p = TranscriptParser()
        p.feed(lines: [try transcriptLines()[k]])
        return try XCTUnwrap(p.openQuestion)
    }

    // MARK: Источник: транскрипт

    func testTranscriptKeepsTheUnansweredQuestionWhole() throws {
        let lines = try transcriptLines()
        var p = TranscriptParser()
        p.feed(lines: [lines[0]])
        let q = try XCTUnwrap(p.openQuestion)
        XCTAssertEqual(q.id, "toolu_018ydmUqMuZuh99JPJ97CQET")
        XCTAssertEqual(q.questions.count, 1)
        let first = q.questions[0]
        XCTAssertEqual(first.header, "Защита")
        XCTAssertTrue(first.text.hasPrefix("Агентам запрещено менять конфиги на серверах."))
        XCTAssertFalse(first.multiSelect)
        XCTAssertEqual(first.options.map(\.label), ["Узкое правило для ops (Recommended)", "Запускаю скрипты сам", "Подтверждаю в панели ops", "Отложить"])
        XCTAssertTrue(first.options.allSatisfy { $0.detail.count > 60 }, "пояснения целиком")
        // Результат с тем же id снимает вопрос.
        p.feed(lines: [lines[1]])
        XCTAssertNil(p.openQuestion)
    }

    func testTranscriptReadsTabsAndMultiSelect() throws {
        let tabs = try question(6)
        XCTAssertEqual(tabs.questions.map(\.header), ["Сервер", "Срок"])
        XCTAssertEqual(tabs.questions.map(\.options.count), [3, 2])
        XCTAssertEqual(try question(8).questions.first?.multiSelect, true)
    }

    func testTurnEndDropsAStaleQuestion() throws {
        var p = TranscriptParser()
        p.feed(lines: [try transcriptLines()[0]])
        XCTAssertNotNil(p.openQuestion)
        p.feed(lines: [#"{"type":"user","uuid":"u9","timestamp":"2026-10-18T12:50:00.000Z","message":{"role":"user","content":"[Request interrupted by user]"}}"#])
        XCTAssertNil(p.openQuestion)
    }

    // MARK: Источник: team status

    func testStatusQuestionDecodesLeniently() throws {
        let json = #"""
        {"name": "manager#1", "role": "manager", "alive": true,
         "question": {"id": "toolu_1", "ts": 1792327819, "extra": {"a": 1},
           "questions": [
             {"question": "Как довести защиту?", "header": "Защита", "multiSelect": false,
              "options": [{"label": "Узкое правило", "description": "Пояснение", "preview": "rule: x"},
                          {"label": "Отложить"}, {"label": 5}, "битый"]},
             {"header": "без вопроса", "options": [{"label": "a"}]},
             {"question": "Второй?", "options": [{"label": "Да"}, {"label": "Нет", "description": null}]}
           ]}}
        """#
        let a = try JSONDecoder().decode(Agent.self, from: Data(json.utf8))
        let q = try XCTUnwrap(a.question)
        XCTAssertEqual(q.id, "toolu_1")
        XCTAssertEqual(q.ts, 1792327819)
        XCTAssertEqual(q.questions.map(\.text), ["Как довести защиту?", "Второй?"], "вопрос без текста выпадает")
        XCTAssertEqual(q.questions[0].options.map(\.label), ["Узкое правило", "Отложить", "5"], "число — текстом, строка вместо объекта выпадает")
        XCTAssertEqual(q.questions[0].options[0].detail, "Пояснение")
        XCTAssertEqual(q.questions[0].options[0].preview, "rule: x")
        XCTAssertNil(q.questions[0].options[1].preview)
        XCTAssertEqual(q.questions[1].header, "")
        XCTAssertFalse(q.questions[1].multiSelect)

        for value in ["null", #""вопрос""#, #"{"id": "x", "questions": []}"#] {
            let b = try JSONDecoder().decode(Agent.self, from: Data(#"{"name": "manager#1", "alive": true, "question": \#(value)}"#.utf8))
            XCTAssertNil(b.question, value)
        }
        // Старый CLI: поля нет.
        XCTAssertNil(try JSONDecoder().decode(Agent.self, from: Data(#"{"name": "manager#1"}"#.utf8)).question)
    }

    @MainActor
    func testSourcesGoInOrderStatusThenTranscript() throws {
        final class Fake: OpenQuestionSource { var openQuestion: PendingQuestion?; init(_ q: PendingQuestion?) { openQuestion = q } }
        let fromStatus = PendingQuestion(id: "s", questions: [.init(header: "", text: "из status?", options: [.init(label: "a"), .init(label: "b")])])
        let fromTranscript = try question(0)
        var agent = Agent(name: "manager#1", role: "manager")
        agent.question = fromStatus
        XCTAssertEqual(PendingQuestion.all(of: [StatusQuestionSource(agent: agent), Fake(fromTranscript)]), [fromStatus, fromTranscript])
        agent.question = nil
        XCTAssertEqual(PendingQuestion.all(of: [StatusQuestionSource(agent: agent), Fake(fromTranscript)]), [fromTranscript])
        agent.question = fromStatus
        agent.alive = false
        XCTAssertEqual(PendingQuestion.all(of: [StatusQuestionSource(agent: agent), Fake(nil)]), [], "у неживого агента вопроса нет")
    }

    func testStaleStatusQuestionGivesWayToTheOneOnScreen() throws {
        // Владелец ответил на вопрос, менеджер сразу задал следующий: в кеше status ещё прежний, в транскрипте — новый.
        let s = try screen("narrow-sel3")
        let stale = try question(2), current = try question(0)
        let picked = try XCTUnwrap(s.pick([stale, current]))
        XCTAssertEqual(picked.question, current)
        XCTAssertEqual(picked.index, 0)
        XCTAssertEqual(s.pick([current, stale])?.question, current, "при совпадении — первый по порядку")
        XCTAssertNil(s.pick([stale]))
    }

    // MARK: Экран формы

    func testClippedFormWithHiddenCursorMatchesTheWholeQuestion() throws {
        let s = try screen("narrow-sel1")
        XCTAssertTrue(s.clipped, "вкладок и вопроса на экране нет")
        XCTAssertNil(s.cursor)
        XCTAssertEqual(s.items.map(\.number), [2, 3, 4, 5, 6])
        XCTAssertEqual(s.optionCount, 4)
        let q = try question(0)
        XCTAssertEqual(s.questionIndex(in: q), 0)
        XCTAssertEqual(s.cursorKind(options: 4), .hidden)
        // Срезанный курсор стоит на варианте: цифра работает сразу.
        XCTAssertEqual(AskKeys.choose(1, cursor: .hidden), ["1"])
    }

    func testCursorOnAVisibleOption() throws {
        let s = try screen("narrow-sel3")
        XCTAssertEqual(s.cursor, 3)
        XCTAssertEqual(s.cursorKind(options: 4), .option(3))
        XCTAssertEqual(s.questionIndex(in: try question(0)), 0)
        XCTAssertEqual(AskKeys.choose(1, cursor: .option(3)), ["1"])
        XCTAssertEqual(AskKeys.choose(6, cursor: .option(3)), ["6"], "цифра «Chat about this» с варианта")
    }

    func testCursorOnTheLastItemLeavesItBeforeTheDigit() throws {
        let s = try screen("narrow-sel6")
        XCTAssertEqual(s.cursorKind(options: 4), .chat)
        XCTAssertEqual(s.questionIndex(in: try question(0)), 0)
        // На «Chat about this» цифру Claude Code не принимает: ↑ на «Type something», ↑ на вариант 4.
        XCTAssertEqual(AskKeys.choose(2, cursor: .chat), ["Up", "Up", "2"])
        XCTAssertEqual(AskKeys.ownAnswer(options: 4, cursor: .chat), ["Up", "Up", "5"])
    }

    func testTypedOwnAnswerKeepsDigitsOutOfTheField() throws {
        let s = try screen("typed")              // «Какая форма?»: два варианта, в поле набрано «1 овал»
        XCTAssertEqual(s.cursorKind(options: 2), .typeSomething)
        XCTAssertEqual(s.items.first { $0.number == 3 }?.text, "1 овал")
        XCTAssertEqual(s.questionIndex(in: try question(4)), 0)
        XCTAssertEqual(AskKeys.choose(1, cursor: .typeSomething), ["Up", "1"], "цифра в поле ушла бы текстом")
        XCTAssertEqual(AskKeys.ownAnswer(options: 2, cursor: .typeSomething), [], "курсор уже в поле")
    }

    func testTabsShowWhichQuestionIsOpen() throws {
        let q = try question(6)
        let first = try screen("tabs-q1"), second = try screen("tabs-q2")
        XCTAssertFalse(first.clipped)
        XCTAssertEqual(first.questionIndex(in: q), 0)
        XCTAssertEqual(second.questionIndex(in: q), 1, "цифра выбрала вариант и открыла следующую вкладку")
        XCTAssertEqual(AskKeys.tab(-1, cursor: .option(1)), ["Left"])
        XCTAssertEqual(AskKeys.tab(1, cursor: .typeSomething), ["Up", "Right"])
    }

    func testClippedTabsFormFindsItsQuestionWithoutTabsOnScreen() throws {
        // Подсказка формы из нескольких вопросов в узкой панели разорвана посреди «Esc to cancel»: часть всё равно находится.
        let s = try screen("tabs-clipped")
        XCTAssertTrue(s.clipped)
        XCTAssertNil(s.cursor)
        let q = try question(10)
        XCTAssertEqual(q.questions.map(\.header), ["Защита", "Срок"])
        XCTAssertEqual(s.questionIndex(in: q), 0)
        // Проверено на стенде: «→» открывает вкладку «Срок», «←» возвращает, «3» при срезанном курсоре выбирает пункт 3.
        XCTAssertEqual(AskKeys.tab(1, cursor: s.cursorKind(options: 4)), ["Right"])
        XCTAssertEqual(AskKeys.choose(3, cursor: s.cursorKind(options: 4)), ["3"])
    }

    func testMultiSelectMarksComeFromTheScreen() throws {
        let s = try screen("multiselect")
        XCTAssertEqual(s.questionIndex(in: try question(8)), 0)
        XCTAssertEqual(s.items.filter { $0.number <= 3 }.map(\.checked), [false, true, false])
        XCTAssertEqual(s.items.first { $0.number == 2 }?.text, "EU")
    }

    func testReviewScreenAndOtherQuestionsDoNotMatch() throws {
        let review = try screen("review")
        XCTAssertTrue(review.review)
        XCTAssertFalse(review.clipped, "на экране проверки подписи о срезанном верхе нет")
        // Экран проверки умещается в панель и показывается живой частью: ответы, «Submit answers», «Cancel».
        let region = try XCTUnwrap(LiveInput.region(SGRParser.parse(String(decoding: try fixture("live-askcard-review.txt"), as: UTF8.self))))
        let rows = region.rows.map { $0.plain.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(rows.contains("Review your answers"), "\(rows)")
        XCTAssertTrue(rows.contains { $0.hasSuffix("1. Submit answers") })
        XCTAssertTrue(rows.contains("2. Cancel"))
        XCTAssertNil(review.questionIndex(in: try question(8)))
        // Экран длинного вопроса с источником другого вопроса не сходится: карточка не показывает чужое.
        XCTAssertNil(try screen("narrow-sel3").questionIndex(in: try question(2)))
        XCTAssertNil(try screen("tabs-q1").questionIndex(in: try question(0)))
    }
}
