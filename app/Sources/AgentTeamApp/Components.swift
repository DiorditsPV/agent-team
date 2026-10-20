import AgentTeamCore
import SwiftUI

/// Верхняя полоса раздела: высота 65.5, отступы 16×28, линия снизу.
struct ScreenHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(AppModel.self) private var app: AppModel?

    var body: some View {
        HStack(spacing: 14) {
            if let app { SidebarReveal(app: app) }
            HStack(spacing: 14) { leading }.fixedSize()
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing }.fixedSize()
        }
        .padding(.horizontal, 28)
        .frame(height: 65.5)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

/// Скрытая боковая панель: отступ под кнопки окна и кнопка «показать панель». У открытой панели — пусто.
struct SidebarReveal: View {
    @Bindable var app: AppModel

    var body: some View {
        if app.sidebarCollapsed {
            HStack(spacing: 6) {
                Color.clear.frame(width: 62, height: 1)      // кнопки окна лежат поверх левого края
                SidebarToggleButton(app: app)
            }
        }
    }
}

struct SidebarToggleButton: View {
    @Bindable var app: AppModel

    var body: some View {
        Button { app.sidebarCollapsed.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(T.muted).frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.sidebarCollapsed ? "Показать боковую панель  ⌘\\" : "Скрыть боковую панель  ⌘\\")
    }
}

/// Заголовок раздела крупным шрифтом Unbounded и подзаголовок.
struct ScreenTitle: View {
    var title: String
    var subtitle: String? = nil
    var tag: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(T.title(20)).kerning(-0.3).foregroundStyle(T.ink).lineLimit(1)
            if let tag {
                Text(tag).font(T.mono(11)).foregroundStyle(T.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4).background(T.surface, ignoresSafeAreaEdges: [])
            }
            if let subtitle { Text(subtitle).font(T.text(14)).foregroundStyle(T.muted).lineLimit(1) }
        }
    }
}

/// Панель с рамкой и необязательной шапкой-подписью капсом.
struct Panel<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    var fill: Color = .clear
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack {
                    SectionLabel(text: title)
                    Spacer()
                    if let trailing { Text(trailing).font(T.mono(11)).foregroundStyle(T.dim) }
                }
                .padding(.horizontal, 18).frame(height: 54)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            }
            content
        }
        .background(fill, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }
}

/// Пустое состояние: короткая причина и что сделать.
struct EmptyState: View {
    var title: String
    var detail: String? = nil
    var icon: String = "tray"
    var action: EmptyAction? = nil
    /// В области агента (лента «Диалога») — цвета темы терминала.
    var agentArea = false

    struct EmptyAction {
        var title: String
        var icon: String
        var busy = false
        var run: () -> Void
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(agentArea ? A.faint : T.faint)
            Text(title).font(agentArea ? A.text(14, .medium) : T.text(14, .medium)).foregroundStyle(agentArea ? A.muted : T.muted)
            if let detail {
                Text(detail).font(agentArea ? A.text(13) : T.text(13)).foregroundStyle(agentArea ? A.dim : T.dim).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            if let action {
                Button(action: action.run) {
                    HStack(spacing: 8) {
                        if action.busy { ProgressView().controlSize(.small) } else { Image(systemName: action.icon) }
                        Text(action.title)
                    }
                }
                .buttonStyle(AppButtonStyle(kind: .primary))
                .disabled(action.busy)
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// Сноска с иконкой (информация, предупреждение).
struct Note: View {
    var text: String
    var icon: String = "info.circle"
    var color: Color = T.muted
    var fill: Color = .clear

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color)
            Text(text).font(T.text(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(fill, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(color == T.muted ? T.line : color.opacity(0.4), lineWidth: 1))
    }
}

/// Строка «ключ — значение» инспектора.
struct KeyValueRow: View {
    var key: String
    var value: String
    var valueColor: Color = T.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).font(T.text(13)).foregroundStyle(T.muted).frame(width: 110, alignment: .leading)
            Text(value).font(T.mono(12)).foregroundStyle(valueColor).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Сообщение о результате действия внизу окна.
struct ActionToast: View {
    @Bindable var project: ProjectModel

    var body: some View {
        if let msg = project.lastActionMessage {
            HStack(spacing: 10) {
                Text(msg).font(T.mono(12)).foregroundStyle(T.ink).lineLimit(2)
                Button { project.clearMessage() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(T.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(T.surface, ignoresSafeAreaEdges: [])
            .overlay(Rectangle().stroke(T.line, lineWidth: 1))
            .padding(16)
            .task(id: msg) {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if project.lastActionMessage == msg { project.clearMessage() }
            }
        }
    }
}

/// Разделитель на месте сводки сжатия контекста: «контекст сжат · чч:мм».
struct CompactDivider: View {
    var time: Date?

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(T.line).frame(height: 1)
            Text("контекст сжат" + (time.map { " · " + clock($0) } ?? "")).font(T.mono(11)).foregroundStyle(T.dim).fixedSize()
            Rectangle().fill(T.line).frame(height: 1)
        }
    }
}
