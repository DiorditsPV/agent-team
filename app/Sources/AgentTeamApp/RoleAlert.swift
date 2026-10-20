import AgentTeamCore
import SwiftUI

/// Цвета плашки: чат пишет токенами чата, экран агента — токенами окна.
struct RoleAlertColors {
    var ink: Color
    var muted: Color
    var rose: Color
    var surface: Color

    static var chat: RoleAlertColors { RoleAlertColors(ink: C.ink, muted: C.muted, rose: C.rose, surface: C.surface) }
    static var window: RoleAlertColors { RoleAlertColors(ink: T.ink, muted: T.muted, rose: T.rose, surface: T.surface) }
}

/// Плашка «в панели <агент> не сессия роли» (`role_check.ok == false`): причина, кнопка «Восстановить роль»
/// (`team restart <агент>`) и её итог. У менеджера ещё и то, что запись в панель стоит.
struct RoleAlertBanner: View {
    let project: ProjectModel
    let agent: Agent
    var colors: RoleAlertColors

    var body: some View {
        let c = colors
        let restoring = project.busyActions.contains("restart:" + agent.name)
        let result = project.roleRestore[agent.name]
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(c.rose)
            VStack(alignment: .leading, spacing: 4) {
                Text("В панели \(ProjectModel.pretty(agent.name)) не сессия роли: \(agent.roleCheck?.reasonText ?? "")")
                    .font(T.text(13, .medium)).foregroundStyle(c.ink).fixedSize(horizontal: false, vertical: true)
                if agent.kind == "manager" {
                    Text("Отправка из поля и очередь стоят: сообщение получил бы разговор без роли.")
                        .font(T.text(12)).foregroundStyle(c.muted).fixedSize(horizontal: false, vertical: true)
                }
                if let result, !restoring {
                    Text(result.message).font(T.mono(11)).foregroundStyle(result.ok ? c.muted : c.rose)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Button {
                Task { await project.restoreRole(agent.name) }
            } label: {
                Text(restoring ? "Восстанавливаю…" : "Восстановить роль").font(T.text(12, .medium)).foregroundStyle(c.rose)
                    .padding(.horizontal, 9).frame(height: 24)
                    .overlay(Rectangle().stroke(c.rose.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(restoring)
            .help("team restart \(agent.name): панель роли поднимается заново с её промптом и прежней сессией")
            .fixedSize()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c.rose.opacity(0.10))
        .overlay(alignment: .top) { Rectangle().fill(c.rose).frame(height: 1) }
    }
}

/// Красная метка в свёрнутой строке и шапке панели агента: в панели не сессия роли. Причина — в подсказке.
struct RoleMark: View {
    let agent: Agent
    var compact = false

    var body: some View {
        if let check = agent.roleCheck, check.notRole {
            Group {
                if compact {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(A.rose)
                        .padding(.horizontal, 3)
                } else {
                    StatusBadge(text: check.mark, color: A.rose)
                }
            }
            .help("В панели не сессия роли: \(check.reasonText). Восстановить — на экране агента")
            .fixedSize()
        }
    }
}
