import AgentTeamCore
import AppKit
import SwiftUI

/// Действие владельца, которое уходит в панель: порядок сохраняется, пока действия идут по одной очереди.
enum LiveAction {
    case text(String)
    case keys([String])
    case paste(String)
}

/// Очередь действий в панель: каждое ждёт предыдущее, иначе быстрый набор мог бы перемешаться.
@MainActor
final class LiveKeySender {
    private let hub: TmuxHub
    private let pane: String
    private var continuation: AsyncStream<LiveAction>.Continuation?

    init(hub: TmuxHub, pane: String) {
        self.hub = hub
        self.pane = pane
        let (stream, cont) = AsyncStream<LiveAction>.makeStream()
        continuation = cont
        Task { [hub, pane] in
            for await a in stream {
                switch a {
                case let .text(t): do { try await hub.sendLiteral(t, to: pane) } catch { NSLog("live-input: text failed: \(error)") }
                case let .keys(k): do { try await hub.sendKeys(k, to: pane) } catch { NSLog("live-input: keys failed: \(error)") }
                case let .paste(t): do { try await hub.pasteText(t, to: pane) } catch { NSLog("live-input: paste failed: \(error)") }
                }
            }
        }
    }

    func send(_ a: LiveAction) { continuation?.yield(a) }
    deinit { continuation?.finish() }
}

/// Нижняя часть панели менеджера, нарисованная вживую: нажатия идут в панель как есть.
final class LiveKeyNSView: NSView {
    var rows: [NSAttributedString] = []
    var cursor: (col: Int, row: Int)?
    var look = TerminalLook.current(grid: false)
    var onAction: (LiveAction) -> Void = { _ in }
    /// Можно ли отправить Esc: во время вопроса о праве или доверии он означал бы отказ, поэтому не уходит.
    var allowEscape: () -> Bool = { true }
    var charWidth: CGFloat = 7
    /// Ширина, по которой подогнан кегль (запоминается при раскладке).
    var lastWidth: CGFloat = 0
    /// Текст, который набирается через метод ввода и ещё не подтверждён (композиция).
    var markedText = ""

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(look.background).setFill()
        bounds.fill()
        let lh = look.lineHeight
        for (i, r) in rows.enumerated() {
            r.draw(with: NSRect(x: 12, y: 6 + CGFloat(i) * lh, width: bounds.width - 24, height: lh), options: [.usesLineFragmentOrigin])
        }
        if !markedText.isEmpty, let c = cursor {
            let font = FontCatalog.nsFont(family: look.family, size: look.size, weight: .regular)
            (markedText as NSString).draw(at: NSPoint(x: 12 + CGFloat(c.col) * charWidth, y: 6 + CGFloat(c.row) * lh), withAttributes: [
                .font: font, .foregroundColor: look.foreground, .backgroundColor: look.foreground.withAlphaComponent(0.18),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ])
        } else if let c = cursor, window?.firstResponder === self {
            look.foreground.withAlphaComponent(0.6).setFill()
            NSRect(x: 12 + CGFloat(c.col) * charWidth, y: 6 + CGFloat(c.row) * lh, width: charWidth, height: lh).fill()
        }
    }

    /// Брать ли фокус при появлении: только когда часть открыта действием владельца (включил строку Claude Code,
    /// отправил команду из поля). Экран команды, открытый очередью или из терминала, фокус не забирает: иначе набираемое
    /// владельцем ушло бы клавишами в экран. Щелчок по части фокус даёт всегда.
    var takesFocusOnAppear = true

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Строка ввода сразу принимает клавиши, как поле в терминале.
        guard takesFocusOnAppear else { return }
        DispatchQueue.main.async { [weak self] in if let self, let w = self.window { w.makeFirstResponder(self) } }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        if event.charactersIgnoringModifiers == "v" { paste(); return true }
        return false
    }

    /// ⌘V: картинка из буфера уходит как Ctrl+V (Claude Code читает картинку из буфера сам), текст — вставкой блоком.
    private func paste() {
        let pb = NSPasteboard.general
        if let s = pb.string(forType: .string), !s.isEmpty {
            onAction(.paste(s))
        } else if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            onAction(.keys(["C-v"]))
        }
    }

    override func keyDown(with event: NSEvent) {
        // Идёт композиция метода ввода: Enter, Esc и стрелки принадлежат ему, а не панели.
        if hasMarkedText() { interpretKeyEvents([event]); return }
        let f = event.modifierFlags
        var mods: KeyMods = []
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.control) { mods.insert(.control) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.command) {
            if event.keyCode == 51 { onAction(.keys(["C-u"])) }      // ⌘⌫ — стереть строку
            return
        }
        let special: SpecialKey? = switch event.keyCode {
        case 36, 76: .enter
        case 53: .escape
        case 48: .tab
        case 51: .backspace
        case 117: .deleteForward
        case 126: .up
        case 125: .down
        case 123: .left
        case 124: .right
        case 115: .home
        case 119: .end
        case 116: .pageUp
        case 121: .pageDown
        default: nil
        }
        if let special {
            if special == .escape, !allowEscape() { NSSound.beep(); return }
            if let keys = TmuxKeys.keys(special, mods) { onAction(.keys(keys)) }
            return
        }
        if mods.contains(.control), let k = TmuxKeys.control(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode) {
            onAction(.keys([k]))
            return
        }
        // Остальное — текст через систему ввода: раскладки, мёртвые клавиши, методы ввода с композицией.
        interpretKeyEvents([event])
    }
}

