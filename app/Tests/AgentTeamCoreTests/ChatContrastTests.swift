import XCTest
@testable import AgentTeamCore

/// Контраст текста во всех темах: чат менеджера (все темы чата поверх всех тем окна), область агента (все темы
/// терминала) и окно. Пара «цвет на фоне» перечислена по элементам, как их красят экраны; порог 4,5:1 для основного
/// текста, 3:1 для служебного (приглушённые подписи, метки состояния).
final class ChatContrastTests: XCTestCase {
    struct Pair { var element: String; var fg: (WindowTheme) -> UInt32; var bg: (WindowTheme) -> UInt32; var min: Double }

    /// Подложка, смешанная с акцентом: выбранная строка списка подсказок.
    private func accentRow(_ t: WindowTheme) -> UInt32 { t.rowHighlight }
    /// Живой черновик ответа красится основным цветом чата без прозрачности: отметку «пишет…» несёт метка.
    private func draftInk(_ t: WindowTheme) -> UInt32 { t.ink }

    private var chatPairs: [Pair] {
        [
            Pair(element: "поле ввода: текст", fg: { $0.ink }, bg: { $0.surface }, min: 4.5),
            Pair(element: "поле ввода: заглушка", fg: { $0.dim }, bg: { $0.surface }, min: 3),
            Pair(element: "поле ввода: значок строки Claude Code", fg: { $0.muted }, bg: { $0.surface }, min: 3),
            Pair(element: "поле ввода: значок «Стоп»", fg: { $0.ink }, bg: { $0.surface }, min: 3),
            Pair(element: "поле ввода: рамка значка", fg: { $0.line }, bg: { $0.surface }, min: 1.1),
            Pair(element: "поле ввода: курсор", fg: { $0.accent }, bg: { $0.surface }, min: 3),
            Pair(element: "поле ввода: выделенный текст", fg: { $0.selectionText }, bg: { $0.selection }, min: 4.5),
            Pair(element: "лента: текст", fg: { $0.ink }, bg: { $0.bg }, min: 4.5),
            Pair(element: "лента: код", fg: { $0.ink }, bg: { $0.well }, min: 4.5),
            Pair(element: "лента: ссылка accent", fg: { $0.accent }, bg: { $0.bg }, min: 4.5),
            Pair(element: "лента: ссылка periwinkle", fg: { $0.periwinkle }, bg: { $0.bg }, min: 4.5),
            Pair(element: "лента: цитата", fg: { $0.muted }, bg: { $0.bg }, min: 4.5),
            Pair(element: "лента: таблица", fg: { $0.ink }, bg: { $0.surface }, min: 4.5),
            Pair(element: "лента: таблица, подпись", fg: { $0.muted }, bg: { $0.surface }, min: 4.5),
            Pair(element: "карточка владельца: текст", fg: { $0.ink }, bg: { $0.surface }, min: 4.5),
            Pair(element: "карточка владельца: время", fg: { $0.dim }, bg: { $0.surface }, min: 3),
            Pair(element: "карточка команды: адреса", fg: { $0.cyan }, bg: { $0.bg }, min: 4.5),
            Pair(element: "карточка команды: текст", fg: { $0.muted }, bg: { $0.bg }, min: 4.5),
            Pair(element: "строки инструментов", fg: { $0.muted }, bg: { $0.bg }, min: 4.5),
            Pair(element: "строки инструментов: цитата SendMessage", fg: { $0.dim }, bg: { $0.bg }, min: 3),
            Pair(element: "строка хода", fg: { $0.muted }, bg: { $0.bg }, min: 4.5),
            Pair(element: "строка хода: Стоп", fg: { $0.ink }, bg: { $0.bg }, min: 4.5),
            Pair(element: "пишет…: метка", fg: { $0.amber }, bg: { $0.bg }, min: 3),
            Pair(element: "пишет…: текст черновика", fg: { self.draftInk($0) }, bg: { $0.bg }, min: 4.5),
            Pair(element: "очередь: «в очереди»", fg: { $0.amber }, bg: { $0.surface }, min: 3),
            Pair(element: "очередь: «остановлено» и «не дошло»", fg: { $0.rose }, bg: { $0.surface }, min: 3),
            Pair(element: "очередь: ↑ сейчас", fg: { $0.accent }, bg: { $0.surface }, min: 4.5),
            Pair(element: "очередь: ✎ ×", fg: { $0.muted }, bg: { $0.surface }, min: 4.5),
            Pair(element: "уведомление «ждёт ответа»: текст", fg: { $0.ink }, bg: { $0.surface }, min: 4.5),
            Pair(element: "уведомление «ждёт ответа»: основная кнопка", fg: { $0.accent }, bg: { $0.surface }, min: 4.5),
            Pair(element: "уведомление «ждёт ответа»: вторая кнопка", fg: { $0.muted }, bg: { $0.surface }, min: 4.5),
            Pair(element: "уведомление «ждёт ответа»: значок", fg: { $0.amber }, bg: { $0.surface }, min: 3),
            Pair(element: "вопрос менеджера в ленте", fg: { $0.muted }, bg: { $0.bg }, min: 4.5),
            Pair(element: "закреплённая запись: текст", fg: { $0.ink }, bg: { $0.pinBackground }, min: 4.5),
            Pair(element: "закреплённая запись: цитата", fg: { $0.muted }, bg: { $0.pinBackground }, min: 4.5),
            Pair(element: "закреплённая запись: ссылка", fg: { $0.accent }, bg: { $0.pinBackground }, min: 3),
            Pair(element: "закреплённая запись: ссылка periwinkle", fg: { $0.periwinkle }, bg: { $0.pinBackground }, min: 3),
            Pair(element: "закреплённая запись: подпись", fg: { $0.dim }, bg: { $0.pinBackground }, min: 3),
            Pair(element: "значок «Закрепить»", fg: { $0.muted }, bg: { $0.bg }, min: 3),
            Pair(element: "значок «Открепить»", fg: { $0.accent }, bg: { $0.bg }, min: 3),
            Pair(element: "меню /: пункт", fg: { $0.ink }, bg: { $0.surface }, min: 4.5),
            Pair(element: "меню /: выбранный пункт", fg: { $0.ink }, bg: { self.accentRow($0) }, min: 4.5),
            Pair(element: "меню /: метка выбранного пункта", fg: { $0.accent }, bg: { self.accentRow($0) }, min: 3),
            Pair(element: "меню /: описание", fg: { $0.dim }, bg: { $0.surface }, min: 3),
        ]
    }

