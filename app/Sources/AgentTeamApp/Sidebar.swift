import AgentTeamCore
import AppKit
import SwiftUI

struct Sidebar: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Swatch(color: T.accent, size: 12)
                Text("agent-team").font(T.mono(15, .semibold)).foregroundStyle(T.ink)
                Spacer(minLength: 0)
                SidebarToggleButton(app: app)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                SectionLabel(text: "Проекты").padding(.horizontal, 10).padding(.bottom, 6)
                ForEach(app.projects) { p in projectRow(p) }
                Button(action: connectProject) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 12)).frame(width: 14)
                        Text("Подключить проект").font(T.text(13))
                        Spacer()
                    }
                    .foregroundStyle(T.muted)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { Task { await app.discoverProjects() } } label: {
                    HStack(spacing: 10) {
                        if app.discovering {
                            ProgressView().controlSize(.mini).frame(width: 14)
                        } else {
                            Image(systemName: "magnifyingglass").font(.system(size: 12)).frame(width: 14)
                        }
                        Text("Найти проекты").font(T.text(13))
                        Spacer()
                    }
                    .foregroundStyle(T.muted)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(app.discovering)
                .help("Каталоги проектов с agents/team.yaml по недавним сессиям Claude Code")
            }

            if let p = app.project {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: sectionCaption(p)).padding(.horizontal, 10).padding(.bottom, 6).lineLimit(1)
                    navRow(.team, "Команда", "rectangle.split.2x2")
                    navRow(.roles, "Роли", "person.2")
                    navRow(.handoffs, "Передачи", "arrow.left.arrow.right", badge: p.waitingHandoffs)
                    navRow(.journal, "Журнал", "list.bullet.rectangle")
                }
            }

            Spacer(minLength: 0)

            navRow(.settings, "Настройки", "gearshape")

            limitsBlock

            if let p = app.project {
                VStack(alignment: .leading, spacing: 4) {
                    Text("tmux · \(p.session)").font(T.mono(11)).foregroundStyle(T.muted).lineLimit(1)
                    Text(p.status?.tracker.map { "трекер · \($0)" } ?? "трекер не задан").font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.top, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 20)
        .padding(.top, 40)          // заголовок окна скрыт: место под кнопки окна
        .frame(width: 248)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(T.side)
        .overlay(alignment: .trailing) { Rectangle().fill(T.line).frame(width: 1) }
        // Лимиты читаются раз в минуту: файлы локальные и маленькие, чтение вне главного потока.
        .task {
            while !Task.isCancelled {
                await app.refreshLimits()
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        }
    }

    /// Лимиты подписки Claude: текущее окно и неделя, от 80 % — янтарным; подробности — в подсказке.
    @ViewBuilder private var limitsBlock: some View {
        let now = app.limitsReadAt
        if let l = app.limits {
            let lines = l.lines(now: now)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines, id: \.text) { line in
                        Text(line.text).font(T.mono(11)).foregroundStyle(line.warning ? T.amber : T.muted).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .help(l.details(now: now))
            }
        } else {
            Text("лимиты: нет данных").font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Лимиты подписки приходят от строки состояния роли после ответа модели. Роли, поднятые до обновления team, получат её после team restart.")
        }
    }

    private func sectionCaption(_ p: ProjectModel) -> String {
        [p.name, p.status?.tracker].compactMap { $0 }.joined(separator: " · ")
    }

    private func projectRow(_ p: ProjectEntry) -> some View {
        let selected = app.selectedSession == p.session
        let starting = selected && app.project?.busyActions.contains("up") == true
        return Button { app.select(p.session) } label: {
            HStack(spacing: 10) {
                Rectangle().fill(p.running && p.liveAgents > 0 ? T.accent : T.faint).frame(width: 7, height: 7)
                Text(p.name).font(T.text(14)).foregroundStyle(selected ? T.ink : T.muted).lineLimit(1)
                Spacer(minLength: 6)
                if starting {
                    ProgressView().controlSize(.mini)
                    Text("поднимается").font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                } else if !p.running, selected, let repo = p.repo {
                    Button { Task { await app.up(repo: repo) } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "play.fill").font(.system(size: 8))
                            Text("поднять").font(T.mono(11))
                        }
                        .foregroundStyle(T.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Rectangle().stroke(T.accent.opacity(0.45), lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Поднять команду: team up в \(p.repo ?? "")")
                } else {
                    Text(p.running ? plural(p.liveAgents, "агент", "агента", "агентов") : "остановлена")
                        .font(T.mono(11)).foregroundStyle(T.dim).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? T.surface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(p.repo ?? p.session)
        .contextMenu {
            if !p.running, let repo = p.repo {
                Button("Поднять команду") { Task { await app.up(repo: repo) } }
            }
            if let repo = p.repo, app.manualRepos.contains(repo) {
                Button("Убрать из списка") { app.removeProject(repo: repo) }
            } else if let repo = p.repo, !p.running, app.discoveredRepos.contains(repo) {
                Button("Скрыть из списка") { app.hideProject(repo: repo) }
            }
        }
    }

    private func navRow(_ s: AppSection, _ title: String, _ icon: String, badge: Int = 0) -> some View {
        let selected = app.section == s
        return Button {
            app.section = s
            if s == .team { app.openedAgent = nil }
            if s == .roles { app.roleTech = false }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 16)
                    .foregroundStyle(selected ? T.accent : T.muted)
                Text(title).font(T.text(14)).foregroundStyle(selected ? T.ink : T.muted)
                Spacer()
                if badge > 0 {
                    Text("\(badge)").font(T.mono(11)).foregroundStyle(T.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(T.amber)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(selected ? T.surface : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func connectProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Каталог проекта с agents/team.yaml"
        panel.prompt = "Подключить"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !app.addProject(repo: url.path) {
            let alert = NSAlert()
            alert.messageText = "В каталоге нет agents/team.yaml"
            alert.informativeText = "Подключается каталог проекта, где команда описана командой team init."
            alert.runModal()
        }
    }
}
