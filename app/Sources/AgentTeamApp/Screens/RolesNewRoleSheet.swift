import AgentTeamCore
import SwiftUI

/// «Новая роль»: имя файла и то, что решает человек. Файл роли и строку в team.yaml пишет `team role new`;
/// worktree, зона и includes CLI берёт по образцу первой роли-исполнителя — их потом правит менеджер.
struct RolesNewRoleSheet: View {
    @Bindable var project: ProjectModel
    var onCreated: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var draft = RoleDraft(title: "", model: "sonnet", description: "", start: "on_demand")
    @State private var creating = false
    @State private var error: String?

    private var nameValid: Bool { TeamCLI.validRoleName(name) }
    private var nameTaken: Bool { project.role(named: name) != nil }
    private var canCreate: Bool { nameValid && !nameTaken && draft.isValid && !creating }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Новая роль").font(T.title(18)).foregroundStyle(T.ink)
            RoleField(title: "Имя файла", hint: nameHint) {
                TextField("", text: $name)
                    .textFieldStyle(.plain).font(T.mono(14)).foregroundStyle(T.ink)
                    .rolesPlaceholder("например, tester", show: name.isEmpty, font: T.mono(14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(T.well, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(!name.isEmpty && (!nameValid || nameTaken) ? T.rose.opacity(0.7) : T.line, lineWidth: 1))
            }
            RoleField(title: "Название", hint: "как роль видна в команде") {
                TextField("", text: $draft.title)
                    .textFieldStyle(.plain).font(T.text(14)).foregroundStyle(T.ink)
                    .rolesPlaceholder("например, Тестировщик", show: draft.title.isEmpty, font: T.text(14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(T.well, ignoresSafeAreaEdges: []).overlay(Rectangle().stroke(T.line, lineWidth: 1))
            }
            RoleField(title: "Модель", hint: nil) {
                RoleOptions(options: [("opus", "глубже, медленнее"), ("sonnet", "основная"), ("haiku", "быстрее, проще")],
                            selection: $draft.model, mono: true, accent: T.accent, changed: false)
            }
            RoleField(title: "Описание", hint: "читает менеджер, когда раздаёт задачи") {
                TextField("", text: $draft.description, axis: .vertical)
                    .textFieldStyle(.plain).font(T.text(14)).foregroundStyle(T.ink).lineLimit(2...5)
                    .rolesPlaceholder("Что роль делает", show: draft.description.isEmpty, font: T.text(14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(T.well, ignoresSafeAreaEdges: []).overlay(Rectangle().stroke(T.line, lineWidth: 1))
            }
            RoleField(title: "Когда поднимать", hint: nil) {
                RoleOptions(options: [("manual", "поднимаете вы"), ("always", "вместе с командой"), ("on_demand", "поднимает менеджер")],
                            labels: ["manual": "Вручную", "always": "Всегда", "on_demand": "По задаче"],
                            selection: $draft.start, mono: false, accent: T.accent, changed: false)
            }
            Text("Зону, права и worktree новой роли CLI берёт по образцу первой роли-исполнителя; поправить их можно, попросив менеджера.")
                .font(T.text(12)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(T.mono(12)).foregroundStyle(T.rose).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(AppButtonStyle(kind: .quiet)).keyboardShortcut(.cancelAction)
                Button(creating ? "Создаю…" : "Создать роль") { Task { await create() } }
                    .buttonStyle(AppButtonStyle(kind: .primary))
                    .disabled(!canCreate).opacity(canCreate ? 1 : 0.4)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(T.bg, ignoresSafeAreaEdges: [])
        .windowAppearance()
    }

    private var nameHint: String {
        if nameTaken { return "такая роль уже есть" }
        if !name.isEmpty && !nameValid { return "строчная латиница, цифры, «-» и «_», с буквы" }
        return "agents/roles/<имя>.md"
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let ok = await project.newRole(name, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), model: draft.model,
                                       description: draft.description.isEmpty ? nil : draft.description, start: draft.start)
        if ok {
            onCreated(name)
            dismiss()
        } else {
            error = project.lastActionMessage ?? "team role new завершился с ошибкой"
        }
    }
}
