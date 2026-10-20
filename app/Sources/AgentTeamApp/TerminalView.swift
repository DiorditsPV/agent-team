import AgentTeamCore
import AppKit
import Observation
import SwiftUI

/// Как рисуется терминал: шрифт, размер, высота строки и палитра темы. Сравнимо: смена любого поля
/// перерисовывает уже открытые панели из имеющихся строк, без нового захвата.
struct TerminalLook: Equatable {
    var family: String
    var size: CGFloat
    var lineFactor: CGFloat
    var palette: TermPalette

    /// Высота строки: по умолчанию около 1,15 кегля, как в терминале. Естественная высота моноширинных
    /// шрифтов больше (у JetBrains Mono — 1,32), поэтому строка задаётся жёстко, без добавочного интервала.
    var lineHeight: CGFloat { round(size * lineFactor) }
    var foreground: NSColor { NSColor(Color(hex: palette.foreground)) }
    var background: Color { Color(hex: palette.background) }

    /// По текущим настройкам; в сетке «Команды» кегль на пункт меньше, чем на экране агента.
    @MainActor
    static func current(grid: Bool) -> TerminalLook {
        let d = DisplayModel.shared
        let t = d.settings.terminal
        return TerminalLook(family: t.family, size: CGFloat(grid ? max(9, t.size - 1) : t.size),
                            lineFactor: CGFloat(t.spacing), palette: d.palette)
    }
}

/// Строки панели в NSAttributedString для AppKit-отрисовки.
enum TermNSRender {
    /// `truncate` — строка не переносится, а обрезается многоточием (панели «Команды»).
    static func paragraph(_ look: TerminalLook, truncate: Bool = false) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = look.lineHeight
        para.maximumLineHeight = look.lineHeight
        para.lineBreakMode = truncate ? .byTruncatingTail : .byCharWrapping
        return para
    }

    static func attributed(_ lines: [StyledLine], look: TerminalLook, truncate: Bool = false) -> NSAttributedString {
        let para = paragraph(look, truncate: truncate)
        let regular = FontCatalog.nsFont(family: look.family, size: look.size, weight: .regular)
        let bold = FontCatalog.nsFont(family: look.family, size: look.size, weight: .bold)
        let base = look.foreground
        let out = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: regular, .paragraphStyle: para])) }
            for run in l.runs {
                var fg = run.style.fg.map { nsColor($0, look, asText: !run.style.inverse) } ?? base
                if run.style.dim { fg = fg.withAlphaComponent(0.6) }
                var attrs: [NSAttributedString.Key: Any] = [.font: run.style.bold ? bold : regular, .paragraphStyle: para]
                if run.style.inverse {
                    attrs[.foregroundColor] = NSColor(Color(hex: look.palette.background))
                    attrs[.backgroundColor] = fg
                } else {
                    attrs[.foregroundColor] = fg
                    if let bg = run.style.bg { attrs[.backgroundColor] = nsColor(bg, look).withAlphaComponent(run.style.soft ? 0.2 : 0.45) }
                }
                if run.style.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                out.append(NSAttributedString(string: run.text, attributes: attrs))
            }
        }
        return out
    }

    /// Палитра ANSI темы берётся как есть; RGB-цвета самой программы (Claude Code) доводятся до контраста 4,5:1
    /// к фону темы с сохранением оттенка: на светлой теме голубой и оранжевый иначе сливаются с белым.
    static func nsColor(_ c: TermColor, _ look: TerminalLook, asText: Bool = false) -> NSColor {
        var rgb = look.palette.rgb(c)
        if asText, case .rgb = c { rgb = Contrast.ensure(rgb, on: look.palette.background) }
        return NSColor(Color(hex: rgb))
    }
}

/// Панель в сетке: дайджест вывода (что агент делает сейчас и последние строки его текста) в AppKit-виде.
/// Строки не переносятся, а обрезаются многоточием. Новый захват только перерисовывает вид и не запускает
/// раскладку SwiftUI — по профилю именно она была главной нагрузкой.
final class TerminalTailNSView: NSView {
    private var output: PaneOutput?
    private var rows: [NSAttributedString] = []
    private var hasHeadline = false
    private var maxLines = 5
    private var look = TerminalLook.current(grid: true)
    private var roster = TeamRoster()
    private var observing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true      // с macOS 14 вид по умолчанию рисует и за своими границами
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    @MainActor
    func configure(output: PaneOutput, maxLines: Int, look: TerminalLook, roster: TeamRoster) {
        let changed = output !== self.output || maxLines != self.maxLines || look != self.look || roster != self.roster
        self.output = output
        self.maxLines = maxLines
        self.look = look
        self.roster = roster
        if changed { refresh() }
        if !observing { observe() }
    }

