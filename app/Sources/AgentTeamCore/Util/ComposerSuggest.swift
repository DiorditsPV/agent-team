import CoreServices
import Foundation

/// Команда Claude Code в списке подсказок: встроенная или пользовательская (файл .md в каталоге commands).
public struct SlashCommand: Equatable, Sendable {
    public enum Source: Equatable, Sendable { case builtin, user, project }
    public var name: String
    public var detail: String
    public var source: Source

    public init(name: String, detail: String, source: Source) {
        self.name = name
        self.detail = detail
        self.source = source
    }
}

public enum SlashCommands {
    /// Встроенные команды Claude Code: перечень держится в коде, из сети не берётся. Сверен с составом Claude Code 2.1.292:
    /// в нём нет `/todos`, `/vim`, `/pr-comments` (на них он отвечает «Unknown command»), а `/agents` только сообщает,
    /// что мастер субагентов убран, — их в подсказках нет.
    public static let builtin: [SlashCommand] = [
        ("add-dir", "добавить рабочий каталог в сессию"),
        ("bug", "отправить отчёт об ошибке"),
        ("clear", "очистить историю и начать заново"),
        ("compact", "сжать контекст, можно с указаниями"),
        ("config", "открыть настройки"),
        ("context", "показать, чем занят контекст"),
        ("cost", "стоимость и лимиты — то же, что /usage"),
        ("doctor", "проверить установку Claude Code"),
        ("exit", "выйти из сессии"),
        ("export", "выгрузить диалог в файл или буфер"),
        ("help", "справка и список команд"),
        ("hooks", "настроить хуки"),
        ("ide", "подключение к IDE"),
        ("init", "создать CLAUDE.md для проекта"),
        ("login", "войти в аккаунт"),
        ("logout", "выйти из аккаунта"),
        ("mcp", "серверы MCP и их состояние"),
        ("memory", "править файлы памяти"),
        ("model", "выбрать модель"),
        ("output-style", "стиль ответов"),
        ("permissions", "права инструментов"),
        ("release-notes", "что нового в версии"),
        ("resume", "вернуться к прошлой сессии"),
        ("review", "проверить текущие изменения"),
        ("rewind", "откатить диалог или код к прошлому шагу"),
        ("security-review", "проверка изменений на уязвимости"),
        ("status", "версия, модель, аккаунт, подключения"),
        ("statusline", "настроить строку состояния"),
        ("terminal-setup", "настроить клавиши терминала"),
        ("usage", "лимиты использования"),
    ].map { SlashCommand(name: $0.0, detail: $0.1, source: .builtin) }

    /// Пользовательские команды: `~/.claude/commands` и `.claude/commands` проекта. Подкаталог — пространство имён
    /// (`dir/name.md` → `dir:name`). Описание — из `description:` во вступлении файла, иначе первая строка текста.
    public static func custom(home: String, projectDir: String?) -> [SlashCommand] {
        var out = scan(dir: (home as NSString).appendingPathComponent(".claude/commands"), source: .user)
        if let projectDir {
            out += scan(dir: (projectDir as NSString).appendingPathComponent(".claude/commands"), source: .project)
        }
        return out
    }

    public static func all(home: String, projectDir: String?) -> [SlashCommand] {
        var seen = Set<String>()
        // Проектная команда перекрывает пользовательскую, обе — встроенную с тем же именем.
        let custom = custom(home: home, projectDir: projectDir)
        let ordered = custom.filter { $0.source == .project } + custom.filter { $0.source == .user } + builtin
        return ordered.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }

    /// Сначала имена, начинающиеся с запроса, затем содержащие его; без запроса — весь список.
    public static func filter(_ list: [SlashCommand], query: String) -> [SlashCommand] {
        let q = query.lowercased()
        guard !q.isEmpty else { return list }
        let prefix = list.filter { $0.name.lowercased().hasPrefix(q) }
        let inside = list.filter { !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
        return prefix + inside
    }

    private static func scan(dir: String, source: SlashCommand.Source) -> [SlashCommand] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: dir) else { return [] }
        var out: [SlashCommand] = []
        for case let rel as String in en where rel.hasSuffix(".md") && !rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            let name = String(rel.dropLast(3)).replacingOccurrences(of: "/", with: ":")
            let text = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent(rel), encoding: .utf8)) ?? ""
            out.append(SlashCommand(name: name, detail: describe(text), source: source))
        }
        return out.sorted { $0.name < $1.name }
    }

    static func describe(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            let front = lines[1..<end]
            lines = Array(lines[(end + 1)...])
            if let d = front.first(where: { $0.hasPrefix("description:") }) {
                let v = d.dropFirst("description:".count).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if !v.isEmpty { return v }
            }
        }
        return lines.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
    }
}

