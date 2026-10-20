import AgentTeamCore
import AppKit
import SwiftUI

/// Цвета Markdown: окно или чат менеджера. Чат красится темой чата, остальные экраны (передачи, инструкция) — темой окна.
struct MDTokens: Equatable {
    var ink, muted, dim, line, surface, well, accent, cyan, periwinkle: Color
    /// Для кеша стилей: разные темы дают разные атрибуты.
    var key: String

    init(_ t: WindowTheme) {
        ink = Color(hex: t.ink); muted = Color(hex: t.muted); dim = Color(hex: t.dim); line = Color(hex: t.line)
        surface = Color(hex: t.surface); well = Color(hex: t.well); accent = Color(hex: t.accent)
        cyan = Color(hex: t.cyan); periwinkle = Color(hex: t.periwinkle)
        key = [t.ink, t.muted, t.surface, t.cyan, t.periwinkle].map { String($0, radix: 16) }.joined(separator: ".")
    }

    static var window: MDTokens { MDTokens(ThemeStore.shared.theme) }
    static var chat: MDTokens { MDTokens(ChatThemeStore.shared.theme) }
    static var agent: MDTokens { MDTokens(AgentAreaStore.shared.theme) }
}

private struct MDTokensKey: EnvironmentKey { static let defaultValue = MDTokens(.appearance) }

extension EnvironmentValues {
    fileprivate var mdTokens: MDTokens {
        get { self[MDTokensKey.self] }
        set { self[MDTokensKey.self] = newValue }
    }
}

/// Ответ модели так, как его показывает терминал Claude Code: заголовки, списки с вложенностью и отметками,
/// цитаты, черта, код с подписью языка, таблицы в рамке. Разбор блоков — `MDParser` с кешем по тексту.
enum MDArea {
    case window, chat, agent
    var tokens: MDTokens { self == .chat ? .chat : self == .agent ? .agent : .window }
}

struct MarkdownView: View {
    var text: String
    /// Без размера — как в настройках чата.
    var size: CGFloat?
    var color: Color?
    /// Где показан текст: чат менеджера — тема чата, область агента — тема терминала, остальное — тема окна.
    var area: MDArea = .window

    var body: some View {
        let tok = area.tokens
        // Выделение работает внутри блока; весь ответ с таблицами и кодом копируется исходным Markdown.
        MDBlocksView(blocks: MDParser.cached(text), size: size ?? ChatFont.size, color: color ?? tok.ink)
            .environment(\.mdTokens, tok)
            .contextMenu {
                Button("Скопировать ответ") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
    }
}

struct MDBlocksView: View {
    var blocks: [MDBlock]
    var size: CGFloat
    var color: Color
    var spacing: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: spacing ?? ChatFont.gap(12)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                MDBlockView(block: b, size: size, color: color)
            }
        }
    }
}

struct MDBlockView: View {
    @Environment(\.mdTokens) private var tok
    var block: MDBlock
    var size: CGFloat
    var color: Color

