import AgentTeamCore
import SwiftUI

/// Раздел «Роли»: список ролей слева, справа — поля, которые решает человек, агенты роли и сводка
/// технических настроек. Технические настройки открываются отдельным экраном (`app.roleTech`).
struct RolesScreen: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    @State private var showNewRole = false

    var body: some View {
        Group {
            if app.roleTech, let role = selected, !role.isShared {
                RolesTechScreen(app: app, project: project, role: role)
            } else {
                main
            }
        }
        .sheet(isPresented: $showNewRole) {
            RolesNewRoleSheet(project: project) { created in
                app.selectRole(created)
                app.roleTech = false
            }
        }
    }

    private var main: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                HStack(spacing: 14) {
                    ScreenTitle(title: "Роли")
                    RolesTag(text: "agents/roles")
                    if let badge = RoleDraft.badge(changedFields) { UnsavedBadge(text: badge) }
                }
            } trailing: {
                Button { showNewRole = true } label: { Label("Новая роль", systemImage: "plus") }
                    .buttonStyle(AppButtonStyle(kind: .normal))
                Button("Отменить") { discard() }
                    .buttonStyle(AppButtonStyle(kind: .quiet))
                    .disabled(!isDirty || saving).opacity(isDirty ? 1 : 0.4)
                Button { Task { await save(restart: false) } } label: { Label("Сохранить", systemImage: "checkmark") }
                    .buttonStyle(AppButtonStyle(kind: .primary))
                    .disabled(!canSave).opacity(canSave ? 1 : 0.4)
                    .keyboardShortcut("s", modifiers: .command)
            }
            ProjectSettingsStrip(project: project)
            HStack(spacing: 0) {
                RolesList(app: app, project: project, dirty: Set(project.roleEdits.keys.filter { isDirty(role: $0) }))
                if let role = selected, role.isShared {
                    SharedRoleView(app: app, project: project, role: role).id("shared:" + role.role)
                } else if let role = selected {
                    editor(role).id(role.role)
                } else {
                    rolesEmpty
                }
            }
        }
    }

    // MARK: состояние

    private var selected: RoleInfo? {
        RoleGroups.resolve(app.selectedRole, shared: app.selectedRoleShared, in: project.roles)
            ?? RoleGroups.resolve(nil, shared: false, in: project.roles)
    }

    /// Правки по ролям — в модели проекта: экран пересоздаётся при смене раздела, а несохранённое должно дожить до
    /// возвращения. Хранятся только тронутые поля, поэтому смена роли снаружи (`team role set`) не откатывается.
    private var drafts: [String: RoleEdits] { project.roleEdits }

    private func base(_ role: RoleInfo) -> RoleDraft { project.roleBase(role) }

    private func draftBinding(_ role: RoleInfo) -> Binding<RoleDraft> {
        Binding(get: { (drafts[role.role] ?? RoleEdits()).applied(to: base(role)) },
                set: { project.recordRoleEdit(role.role, form: $0, base: base(role)) })
    }

    private func isDirty(role name: String) -> Bool {
        guard let r = project.role(named: name), let d = drafts[name] else { return false }
        return !d.changed(from: base(r)).isEmpty
    }

    private var changedFields: [RoleDraft.Field] {
        guard let r = selected, let d = drafts[r.role] else { return [] }
        return d.changed(from: base(r))
    }

    private var saving: Bool { selected.map { project.savingRoles.contains($0.role) } ?? false }
    private var isDirty: Bool { !changedFields.isEmpty }
    private var canSave: Bool {
        guard isDirty, !saving, let r = selected, let e = drafts[r.role] else { return false }
        return e.applied(to: base(r)).isValid
    }

    private func discard() {
        guard let r = selected else { return }
        project.discardRoleEdits(r.role)
    }

    private func save(restart: Bool) async {
        guard let r = selected else { return }
        guard await project.saveRoleEdits(r.role, base: base(r)) else { return }
        if restart {
            // Без --fresh: агент продолжает свою сессию, а spawn заново собирает инструкцию и параметры claude.
            for a in project.agents(ofRole: r.role) { await project.restart(a.name, fresh: false) }
        }
    }

    // MARK: правая часть

    private func editor(_ role: RoleInfo) -> some View {
        let draft = draftBinding(role)
        let changed = Set(drafts[role.role].map { $0.changed(from: base(role)) } ?? [])
        let agents = project.agents(ofRole: role.role)
        let color = roleColor(role.role, in: project)
        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Swatch(color: color, size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(role.role).font(T.title(22)).kerning(-0.3).foregroundStyle(T.ink).lineLimit(1)
                Text(roleSubtitle(role, running: agents.count)).font(T.text(14)).foregroundStyle(T.muted).lineLimit(1)
            }
            if let err = role.error {
                Note(text: "Роль не читается: \(err)", icon: "exclamationmark.triangle", color: T.rose)
            }
            HStack(alignment: .top, spacing: 28) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        fields(role, draft: draft, changed: changed, accent: color)
                        if role.isInheriting { ParentRoleBlock(role: role, parent: project.parent(of: role)) }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                VStack(spacing: 16) {
                    agentsCard(role, agents: agents, color: color)
                    techCard(role)
                    Spacer(minLength: 0)
                }
                .frame(width: 340)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if !changed.isEmpty, !agents.isEmpty {
                applyNote(role, agents: agents)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func roleSubtitle(_ role: RoleInfo, running: Int) -> String {
        var parts = [role.isInheriting ? "роль проекта \(project.name) · наследует \(role.extends ?? "")" : "роль проекта \(project.name)"]
        if running > 0 {
            parts.append(plural(running, "агент работает", "агента работают", "агентов работают"))
        } else {
            parts.append("агентов нет")
        }
        return parts.joined(separator: " · ")
    }

    private func fields(_ role: RoleInfo, draft: Binding<RoleDraft>, changed: Set<RoleDraft.Field>, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            RoleField(title: "Название", hint: "как роль видна в команде") {
                TextField("", text: draft.title)
                    .textFieldStyle(.plain).font(T.text(14)).foregroundStyle(T.ink)
                    .rolesPlaceholder("Название роли", show: draft.wrappedValue.title.isEmpty, font: T.text(14))
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(T.well, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(fieldBorder(changed.contains(.title), invalid: draft.wrappedValue.title.trimmingCharacters(in: .whitespaces).isEmpty), lineWidth: 1))
            }
            RoleField(title: "Модель", hint: "кто выполняет работу роли") {
                RoleOptions(options: [("opus", "глубже, медленнее"), ("sonnet", "основная"), ("haiku", "быстрее, проще")],
                            selection: draft.model, mono: true, accent: accent, changed: changed.contains(.model))
            }
            RoleField(title: "Описание", hint: "что роль делает — читает менеджер, когда раздаёт задачи") {
                TextField("", text: draft.description, axis: .vertical)
                    .textFieldStyle(.plain).font(T.text(14)).foregroundStyle(T.ink).lineSpacing(4)
                    .rolesPlaceholder("Одна-две фразы о работе роли", show: draft.wrappedValue.description.isEmpty, font: T.text(14))
                    .lineLimit(2...8)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(T.well, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(fieldBorder(changed.contains(.description)), lineWidth: 1))
            }
            RoleField(title: "Когда поднимать", hint: "режим запуска") {
                RoleOptions(options: [("manual", "поднимаете вы"), ("always", "вместе с командой"), ("on_demand", "поднимает менеджер")],
                            labels: ["manual": "Вручную", "always": "Постоянная", "on_demand": "По требованию"],
                            selection: draft.start, mono: false, accent: accent, changed: changed.contains(.start))
            }
        }
    }

    private func fieldBorder(_ changed: Bool, invalid: Bool = false) -> Color {
        if invalid { return T.rose.opacity(0.7) }
        return changed ? T.amber : .clear
    }

    private func agentsCard(_ role: RoleInfo, agents: [Agent], color: Color) -> some View {
        RoleCard(title: "Агенты роли") {
            ForEach(agents) { a in
                Button { app.openAgent(a.name) } label: {
                    HStack(spacing: 10) {
                        Text(ProjectModel.pretty(a.name)).font(T.mono(12)).foregroundStyle(color).lineLimit(1)
                        Text(project.taskLabel(of: a.name)?.text ?? "").font(T.mono(12)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.tail)
                            .help(project.taskLabel(of: a.name)?.tooltip() ?? "")
                        Spacer(minLength: 8)
                        Text(AgentTime.session(started: a.started)).font(T.mono(11)).foregroundStyle(T.muted).help(project.timeTooltip(a))
                        let (dot, hint) = agentDot(a)
                        Circle().fill(dot).frame(width: 7, height: 7).help(hint)
                    }
                    .padding(.horizontal, 14).frame(height: 43.5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            }
            if agents.isEmpty {
                Text("Сейчас не запущен ни один агент этой роли")
                    .font(T.text(13)).foregroundStyle(T.dim)
                    .padding(.horizontal, 14).frame(height: 43.5, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            }
            if role.kind != "manager" {
                Button { Task { await project.spawn(role: role.role) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 12))
                        Text(project.busyActions.contains("spawn:" + role.role) ? "Поднимаю…" : "Новый агент этой роли").font(T.text(13))
                        Spacer()
                    }
                    .foregroundStyle(T.ink)
                    .padding(.horizontal, 14).frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(project.busyActions.contains("spawn:" + role.role))
            }
        }
    }

    private func agentDot(_ a: Agent) -> (Color, String) {
        let st = project.agentStatus(a)
        let text = st.label
        switch st.state {
        case .working: return (T.accent, text)
        case .waiting: return (T.amber, text)
        case .quiet: return (T.muted, text)
        case .stopped, .noData: return (T.faint, text)
        }
    }

    private func techCard(_ role: RoleInfo) -> some View {
        RoleCard(title: "Технические настройки") {
            techRow("репозиторий", RoleSummary.repoName(role.worktree?.repo) ?? (role.worktree == nil ? "без worktree" : project.name))
            techRow("зона", RoleSummary.zone(role.zone))
            techRow("общие правила", role.includes.isEmpty ? "—" : plural(role.includes.count, "файл", "файла", "файлов"))
            techRow("права", plural(role.effectiveAllow.count, "инструмент", "инструмента", "инструментов"))
            techRow(role.isInheriting ? "инструкция (итог)" : "инструкция", plural(RoleSummary.lineCount(role.isInheriting ? role.instruction : role.body), "строка", "строки", "строк"))
            Button { app.roleTech = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lock").font(.system(size: 12))
                    Text("Открыть — только чтение").font(T.text(13))
                    Spacer()
                    Image(systemName: "arrow.right").font(.system(size: 13))
                }
                .foregroundStyle(T.ink)
                .padding(.horizontal, 14).frame(height: 43.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
        }
    }

    private func techRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).font(T.text(13)).foregroundStyle(T.muted)
            Spacer(minLength: 12)
            Text(value).font(T.mono(12)).foregroundStyle(T.ink).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 14).frame(height: 36)
    }

    private func applyNote(_ role: RoleInfo, agents: [Agent]) -> some View {
        let names = agents.map { ProjectModel.pretty($0.name) }
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " и " + names.last!
        let who = names.count == 1 ? "Сейчас работает \(list)" : "Сейчас работают \(list)"
        let tail = role.kind == "manager"
            ? " — перезапуск прервёт разговор с менеджером: он продолжит ту же сессию с новыми настройками."
            : " — «Сохранить и перезапустить» продолжит их сессии (--resume) уже с новыми настройками."
        return HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 13)).foregroundStyle(T.amber)
            Text("Изменения действуют с перезапуска. " + who + tail)
                .font(T.text(13)).foregroundStyle(T.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button(saving ? "Сохраняю…" : "Сохранить и перезапустить") { Task { await save(restart: true) } }
                .buttonStyle(AppButtonStyle(kind: .warn))
                .disabled(!canSave).opacity(canSave ? 1 : 0.5)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(T.amberBg, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(T.amber.opacity(0.35), lineWidth: 1))
    }

    private var rolesEmpty: some View {
        EmptyState(title: project.rolesError == nil ? "Ролей нет" : "Роли не прочитаны",
                   detail: project.rolesError ?? "Роли лежат в agents/roles. Создайте первую кнопкой «Новая роль».",
                   icon: "person.2")
    }
}