/// Что набирает владелец в конце поля: имя команды после «/» в начале или путь после «@».
public enum ComposerTrigger: Equatable, Sendable {
    case slash(query: String)
    /// `range` — «@запрос» в тексте (в UTF-16, как у NSString).
    case mention(query: String, range: NSRange)

    public static func detect(text: String, cursor: Int) -> ComposerTrigger? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let head = ns.substring(to: cursor)
        if head.hasPrefix("/"), !head.contains(where: \.isWhitespace) {
            return .slash(query: String(head.dropFirst()))
        }
        var start = cursor
        while start > 0, let u = Unicode.Scalar(ns.character(at: start - 1)), !CharacterSet.whitespacesAndNewlines.contains(u) { start -= 1 }
        guard start < cursor, ns.character(at: start) == 0x40 else { return nil }          // «@»
        return .mention(query: ns.substring(with: NSRange(location: start + 1, length: cursor - start - 1)),
                        range: NSRange(location: start, length: cursor - start))
    }
}

/// Файлы каталога проекта для поиска по «@».
public enum ProjectFiles {
    static let skipped: Set<String> = [".git", ".team", ".build", "build", "node_modules", "venv", ".venv", "__pycache__",
                                       "DerivedData", ".idea", ".next", "dist", "target", "Pods"]

    /// Пути относительно корня, без служебных и скрытых каталогов. Потолок защищает от огромных деревьев.
    public static func list(root: String, limit: Int = 20_000) -> [String] {
        guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        while let rel = en.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            let isDir = (en.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory
            if isDir {
                if skipped.contains(name) || name.hasPrefix(".") { en.skipDescendants() }
                continue
            }
            if name.hasPrefix(".") { continue }
            out.append(rel)
            if out.count >= limit { break }
        }
        return out.sorted()
    }

    /// Индекс дерева для поиска; `truncated` — дерево упёрлось в потолок.
    public static func index(root: String, limit: Int = 20_000) -> FileIndex {
        let files = list(root: root, limit: limit)
        return FileIndex(files, truncated: files.count >= limit)
    }

    /// Путь внутри служебного или скрытого каталога либо скрытый файл: в список он не попадает, и его изменения
    /// (`.git` при каждой команде git, `.build` во время сборки) перечитывать дерево не заставляют.
    public static func isIgnored(relative rel: String) -> Bool {
        rel.split(separator: "/").contains { skipped.contains(String($0)) || $0.hasPrefix(".") }
    }

    /// Имя файла, начинающееся с запроса, лучше имени с запросом внутри, оно лучше пути с запросом; дальше — короче имя, затем короче путь.
    public static func filter(_ files: [String], query: String, limit: Int = 8) -> [String] {
        filter(FileIndex(files), query: query, limit: limit)
    }

    /// То же по готовому индексу: нижний регистр и длины посчитаны заранее, из совпадений держатся только `limit` лучших.
    public static func filter(_ index: FileIndex, query: String, limit: Int = 8) -> [String] {
        guard limit > 0 else { return [] }
        let q = FileIndex.bytes(query)
        guard !q.isEmpty else { return Array(index.shortest.prefix(limit)) }
        var best: [(key: Int, path: String)] = []
        best.reserveCapacity(limit + 1)
        for e in index.entries {
            let score: Int
            if FileIndex.has(e.name, prefix: q) { score = 0 }
            else if FileIndex.has(e.name, inside: q) { score = 1 }
            else if FileIndex.has(e.lower, inside: q) { score = 2 }
            else { continue }
            let key = score * 100_000 + e.nameLength * 100 + min(e.pathLength, 99)
            if best.count == limit, let last = best.last, (key, e.path) >= (last.key, last.path) { continue }
            let at = best.firstIndex { (key, e.path) < ($0.key, $0.path) } ?? best.count
            best.insert((key, e.path), at: at)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.path)
    }
}