    var body: some View {
        switch block {
        case let .heading(level, s):
            Text(MDStyle.inline(s, size: headingSize(level), weight: .semibold, tok: tok))
                .font(ChatFont.text(headingSize(level), .semibold)).foregroundStyle(level > 3 ? tok.muted : color)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.top, ChatFont.gap(level <= 2 ? 6 : 2))
        case let .lead(s):
            Text(MDStyle.inline(s, size: size, weight: .semibold, tok: tok)).font(ChatFont.text(size, .semibold)).foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.bottom, -ChatFont.gap(8))
        case let .paragraph(s):
            paragraph(s)
        case let .list(ordered, items):
            MDListView(ordered: ordered, items: items, size: size, color: color)
        case let .quote(inner):
            MDBlocksView(blocks: inner, size: size, color: tok.muted, spacing: ChatFont.gap(8))
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Rectangle().fill(tok.line).frame(width: 2) }
        case .rule:
            Rectangle().fill(tok.line).frame(height: 1).frame(maxWidth: .infinity)
        case let .code(language, s):
            MDCodeView(language: language, text: s)
        case let .table(t):
            MDTableView(table: t, size: size, color: color)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return size + 5
        case 2: return size + 3
        case 3: return size + 1
        default: return size
        }
    }

    private func paragraph(_ s: String) -> some View {
        Text(MDStyle.inline(s, size: size, tok: tok)).font(ChatFont.text(size)).foregroundStyle(color).lineSpacing(ChatFont.spacing)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

struct MDListView: View {
    @Environment(\.mdTokens) private var tok
    var ordered: Bool
    var items: [MDListItem]
    var size: CGFloat
    var color: Color

    var body: some View {
        // Номера одной ширины: «9.» и «10.» выравниваются по тексту пункта.
        let markerWidth = ordered ? CGFloat(items.map(\.marker.count).max() ?? 2) * size * 0.62 : size * 0.9
        VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(it).frame(minWidth: markerWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: ChatFont.gap(6)) {
                        if !it.text.isEmpty {
                            Text(MDStyle.inline(it.text, size: size, tok: tok)).font(ChatFont.text(size))
                                .foregroundStyle(it.task == true ? tok.muted : color).lineSpacing(ChatFont.spacing)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                        if !it.children.isEmpty {
                            MDBlocksView(blocks: it.children, size: size, color: color, spacing: ChatFont.gap(6))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ it: MDListItem) -> some View {
        if let done = it.task {
            Image(systemName: done ? "checkmark.square.fill" : "square")
                .font(.system(size: size - 2)).foregroundStyle(done ? tok.accent : tok.dim)
        } else {
            Text(ordered ? it.marker : "—").font(ChatFont.text(size)).foregroundStyle(tok.muted)
        }
    }
}

/// Код: моноширинный, строки не переносятся — длинная прокручивается вбок; язык подписан над кодом.
struct MDCodeView: View {
    @Environment(\.mdTokens) private var tok
    var language: String?
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language).font(T.mono(11)).foregroundStyle(tok.dim)
                    .padding(.horizontal, 12).padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(T.mono(12)).foregroundStyle(tok.ink).lineSpacing(4)
                    .fixedSize().textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tok.well)
        .overlay(Rectangle().stroke(tok.line, lineWidth: 1))
    }
}

/// Таблица в рамке: шапка на подложке, колонки по выравниванию разделителя. Шире чата — прокручивается
/// вбок внутри своей рамки; длинная ячейка переносится по словам в пределах колонки.
struct MDTableView: View {
    @Environment(\.mdTokens) private var tok
    var table: MDTable
    var size: CGFloat
    var color: Color

    @State private var viewWidth: CGFloat = 0
    @State private var contentMaxX: CGFloat = 0

    var body: some View {
        let cols = table.header.count
        let all = [table.header] + table.rows
        // Правый край гаснет, пока за ним есть колонки: срезанная таблица не выглядит законченной.
        let more = contentMaxX > viewWidth + 1
        ScrollView(.horizontal) {
            MDTableLayout(columns: cols, maxColumn: size * 26) {
                ForEach(Array(all.enumerated()), id: \.offset) { r, row in
                    ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                        self.cell(cell, header: r == 0, align: table.alignments[c], lastColumn: c == cols - 1, lastRow: r == all.count - 1)
                    }
                }
            }
            .overlay(Rectangle().stroke(tok.line, lineWidth: 1))
            .padding(1)
            .background(GeometryReader { g in
                Color.clear.onChange(of: g.frame(in: .named("mdtable")).maxX, initial: true) { _, x in contentMaxX = x }
            })
        }
        .coordinateSpace(name: "mdtable")
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(GeometryReader { g in
            Color.clear.onChange(of: g.size.width, initial: true) { _, w in viewWidth = w }
        })
        .mask {
            HStack(spacing: 0) {
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(more ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 56)
            }
        }
    }

    private func cell(_ s: String, header: Bool, align: MDAlignment, lastColumn: Bool, lastRow: Bool) -> some View {
        let a: Alignment = align == .center ? .top : align == .right ? .topTrailing : .topLeading
        let ta: TextAlignment = align == .center ? .center : align == .right ? .trailing : .leading
        return Text(MDStyle.inline(s, size: size - 1, weight: header ? .semibold : .regular, tok: tok))
            .font(ChatFont.text(size - 1, header ? .semibold : .regular)).foregroundStyle(color)
            .multilineTextAlignment(ta).lineSpacing(3)
            .textSelection(.enabled)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: a)
            .background(header ? tok.surface : Color.clear)
            .overlay(alignment: .trailing) { if !lastColumn { Rectangle().fill(tok.line).frame(width: 1) } }
            .overlay(alignment: .bottom) { if !lastRow { Rectangle().fill(tok.line).frame(height: 1) } }
    }
}