// MARK: - общие части экрана ролей

/// Список ролей слева в двух блоках: «Роли проекта» (собственные и наследующие) и «Общие роли» (библиотека инструмента).
struct RolesList: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    var dirty: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                blockTitle("Роли проекта")
                let starts = Dictionary(project.roleStartRows.map { ($0.role, $0) }, uniquingKeysWith: { a, _ in a })
                ForEach(project.projectRoles) { r in row(r, start: starts[r.role]) }
                if !project.sharedRoles.isEmpty {
                    blockTitle("Общие роли").padding(.top, 14)
                    ForEach(project.sharedRoles) { r in sharedRow(r) }
                }
            }
            .padding(.vertical, 12)
        }
        .scrollIndicators(.never)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(T.side, ignoresSafeAreaEdges: [])
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
    }

    private func blockTitle(_ text: String) -> some View {
        SectionLabel(text: text).padding(.horizontal, 20).frame(height: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var current: RoleInfo? { RoleGroups.resolve(app.selectedRole, shared: app.selectedRoleShared, in: project.roles) ?? project.projectRoles.first }

    private func select(_ r: RoleInfo) {
        app.selectRole(r.role, shared: r.isShared)
        if r.isShared { app.roleTech = false }
    }

    /// Строка роли проекта. Под названием — режим запуска: он меняется прямо в списке, без карточки. У менеджера
    /// переключателя нет (`RoleStart.rows`): он поднимается всегда. Строка — не кнопка, а щелчок по ней: кнопка
    /// вокруг переключателя перехватывала бы его сегменты.
    private func row(_ r: RoleInfo, start: RoleStartRow?) -> some View {
        let color = roleColor(r.role, in: project)
        let isSel = r.role == current?.role && !(current?.isShared ?? false)
        let running = project.agents(ofRole: r.role).count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Swatch(color: color)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(r.role).font(T.mono(13, .semibold)).foregroundStyle(color).lineLimit(1)
                        if dirty.contains(r.role) {
                            Circle().fill(T.amber).frame(width: 6, height: 6).help("есть несохранённые изменения")
                        }
                    }
                    .layoutPriority(1)
                    Text(r.title ?? "без названия").font(T.text(12)).foregroundStyle(T.muted).lineLimit(1)
                    if let base = RoleGroups.baseLabel(r, shared: project.libraryRoles) {
                        Text(base).font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                            .help("на основе общей роли \(RoleGroups.baseName(r, shared: project.libraryRoles) ?? "")")
                    }
                }
                Spacer(minLength: 8)
                Text(running > 0 ? plural(running, "агент", "агента", "агентов") : "—")
                    .font(T.mono(11)).foregroundStyle(running > 0 ? T.muted : T.dim).lineLimit(1).fixedSize()
                    .help(running > 0 ? "работающих агентов роли" : "агентов этой роли не запущено")
            }
            if let start { RoleStartSwitch(project: project, row: start).padding(.leading, 20) }
        }
        .padding(.horizontal, 20).padding(.vertical, start == nil ? 0 : 12)
        .frame(minHeight: 64)
        .background(isSel ? T.surface : .clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .leading) { Rectangle().fill(isSel ? color : .clear).frame(width: 2) }
        .contentShape(Rectangle())
        .onTapGesture { select(r) }
    }

    private func sharedRow(_ r: RoleInfo) -> some View {
        let color = roleColor(r.role, in: project)
        let isSel = r.role == current?.role && (current?.isShared ?? false)
        let busy = project.busyActions.contains("add:" + r.role)
        return HStack(spacing: 12) {
            Swatch(color: color)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.role).font(T.mono(13, .semibold)).foregroundStyle(color).lineLimit(1)
                Text(r.title ?? "без названия").font(T.text(12)).foregroundStyle(T.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                Task { if await project.addSharedRole(r.role) { app.selectRole(r.role) } }
            } label: {
                Text(busy ? "Добавляю…" : "Добавить").font(T.text(12)).foregroundStyle(T.ink).lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(Rectangle().stroke(T.line, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(busy)
            .help("Добавить в проект: тонкая роль с extends: \(r.role)")
        }
        .padding(.horizontal, 20).frame(height: 64)
        .background(isSel ? T.surface : .clear, ignoresSafeAreaEdges: [])
        .overlay(alignment: .leading) { Rectangle().fill(isSel ? color : .clear).frame(width: 2) }
        .contentShape(Rectangle())
        .onTapGesture { select(r) }
    }
}

/// Текст общей роли под полями наследующей: свёрнут, только чтение.
struct ParentRoleBlock: View {
    var role: RoleInfo
    var parent: RoleInfo?
    @State private var open = AppDefaults.isProbeRun(CommandLine.arguments) && LaunchOptions.current.expandParent

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 11))
                    Text("Общая роль \(role.extends ?? "")").font(T.text(13, .medium))
                    Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(T.dim)
                    Spacer()
                    Text("только чтение").font(T.text(12)).foregroundStyle(T.dim)
                }
                .foregroundStyle(T.ink).padding(.horizontal, 14).frame(height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ScrollView {
                    Text(parent?.body ?? "Текст общей роли недоступен.")
                        .font(T.mono(12)).lineSpacing(5).foregroundStyle(T.muted).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                }
                .frame(maxHeight: 260)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            }
        }
        .background(T.well, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }
}

