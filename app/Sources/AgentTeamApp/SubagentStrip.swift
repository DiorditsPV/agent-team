import AgentTeamCore
import SwiftUI

/// Субагенты, которых сессия запустила и которые ещё работают: вид, задача, текущее действие, сколько идут; и ждёт ли их
/// ход. Читает модель проекта (`ProjectModel.subagents`): опрос один на проект, пока полоса на экране; пустая полоса
/// места не занимает: отступы (`insets`) у неё внутренние, а снаружи — стек нулевой высоты, на котором живёт подписка.
struct SubagentStrip: View {
    let project: ProjectModel
    let sessionID: String?
    let cwd: String?
    var colors: TurnStatusColors
    var dense = false
    var insets = EdgeInsets()

    private var agents: BackgroundAgents { sessionID.flatMap { project.subagents[$0] } ?? .none }

    var body: some View {
        VStack(spacing: 0) {
            if !agents.running.isEmpty {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: dense ? 3 : 5) {
                        Text(header).font(T.mono(11)).foregroundStyle(agents.turnWaits ? colors.accent : colors.muted)
                        ForEach(agents.running) { a in row(a, now: ctx.date) }
                    }
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(colors.line).frame(width: 2) }
                    .padding(insets)
                }
            }
        }
        .task(id: (sessionID ?? "") + "|" + (cwd ?? "")) {
            guard let sid = sessionID else { return }
            project.watchSubagents(sessionID: sid, cwd: cwd, true)
            // Подписка живёт, пока полоса на экране: задача отменяется при уходе вида или смене сессии.
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
            project.watchSubagents(sessionID: sid, cwd: cwd, false)
        }
    }

    private var header: String {
        let n = agents.running.count
        let what = n == 1 ? "субагент" : (2...4).contains(n % 10) && !(12...14).contains(n % 100) ? "субагента" : "субагентов"
        return "\(n) \(what) в работе" + (agents.turnWaits ? " · ход ждёт их" : "")
    }

    /// Две строки: вид, задача и время; ниже — текущее действие. В узкой панели одной строке действие не помещалось.
    private func row(_ a: BackgroundAgent, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ProgressView().controlSize(.mini).tint(colors.accent)
                Text(a.type).font(T.mono(11, .semibold)).foregroundStyle(colors.ink).fixedSize()
                Text(a.task).font(T.mono(11)).foregroundStyle(colors.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                Text(a.elapsedText(now: now)).font(T.mono(11)).foregroundStyle(colors.muted).fixedSize()
            }
            if let act = a.action {
                Text(act).font(T.mono(11)).foregroundStyle(colors.dim).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 22)
            }
        }
        .help([a.type, a.task, a.action].compactMap { $0 }.joined(separator: "\n"))
    }
}