/// Файлы проекта, подготовленные для поиска по «@»: имя и путь в нижнем регистре (байты UTF-8 в составной форме,
/// чтобы «й» в имени файла и в запросе совпадали), длины для ранжирования и самые короткие пути для пустого запроса.
public struct FileIndex: Sendable {
    struct Entry: Sendable {
        let path: String
        let lower: [UInt8]
        let name: [UInt8]
        let nameLength: Int
        let pathLength: Int
    }

    let entries: [Entry]
    let shortest: [String]
    /// Пути индекса и их каталоги: по ним наблюдатель отличает новый или удалённый файл от правки существующего.
    public let paths: Set<String>
    public let dirs: Set<String>
    /// Дерево больше потолка `ProjectFiles.list`: часть файлов в индекс не попала.
    public let truncated: Bool

    public init(_ files: [String], truncated: Bool = false) {
        entries = files.map { f in
            let lower = f.lowercased()
            let name = (lower as NSString).lastPathComponent
            return Entry(path: f, lower: Self.bytes(lower), name: Self.bytes(name), nameLength: name.count, pathLength: f.count)
        }
        shortest = Array(entries.sorted { ($0.pathLength, $0.path) < ($1.pathLength, $1.path) }.prefix(32).map(\.path))
        paths = Set(files)
        var dirs = Set<String>()
        for f in files {
            var d = (f as NSString).deletingLastPathComponent
            while !d.isEmpty, dirs.insert(d).inserted { d = (d as NSString).deletingLastPathComponent }
        }
        self.dirs = dirs
        self.truncated = truncated
    }

    public var count: Int { entries.count }

    static func bytes(_ s: String) -> [UInt8] { Array(s.lowercased().precomposedStringWithCanonicalMapping.utf8) }

    static func has(_ s: [UInt8], prefix q: [UInt8]) -> Bool {
        q.count <= s.count && s.starts(with: q)
    }

    static func has(_ s: [UInt8], inside q: [UInt8]) -> Bool {
        guard q.count <= s.count, let first = q.first else { return q.isEmpty }
        var i = 0
        let last = s.count - q.count
        while i <= last {
            if s[i] == first {
                var j = 1
                while j < q.count, s[i + j] == q[j] { j += 1 }
                if j == q.count { return true }
            }
            i += 1
        }
        return false
    }
}

/// История ввода: ↑ в пустом поле листает прошлые сообщения от новых к старым, ↓ возвращает; на выходе — набранное.
public struct InputHistory: Equatable, Sendable {
    public private(set) var entries: [String] = []
    private var index: Int?
    private var stash = ""

    public init() {}

    /// Сообщения владельца по порядку; подряд идущие повторы схлопываются.
    public mutating func reload(_ messages: [String]) {
        var out: [String] = []
        for m in messages where !m.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && out.last != m { out.append(m) }
        entries = out
        if let i = index, i >= out.count { index = nil }
    }

    /// Листаем ли сейчас историю: поле показывает запись, а не набранное.
    public func isBrowsing(_ text: String) -> Bool {
        guard let index, index < entries.count else { return false }
        return entries[index] == text
    }

    /// ↑: допустим в пустом поле или пока листаем. Возвращает новый текст поля.
    public mutating func up(current: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if let i = index, isBrowsing(current) {
            guard i > 0 else { return nil }
            index = i - 1
        } else if current.isEmpty {
            stash = ""
            index = entries.count - 1
        } else {
            return nil
        }
        return entries[index!]
    }

    /// ↓: к более новой записи, с последней — обратно к набранному.
    public mutating func down(current: String) -> String? {
        guard let i = index, isBrowsing(current) else { return nil }
        if i + 1 < entries.count {
            index = i + 1
            return entries[i + 1]
        }
        index = nil
        return stash
    }

    public mutating func reset() { index = nil }
}

/// Список подсказок под полем ввода: команды по «/», файлы по «@».
@MainActor
@Observable
public final class ComposerSuggest {
    public enum Item: Equatable, Sendable, Identifiable {
        case command(SlashCommand)
        case file(String)

