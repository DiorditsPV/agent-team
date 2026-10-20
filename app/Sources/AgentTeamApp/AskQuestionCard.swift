import AgentTeamCore
import SwiftUI

/// Открытый вопрос менеджера (`AskUserQuestion`) на месте строки Claude Code. Вопрос, варианты и пояснения взяты целиком
/// из источника (`OpenQuestionSource`): в узкой панели Claude Code срезает верх формы. Курсор и отметки взяты с экрана
/// панели. Выбор уходит в панель клавишами (`AskKeys`), теми же, что владелец нажал бы в терминале.
struct AskQuestionCard: View {
    let question: PendingQuestion
    /// Вопрос, чью вкладку показывает панель.
    let index: Int
    let screen: AskFormScreen
    /// Предельная высота карточки: лента над ней остаётся видна.
    var maxHeight: CGFloat
    var send: (LiveAction) -> Void
    @State private var own = ""
    @FocusState private var focused: Bool
    @FocusState private var ownFocused: Bool

    private var q: PendingQuestion.Question { question.questions[index] }
    private var n: Int { q.options.count }
    private var cursor: AskCursor { screen.cursorKind(options: n) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(q.text).font(C.text(14, .medium)).foregroundStyle(C.ink)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            .padding(.bottom, 6)
                        ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                            optionRow(i + 1, o).id(i + 1)
                        }
                        ownAnswerRow.id(n + 1)
                        chatRow.id(n + 2)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { scroll(proxy) }
                .onChange(of: screen.cursor) { scroll(proxy) }
            }
            footer
        }
        .background(C.surface)
        .overlay(alignment: .top) { Rectangle().fill(C.amber).frame(height: 1) }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in forward(press) }
        .onAppear { focused = true }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let c = screen.cursor else { return }
        proxy.scrollTo(c, anchor: .center)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "questionmark.bubble").font(.system(size: 12)).foregroundStyle(C.amber)
            Text("Вопрос менеджера").font(C.text(12, .medium)).foregroundStyle(C.muted)
            if question.questions.count > 1 {
                ForEach(Array(question.questions.enumerated()), id: \.offset) { i, item in
                    Button { send(.keys(AskKeys.tab(i - index, cursor: cursor))) } label: {
                        Text(item.header.isEmpty ? "Вопрос \(i + 1)" : item.header)
                            .font(C.text(12, i == index ? .semibold : .regular))
                            .foregroundStyle(i == index ? C.onAccent : C.ink)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(i == index ? C.accent : Color.clear)
                            .overlay(Rectangle().stroke(C.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help(i == index ? "Этот вопрос открыт в панели" : "Перейти к вопросу в панели")
                }
            } else if !q.header.isEmpty {
                Text("· " + q.header).font(C.text(12)).foregroundStyle(C.dim)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 14).padding(.top, 9)
    }

    private func optionRow(_ k: Int, _ o: PendingQuestion.Option) -> some View {
        let selected = cursor == .option(k)
        let checked = screen.items.first { $0.number == k }?.checked
        return Button { send(.keys(AskKeys.choose(k, cursor: cursor))) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(selected ? "❯" : " ").font(C.mono(13, .semibold)).foregroundStyle(C.accent).frame(width: 12)
                Text("\(k).").font(C.mono(13)).foregroundStyle(C.muted)
                // Отметка срезанного сверху пункта на экране не видна: «[·]», а не «[ ]», чтобы не выдавать догадку за состояние.
                if q.multiSelect {
                    Text(checked == true ? "[✔]" : checked == false ? "[ ]" : "[·]").font(C.mono(13))
                        .foregroundStyle(checked == true ? C.accent : C.muted)
                        .help(checked == nil ? "Пункт срезан в панели: отметки не видно" : "")
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(o.label).font(C.text(13, .semibold)).foregroundStyle(C.ink)
                    if !o.detail.isEmpty {
                        Text(o.detail).font(C.text(12.5)).foregroundStyle(C.muted).fixedSize(horizontal: false, vertical: true)
                    }
                    if let p = o.preview {
                        Text(p).font(C.mono(11.5)).foregroundStyle(C.ink).fixedSize(horizontal: false, vertical: true)
                            .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(C.well)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(selected ? C.accentBg : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(q.multiSelect ? "Отметить или снять отметку в панели (цифра \(k))" : "Выбрать в панели (цифра \(k))")
    }

    private var ownAnswerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(cursor == .typeSomething ? "❯" : " ").font(C.mono(13, .semibold)).foregroundStyle(C.accent).frame(width: 12)
            Text("\(n + 1).").font(C.mono(13)).foregroundStyle(C.muted)
            TextField("Свой ответ", text: $own)
                .textFieldStyle(.plain).font(C.text(13)).foregroundStyle(C.ink)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .overlay(Rectangle().stroke(ownFocused ? C.accent : C.line, lineWidth: 1))
                .focused($ownFocused)
                .onSubmit(sendOwn)
            Button("Ответить", action: sendOwn)
                .buttonStyle(.plain).font(C.text(12, .medium)).foregroundStyle(own.isEmpty ? C.dim : C.accent)
                .disabled(own.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(cursor == .typeSomething ? C.accentBg : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(C.line).frame(height: 1) }
        .padding(.top, 4)
    }

    private var chatRow: some View {
        Button { send(.keys(AskKeys.choose(n + 2, cursor: cursor))) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cursor == .chat ? "❯" : " ").font(C.mono(13, .semibold)).foregroundStyle(C.accent).frame(width: 12)
                Text("\(n + 2).").font(C.mono(13)).foregroundStyle(C.muted)
                Text("Обсудить в чате").font(C.text(13)).foregroundStyle(C.ink)
                Text("Chat about this").font(C.text(12)).foregroundStyle(C.dim)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 6)
            .background(cursor == .chat ? C.accentBg : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Вопрос уходит обратно в чат: менеджер спросит иначе")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(cursorNote).font(C.text(11.5)).foregroundStyle(C.dim).lineLimit(2)
            Spacer(minLength: 6)
            if q.multiSelect {
                Button("Дальше") { send(.keys(AskKeys.leave(cursor) + ["Tab"])) }
                    .buttonStyle(.plain).font(C.text(12, .medium)).foregroundStyle(C.accent)
                    .help("Закончить отметки и перейти дальше (Tab в панели)")
            }
            Button("Отменить вопрос") { send(.keys(["Escape"])) }
                .buttonStyle(.plain).font(C.text(12)).foregroundStyle(C.muted)
                .help("Esc в панели: менеджер получит отказ отвечать")
        }
        .padding(.horizontal, 14).padding(.bottom, 9).padding(.top, 2)
        // Место под значок возврата к полю приложения справа внизу.
        .padding(.trailing, 44)
    }

    private var cursorNote: String {
        switch cursor {
        case let .option(k): "Щелчок или цифра — выбор; курсор панели на пункте \(k)"
        case .typeSomething: "Курсор панели в поле своего ответа"
        case .chat: "Курсор панели на «Chat about this»"
        case .hidden: "Щелчок или цифра — выбор; курсор панели на пункте выше её края"
        }
    }

    private func sendOwn() {
        let t = own.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        send(.keys(AskKeys.ownAnswer(options: n, cursor: cursor)))
        send(.text(t))
        send(.keys(["Enter"]))
        own = ""
        focused = true
    }

    /// Клавиши карточки уходят в панель, как из строки Claude Code: стрелки, Enter, Esc, Tab и цифры пунктов.
    private func forward(_ press: KeyPress) -> KeyPress.Result {
        guard !ownFocused else { return .ignored }
        let map: [KeyEquivalent: String] = [.upArrow: "Up", .downArrow: "Down", .leftArrow: "Left", .rightArrow: "Right",
                                            .return: "Enter", .escape: "Escape", .tab: "Tab"]
        if let k = map[press.key] { send(.keys([k])); return .handled }
        if let c = press.characters.first, let d = c.wholeNumberValue, (1...(n + 2)).contains(d) {
            send(.keys(AskKeys.choose(d, cursor: cursor)))
            return .handled
        }
        return .ignored
    }
}
