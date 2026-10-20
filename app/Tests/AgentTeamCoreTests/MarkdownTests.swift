import Foundation
import XCTest
@testable import AgentTeamCore

final class MarkdownTests: XCTestCase {
    func testTableWithAlignmentAndEscapedPipe() {
        let md = """
        | Шаг | Статус | Время |
        |:----|:------:|------:|
        | Сборка | готово | 12 с |
        | Проверка \\| линтер | `a \\| b` | 3 с |
        """
        XCTAssertEqual(MDParser.parse(md), [
            .table(MDTable(header: ["Шаг", "Статус", "Время"], alignments: [.left, .center, .right], rows: [
                ["Сборка", "готово", "12 с"],
                ["Проверка | линтер", "`a | b`", "3 с"],
            ])),
        ])
    }

    func testTableWithoutOuterPipesPadsAndTrimsRows() {
        let md = """
        Итог по веткам:
        Ветка | Коммитов | Ревью
        --- | --- | :---:
        main | 4
        feature | 2 | да | лишняя
        Дальше обычный текст.
        """
        XCTAssertEqual(MDParser.parse(md), [
            .paragraph("Итог по веткам:"),
            .table(MDTable(header: ["Ветка", "Коммитов", "Ревью"], alignments: [.none, .none, .center], rows: [
                ["main", "4", ""],
                ["feature", "2", "да"],
            ])),
            .paragraph("Дальше обычный текст."),
        ])
    }

    func testPipeWithoutDelimiterStaysParagraph() {
        let md = "| это не таблица |\n| и это тоже |"
        XCTAssertEqual(MDParser.parse(md), [.paragraph("| это не таблица |\n| и это тоже |")])
        // Разделитель с другим числом колонок — тоже не таблица, текст не теряется.
        XCTAssertEqual(MDParser.parse("a | b\n---|---|---"), [.paragraph("a | b\n---|---|---")])
    }

    func testNestedListsAndTasks() {
        let md = """
        - первый
          - вложенный
            - третий уровень
        - второй
        1. шаг
           - [x] сделано
           - [ ] не сделано
        2. шаг два
          продолжение без отступа маркера
        """
        XCTAssertEqual(MDParser.parse(md), [
            .list(ordered: false, items: [
                MDListItem(marker: "-", text: "первый", children: [
                    .list(ordered: false, items: [
                        MDListItem(marker: "-", text: "вложенный", children: [
                            .list(ordered: false, items: [MDListItem(marker: "-", text: "третий уровень")]),
                        ]),
                    ]),
                ]),
                MDListItem(marker: "-", text: "второй"),
            ]),
            .list(ordered: true, items: [
                MDListItem(marker: "1.", text: "шаг", children: [
                    .list(ordered: false, items: [
                        MDListItem(marker: "-", task: true, text: "сделано"),
                        MDListItem(marker: "-", task: false, text: "не сделано"),
                    ]),
                ]),
                MDListItem(marker: "2.", text: "шаг два\nпродолжение без отступа маркера"),
            ]),
        ])
    }

    func testListItemsSeparatedByBlankLinesStayOneList() {
        let md = "1. раз\n\n2. два\n\nабзац"
        XCTAssertEqual(MDParser.parse(md), [
            .list(ordered: true, items: [MDListItem(marker: "1.", text: "раз"), MDListItem(marker: "2.", text: "два")]),
            .paragraph("абзац"),
        ])
    }

    func testCodeKeepsIndentationAndLanguage() {
        let md = """
        ```swift
        func f() {
            if x {
                return
            }
        }
        ```
          ```
          отступ забора снят
            а свой сохранён
          ```
        """
        XCTAssertEqual(MDParser.parse(md), [
            .code(language: "swift", text: "func f() {\n    if x {\n        return\n    }\n}"),
            .code(language: nil, text: "отступ забора снят\n  а свой сохранён"),
        ])
    }

    func testUnclosedFenceRunsToEnd() {
        XCTAssertEqual(MDParser.parse("```sh\nls\n\n# не заголовок"), [.code(language: "sh", text: "ls\n\n# не заголовок")])
    }

    func testCodeInsideListItem() {
        let md = "1. Запустить:\n   ```sh\n   swift test\n   ```"
        XCTAssertEqual(MDParser.parse(md), [
            .list(ordered: true, items: [
                MDListItem(marker: "1.", text: "Запустить:", children: [.code(language: "sh", text: "swift test")]),
            ]),
        ])
    }

    func testMixedReply() {
        let md = """
        ## Итог

        **Что сделано.**
        Сборка прошла, *два* предупреждения.

        > Цитата из отчёта
        > во две строки

        ---
        ### Дальше
        * пункт
        #тег без пробела
        """
        XCTAssertEqual(MDParser.parse(md), [
            .heading(level: 2, text: "Итог"),
            .lead("Что сделано."),
            .paragraph("Сборка прошла, *два* предупреждения."),
            .quote([.paragraph("Цитата из отчёта\nво две строки")]),
            .rule,
            .heading(level: 3, text: "Дальше"),
            .list(ordered: false, items: [MDListItem(marker: "*", text: "пункт\n#тег без пробела")]),
        ])
        XCTAssertEqual(MDParser.parse("#тег"), [.paragraph("#тег")])
    }

    func testCachedMatchesParse() {
        let md = "# Заголовок\n\n- a\n- b"
        XCTAssertEqual(MDParser.cached(md), MDParser.parse(md))
        XCTAssertEqual(MDParser.cached(md), MDParser.parse(md))
    }

    func testInlineMarksAndLinks() {
        let a = MDInline.attributed("**жирный** *курсив* ~~зачёркнуто~~ `код` [ссылка](https://example.com/a)")
        XCTAssertEqual(String(a.characters), "жирный курсив зачёркнуто код ссылка")
        func intent(_ word: String) -> InlinePresentationIntent? {
            a.runs.first { String(a[$0.range].characters) == word }?.inlinePresentationIntent
        }
        XCTAssertEqual(intent("жирный"), .stronglyEmphasized)
        XCTAssertEqual(intent("курсив"), .emphasized)
        XCTAssertEqual(intent("зачёркнуто"), .strikethrough)
        XCTAssertEqual(intent("код"), .code)
        XCTAssertEqual(a.runs.first { String(a[$0.range].characters) == "ссылка" }?.link, URL(string: "https://example.com/a"))
    }

    func testBareUrlBecomesLinkButFileNamesAndCodeDoNot() {
        let a = MDInline.attributed("задача https://example.com/issue/1, файл AgentTeam.app и `https://x.example/raw`")
        let links = a.runs.compactMap { r in r.link.map { ($0, String(a[r.range].characters)) } }
        XCTAssertEqual(links.map(\.0), [URL(string: "https://example.com/issue/1")])
        XCTAssertEqual(links.map(\.1), ["https://example.com/issue/1"])
    }

    func testUnknownMarkupKeptAsText() {
        let s = "team spawn <роль> и **не закрыто"
        XCTAssertEqual(String(MDInline.attributed(s).characters), s)
    }
}