        public var id: String {
            switch self {
            case let .command(c): return "/" + c.name
            case let .file(f): return "@" + f
            }
        }
        public var title: String {
            switch self {
            case let .command(c): return "/" + c.name
            case let .file(f): return (f as NSString).lastPathComponent
            }
        }
        public var detail: String {
            switch self {
            case let .command(c): return c.detail
            case let .file(f): return (f as NSString).deletingLastPathComponent
            }
        }
    }

    public private(set) var items: [Item] = []
    public private(set) var trigger: ComposerTrigger?
    public var selected = 0
    public var isOpen: Bool { !items.isEmpty }
    public var maxItems = 8

    @ObservationIgnored private var commands: [SlashCommand] = SlashCommands.builtin
    @ObservationIgnored private var index: FileIndex?
    @ObservationIgnored private var root: String?
    @ObservationIgnored private var loading = false
    /// Пока дерево читалось, пришли новые изменения: по окончании оно читается ещё раз.
    @ObservationIgnored private var reloadPending = false
    @ObservationIgnored private var watcher: FSWatcher?
    @ObservationIgnored private var dismissedFor: ComposerTrigger?
    @ObservationIgnored private var lastText = ""
    @ObservationIgnored private var lastCursor = 0
    @ObservationIgnored private var hasInput = false
    /// Номер последнего запроса к фильтру файлов: опоздавший ответ на прежний запрос отбрасывается.
    @ObservationIgnored private var generation = 0
    /// Сколько раз фильтр файлов запускался (для тестов: одинаковое нажатие не пересчитывается).
    @ObservationIgnored private(set) var fileFilterRuns = 0
    /// Сколько раз читалось дерево (для тестов: служебные каталоги и правка содержимого его не перечитывают).
    @ObservationIgnored private(set) var fileLoads = 0

    public init() {}

    /// Каталог проекта менеджера: команды читаются сразу (файлов мало), дерево файлов — при первом «@»,
    /// дальше оно перечитывается по FSEvents, когда в проекте появляется или исчезает файл.
    public func configure(root: String?, home: String = NSHomeDirectory()) {
        guard root != self.root else { return }
        self.root = root
        index = nil
        loading = false
        reloadPending = false
        watcher?.stop()
        watcher = nil
        commands = SlashCommands.all(home: home, projectDir: root)
        if hasInput { refresh() }
    }

    /// Текст поля и курсор. Поле сообщает о правке и о сдвиге курсора отдельно, поэтому одна и та же пара приходит
    /// дважды на нажатие: повтор ничего не пересчитывает.
    public func update(text: String, cursor: Int) {
        if hasInput, text == lastText, cursor == lastCursor { return }
        hasInput = true
        lastText = text
        lastCursor = cursor
        refresh()
    }

    private func refresh() {
        let t = ComposerTrigger.detect(text: lastText, cursor: lastCursor)
        let wasMention = if case .mention = trigger { true } else { false }
        trigger = t
        generation += 1
        if t != nil, t == dismissedFor { items = []; return }
        dismissedFor = nil
        switch t {
        case let .slash(q):
            items = SlashCommands.filter(commands, query: q).prefix(maxItems).map { .command($0) }
        case let .mention(q, _):
            // Пока фильтр считает новый список, стоит прежний, суженный до путей с текущим запросом: без мигания
            // на каждом символе, и Enter или Tab до ответа подставляют только то, что подходит к набранному.
            // Не подошло ничего — список закрыт, и Enter уходит как обычный ввод.
            if wasMention { narrow(to: q) } else { items = [] }
            guard let index else {
                if !loading { loadFiles() }            // нажатия во время первого чтения второе чтение не заказывают
                return
            }
            filterFiles(index, query: q)
        case nil:
            items = []
        }
        selected = min(selected, max(0, items.count - 1))
    }

    /// Прежний список, сокращённый до путей, в которых есть запрос. Выбранный пункт остаётся выбранным, если уцелел.
    private func narrow(to query: String) {
        let q = FileIndex.bytes(query)
        let keep = selectedID
        items = items.filter { item in
            guard case let .file(f) = item else { return false }
            return FileIndex.has(FileIndex.bytes(f), inside: q)
        }
        selected = items.firstIndex { $0.id == keep } ?? 0
    }

    private var selectedID: String? { items.indices.contains(selected) ? items[selected].id : nil }

