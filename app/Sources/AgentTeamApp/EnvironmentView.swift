import AgentTeamCore
import AppKit
import SwiftUI

/// Окно «Окружение»: tmux, git, uv, claude и team — найденный путь и версия; если чего-то нет — команда для копирования.
/// Версии проверяются при открытии окна и по кнопке; приложение ничего не устанавливает.
struct EnvironmentView: View {
    @Bindable var app: AppModel
    @State private var checks: [ToolCheck] = []
    @State private var checking = false

    static let windowID = "environment"
    static let title = "Окружение"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Окружение").font(T.title(20)).kerning(-0.3).foregroundStyle(T.ink)
                Text(source).font(T.text(13)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28).padding(.top, 36).padding(.bottom, 18)

            VStack(spacing: 0) {
                if checks.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Проверка…").font(T.text(13)).foregroundStyle(T.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(checks) { c in row(c) }
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Text("Окружение берётся из login-шелла при запуске приложения. Установили что-то — перезапустите приложение.")
                    .font(T.text(12)).foregroundStyle(T.dim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button { Task { await run() } } label: {
                    HStack(spacing: 6) {
                        if checking { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
                        Text("Проверить снова")
                    }
                }
                .buttonStyle(AppButtonStyle(kind: .normal))
                .disabled(checking)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .overlay(alignment: .top) { Rectangle().fill(T.line).frame(height: 1) }
        }
        .frame(width: 720)
        .frame(minHeight: 560)
        .background(T.bg)
        .foregroundStyle(T.ink)
        .ignoresSafeArea()
        .task { await run() }
    }

    private var source: String {
        let env = ToolLocator.environment
        let locale = env["LC_ALL"] ?? env["LC_CTYPE"] ?? env["LANG"] ?? "—"
        let from = ToolLocator.usesLoginShell
            ? "PATH и локаль — из login-шелла \(LoginEnvironment.userShell)"
            : "login-шелл не ответил — PATH по умолчанию с каталогами Homebrew и ~/.local/bin"
        return "\(from). Локаль дочерних процессов: \(locale)."
    }

    private func run() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        checks = await EnvironmentCheck.run(toolPath: app.toolPath, cli: app.cli)
    }

    private func row(_ c: ToolCheck) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 15)).foregroundStyle(c.ok ? T.accent : T.amber)
                .frame(width: 18).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(c.name).font(T.mono(14, .semibold)).foregroundStyle(T.ink)
                    if let v = c.version {
                        Text(v).font(T.mono(12)).foregroundStyle(T.muted).lineLimit(1).textSelection(.enabled)
                    }
                    if let p = c.problem {
                        Text(p).font(T.text(12, .medium)).foregroundStyle(T.amber)
                    }
                }
                if let path = c.path {
                    Text(path).font(T.mono(12)).foregroundStyle(T.dim).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled).help(path)
                }
                if let hint = c.hint, !c.ok {
                    Text(hint).font(T.text(12)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                }
                if let fix = c.fix, !c.ok {
                    HStack(spacing: 8) {
                        Text(fix).font(T.mono(12)).foregroundStyle(T.ink).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(T.well, ignoresSafeAreaEdges: [])
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fix, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(AppButtonStyle(kind: .quiet))
                            .help("Скопировать команду")
                        if c.name == "team" {
                            SettingsLink { Text("Настройки…") }.buttonStyle(AppButtonStyle(kind: .normal))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }
}

/// Пункт меню приложения: окно «Окружение».
struct EnvironmentMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Окружение…") { openWindow(id: EnvironmentView.windowID) }
    }
}
