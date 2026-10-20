import AgentTeamCore
import SwiftUI

/// Технические настройки роли: только чтение. Эти поля пишет менеджер вместе с ролью;
/// «Открыть файл» показывает исходный roles/<роль>.md, «К роли» возвращает на основной экран.
struct RolesTechScreen: View {
    @Bindable var app: AppModel
    @Bindable var project: ProjectModel
    var role: RoleInfo
    @State private var mode: Mode

    enum Mode: Hashable { case body, built, file }

    init(app: AppModel, project: ProjectModel, role: RoleInfo) {
        self.app = app; self.project = project; self.role = role
        // У наследующей роли тело — только уточнения: итог показывает собранная инструкция.
        _mode = State(initialValue: role.isInheriting ? .built : .body)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                HStack(spacing: 14) {
                    Text("Роли / \(role.role) /").font(T.text(14)).foregroundStyle(T.muted).lineLimit(1).fixedSize()
                    Text("Технические настройки").font(T.title(20)).kerning(-0.3).foregroundStyle(T.ink).lineLimit(1).fixedSize()
                    RolesTag(text: relativeFile)
                    UnsavedBadge(text: "только чтение", color: T.muted).fixedSize()
                }
            } trailing: {
                Button { app.roleTech = false } label: { Label("К роли", systemImage: "arrow.left") }
                    .buttonStyle(AppButtonStyle(kind: .normal))
                Button { mode = .file } label: { Label("Открыть файл", systemImage: "doc.text") }
                    .buttonStyle(AppButtonStyle(kind: mode == .file ? .normal : .quiet))
            }
            HStack(spacing: 0) {
                RolesList(app: app, project: project)
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 28) {
                        leftColumn.frame(maxWidth: .infinity)
                        rightColumn.frame(maxWidth: .infinity)
                    }
                    instruction
                    Note(text: "Эти поля пишет и поддерживает менеджер вместе с ролью. Чтобы что-то поменять, попросите менеджера — он поправит файл роли и перезапустит агентов.",
                         icon: "lock")
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: role.role) { mode = role.isInheriting ? .built : .body }
    }

    private var relativeFile: String {
        guard let f = role.file else { return "agents/roles/\(role.role).md" }
        return f.hasPrefix(project.repo + "/") ? String(f.dropFirst(project.repo.count + 1)) : f
    }

    // MARK: колонки

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            TechField(key: "role", hint: "имя файла") { TechValue(text: role.role) }
            TechField(key: "kind") {
                Text(role.kind ?? "executor").font(T.mono(12)).foregroundStyle(T.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(T.line, ignoresSafeAreaEdges: [])
                    .padding(2).overlay(Rectangle().stroke(T.line, lineWidth: 1))
            }
            TechField(key: "tracker_zone") { TechValue(text: role.trackerZone ?? "—", mono: role.trackerZone == nil) }
            HStack(alignment: .top, spacing: 12) {
                TechField(key: "worktree.repo") { TechValue(text: role.worktree?.repo ?? (role.worktree == nil ? "—" : "репозиторий проекта"), mono: role.worktree?.repo != nil || role.worktree == nil) }
                TechField(key: "worktree.dir") { TechValue(text: role.worktree?.dir ?? "—") }
            }
            TechField(key: "ветка агента", hint: role.worktree == nil ? "работает в каталоге проекта" : "у #2 и далее — с суффиксом -<номер>") {
                TechValue(text: role.worktree?.branch ?? "—")
            }
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            TechField(key: "zone", hint: RoleSummary.repoName(role.worktree?.repo).map { "репозиторий \($0)" }) {
                if role.zone.isEmpty {
                    Text("не задана — роль не правит файлы проекта").font(T.text(12)).foregroundStyle(T.dim)
                } else {
                    TechChips(items: role.zone.map { ($0, T.cyan) })
                }
            }
            TechField(key: "includes", hint: "agents/shared") {
                if role.includes.isEmpty {
                    Text("нет").font(T.text(12)).foregroundStyle(T.dim)
                } else {
                    VStack(spacing: 0) {
                        ForEach(role.includes, id: \.self) { inc in
                            Text(inc).font(T.mono(12)).foregroundStyle(T.ink).lineLimit(1)
                                .padding(.horizontal, 10).frame(height: 31.5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
                        }
                    }
                    .overlay(Rectangle().stroke(T.line, lineWidth: 1))
                }
            }
            TechField(key: "allow", hint: role.allow.isEmpty ? "набор team по умолчанию" : "янтарным — свои права роли, остальное — набор team") {
                let own = Set(role.allow)
                TechChips(items: role.effectiveAllow.map { ($0, own.contains($0) ? T.amber : T.muted) })
            }
        }
    }

    // MARK: инструкция

    private var instruction: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Segmented(items: [(Mode.body, "тело", nil), (Mode.built, "собранная", nil), (Mode.file, "файл", nil)], selection: $mode)
                Text(caption).font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 12)
                Text("+ \(plural(role.includes.count, "include", "includes", "includes")) → .team/build/\(role.role).txt")
                    .font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
            ScrollView {
                Text(RolesTechText.render(text, file: mode == .file))
                    .font(T.mono(12)).lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 20).padding(.vertical, 14)
            }
        }
        .frame(maxHeight: .infinity)
        .background(T.well, ignoresSafeAreaEdges: [])
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }

    private var caption: String {
        switch mode {
        case .body: return "тело \(relativeFile) · только чтение"
        case .built: return "во что собирается: тело и includes"
        case .file: return "исходный файл \(relativeFile)"
        }
    }

    private var text: String {
        switch mode {
        case .body: return role.body ?? "Тело роли не прочитано."
        case .built: return role.instruction ?? "Инструкция не собрана."
        case .file:
            guard let f = role.file, let s = try? String(contentsOfFile: f, encoding: .utf8) else { return "Файл роли не прочитан." }
            return s
        }
    }
}

