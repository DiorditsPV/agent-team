import AgentTeamCore
import SwiftUI

/// Макет рабочего окна для настроек цвета: боковая панель и шапка в теме окна, чат менеджера в теме чата, колонка
/// агентов — карточки в теме терминала и кусок вывода в палитре терминала. Каждая зона читает только свои токены
/// (`T`, `C`, `A`), поэтому выбор палитры сразу перерисовывает свою часть макета, как в настоящем окне.
/// Собран из лёгких видов: настоящие экраны тяжёлые и держат живые данные.
struct WindowMockup: View {
    static let height: CGFloat = 360

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(T.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(T.line).frame(height: 1)
                HStack(spacing: 0) {
                    chat
                    Rectangle().fill(T.line).frame(width: 1)
                    agents.frame(width: 300)
                }
                // minHeight 0: при крупном шрифте содержимое выше макета обрезается снизу, а не выталкивает шапку вверх.
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
            }
        }
        .frame(height: Self.height)
        .background(T.bg)
        .clipped()
        .overlay(Rectangle().stroke(T.line, lineWidth: 1))
        .allowsHitTesting(false)
    }

    // MARK: окно (T)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Swatch(color: T.accent)
                Text("agent-team").font(T.mono(12, .medium)).foregroundStyle(T.ink)
            }
            .padding(.horizontal, 8).padding(.bottom, 10)
            sideItem("Команда", selected: true)
            sideItem("Роли")
            sideItem("Передачи", count: "2")
            sideItem("Журнал")
            Text("ПРОЕКТЫ").font(T.mono(10)).kerning(1).foregroundStyle(T.dim)
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            project("demo", T.accent)
            project("sandbox", T.amber)
            project("lab", T.rose)
            Spacer(minLength: 0)
            sideItem("Настройки")
        }
        .padding(10)
        .frame(width: 150, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(T.side)
    }

    private func sideItem(_ title: String, selected: Bool = false, count: String? = nil) -> some View {
        HStack {
            Text(title).font(T.text(13)).foregroundStyle(selected ? T.ink : T.muted)
            Spacer(minLength: 4)
            if let count { Text(count).font(T.mono(11)).foregroundStyle(T.amber) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? T.surface : .clear)
        .overlay(alignment: .leading) { if selected { Rectangle().fill(T.accent).frame(width: 2) } }
    }

    private func project(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name).font(T.mono(12)).foregroundStyle(T.muted)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("agent-team").font(T.title(15)).foregroundStyle(T.ink)
            // Цвета ролей окна: ими помечены роли на экране «Роли» и в журнале.
            HStack(spacing: 3) {
                ForEach(Array(T.rolePalette.enumerated()), id: \.offset) { _, c in Swatch(color: c) }
            }
            Text("3 агента · работает").font(T.text(12)).foregroundStyle(T.muted)
            Spacer(minLength: 8)
            // Кнопки окна теми же стилями, что на экранах: основная, обычная, опасная.
            Button("Новый агент") {}.buttonStyle(AppButtonStyle(kind: .primary))
            Button("Перезапустить") {}.buttonStyle(AppButtonStyle())
            Button("Остановить") {}.buttonStyle(AppButtonStyle(kind: .danger))
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: чат менеджера (C)

    static let managerReply = """
    Тесты прошли, **два** предупреждения; подробности в `report.md`.

    ```sh
    swift test
    ```
    """

    private var chat: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Rectangle().fill(C.accent).frame(width: 8, height: 8)
                Text("менеджер").font(C.mono(13, .semibold)).foregroundStyle(C.accent)
                Text("работает").font(C.mono(11)).foregroundStyle(C.dim)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(C.line).frame(height: 1) }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer(minLength: 40)
                    // Реплики и поле ввода — шрифтом чата из настроек, как в настоящей ленте.
                    Text("Проверь DEMO-12 и собери сводку").font(ChatFont.text(ChatFont.size)).foregroundStyle(C.ink)
                        .lineSpacing(ChatFont.spacing)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(C.surface)
                }
                MarkdownView(text: Self.managerReply, area: .chat)
                HStack(spacing: 6) {
                    Text("⏺").font(C.mono(12)).foregroundStyle(C.dim)
                    Text("Read(src/dates.py)").font(C.mono(12)).foregroundStyle(C.muted)
                }
                HStack(spacing: 6) {
                    Text("✻").font(C.mono(12)).foregroundStyle(C.amber)
                    Text("Думаю… 14 с · 2,1k токенов").font(C.mono(11)).foregroundStyle(C.dim)
                }
            }
            .padding(16)
            // Лента обрезается снизу, а поле ввода остаётся в кадре при любом размере шрифта чата.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            HStack {
                Text("Напишите менеджеру…").font(ChatFont.text(ChatFont.size)).foregroundStyle(C.dim).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold)).foregroundStyle(C.onAccent)
                    .frame(width: 22, height: 22).background(C.accent)
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: 34)
            .background(C.well)
            .overlay(Rectangle().stroke(C.line, lineWidth: 1))
            .padding(12)
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(C.bg)
    }

    // MARK: агенты (заголовок колонки — T, карточки — A, вывод — палитра терминала)

    /// Вывод ревьюера: дифф, спиннер и итог тестов в цветах ANSI.
    static let terminalSample = """
        12 \u{1B}[41m- return parse(s)    \u{1B}[0m
        12 \u{1B}[42m+ return parse(s, tz) \u{1B}[0m
    \u{1B}[33m✻\u{1B}[0m Работаю… \u{1B}[2m(14s)\u{1B}[0m
    \u{1B}[32m✓\u{1B}[0m 147 прошли, \u{1B}[31m1\u{1B}[0m упал
    """

    private var agents: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Агенты").font(T.text(13, .medium)).foregroundStyle(T.ink)
                Text("3").font(T.mono(11)).foregroundStyle(T.dim)
                Spacer()
                HStack(spacing: 2) {
                    Text("Все").font(T.text(11)).foregroundStyle(T.ink).padding(.horizontal, 8).padding(.vertical, 3).background(T.line)
                    Text("Ждут").font(T.text(11)).foregroundStyle(T.muted).padding(.horizontal, 8).padding(.vertical, 3)
                }
                .padding(2).background(T.surface)
            }
            threadCard
            // Свёрнутая строка выше вывода: при крупном шрифте терминала обрезается хвост вывода, а не третий статус.
            collapsedRow
            outputCard
        }
        .padding(10)
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .background(T.bg)
    }

    private func role(_ i: Int) -> Color { A.rolePalette[i % A.rolePalette.count] }

    private func agentHead(_ name: String, _ color: Color, status: String, _ statusColor: Color) -> some View {
        HStack(spacing: 6) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(name).font(A.mono(12, .medium)).foregroundStyle(color)
            Spacer()
            StatusBadge(text: status, color: statusColor, size: 10)
        }
    }

    private var threadCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            agentHead("исполнитель", role(0), status: "работает", A.accent)
            HStack(spacing: 6) {
                Image(systemName: "chevron.right.2").font(.system(size: 10)).foregroundStyle(A.dim)
                Text("Bash(uv run pytest)").font(A.mono(12)).foregroundStyle(A.muted)
            }
            HStack(spacing: 6) {
                Text("ревьюер →").font(A.mono(11)).foregroundStyle(role(1))
                Text("замечаний нет").font(A.text(12)).foregroundStyle(A.ink)
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(A.line).frame(width: 2) }
            HStack(spacing: 8) {
                Text("✓ 147 прошли").font(A.mono(11)).foregroundStyle(A.accent)
                Text("✗ 1 упал").font(A.mono(11)).foregroundStyle(A.rose)
                Spacer()
                Text("10:22").font(A.mono(11)).foregroundStyle(A.faint)
            }
        }
        .padding(10)
        .background(A.bg)
        .overlay(Rectangle().stroke(A.line, lineWidth: 1))
    }

    private var outputCard: some View {
        let look = TerminalLook.current(grid: true)
        let lines = Self.terminalSample.split(separator: "\n", omittingEmptySubsequences: false).count
        return VStack(alignment: .leading, spacing: 0) {
            agentHead("ревьюер", role(1), status: "ждёт", A.amber)
                .padding(10)
            TerminalPreview(lines: SGRParser.parse(Self.terminalSample), look: look)
                .frame(height: CGFloat(lines) * look.lineHeight + 24)
                .background(look.background)
        }
        .background(A.bg)
        .overlay(Rectangle().stroke(A.line, lineWidth: 1))
    }

    private var collapsedRow: some View {
        agentHead("писатель", role(2), status: "ошибка", A.rose)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(A.bg)
            .overlay(Rectangle().stroke(A.line, lineWidth: 1))
    }
}
