import AgentTeamCore
import SwiftUI

/// Цвета строки хода: чат берёт токены чата, «Диалог» агента — токены области агента.
struct TurnStatusColors {
    var ink: Color, muted: Color, dim: Color, accent: Color, line: Color

    static var chat: TurnStatusColors { .init(ink: C.ink, muted: C.muted, dim: C.dim, accent: C.accent, line: C.line) }
    static var agent: TurnStatusColors { .init(ink: A.ink, muted: A.muted, dim: A.dim, accent: A.accent, line: A.line) }
}

/// Что делает агент сейчас: глагол спиннера, время хода и токены — из панели tmux. Панель подписывается, пока
/// строка на экране. «Стоп» — значок в поле ввода (ComposerStopButton).
struct TurnStatusRow: View {
    let hub: TmuxHub
    let pane: String
    var colors: TurnStatusColors
    /// Строка сама подписывает панель (панели агентов). Чат менеджера подписывает панель сам по правилу «в ходе или ждёт
    /// ответа»: подписка строки держала бы панель менеджера и в простое.
    var subscribes = true

    var body: some View {
        let out = hub.output(for: pane)
        Group {
            if let s = out.turn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini).tint(colors.accent)
                    Text(label(s)).font(T.mono(11)).foregroundStyle(colors.muted).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                }
            }
        }
        .onAppear { if subscribes { hub.show(pane, detail: .grid) } }
        .onDisappear { if subscribes { hub.hide(pane, detail: .grid) } }
        .id(pane)
    }

    private func label(_ s: TurnStatus) -> String {
        var parts = [s.verb + "…", s.elapsedText]
        if let t = s.tokens { parts.append("\(s.arrow ?? "↓") \(t) ток.") }
        if let n = s.note { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}
