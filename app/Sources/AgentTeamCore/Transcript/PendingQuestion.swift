import Foundation

/// Вопрос `AskUserQuestion` целиком, как его задала модель: вопросы, варианты и их пояснения. Форма Claude Code в узкой
/// или низкой панели не умещается на экране, и её верх (вкладки, вопрос, первые пункты) срезан: Claude Code рисует в
/// альтернативном экране, истории у панели нет. Поэтому показываемый владельцу вопрос берётся из входа инструмента,
/// а с экрана — только где сейчас курсор.
///
/// Тот же вид у поля `question` агента в `team status --json`: строки по умолчанию пустые, `multiSelect` — false,
/// неизвестные поля пропускаются, битый вопрос или вариант выпадает, а не обнуляет всё.
public struct PendingQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var detail: String
        /// Образец (код, макет) к варианту, если модель его дала.
        public var preview: String?

        public init(label: String, detail: String = "", preview: String? = nil) {
            self.label = label
            self.detail = detail
            self.preview = preview
        }

        enum CodingKeys: String, CodingKey {
            case label, preview
            case detail = "description"
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            label = c.lossyString(.label) ?? ""
            detail = c.lossyString(.detail) ?? ""
            preview = c.lossyString(.preview).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    public struct Question: Codable, Equatable, Sendable {
        /// Короткая подпись вкладки («Защита»).
        public var header: String
        public var text: String
        public var multiSelect: Bool
        public var options: [Option]

        public init(header: String, text: String, multiSelect: Bool = false, options: [Option]) {
            self.header = header
            self.text = text
            self.multiSelect = multiSelect
            self.options = options
        }

        enum CodingKeys: String, CodingKey {
            case header, multiSelect, options
            case text = "question"
        }

        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            header = c.lossyString(.header) ?? ""
            text = c.lossyString(.text) ?? ""
            multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
            options = ((try? c.decodeIfPresent(LossyList<Option>.self, forKey: .options))?.items ?? []).filter { !$0.label.isEmpty }
        }
    }

    /// `tool_use_id` вызова: по нему результат снимает вопрос.
    public var id: String
    /// Начало вызова, unix-секунды (есть только у источника из `team status`).
    public var ts: Int?
    public var questions: [Question]

    public init(id: String, ts: Int? = nil, questions: [Question]) {
        self.id = id
        self.ts = ts
        self.questions = questions
    }

    enum CodingKeys: String, CodingKey { case id, ts, questions }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.lossyString(.id) ?? ""
        ts = c.lossyInt(.ts)
        questions = ((try? c.decodeIfPresent(LossyList<Question>.self, forKey: .questions))?.items ?? [])
            .filter { !$0.text.isEmpty && !$0.options.isEmpty }
    }

    /// Есть что показать: хотя бы один вопрос с вариантами.
    public var isUsable: Bool { !questions.isEmpty }

    /// Вопрос из входа `AskUserQuestion`; `nil`, если в нём нет ни одного вопроса с вариантами.
    public static func parse(id: String, input: [String: Any]) -> PendingQuestion? {
        let qs = ((input["questions"] as? [[String: Any]]) ?? []).compactMap { q -> Question? in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = ((q["options"] as? [[String: Any]]) ?? []).compactMap { o -> Option? in
                guard let label = o["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, detail: o["description"] as? String ?? "", preview: (o["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 })
            }
            guard !options.isEmpty else { return nil }
            return Question(header: q["header"] as? String ?? "", text: text, multiSelect: q["multiSelect"] as? Bool ?? false, options: options)
        }
        return qs.isEmpty ? nil : PendingQuestion(id: id, questions: qs)
    }
}

/// Откуда приложение знает открытый вопрос менеджера целиком. Источники по порядку:
/// - поле `question` агента в `team status --json`: `team` ловит вход вызова хуком, до ответа;
/// - неотвеченный `tool_use` в транскрипте (`AgentThreadModel`). Claude Code пишет одиночный вызов `AskUserQuestion`
///   в транскрипт только вместе с ответом; сразу запись появляется, если в том же сообщении был другой инструмент
///   и его результат уже пришёл.
///
/// Пока оба источника молчат, приложение показывает форму с экрана панели, как Claude Code её нарисовал.
@MainActor
public protocol OpenQuestionSource {
    var openQuestion: PendingQuestion? { get }
}

/// Источник из `team status --json`: поле `question` агента.
public struct StatusQuestionSource: OpenQuestionSource {
    public var agent: Agent?
    public init(agent: Agent?) { self.agent = agent }
    public var openQuestion: PendingQuestion? { agent?.alive == true ? agent?.question : nil }
}

extension PendingQuestion {
    /// Вопросы источников по порядку. Показывается первый, который сходится с экраном (`AskFormScreen.pick`): кеш status
    /// бывает на опрос позади, и старый вопрос в нём не должен закрывать новый из транскрипта.
    @MainActor public static func all(of sources: [any OpenQuestionSource]) -> [PendingQuestion] {
        sources.compactMap(\.openQuestion)
    }
}