/// Общая роль библиотеки: только чтение; в проект добавляется тонким файлом с extends.
struct SharedRoleView: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    var role: RoleInfo

    var body: some View {
        let color = roleColor(role.role, in: project)
        let inProject = RoleGroups.isInProject(role, projectRoles: project.projectRoles)
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Swatch(color: color, size: 12).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(role.role).font(T.title(22)).kerning(-0.3).foregroundStyle(T.ink).lineLimit(1)
                Text("общая роль · библиотека инструмента").font(T.text(14)).foregroundStyle(T.muted).lineLimit(1)
                Spacer()
                if inProject {
                    UnsavedBadge(text: "в проекте", color: T.muted).fixedSize()
                } else {
                    Button { Task { await project.addSharedRole(role.role) } } label: { Label("Добавить в проект", systemImage: "plus") }
                        .buttonStyle(AppButtonStyle(kind: .normal))
                }
            }
            if let title = role.title { RoleField(title: "Название") { TechValue(text: title, mono: false) } }
            if let d = role.description { RoleField(title: "Описание") { TechValue(text: d, mono: false) } }
            RoleField(title: "Инструкция", hint: "только чтение") {
                ScrollView {
                    Text(role.body ?? role.instruction ?? "Текст роли недоступен.")
                        .font(T.mono(12)).lineSpacing(5).foregroundStyle(T.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(14)
                }
                .background(T.well, ignoresSafeAreaEdges: [])
                .overlay(Rectangle().stroke(T.line, lineWidth: 1))
            }
            Note(text: "Общая роль в проекте только читается. «Добавить в проект» создаёт в agents/roles тонкий файл с extends: \(role.role): в нём можно уточнить роль под проект.", icon: "lock")
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Пометка «описание изменено» в шапке.
struct UnsavedBadge: View {
    var text: String
    var color: Color = T.amber
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(T.mono(11)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(Rectangle().stroke(color.opacity(color == T.amber ? 1 : 0.5), lineWidth: 1))
    }
}

/// Поле формы роли: подпись слева, подсказка справа, содержимое ниже.
struct RoleField<Content: View>: View {
    var title: String
    var hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(T.text(13, .medium)).foregroundStyle(T.ink)
                Spacer(minLength: 12)
                if let hint { Text(hint).font(T.text(12)).foregroundStyle(T.dim).lineLimit(1) }
            }
            content
        }
    }
}