    /// Фильтр файлов идёт вне главного потока; ответ принимается, только если запрос за это время не сменился.
    private func filterFiles(_ index: FileIndex, query: String) {
        fileFilterRuns += 1
        let g = generation
        let limit = maxItems
        Task.detached(priority: .userInitiated) { [weak self] in
            let found = ProjectFiles.filter(index, query: query, limit: limit)
            await MainActor.run {
                guard let self, self.generation == g else { return }
                self.items = found.map { .file($0) }
                self.selected = min(self.selected, max(0, self.items.count - 1))
            }
        }
    }

    public func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    /// Esc: список закрывается до следующего изменения запроса.
    public func dismiss() {
        dismissedFor = trigger
        generation += 1
        items = []
    }

    /// Выбранное подставляется в текст: «/имя » вместо набранного или «@путь » вместо «@запроса».
    public func accept() -> (text: String, cursor: Int)? {
        guard items.indices.contains(selected), let trigger else { return nil }
        let ns = lastText as NSString
        switch (items[selected], trigger) {
        case let (.command(c), .slash):
            let tail = ns.substring(from: lastCursor)
            let head = "/" + c.name + " "
            return (head + tail, (head as NSString).length)
        case let (.file(f), .mention(_, range)):
            // Пробел после пути ставится, только если дальше нет своего: двойного пробела не будет.
            let tail = ns.substring(from: range.location + range.length)
            let spaced = tail.first.map { $0.isWhitespace } ?? false
            let insert = "@" + f + (spaced ? "" : " ")
            let text = ns.replacingCharacters(in: range, with: insert)
            return (text, range.location + (insert as NSString).length + (spaced ? 1 : 0))
        default:
            return nil
        }
    }

    /// Набрано «/имя» целиком и такая команда есть: Enter отправляет, а не подставляет то же самое.
    public var typedExactCommand: Bool {
        guard case let .slash(q) = trigger else { return false }
        return commands.contains { $0.name == q }
    }

    /// Чтение дерева в фоне. Повторный запрос во время чтения не теряется: дерево перечитывается ещё раз.
    private func loadFiles() {
        guard let root else { return }
        if loading { reloadPending = true; return }
        loading = true
        fileLoads += 1
        // Наблюдатель начнёт с события до чтения: файл, созданный, пока дерево перечислялось, не потеряется.
        let since = FSEventsGetCurrentEventId()
        Task.detached(priority: .utility) { [weak self] in
            let fresh = ProjectFiles.index(root: root)
            await MainActor.run {
                guard let self, self.root == root else { return }
                self.loading = false
                self.index = fresh
                if self.watcher == nil { self.watch(root, since: since) }
                if self.reloadPending {
                    self.reloadPending = false
                    self.loadFiles()
                }
                if case .mention = self.trigger { self.refresh() }
            }
        }
    }

    /// FSEvents по корню проекта. Перечитывается дерево, только когда файл появился или исчез: правка содержимого,
    /// служебные и скрытые каталоги список не меняют.
    private func watch(_ root: String, since: FSEventStreamEventId) {
        let real = Self.realPath(root)
        watcher = FSWatcher(paths: [real], since: since) { [weak self] changed in
            let rels = changed.compactMap { p -> String? in
                guard p.hasPrefix(real + "/") else { return nil }
                let rel = String(p.dropFirst(real.count + 1))
                return ProjectFiles.isIgnored(relative: rel) ? nil : rel
            }
            guard !rels.isEmpty else { return }
            let exists = rels.map { FileManager.default.fileExists(atPath: real + "/" + $0) }
            Task { @MainActor [weak self] in self?.filesChanged(root: root, rels: rels, exists: exists) }
        }
    }

    private func filesChanged(root: String, rels: [String], exists: [Bool]) {
        guard root == self.root, let index else { return }
        // Известный файл или каталог исчез, неизвестный появился (переименование даёт оба события). Новый файл
        // в дереве, упёршемся в потолок, всё равно не попал бы в список.
        let changed = zip(rels, exists).contains { rel, ex in
            index.paths.contains(rel) || index.dirs.contains(rel) ? !ex : (ex && !index.truncated)
        }
        if changed { loadFiles() }
    }

    /// FSEvents сообщает настоящие пути (`/private/var/…`), а корень может прийти через ссылку (`/var/…`).
    private static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }
}