    private var windowThemes: [(String, WindowTheme)] {
        [("appearance", WindowTheme.appearance)] + TermPalettes.all.map { ($0.name, WindowTheme.from($0)) }
    }

    private var chatChoices: [String] { [ChatThemeChoice.window] + TermPalettes.all.map(\.id) }

    /// Чат: любая тема чата поверх любой темы окна; чат красится только своими токенами.
    func testChatElementsReadableInEveryThemeCombination() {
        var failures: [String] = []
        for (windowName, window) in windowThemes {
            for choice in chatChoices {
                let t = ChatThemeChoice.theme(choice: choice, window: window)
                for p in chatPairs {
                    let c = TermPalette.contrast(p.fg(t), p.bg(t))
                    if c < p.min { failures.append("окно «\(windowName)», чат «\(choice)»: \(p.element) \(String(format: "%.2f", c)) < \(p.min)") }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) нарушений, первые:\n" + failures.prefix(25).joined(separator: "\n"))
    }

    /// Область агента: тема терминала; карточки, строки инструментов, строка хода, заголовки.
    func testAgentAreaReadableInEveryTerminalTheme() {
        var failures: [String] = []
        let ids = TermPalettes.all.map(\.id) + [TermPalettes.defaultID]
        for id in ids {
            let t = AgentAreaTheme.theme(terminalThemeID: id)
            for p in chatPairs where !p.element.hasPrefix("поле ввода") && !p.element.hasPrefix("очередь") && !p.element.hasPrefix("меню") {
                let c = TermPalette.contrast(p.fg(t), p.bg(t))
                if c < p.min { failures.append("терминал «\(id)»: \(p.element) \(String(format: "%.2f", c)) < \(p.min)") }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) нарушений, первые:\n" + failures.prefix(25).joined(separator: "\n"))
    }

    /// Подложка закреплённой записи заметна хотя бы в большинстве тем (в слабых остаётся метка слева).
    func testPinBackgroundIsVisibleInMostThemes() {
        let themes = windowThemes
        let tinted = themes.filter { TermPalette.contrast($0.1.pinBackground, $0.1.bg) >= 1.04 }
        XCTAssertGreaterThanOrEqual(tinted.count * 4, themes.count * 3, "без подложки: \(themes.filter { !tinted.map(\.0).contains($0.0) }.map(\.0))")
    }

    /// Выделение текста читается и отличается от фона поля.
    func testSelectionIsVisibleAgainstSurface() {
        for (name, w) in windowThemes {
            XCTAssertGreaterThanOrEqual(TermPalette.contrast(w.selection, w.surface), 1.3, "\(name): выделение сливается с полем")
        }
    }

    /// Файлы чата красятся токенами чата `C`, а не окна `T`: на тёмном окне со светлой темой чата текст в поле
    /// иначе получался цветом окна (светлым) на светлой подложке.
    func testChatSourcesUseChatTokensNotWindowTokens() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = root.appendingPathComponent("Sources/AgentTeamApp")
        let files = ["ChatPanel.swift", "ComposerField.swift"]
        let pattern = try NSRegularExpression(pattern: #"\bT\.(ink|muted|dim|faint|accent|onAccent|bg|side|surface|well|line|amber|amberBg|rose|cyan|violet|periwinkle|accentBg)\b"#)
        for f in files {
            let text = try String(contentsOf: app.appendingPathComponent(f), encoding: .utf8)
            let hits = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
            XCTAssertTrue(hits.isEmpty, "\(f) красит токенами окна: \(hits)")
        }
    }
}