extension LiveKeyNSView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Функциональные клавиши приходят символами из частной области Unicode — это не текст.
        let printable = String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0xF700...0xF8FF).contains($0.value) && $0.value >= 0x20 }))
        if !printable.isEmpty { onAction(.text(printable)) }
        needsDisplay = true
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        needsDisplay = true
    }

    func unmarkText() { markedText = ""; needsDisplay = true }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length) }
    func hasMarkedText() -> Bool { !markedText.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    /// Где окно кандидатов: у курсора.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let lh = look.lineHeight
        let c = cursor ?? (0, 0)
        let local = NSRect(x: 12 + CGFloat(c.col) * charWidth, y: 6 + CGFloat(c.row + 1) * lh, width: charWidth, height: lh)
        guard let w = window else { return local }
        return w.convertToScreen(convert(local, to: nil))
    }

    override func doCommand(by selector: Selector) {}
}

struct LiveTerminal: NSViewRepresentable {
    var rows: [StyledLine]
    var cursor: (col: Int, row: Int)?
    var look: TerminalLook
    /// Ширина панели tmux в столбцах: размер шрифта подгоняется так, чтобы все столбцы влезли в ширину поля.
    /// Окно tmux не трогается: у владельца оно может быть открыто в настоящем терминале, и его размер менять нельзя.
    var columns: Int?
    var allowEscape: () -> Bool = { true }
    /// Брать ли фокус при появлении (`LiveKeyNSView.takesFocusOnAppear`).
    var takesFocus = true
    var onAction: (LiveAction) -> Void

    /// Вид с кеглем, при котором `columns` столбцов занимают `width`; не крупнее обычного и не мельче 8 pt.
    static func fitted(_ look: TerminalLook, columns: Int?, width: CGFloat) -> TerminalLook {
        guard let columns, columns > 0, width > 40 else { return look }
        let font = FontCatalog.nsFont(family: look.family, size: 100, weight: .regular)
        let ratio = ("M" as NSString).size(withAttributes: [.font: font]).width / 100
        var l = look
        l.size = max(8, min(look.size, (((width - 24) / (CGFloat(columns) * ratio)) * 2).rounded(.down) / 2))
        return l
    }

    func makeNSView(context: Context) -> LiveKeyNSView {
        let v = LiveKeyNSView()
        v.takesFocusOnAppear = takesFocus
        return v
    }

    func updateNSView(_ v: LiveKeyNSView, context: Context) {
        let l = Self.fitted(look, columns: columns, width: v.lastWidth)
        v.look = l
        v.rows = rows.map { TermNSRender.attributed([$0], look: l) }
        v.cursor = cursor
        v.onAction = onAction
        v.allowEscape = allowEscape
        let font = FontCatalog.nsFont(family: l.family, size: l.size, weight: .regular)
        v.charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
        v.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LiveKeyNSView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        if abs(nsView.lastWidth - width) > 0.5 { nsView.lastWidth = width }
        let l = Self.fitted(look, columns: columns, width: width)
        return CGSize(width: width, height: CGFloat(rows.count) * l.lineHeight + 12)
    }
}

/// Нижняя часть панели менеджера под лентой чата: строка ввода Claude Code, меню `/` и `@`, диалоги, строка режима,
/// экран встроенной команды (`/mcp`, `/config`… — целиком, клавиши идут в панель) и экран, которого приложение не знает
/// (его низ как есть).
struct LiveInputPanel: View {
    let hub: TmuxHub
    let pane: String
    /// Размер области чата: форма выше неё прокручивается, а не вытесняет ленту.
    var available: CGSize = CGSize(width: 600, height: 900)
    /// Открытый вопрос менеджера целиком по порядку источников (`ProjectModel.managerQuestions`): форма в панели
    /// показывается карточкой первого, который сходится с экраном.
    var questions: [PendingQuestion] = []
    /// Возврат к полю приложения; `nil` — значка нет (экран команды показан сам, при выключенной строке Claude Code:
    /// закрывает его Esc).
    var onFallback: (() -> Void)?
    /// Брать ли фокус при появлении: часть открыта действием владельца.
    var takesFocus = true
    @State private var sender: LiveKeySender?
    @MainActor private static var scriptStarted = false

