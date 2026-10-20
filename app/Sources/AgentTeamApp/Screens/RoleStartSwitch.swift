import AgentTeamCore
import SwiftUI

/// Режим запуска у строки роли в списке ролей: «постоянная / по требованию»; у роли в режиме «вручную» он
/// стоит первым, в том же порядке, что в карточке роли.
/// Значение то же, что в карточке роли, вместе с её несохранённой правкой режима (она обведена янтарным). Выбор сразу
/// уходит в `team role set <роль> --start …`; файл приложение не правит. Ошибка CLI показывается под переключателем.
struct RoleStartSwitch: View {
    @Bindable var project: ProjectModel
    var row: RoleStartRow

    var body: some View {
        let shown = project.roleStartShown(row.role) ?? project.roleStarts.shown(row)
        let drafted = project.roleEdits[row.role]?.values[.start] != nil
        let saving = project.savingRoles.contains(row.role)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Segmented(items: project.roleStarts.options(row, shown: shown).map { ($0, RoleStart.label($0), nil) },
                          selection: Binding(get: { shown }, set: { start in Task { await project.saveRoleStart(row.role, start) } }),
                          compact: true)
                    .fixedSize()
                    .overlay(Rectangle().stroke(drafted ? T.amber : .clear, lineWidth: 1))
                    .disabled(saving)
                    .help(drafted ? "Режим изменён в карточке роли и не сохранён. Выбор здесь сохраняет только режим."
                                  : "Постоянная роль поднимается с командой (team up), по требованию — когда менеджер даёт ей задачу.")
                if saving { ProgressView().controlSize(.mini) }
            }
            if let error = project.roleStarts.errors[row.role] {
                Text(error).font(T.text(11)).foregroundStyle(T.rose).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
