import AgentTeamCore
import SwiftUI

/// Палитры под макетом окна: по колонке на окно, чат менеджера и агентов. Выбор применяется сразу и меняет свою зону
/// макета; «Сбросить» в колонке возвращает только цвет, шрифты сбрасываются в блоках текста.
struct PaletteColumns: View {
    var display: DisplayModel

    var body: some View {
        // Три равные колонки на всю ширину: под каждой зоной макета — своя палитра, имена тем не обрезаются.
        HStack(alignment: .top, spacing: 20) {
            windowColumn.frame(maxWidth: .infinity)
            chatColumn.frame(maxWidth: .infinity)
            agentsColumn.frame(maxWidth: .infinity)
        }
    }

    private var windowColumn: some View {
        let current = display.windowThemeChoice
        func pick(_ id: String) -> () -> Void { { display.selectWindowTheme(id) } }
        return column("Окно", reset: display.resetWindowColors) {
            row("Оформление приложения", .appearance, selected: current == WindowThemeChoice.app, action: pick(WindowThemeChoice.app))
            group("Тёмные", TermPalettes.dark) { p in row(p.name, .from(p), selected: current == p.id, action: pick(p.id)) }
            group("Светлые", TermPalettes.light) { p in row(p.name, .from(p), selected: current == p.id, action: pick(p.id)) }
        }
    }

    private var chatColumn: some View {
        let current = display.chatThemeChoice
        func pick(_ id: String) -> () -> Void { { display.selectChatTheme(id) } }
        return column("Чат менеджера", reset: display.resetChatColors) {
            row("Как окно", display.windowTheme, selected: current == ChatThemeChoice.window, action: pick(ChatThemeChoice.window))
            row("Оформление приложения", .appearance, selected: current == WindowThemeChoice.app, action: pick(WindowThemeChoice.app))
            group("Тёмные", TermPalettes.dark) { p in row(p.name, .from(p), selected: current == p.id, action: pick(p.id)) }
            group("Светлые", TermPalettes.light) { p in row(p.name, .from(p), selected: current == p.id, action: pick(p.id)) }
        }
    }

    private var agentsColumn: some View {
        let current = display.palette.id
        return column("Агенты и терминал", reset: display.resetAgentColors) {
            group("Тёмные", TermPalettes.dark) { p in terminalRow(p, selected: current == p.id) }
            group("Светлые", TermPalettes.light) { p in terminalRow(p, selected: current == p.id) }
        }
    }

    // MARK: части

    private func column<Content: View>(_ title: String, reset: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Button("Сбросить", action: reset).buttonStyle(AppButtonStyle(kind: .quiet))
            }
            content()
        }
    }

    private func group<Row: View>(_ title: String, _ palettes: [TermPalette], @ViewBuilder row: @escaping (TermPalette) -> Row) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(T.mono(11)).foregroundStyle(T.dim).padding(.top, 8)
            ForEach(palettes) { p in row(p) }
        }
    }

    /// Строка темы окна или чата: фон, текст и цвета статусов темы.
    private func row(_ name: String, _ t: WindowTheme, selected: Bool, action: @escaping () -> Void) -> some View {
        tile(name, background: t.bg, ink: t.ink, colors: [t.accent, t.cyan, t.violet, t.periwinkle, t.rose, t.amber],
             selected: selected, action: action)
    }

    /// Строка темы терминала: фон, текст и шесть цветов ANSI.
    private func terminalRow(_ p: TermPalette, selected: Bool) -> some View {
        tile(p.name, background: p.background, ink: p.foreground, colors: (1...6).map { p.ansi[$0] }, selected: selected) {
            display.selectTheme(p.id)
        }
    }

    private func tile(_ name: String, background: UInt32, ink: UInt32, colors: [UInt32], selected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(name).font(T.text(12, .medium)).foregroundStyle(Color(hex: ink)).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    ForEach(Array(colors.enumerated()), id: \.offset) { _, c in
                        Rectangle().fill(Color(hex: c)).frame(width: 9, height: 10)
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: background), ignoresSafeAreaEdges: [])
            .overlay(Rectangle().stroke(selected ? T.accent : T.line, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