/// Выбор из трёх карточек одной ширины (модель, режим запуска).
struct RoleOptions: View {
    var options: [(String, String)]
    var labels: [String: String] = [:]
    @Binding var selection: String
    var mono: Bool
    var accent: Color
    var changed: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { value, detail in
                let on = selection == value
                Button { selection = value } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(labels[value] ?? value).font(mono ? T.mono(13, .semibold) : T.text(13, .semibold))
                            .foregroundStyle(on ? accent : T.ink)
                        Text(detail).font(T.text(12)).foregroundStyle(T.muted).lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(on ? T.surface : T.well, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(on ? (changed ? T.amber : accent) : T.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Карточка правой колонки с шапкой капсом.
struct RoleCard<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title)
                .padding(.horizontal, 14).frame(height: 39.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            content
        }
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }
}

/// Серый тег рядом с заголовком («agents/roles»). Свой, а не `ScreenTitle(tag:)`: заливка не должна уходить
/// в зону скрытого заголовка окна.
struct RolesTag: View {
    var text: String
    var body: some View {
        Text(text).font(T.mono(11)).foregroundStyle(T.muted).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(T.surface, ignoresSafeAreaEdges: [])
    }
}

extension View {
    /// Подсказка в пустом поле. `prompt` у TextField на macOS рисуется цветом текста, и пустое поле
    /// выглядит заполненным — поэтому подсказка своим слоем, приглушённо.
    func rolesPlaceholder(_ text: String, show: Bool, font: Font) -> some View {
        overlay(alignment: .topLeading) {
            if show { Text(text).font(font).foregroundStyle(T.dim).allowsHitTesting(false) }
        }
    }
}