    /// Значок возврата к полю приложения: на месте переключателя поля приложения (справа внизу, у стрелки «Отправить»).
    @ViewBuilder private func returnIcon(_ tint: Color) -> some View {
        if let onFallback {
            ComposerIconButton(symbol: "square.and.pencil", help: "Вернуться к полю приложения: черновик, очередь, картинки", tint: tint, action: onFallback)
                .padding(.trailing, 12).padding(.bottom, 12)
        }
    }

    /// Карточка вопроса: форма открыта, источник знает вопрос, и экран показывает его же (сверка по подписям пунктов).
    private func card(_ region: (rows: [StyledLine], offset: Int), formOpen: Bool) -> (PendingQuestion, Int, AskFormScreen)? {
        guard formOpen, !questions.isEmpty, let screen = AskFormScreen.read(region.rows.map(\.plain)),
              let (q, i) = screen.pick(questions) else { return nil }
        return (q, i, screen)
    }

    var body: some View {
        let out = hub.output(for: pane)
        let look = TerminalLook.current(grid: false)
        // Экран, которого приложение не знает (нет ни строки ввода, ни диалога, ни экрана команды), — его низ как есть:
        // владелец видит, что в панели, и отвечает клавишами.
        let region = LiveInput.region(out.lines) ?? LiveInput.tail(out.lines)
        let shown = region.flatMap { card($0, formOpen: out.askFormOpen) }
        VStack(alignment: .leading, spacing: 0) {
            if let (q, i, screen) = shown, let sender {
                AskQuestionCard(question: q, index: i, screen: screen, maxHeight: max(160, available.height * 0.66 - 70),
                                send: { sender.send($0) })
            } else if let region, let sender {
                // Источник вопроса молчит, а Claude Code срезал верх формы: вопроса на экране нет — об этом подпись.
                if out.askFormOpen, AskFormScreen.read(region.rows.map(\.plain))?.clipped == true {
                    Text("Верх формы не помещается в панель — вопрос появится целиком, как только будет записан")
                        .font(C.text(12)).foregroundStyle(C.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                // Живая часть занимает не больше двух третей области чата: лента остаётся видна. Экран команды — почти всю
                // область: он и есть то, что владелец сейчас читает.
                let fitted = LiveTerminal.fitted(look, columns: out.columns, width: available.width)
                let limit = Int((available.height * (out.commandScreen ? 0.9 : 0.66) - 12) / fitted.lineHeight)
                let r = LiveInput.fit(region.rows, limit: limit)
                // В форме выбора курсор tmux стоит на «❯» или в первой строке панели и закрывал бы выбор блоком; он нужен
                // только правее номера пункта, когда владелец пишет свой ответ в «Type something».
                let form = out.askFormOpen
                let cursor = out.cursor.flatMap { c -> (col: Int, row: Int)? in
                    guard let row = r.source.firstIndex(of: c.y - region.offset),
                          !form || (c.x > 4 && r.rows[row].plain.contains("❯")) else { return nil }
                    return (c.x, row)
                }
                LiveTerminal(rows: r.rows, cursor: cursor, look: look, columns: out.columns,
                             // Тот же признак вопроса о праве, что у поля приложения; форму вопроса владелец в строке отменяет сам.
                             allowEscape: { hub.paneState(pane).lineEscapeAllowed },
                             takesFocus: takesFocus,
                             onAction: { sender.send($0) })
            } else {
                Text("Экран панели Claude Code пуст").font(T.mono(11)).foregroundStyle(C.dim).padding(14)
            }
        }
        .background(shown == nil ? look.background : C.surface)
        // На фоне терминала значок красится его цветом текста, на карточке — токеном чата.
        .overlay(alignment: .bottomTrailing) { returnIcon(shown == nil ? Color(nsColor: look.foreground) : C.muted) }
        .overlay(alignment: .top) { Rectangle().fill(C.line).frame(height: 1) }
        .onAppear {
            hub.show(pane, detail: .live)
            if sender == nil { sender = LiveKeySender(hub: hub, pane: pane) }
        }
        .onDisappear { hub.hide(pane, detail: .live) }
        .task(id: sender == nil ? 0 : 1) { await runProbeScript() }
        .id(pane)
    }

    /// Для проверок и снимков: `AGENT_TEAM_LIVE_SCRIPT="text:/rewind,keys:Enter,wait:2,keys:Down|Enter"` проигрывает
    /// действия по той же очереди, что и нажатия владельца (после появления живой части). Клавиши `keys:` через «|».
    private func runProbeScript() async {
        guard let script = ProbeFlags.liveScript, let sender else { return }
        guard !Self.scriptStarted else { return }      // панель могла пересоздаться: скрипт идёт один раз
        Self.scriptStarted = true
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for step in script.split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "text": sender.send(.text(parts[1]))
            case "keys": sender.send(.keys(parts[1].split(separator: "|").map(String.init)))
            case "wait": try? await Task.sleep(nanoseconds: UInt64((Double(parts[1]) ?? 1) * 1_000_000_000))
            default: break
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
