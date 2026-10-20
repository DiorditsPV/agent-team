import AgentTeamCore
import SwiftUI

/// Раздел «Передачи»: состояние ролей между сессиями. Список слева (строки одной высоты), карточка справа.
struct HandoffsScreen: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    @State private var selectedID: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                ScreenTitle(title: "Передачи", subtitle: "состояние ролей между сессиями")
            } trailing: {
                EmptyView()
            }
            if project.handoffs.isEmpty {
                EmptyState(title: "Передач пока нет",
                           detail: "Передача — файл, в который агент записывает сделанное, проверенное и следующие шаги перед сменой сессии. Её запрашивают «Передать» в меню агента или командой team handoff <агент>. Новая сессия (team restart <агент> --fresh) начинается с передачи, и та отмечается использованной.",
                           icon: "arrow.left.arrow.right")
            } else {
                HStack(spacing: 0) {
                    list
                    if let h = selected { HandoffsDetail(app: app, project: project, handoff: h).id(h.id) }
                }
            }
        }
    }

    private var selected: Handoff? { project.handoffs.first { $0.id == selectedID } ?? project.handoffs.first }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(project.handoffs) { h in row(h) }
            }
        }
        .scrollIndicators(.never)
        .frame(width: 400)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
    }

    private func row(_ h: Handoff) -> some View {
        let role = String(h.agent.split(separator: "#").first ?? "")
        let color = roleColor(role, in: project)
        let isSel = h.id == selected?.id
        return Button { selectedID = h.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Swatch(color: color)
                    Text(ProjectModel.pretty(h.agent)).font(T.mono(13)).foregroundStyle(color).lineLimit(1)
                    Text(ShortTime.label(h.ts)).font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(h.isWaiting ? "ждёт запуска" : "использована" + (h.usedAt.map { " " + ShortTime.label($0) } ?? "")).font(T.mono(11))
                        .foregroundStyle(h.isWaiting ? T.amber : T.muted).lineLimit(1)
                }
                Text(HandoffsText.title(h)).font(T.text(14)).foregroundStyle(h.task == nil ? T.dim : T.ink).lineLimit(1)
                Text(h.reason.flatMap { $0.isEmpty ? nil : $0 } ?? "причина не указана").font(T.text(12))
                    .foregroundStyle(h.reason == nil ? T.dim : T.muted).lineLimit(1)
            }
            .padding(.horizontal, 24)
            .frame(height: 94)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSel ? T.surface : .clear, ignoresSafeAreaEdges: [])
            .overlay(alignment: .leading) { Rectangle().fill(isSel ? T.accent : .clear).frame(width: 2) }
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum HandoffsText {
    /// Строка задачи: ID задачи из передачи. Названия задачи в контракте нет — не придумываем его.
    static func title(_ h: Handoff) -> String {
        h.task.flatMap { $0.isEmpty ? nil : $0 } ?? "без задачи"
    }

    static func home(_ path: String?) -> String? {
        guard let path else { return nil }
        let h = NSHomeDirectory()
        return path.hasPrefix(h) ? "~" + path.dropFirst(h.count) : path
    }
}

/// Карточка передачи: факты 2×2, четыре блока в два столбца одной высоты, «Дальше» полосой.
struct HandoffsDetail: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    var handoff: Handoff

    private var role: String { String(handoff.agent.split(separator: "#").first ?? "") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(ProjectModel.pretty(handoff.agent)) · \(handoff.task ?? "передача")")
                        .font(T.title(20)).kerning(-0.3).foregroundStyle(T.ink).lineLimit(2)
                    Text(meta).font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                }
                facts
                VStack(spacing: 12) {
                    pair(("Сделано", handoff.sections.done), ("Проверено", handoff.sections.verified))
                    pair(("В работе", handoff.sections.inProgress), ("Подводные камни", handoff.sections.pitfalls))
                }
                next
                footer
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var meta: String {
        var parts = [ShortTime.label(handoff.ts)]
        if let r = handoff.reason, !r.isEmpty { parts.append(r.lowercased()) }
        parts.append(handoff.isWaiting ? "ждёт запуска" : "использована" + (handoff.usedAt.map { " " + ShortTime.label($0) } ?? ""))
        return parts.joined(separator: " · ")
    }

    private var facts: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                fact("Агент", ProjectModel.pretty(handoff.agent), color: roleColor(role, in: project))
                Rectangle().fill(T.line).frame(width: 1)
                fact("Задача", handoff.task ?? "—")
            }
            Rectangle().fill(T.line).frame(height: 1)
            HStack(spacing: 0) {
                fact("Ветка", handoff.branch ?? "—")
                Rectangle().fill(T.line).frame(width: 1)
                fact("Worktree", HandoffsText.home(handoff.worktree) ?? "—")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }

    private func fact(_ key: String, _ value: String, color: Color = T.ink) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(key.uppercased()).font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
            Text(value).font(T.mono(13)).foregroundStyle(value == "—" ? T.dim : color)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(value)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func pair(_ a: (String, String), _ b: (String, String)) -> some View {
        HStack(alignment: .top, spacing: 12) {
            block(a.0, a.1)
            block(b.0, b.1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func block(_ key: String, _ value: String) -> some View {
        let empty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Text(key.uppercased()).font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
            if empty {
                Text("не заполнено").font(T.text(14)).foregroundStyle(T.dim)
            } else {
                MarkdownView(text: value)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 116, maxHeight: .infinity, alignment: .topLeading)
        .background(T.surface, ignoresSafeAreaEdges: [])
    }

    private var next: some View {
        let value = handoff.sections.next.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("ДАЛЬШЕ").font(T.mono(10)).kerning(1).foregroundStyle(T.accent)
            Image(systemName: "arrow.right").font(.system(size: 12)).foregroundStyle(T.accent)
            if value.isEmpty {
                Text("следующий шаг не записан").font(T.text(14)).foregroundStyle(T.dim)
            } else {
                MarkdownView(text: value)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .frame(minHeight: 56)
        .background(T.accentBg, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(T.accent.opacity(0.3), lineWidth: 1))
    }

    private var footer: some View {
        let name = ProjectModel.pretty(handoff.agent)
        let note = handoff.isWaiting
            ? "Ждёт: \(name) ещё не перезапущен с новой сессией. После team restart \(handoff.agent) --fresh передача отметится использованной."
            : "Использована\(handoff.usedAt.map { " в " + ShortTime.label($0) } ?? ""): после неё \(name) перезапущен с новой сессией (--fresh)."
        return HStack(spacing: 16) {
            Image(systemName: "info.circle").font(.system(size: 13)).foregroundStyle(T.muted)
            Text(note).font(T.text(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button { app.openAgent(handoff.agent) } label: { Label("Открыть \(name)", systemImage: "apple.terminal") }
                .buttonStyle(AppButtonStyle(kind: .normal))
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }
}
