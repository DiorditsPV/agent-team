import AgentTeamCore
import SwiftUI

/// Полоса над списком ролей: настройки проекта из agents/team.yaml (только чтение) и проверка `team check`.
/// Раздел «Состав» слит с «Ролями»: роли, их запуск и файлы уже на этом экране, остались шапка team.yaml и проверка.
/// Новое поле team.yaml (например idle_stop_minutes) добавляется ещё одной ячейкой в `cells`.
struct ProjectSettingsStrip: View {
    @Bindable var project: ProjectModel
    @State private var checkOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                cells
                checkCell
            }
            .frame(height: 64)
            if checkOpen { checkDetails }
        }
        .background(T.side, ignoresSafeAreaEdges: [])
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    // MARK: team.yaml

    private var cells: some View {
        let y = project.teamYAML
        let tracker = y.tracker ?? project.status?.tracker
        return HStack(spacing: 0) {
            cell("layout") {
                HStack(spacing: 2) {
                    ForEach(["windows", "panes"], id: \.self) { v in
                        let on = (y.layout ?? "windows") == v
                        Text(v).font(T.mono(12)).foregroundStyle(on ? T.ink : T.muted)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(on ? T.line : .clear, ignoresSafeAreaEdges: [])
                    }
                }
                .padding(2).background(T.well, ignoresSafeAreaEdges: [])
                .help("Раскладку задаёт team.yaml; меняет её менеджер")
            }
            divider
            cell("manager") { value(y.manager ?? "—", color: y.manager == nil ? T.dim : T.accent) }
            divider
            cell("tracker") { value(tracker ?? "не задан", color: tracker == nil ? T.dim : T.ink) }
            divider
            cell("worktree_root") { value(y.worktreeRoot ?? "рядом с проектом", color: y.worktreeRoot == nil ? T.dim : T.ink) }
            divider
            IdleStopCell(project: project)
        }
    }

    private var divider: some View { Rectangle().fill(T.line).frame(width: 1).padding(.vertical, 12) }

    private func cell<C: View>(_ key: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(key).font(T.mono(11)).foregroundStyle(T.dim)
            content()
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func value(_ s: String, color: Color) -> some View {
        Text(s).font(T.mono(13)).foregroundStyle(color).lineLimit(1).truncationMode(.middle).help(s)
    }

    // MARK: team check

    private var checkCell: some View {
        HStack(spacing: 12) {
            Rectangle().fill(T.line).frame(width: 1).padding(.vertical, 12)
            Button { Task { await project.runCheck(); checkOpen = true } } label: {
                Label(project.checkRunning ? "Проверяю…" : "team check", systemImage: "checklist")
            }
            .buttonStyle(AppButtonStyle(kind: .normal))
            .disabled(project.checkRunning)
            .help("Проверить роли, includes, worktree и права")
            summary
            Spacer(minLength: 0)
        }
        .padding(.trailing, 20)
        .frame(width: 380)
    }

    @ViewBuilder private var summary: some View {
        if project.checkRunning {
            Text("идёт проверка").font(T.mono(11)).foregroundStyle(T.dim)
        } else if let err = project.checkError {
            Text("нет отчёта").font(T.mono(11)).foregroundStyle(T.rose).help(err)
        } else if let c = project.check {
            let n = c.problems.count
            let color: Color = c.problems.contains { $0.level == "error" } ? T.rose : n > 0 ? T.amber : T.accent
            Button { checkOpen.toggle() } label: {
                HStack(spacing: 6) {
                    Text("\(c.passed) ✓").foregroundStyle(T.accent)
                    Text(n == 0 ? "без замечаний" : "\(n) !").foregroundStyle(color)
                    Image(systemName: checkOpen ? "chevron.up" : "chevron.down").font(.system(size: 10)).foregroundStyle(T.dim)
                }
                .font(T.mono(12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(checkOpen ? "Свернуть отчёт" : "Показать отчёт")
        } else {
            Text("не запускалась").font(T.mono(11)).foregroundStyle(T.dim)
        }
    }

    private var checkDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    Text(project.checkTime.map { "team check · " + ShortTime.ago($0, now: ctx.date) } ?? "team check")
                        .font(T.mono(11)).foregroundStyle(T.dim)
                }
                Spacer()
            }
            if let err = project.checkError {
                Note(text: "team check не вернул отчёт: \(err)", icon: "exclamationmark.triangle", color: T.rose)
            }
            if let c = project.check {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(c.problems + c.issues.filter { $0.level == "ok" }) { item($0) }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 220)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
    }

    private func item(_ i: CheckReport.Issue) -> some View {
        let (mark, color): (String, Color) = switch i.level {
        case "ok": ("✓", T.accent)
        case "error": ("✕", T.rose)
        default: ("!", T.amber)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(mark).font(T.mono(13, .semibold)).foregroundStyle(color).frame(width: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(i.title).font(T.text(13, .medium)).foregroundStyle(T.ink)
                if !i.detail.isEmpty {
                    Text(i.detail).font(T.text(12)).foregroundStyle(T.muted).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Ячейка автоостановки: число минут простоя или «выкл». Enter записывает в team.yaml через `team set`, ошибка — под полем.
struct IdleStopCell: View {
    @Bindable var project: ProjectModel
    @State private var text = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    /// Что стоит в team.yaml: число, «выкл»; пусто — ключа нет (действует умолчание, оно в подсказке поля).
    private var current: String {
        switch project.teamYAML.idleStop {
        case .byDefault: return ""
        case let .minutes(n): return String(n)
        case .off: return "выкл"
        }
    }
    private var isDefault: Bool { project.teamYAML.idleStop == .byDefault }
    private var parsed: IdleStopInput { IdleStopInput.parse(text) }
    private var changed: Bool { text.trimmingCharacters(in: .whitespaces) != current }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("автоостановка").font(T.mono(11)).foregroundStyle(T.dim)
            HStack(spacing: 6) {
                TextField("", text: $text)
                    .textFieldStyle(.plain).font(T.mono(13)).foregroundStyle(T.ink)
                    .rolesPlaceholder(String(IdleStopSetting.defaultMinutes), show: text.isEmpty, font: T.mono(13))
                    .focused($focused)
                    .frame(width: 44)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(T.well, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(parsed == .invalid ? T.rose.opacity(0.8) : changed ? T.amber : .clear, lineWidth: 1))
                    .onSubmit { Task { await apply() } }
                    .disabled(project.idleStopSaving)
                    .help("Минуты простоя, после которых агент «по требованию» без задачи останавливается (team reap раз в минуту). Без значения — 15 минут по умолчанию; «выкл» — выключить. Enter — записать в team.yaml.")
                if project.teamYAML.idleStop != .off {
                    Text("мин").font(T.mono(12)).foregroundStyle(T.muted)
                }
                if project.idleStopSaving {
                    ProgressView().controlSize(.small)
                } else if changed, parsed != .invalid {
                    Button("Записать") { Task { await apply() } }
                        .buttonStyle(AppButtonStyle(kind: .quiet)).fixedSize()
                }
            }
            if isDefault, text.isEmpty, project.idleStopError == nil {
                Text("по умолчанию").font(T.text(11)).foregroundStyle(T.dim).lineLimit(1)
            }
            if let err = project.idleStopError ?? (parsed == .invalid ? "минуты или «выкл»" : nil) {
                Text(err).font(T.text(11)).foregroundStyle(T.rose).lineLimit(1).truncationMode(.tail).help(err)
            }
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 215, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .onAppear { text = LaunchOptions.current.idleDraft ?? current }
        .onChange(of: current) { _, new in if !focused { text = new } }
        .onChange(of: text) { _, _ in if project.idleStopError != nil { project.clearIdleStopError() } }
    }

    private func apply() async {
        let ok = await project.setIdleStop(parsed)
        if ok { text = current }
    }
}