/// Подсветка markdown роли: заголовки и ключи frontmatter — янтарём, пункты — приглушённо.
enum RolesTechText {
    static func render(_ text: String, file: Bool) -> AttributedString {
        var out = AttributedString()
        var inFront = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, raw) in lines.enumerated() {
            let line = String(raw)
            if i > 0 { out += AttributedString("\n") }
            if file && line == "---" { inFront.toggle(); out += colored(line, T.dim); continue }
            if file && inFront, let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") {
                out += colored(String(line[...colon]), T.amber)
                out += colored(String(line[line.index(after: colon)...]), T.ink)
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { out += colored(line, T.amber) }
            else if t.hasPrefix("- ") || t.first.map({ $0.isNumber }) == true { out += colored(line, T.muted) }
            else { out += colored(line, T.ink) }
        }
        return out
    }

    private static func colored(_ s: String, _ c: Color) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = c
        return a
    }
}

struct TechField<Content: View>: View {
    var key: String
    var hint: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(key).font(T.mono(11)).foregroundStyle(T.dim)
                Spacer(minLength: 8)
                if let hint { Text(hint).font(T.text(11)).foregroundStyle(T.dim).lineLimit(1) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Значение поля только для чтения: рамка без заливки, высота 34.
struct TechValue: View {
    var text: String
    var mono = true

    var body: some View {
        Text(text).font(mono ? T.mono(13) : T.text(13)).foregroundStyle(text == "—" ? T.dim : T.ink)
            .lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .overlay(Rectangle().stroke(T.line, lineWidth: 1))
    }
}

/// Чипы с переносом по строкам.
struct TechChips: View {
    var items: [(String, Color)]

    var body: some View {
        TechFlow(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                Text(it.0).font(T.mono(12)).foregroundStyle(it.1).lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(T.surface, ignoresSafeAreaEdges: [])
            }
        }
    }
}

/// Раскладка «слева направо с переносом».
struct TechFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let w = rows.map(\.width).max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var cur = Row()
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            let add = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if add > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = Row(items: [i], width: s.width, height: s.height)
            } else {
                cur.items.append(i)
                cur.width = add
                cur.height = max(cur.height, s.height)
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
