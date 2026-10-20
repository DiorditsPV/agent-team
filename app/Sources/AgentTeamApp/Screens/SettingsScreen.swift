import AgentTeamCore
import AppKit
import SwiftUI

/// Раздел «Настройки» — о самом приложении: цвета окна, чата и агентов на макете рабочего окна, вид текста в чате
/// менеджера и в терминалах агентов, путь к team, «Окружение». Выбор применяется сразу и хранится в UserDefaults.
/// Проектное (роли и их режим запуска) настраивается на вкладках проекта.
struct SettingsScreen: View {
    @Bindable var app: AppModel
    var display: DisplayModel = .shared
    @State private var toolPath = ""
    @State private var teamVersion = "…"
    /// Чья лента настраивается в блоке «Что показывать в ленте».
    @State private var feedTarget = FeedTarget.manager

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader {
                ScreenTitle(title: "Настройки", subtitle: "цвета, вид текста и инструмент team")
            } trailing: {
                EmptyView()
            }
            GeometryReader { geo in
                // Макет закреплён над прокруткой, чтобы выбор в любой колонке палитр сразу был виден на нём. На невысоком
                // окне (ниже ~800 pt) он съел бы бо́льшую часть экрана — там макет прокручивается вместе со всем.
                let pinned = geo.size.height >= Self.pinnedMockupHeight
                VStack(spacing: 0) {
                    if pinned {
                        mockupSection
                            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 16)
                            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                if !pinned { mockupSection }
                                paletteBlock
                                inputBlock
                                chatBlock
                                feedBlock.id("feed")
                                terminalBlock
                                toolBlock
                            }
                            .padding(28)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        // Для снимка (`AGENT_TEAM_SETTINGS_SCROLL=feed`): экран открывается на этом блоке. Повторяется
                        // при смене закрепления: окно снимка получает размер после первого кадра, макет уходит из прокрутки
                        // или приходит в неё, и прежнее смещение указывало бы на другой блок.
                        .task(id: pinned) {
                            guard let anchor = ProcessInfo.processInfo.environment["AGENT_TEAM_SETTINGS_SCROLL"],
                                  anchor == "feed" else { return }
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                }
            }
        }
        .onAppear { toolPath = app.toolPath }
        .task(id: app.toolPath) { teamVersion = await EnvironmentCheck.teamVersion(cli: app.cli) }
    }

    /// Высота области под шапкой экрана, с которой макет закрепляется. Окно в 800 pt даёт область около 740 pt; запас
    /// в 12 pt держит его закреплённым и при дробной высоте области или чуть более высокой шапке.
    static let pinnedMockupHeight: CGFloat = 728

    // MARK: цвета

    private var mockupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionLabel(text: "Цвета")
                Text("Окно, чат менеджера и агенты выбираются отдельно; макет показывает, как они смотрятся вместе.")
                    .font(T.text(13)).foregroundStyle(T.muted)
            }
            WindowMockup()
        }
    }

    private var paletteBlock: some View {
        PaletteColumns(display: display)
            .padding(.bottom, 24)
            .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    // MARK: лента

    enum FeedTarget: Hashable { case manager, agents }

    /// Что показывать в ленте: отдельно для чата менеджера и для лент агентов («Диалог» и панели «Команды»).
    private var feedBlock: some View {
        let manager = feedTarget == .manager
        let binding: (WritableKeyPath<FeedVisibility, Bool>) -> Binding<Bool> = { key in
            Binding(get: { (manager ? display.settings.feedManager : display.settings.feedAgents)[keyPath: key] },
                    set: {
                        if manager { display.settings.feedManager[keyPath: key] = $0 } else { display.settings.feedAgents[keyPath: key] = $0 }
                    })
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: "Что показывать в ленте")
                Spacer()
                Button("Сбросить", action: display.resetFeed).buttonStyle(AppButtonStyle(kind: .quiet))
            }
            Text("Выключенное не показывается и не оставляет пустых промежутков. Применяется сразу ко всем открытым лентам.")
                .font(T.text(13)).foregroundStyle(T.muted)
            Segmented(items: [(FeedTarget.manager, "Чат менеджера", nil), (FeedTarget.agents, "Агенты", nil)], selection: $feedTarget)
                .fixedSize()
            VStack(alignment: .leading, spacing: 8) {
                feedToggle("Bash-команды", binding(\.bash))
                feedToggle("Чтение и правка файлов", binding(\.files), hint: "Read, Edit, Write, NotebookEdit")
                feedToggle("Прочие инструменты", binding(\.otherTools))
                feedToggle("Сообщения команды", binding(\.teamMessages))
                feedToggle("Обращения к трекеру", binding(\.tracker))
                feedToggle("«Контекст сжат»", binding(\.compacted))
                feedToggle("Длительность и время хода", binding(\.turnDuration))
                feedToggle("Строка хода", binding(\.turnStatus), hint: "что делает агент сейчас, время и токены")
                if manager { feedToggle("Черновик «пишет…»", binding(\.draft)) }
            }
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    private func feedToggle(_ title: String, _ isOn: Binding<Bool>, hint: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 8) {
                Text(title).font(T.text(13)).foregroundStyle(T.ink)
                if let hint { Text(hint).font(T.mono(11)).foregroundStyle(T.dim) }
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: чат

    private var chatBlock: some View {
        block("Текст чата менеджера", reset: display.resetChatText) {
            VStack(alignment: .leading, spacing: 14) {
                fontRow(family: Binding(get: { display.settings.chat.family }, set: { display.settings.chat.family = $0 }))
                sliderRow("Размер", value: Binding(get: { display.settings.chat.size }, set: { display.settings.chat.size = $0 }),
                          range: DisplaySettings.chatSize, step: 1, label: "\(Int(display.settings.chat.size)) pt")
                sliderRow("Интервал", value: Binding(get: { display.settings.chat.spacing }, set: { display.settings.chat.spacing = $0 }),
                          range: DisplaySettings.chatSpacing, step: 1, label: "+\(Int(display.settings.chat.spacing)) pt")
            }
        } preview: {
            MarkdownView(text: Self.chatSample, area: .chat)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(C.bg)
        }
    }

    static let chatSample = """
    ## Сводка прогона

    Тесты прошли, **два** предупреждения; подробности в `report.md` и на https://example.com/run/42.

    | Роль | Задача | Статус | Тесты |
    |:-----|:------:|:------:|------:|
    | исполнитель | DEMO-12 | готово | 148 |
    | ревьюер | DEMO-12 | ревью | — |

    ```sh
    swift test
    ```
    """

    // MARK: терминал

    private var terminalBlock: some View {
        block("Текст терминала агентов", reset: display.resetTerminalText) {
            VStack(alignment: .leading, spacing: 14) {
                fontRow(family: Binding(get: { display.settings.terminal.family }, set: { display.settings.terminal.family = $0 }))
                sliderRow("Размер", value: Binding(get: { display.settings.terminal.size }, set: { display.settings.terminal.size = $0 }),
                          range: DisplaySettings.terminalSize, step: 1, label: "\(Int(display.settings.terminal.size)) pt")
                sliderRow("Интервал", value: Binding(get: { display.settings.terminal.spacing }, set: { display.settings.terminal.spacing = $0 }),
                          range: DisplaySettings.terminalSpacing, step: 0.05,
                          label: String(format: "%.2f", display.settings.terminal.spacing).replacingOccurrences(of: ".", with: ","))
            }
        } preview: {
            let look = TerminalLook.current(grid: false)
            TerminalPreview(lines: SGRParser.parse(Self.terminalSample), look: look)
                .frame(height: CGFloat(Self.terminalSample.split(separator: "\n", omittingEmptySubsequences: false).count) * look.lineHeight + 24)
                .background(look.background)
        }
    }

    /// Вывод агента: дифф, спиннер, сообщение команды, ошибка и ряд цветов палитры.
    static let terminalSample = """
    \u{1B}[1m⏺\u{1B}[0m Update(src/dates.py)
      \u{1B}[2m⎿\u{1B}[0m  2 additions, 1 removal
          12 \u{1B}[41m- return parse(s)    \u{1B}[0m
          12 \u{1B}[42m+ return parse(s, tz) \u{1B}[0m
    \u{1B}[33m✻\u{1B}[0m Работаю над задачей… \u{1B}[2m(14s · esc — прервать)\u{1B}[0m
    \u{1B}[36m[team]\u{1B}[0m ревьюер → исполнитель: замечаний нет, можно сливать
    \u{1B}[31m✗\u{1B}[0m \u{1B}[1mFAILED\u{1B}[0m tests/test_dates.py::test_tz — AssertionError
    \u{1B}[32m✓\u{1B}[0m 147 тестов прошли, \u{1B}[31m1\u{1B}[0m упал
    \u{1B}[31m■\u{1B}[32m■\u{1B}[33m■\u{1B}[34m■\u{1B}[35m■\u{1B}[36m■\u{1B}[0m \u{1B}[91m■\u{1B}[92m■\u{1B}[93m■\u{1B}[94m■\u{1B}[95m■\u{1B}[96m■\u{1B}[0m  \u{1B}[1mжирный\u{1B}[0m \u{1B}[2mтусклый\u{1B}[0m \u{1B}[7mинверсия\u{1B}[0m \u{1B}[4mподчёркнутый\u{1B}[0m
    """

    // MARK: инструмент

    // MARK: поле ввода менеджеру

    private var inputBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Поле ввода менеджеру")
            Picker("", selection: Binding(get: { display.settings.liveInput }, set: { display.settings.liveInput = $0 })) {
                Text("Поле приложения").tag(false)
                Text("Строка Claude Code").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 400)
            Text(display.settings.liveInput
                 ? "Под лентой чата — живая нижняя часть панели менеджера: сама строка ввода Claude Code с меню «/» и «@», историей по ↑, диалогами прав и вопросами. Клавиши уходят в панель как есть; размер окна tmux не меняется, шрифт подгоняется под ширину поля."
                 : "Своё поле приложения: черновик, очередь, картинки, подсказки.")
                .font(T.text(13)).foregroundStyle(T.muted).frame(maxWidth: 640, alignment: .leading)
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    private var toolBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: "Инструмент team")
            HStack(spacing: 8) {
                TextField("", text: $toolPath, prompt: Text("путь к клону agent-team").foregroundColor(T.dim))
                    .textFieldStyle(.plain).font(T.mono(12)).foregroundStyle(T.ink)
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(T.surface, ignoresSafeAreaEdges: [])
                    .overlay(Rectangle().stroke(T.line, lineWidth: 1))
                    .onSubmit { app.toolPath = toolPath }
                Button("Выбрать…", action: choose).buttonStyle(AppButtonStyle())
                Button("Применить") { app.toolPath = toolPath }.buttonStyle(AppButtonStyle())
            }
            Text(app.cli.map { "Вызов: " + ([$0.executable] + $0.prefixArgs).joined(separator: " ") } ?? "team не найден")
                .font(T.mono(11)).foregroundStyle(T.muted)
            Text("Версия team: \(teamVersion)").font(T.mono(11)).foregroundStyle(T.muted)
            Text("Сервер tmux: \(app.hub.socketName.map { "-L \($0)" } ?? "по умолчанию")").font(T.mono(11)).foregroundStyle(T.dim)
            EnvironmentMenuButton().buttonStyle(AppButtonStyle())
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        toolPath = url.path
        app.toolPath = url.path
    }

    // MARK: общие части

    private func block<C: View, P: View>(_ title: String, reset: @escaping () -> Void,
                                         @ViewBuilder controls: () -> C, @ViewBuilder preview: () -> P) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionLabel(text: title)
                Spacer()
                Button("Сбросить", action: reset).buttonStyle(AppButtonStyle(kind: .quiet))
            }
            HStack(alignment: .top, spacing: 24) {
                controls().frame(width: 360, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Превью").font(T.mono(11)).foregroundStyle(T.dim)
                    preview().overlay(Rectangle().stroke(T.line, lineWidth: 1))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) { Rectangle().fill(T.line).frame(height: 1) }
    }

    private func fontRow(family: Binding<String>) -> some View {
        HStack {
            Text("Шрифт").font(T.text(13)).foregroundStyle(T.muted).frame(width: 80, alignment: .leading)
            Picker("", selection: family) {
                // Сохранённый шрифт мог пропасть из системы — показываем и его, чтобы выбор не «прыгал».
                ForEach(FontCatalog.families.contains(family.wrappedValue) ? FontCatalog.families : [family.wrappedValue] + FontCatalog.families,
                        id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        HStack {
            Text(title).font(T.text(13)).foregroundStyle(T.muted).frame(width: 80, alignment: .leading)
            Slider(value: value, in: range, step: step).tint(T.accent)
            Text(label).font(T.mono(12)).foregroundStyle(T.ink).frame(width: 56, alignment: .trailing)
        }
    }
}

/// Статичный вывод терминала для превью: те же шрифт, цвета и высота строки, что у панелей.
struct TerminalPreview: NSViewRepresentable {
    var lines: [StyledLine]
    var look: TerminalLook

    final class PreviewView: NSView {
        var text = NSAttributedString()
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            text.draw(with: bounds.insetBy(dx: 14, dy: 12), options: [.usesLineFragmentOrigin])
        }
    }

    func makeNSView(context: Context) -> PreviewView { PreviewView() }

    func updateNSView(_ v: PreviewView, context: Context) {
        v.text = TermNSRender.attributed(lines, look: look)
        v.needsDisplay = true
    }
}