    @MainActor
    private func observe() {
        guard let output else { return }
        observing = true
        withObservationTracking {
            _ = output.lines
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.window != nil else { self?.observing = false; return }
                    self.refresh()
                    self.observe()
                }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !observing {
            MainActor.assumeIsolated {
                refresh()
                observe()
            }
        }
    }

    @MainActor
    private func refresh() {
        guard let output else { return }
        let digest = PaneDigest.make(output.lines, bodyLines: maxLines, roster: roster)
        hasHeadline = digest.headline != nil
        rows = digest.rows.map { TermNSRender.attributed([$0], look: look, truncate: true) }
        needsDisplay = true
    }

    /// Зазор между заголовком («что делает сейчас») и текстом под ним.
    private let headGap: CGFloat = 4

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }
        let lh = look.lineHeight
        let gap = hasHeadline && rows.count > 1 ? headGap : 0
        let capacity = max(1, Int((bounds.height - gap) / lh))
        // Заголовок виден всегда; из текста остаются последние строки, которые влезли.
        let shown = hasHeadline ? [rows[0]] + rows.dropFirst().suffix(max(0, capacity - 1)) : Array(rows.suffix(capacity))
        for (i, row) in shown.enumerated() {
            let y = CGFloat(i) * lh + (hasHeadline && i > 0 ? gap : 0)
            row.draw(with: NSRect(x: 0, y: y, width: bounds.width, height: lh),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}

struct TerminalTail: NSViewRepresentable {
    let output: PaneOutput
    var maxLines = 5
    var look: TerminalLook
    var roster = TeamRoster()

    func makeNSView(context: Context) -> TerminalTailNSView { TerminalTailNSView() }

    func updateNSView(_ v: TerminalTailNSView, context: Context) {
        v.configure(output: output, maxLines: maxLines, look: look, roster: roster)
    }

    // Размер задаёт родитель: содержимое не влияет на раскладку.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalTailNSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 300, height: proposal.height ?? 200)
    }
}

/// Полный вывод на экране агента: NSTextView в прокрутке; пока пользователь внизу — держится на последней строке.
struct TerminalScroll: NSViewRepresentable {
    let output: PaneOutput
    var look: TerminalLook
    var roster = TeamRoster()

    @MainActor
    final class Coordinator {
        var observing = false
        var dismantled = false
        weak var textView: NSTextView?
        weak var scroll: NSScrollView?
        var output: PaneOutput?
        var look = TerminalLook.current(grid: false)
        var roster = TeamRoster()

        @MainActor
        func refresh(force: Bool = false) {
            guard let output, let tv = textView, let scroll else { return }
            let clip = scroll.contentView
            let docHeight = tv.frame.height
            let atBottom = clip.bounds.maxY >= docHeight - 24
            if !force, tv.selectedRange().length > 0 { return }      // не сбивать выделение
            let s = TermNSRender.attributed(TeamMessages.decorate(PaneTail.content(output.lines), roster: roster), look: look)
            tv.textStorage?.setAttributedString(s)
            if atBottom { tv.scrollToEndOfDocument(nil) }
        }

        @MainActor
        func observe() {
            guard let output else { return }
            observing = true
            withObservationTracking {
                _ = output.lines
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Наблюдение живёт, пока вид не разобран: первый захват может прийти раньше, чем вид попал в окно.
                        guard let self, !self.dismantled else { return }
                        self.refresh()
                        self.observe()
                    }
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ v: NSScrollView, coordinator: Coordinator) { coordinator.dismantled = true }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.isAutomaticLinkDetectionEnabled = false
        context.coordinator.textView = tv
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ v: NSScrollView, context: Context) {
        let c = context.coordinator
        let changed = c.output !== output
        let restyled = c.look != look || c.roster != roster
        c.output = output
        c.look = look
        c.roster = roster
        if changed || !c.observing {
            c.refresh()
            (c.textView)?.scrollToEndOfDocument(nil)
            c.observe()
        } else if restyled {
            c.refresh(force: true)      // смена шрифта или темы — из имеющихся строк, без нового захвата
        }
    }
}