/// Сетка таблицы: ширина колонки — по самой широкой ячейке, но не больше `maxColumn`; высота строки —
/// по самой высокой ячейке при этой ширине. `Grid` в горизонтальной прокрутке переносить текст не умеет.
struct MDTableLayout: Layout {
    var columns: Int
    var maxColumn: CGFloat

    struct Metrics {
        var widths: [CGFloat]
        var heights: [CGFloat]
    }

    func makeCache(subviews: Subviews) -> Metrics? { nil }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) -> CGSize {
        let m = metrics(subviews, &cache)
        return CGSize(width: m.widths.reduce(0, +), height: m.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Metrics?) {
        let m = metrics(subviews, &cache)
        var y = bounds.minY
        for r in m.heights.indices {
            var x = bounds.minX
            for c in 0..<columns {
                let i = r * columns + c
                guard i < subviews.count else { break }
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: m.widths[c], height: m.heights[r]))
                x += m.widths[c]
            }
            y += m.heights[r]
        }
    }

    func updateCache(_ cache: inout Metrics?, subviews: Subviews) { cache = nil }

    private func metrics(_ subviews: Subviews, _ cache: inout Metrics?) -> Metrics {
        if let cache { return cache }
        guard columns > 0 else { return Metrics(widths: [], heights: []) }
        let rows = (subviews.count + columns - 1) / columns
        var widths = Array(repeating: CGFloat(0), count: columns)
        for (i, s) in subviews.enumerated() {
            widths[i % columns] = max(widths[i % columns], min(ceil(s.sizeThatFits(.unspecified).width), maxColumn))
        }
        var heights = Array(repeating: CGFloat(0), count: rows)
        for (i, s) in subviews.enumerated() {
            let h = s.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height
            heights[i / columns] = max(heights[i / columns], ceil(h))
        }
        let m = Metrics(widths: widths, heights: heights)
        cache = m
        return m
    }
}

/// Инлайн-разметка в атрибуты темы: код — моноширинным на подложке, ссылки — цветом с подчёркиванием.
/// Готовые строки кешируются: лента перерисовывается при каждом событии транскрипта.
@MainActor
enum MDStyle {
    nonisolated(unsafe) private static let cache: NSCache<NSString, Box> = {
        let c = NSCache<NSString, Box>()
        c.countLimit = 4000
        return c
    }()

    private final class Box {
        let value: AttributedString
        init(_ v: AttributedString) { value = v }
    }

    static func inline(_ s: String, size: CGFloat, weight: Font.Weight = .regular, tok: MDTokens) -> AttributedString {
        let family = ChatFont.look.family
        let key = "\(family)|\(size)|\(weight)|\(tok.key)|\(s)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        var a = MDInline.attributed(s)
        for run in a.runs {
            let intent = run.inlinePresentationIntent ?? []
            var c = AttributeContainer()
            let bold = intent.contains(.stronglyEmphasized) || weight == .semibold
            if intent.contains(.code) {
                c.font = T.mono(size - 1.5)
                c.foregroundColor = tok.periwinkle
                c.backgroundColor = tok.surface
            } else if intent.contains(.emphasized) {
                c.font = italic(family, size, bold ? .semibold : weight)
            } else if intent.contains(.stronglyEmphasized) {
                c.font = ChatFont.text(size, .semibold)
            }
            if intent.contains(.strikethrough) {
                c.strikethroughStyle = .single
                c.foregroundColor = tok.muted
            }
            if run.link != nil {
                c.foregroundColor = tok.cyan
                c.underlineStyle = .single
            }
            a[run.range].mergeAttributes(c)
            a[run.range].inlinePresentationIntent = nil
        }
        cache.setObject(Box(a), forKey: key)
        return a
    }

    /// Курсивного начертания у Onest нет — наклон задаётся матрицей шрифта (в ней же кегль).
    private static func italic(_ family: String, _ size: CGFloat, _ weight: Font.Weight) -> Font {
        let base = FontCatalog.nsFont(family: family, size: size, weight: weight)
        let skew = AffineTransform(m11: size, m12: 0, m21: size * 0.2, m22: size, tX: 0, tY: 0)
        let slanted = NSFont(descriptor: base.fontDescriptor.withMatrix(skew), size: 0) ?? base
        return Font(slanted)
    }
}

/// Длинный Markdown-документ (инструкция роли) в прокручиваемой подложке.
struct MarkdownDocument: View {
    var text: String
    var size: CGFloat = 13

    var body: some View {
        ScrollView {
            MarkdownView(text: text, size: size)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
        }
        .background(T.well, ignoresSafeAreaEdges: [])
    }
}
