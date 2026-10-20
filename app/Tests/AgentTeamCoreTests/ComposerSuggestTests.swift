import XCTest
@testable import AgentTeamCore

final class ComposerTriggerTests: XCTestCase {
    func testSlashOnlyAtStartWithoutSpaces() {
        XCTAssertEqual(ComposerTrigger.detect(text: "/co", cursor: 3), .slash(query: "co"))
        XCTAssertEqual(ComposerTrigger.detect(text: "/", cursor: 1), .slash(query: ""))
        XCTAssertNil(ComposerTrigger.detect(text: "/compact now", cursor: 12), "после пробела это уже аргумент")
        XCTAssertNil(ComposerTrigger.detect(text: "привет /co", cursor: 10), "слэш не в начале поля")
    }

    func testMentionTokenBeforeCursor() {
        let t = ComposerTrigger.detect(text: "см. @src/Ap", cursor: 11)
        XCTAssertEqual(t, .mention(query: "src/Ap", range: NSRange(location: 4, length: 7)))
        XCTAssertNil(ComposerTrigger.detect(text: "почта a@b.ru", cursor: 12), "@ внутри слова — не упоминание")
        XCTAssertNil(ComposerTrigger.detect(text: "@file готово", cursor: 12), "курсор после пробела")
    }
}

final class SlashCommandsTests: XCTestCase {
    private func tmp() -> String {
        let d = NSTemporaryDirectory() + "cmd-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func testFilterPrefixBeforeContains() {
        let r = SlashCommands.filter(SlashCommands.builtin, query: "co").map(\.name)
        XCTAssertEqual(r.first, "compact")
        XCTAssertTrue(r.contains("config") && r.contains("context") && r.contains("cost"))
        let re = SlashCommands.filter(SlashCommands.builtin, query: "re").map(\.name)
        XCTAssertTrue(re.contains("security-review"), "имя с запросом внутри идёт после начинающихся с него")
        XCTAssertLessThan(re.firstIndex(of: "rewind")!, re.firstIndex(of: "security-review")!)
        XCTAssertEqual(SlashCommands.filter(SlashCommands.builtin, query: "").count, SlashCommands.builtin.count)
    }

    /// Подсказки — только команды, которые есть в Claude Code 2.1.292: на остальные он отвечает «Unknown command».
    func testBuiltinHasNoRemovedCommands() {
        let names = Set(SlashCommands.builtin.map(\.name))
        for gone in ["todos", "vim", "pr-comments", "agents"] { XCTAssertFalse(names.contains(gone), gone) }
        for kept in ["review", "cost", "rewind", "statusline", "security-review"] { XCTAssertTrue(names.contains(kept), kept) }
    }

    func testCustomCommandsFromHomeAndProjectWithNamespaceAndDescription() throws {
        let home = tmp(), proj = tmp()
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/.claude/commands/git", withIntermediateDirectories: true)
        try "---\ndescription: \"Сводка PR\"\n---\nТекст".write(toFile: home + "/.claude/commands/git/pr.md", atomically: true, encoding: .utf8)
        try fm.createDirectory(atPath: proj + "/.claude/commands", withIntermediateDirectories: true)
        try "# Заголовок\n\nПервая строка тела".write(toFile: proj + "/.claude/commands/deploy.md", atomically: true, encoding: .utf8)
        try "/* не команда */".write(toFile: proj + "/.claude/commands/notes.txt", atomically: true, encoding: .utf8)

        let all = SlashCommands.all(home: home, projectDir: proj)
        let pr = try XCTUnwrap(all.first { $0.name == "git:pr" })
        XCTAssertEqual(pr.detail, "Сводка PR")
        XCTAssertEqual(pr.source, .user)
        let deploy = try XCTUnwrap(all.first { $0.name == "deploy" })
        XCTAssertEqual(deploy.detail, "Первая строка тела")
        XCTAssertEqual(deploy.source, .project)
        XCTAssertNil(all.first { $0.name == "notes" })
        XCTAssertNotNil(all.first { $0.name == "compact" }, "встроенные остаются")
    }

    func testProjectCommandOverridesBuiltinWithSameName() throws {
        let proj = tmp()
        try FileManager.default.createDirectory(atPath: proj + "/.claude/commands", withIntermediateDirectories: true)
        try "---\ndescription: свой\n---\n".write(toFile: proj + "/.claude/commands/review.md", atomically: true, encoding: .utf8)
        let all = SlashCommands.all(home: tmp(), projectDir: proj)
        XCTAssertEqual(all.filter { $0.name == "review" }.count, 1)
        XCTAssertEqual(all.first { $0.name == "review" }?.detail, "свой")
    }
}

final class ProjectFilesTests: XCTestCase {
    func testListSkipsServiceDirsAndFilterRanksByName() throws {
        let root = NSTemporaryDirectory() + "files-\(UUID().uuidString)"
        let fm = FileManager.default
        for d in ["Sources/App", ".git", "node_modules/x", "docs"] { try fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true) }
        for f in ["Sources/App/Main.swift", "Sources/App/Mainly.swift", "docs/main-notes.md", ".git/HEAD", "node_modules/x/main.js", "README.md"] {
            try "x".write(toFile: root + "/" + f, atomically: true, encoding: .utf8)
        }
        let files = ProjectFiles.list(root: root)
        XCTAssertEqual(files.sorted(), ["README.md", "Sources/App/Main.swift", "Sources/App/Mainly.swift", "docs/main-notes.md"])
        XCTAssertEqual(ProjectFiles.filter(files, query: "main"), ["Sources/App/Main.swift", "Sources/App/Mainly.swift", "docs/main-notes.md"],
                       "имя с запросом в начале: короче имя раньше")
        XCTAssertEqual(ProjectFiles.filter(files, query: "main").first, "Sources/App/Main.swift")
        XCTAssertEqual(ProjectFiles.filter(files, query: "app/ma").first, "Sources/App/Main.swift", "запрос по пути")
        XCTAssertTrue(ProjectFiles.filter(files, query: "zzz").isEmpty)
    }

    /// Прежний фильтр: нижний регистр каждого пути на каждый запрос и сортировка всех совпадений. Эталон порядка.
    private func reference(_ files: [String], _ query: String, limit: Int = 8) -> [String] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(files.sorted { ($0.count, $0) < ($1.count, $1) }.prefix(limit)) }
        var scored: [(Int, String)] = []
        for f in files {
            let lower = f.lowercased()
            let name = (lower as NSString).lastPathComponent
            let score: Int
            if name.hasPrefix(q) { score = 0 } else if name.contains(q) { score = 1 } else if lower.contains(q) { score = 2 } else { continue }
            scored.append((score * 100_000 + name.count * 100 + min(f.count, 99), f))
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(limit).map(\.1)
    }

    /// 20 тыс. путей — потолок дерева: индекс даёт тот же порядок, что прежний фильтр, и считается быстрее.
    func testIndexOnLargeListMatchesReferenceOrder() {
        var files: [String] = []
        let dirs = ["Sources/App", "Sources/Core/Util", "Tests/CoreTests", "docs/guides", "Ресурсы/Шрифты", "web/components"]
        for i in 0..<20_000 {
            let d = dirs[i % dirs.count]
            let ext = ["swift", "md", "ts", "json"][i % 4]
            files.append("\(d)/\(["Main", "Composer", "Suggest", "View", "Отчёт", "index"][(i / 7) % 6])\(i).\(ext)")
        }
        files += ["Sources/App/main.swift", "README.md", "Ресурсы/Шрифты/Йота.txt"]
        let index = FileIndex(files)
        XCTAssertEqual(index.count, files.count)
        for q in ["", "m", "main", "comp", "COMPOSER1", "core/util", "s/app/ma", "отчёт", "Йо", "1999", ".md", "zzz", "/"] {
            XCTAssertEqual(ProjectFiles.filter(index, query: q), reference(files, q), "запрос «\(q)»")
        }
        let t0 = Date()
        for q in ["m", "co", "comp", "compo", "compos"] { _ = ProjectFiles.filter(index, query: q) }
        let indexed = Date().timeIntervalSince(t0) / 5
        let t1 = Date()
        for q in ["m", "co", "comp", "compo", "compos"] { _ = reference(files, q) }
        let old = Date().timeIntervalSince(t1) / 5
        print(String(format: "ProjectFiles.filter на 20 тыс. путей: индекс %.1f мс, прежний фильтр %.1f мс на запрос", indexed * 1000, old * 1000))
    }

    func testIgnoredPathsAreServiceAndHidden() {
        XCTAssertTrue(ProjectFiles.isIgnored(relative: ".git/index"))
        XCTAssertTrue(ProjectFiles.isIgnored(relative: "app/.build/debug/x.o"))
        XCTAssertTrue(ProjectFiles.isIgnored(relative: "web/node_modules/a/b.js"))
        XCTAssertTrue(ProjectFiles.isIgnored(relative: "src/.hidden.swift"))
        XCTAssertFalse(ProjectFiles.isIgnored(relative: "src/Main.swift"))
        XCTAssertFalse(ProjectFiles.isIgnored(relative: "builder/Main.swift"))
    }
}

final class InputHistoryTests: XCTestCase {
    func testUpInEmptyFieldBrowsesNewestFirstAndDownReturnsToDraft() {
        var h = InputHistory()
        h.reload(["первое", "второе", "третье"])
        XCTAssertNil(h.up(current: "набираю"), "в непустом поле ↑ историю не листает")
        XCTAssertEqual(h.up(current: ""), "третье")
        XCTAssertEqual(h.up(current: "третье"), "второе")
        XCTAssertEqual(h.up(current: "второе"), "первое")
        XCTAssertNil(h.up(current: "первое"), "дальше начала не уходим")
        XCTAssertEqual(h.down(current: "первое"), "второе")
        XCTAssertEqual(h.down(current: "второе"), "третье")
        XCTAssertEqual(h.down(current: "третье"), "", "с последней записи — обратно в пустое поле")
        XCTAssertNil(h.down(current: ""))
    }

    func testEditedEntryStopsBrowsingAndRepeatsCollapse() {
        var h = InputHistory()
        h.reload(["а", "а", "б", "", "  "])
        XCTAssertEqual(h.entries, ["а", "б"])
        XCTAssertEqual(h.up(current: ""), "б")
        XCTAssertNil(h.up(current: "б правка"), "запись изменили — это уже набранный текст")
        XCTAssertFalse(h.isBrowsing("б правка"))
    }
}

@MainActor
final class ComposerSuggestTests: XCTestCase {
    private func make() -> ComposerSuggest {
        let s = ComposerSuggest()
        s.configure(root: nil, home: NSTemporaryDirectory() + "no-home-\(UUID().uuidString)")
        return s
    }

    func testSlashListAcceptAndEscape() throws {
        let s = make()
        s.update(text: "/com", cursor: 4)
        XCTAssertTrue(s.isOpen)
        XCTAssertEqual(s.items.first?.title, "/compact")
        let r = try XCTUnwrap(s.accept())
        XCTAssertEqual(r.text, "/compact ")
        XCTAssertEqual(r.cursor, 9)

        s.dismiss()
        XCTAssertFalse(s.isOpen)
        s.update(text: "/com", cursor: 4)
        XCTAssertFalse(s.isOpen, "после Esc тот же запрос список не открывает")
        s.update(text: "/comp", cursor: 5)
        XCTAssertTrue(s.isOpen, "изменили запрос — список снова")
        s.update(text: "обычный текст", cursor: 5)
        XCTAssertFalse(s.isOpen)
    }

    func testMoveWrapsAndExactCommandSubmits() {
        let s = make()
        s.update(text: "/", cursor: 1)
        let n = s.items.count
        XCTAssertEqual(n, s.maxItems)
        s.move(-1)
        XCTAssertEqual(s.selected, n - 1)
        s.move(1)
        XCTAssertEqual(s.selected, 0)
        s.update(text: "/compact", cursor: 8)
        XCTAssertTrue(s.typedExactCommand)
        s.update(text: "/compa", cursor: 6)
        XCTAssertFalse(s.typedExactCommand)
    }

    func testMentionInsertsPathInPlaceKeepingTail() async throws {
        let root = NSTemporaryDirectory() + "sug-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/src/Composer.swift", atomically: true, encoding: .utf8)
        let s = ComposerSuggest()
        s.configure(root: root, home: NSTemporaryDirectory() + "no-home-\(UUID().uuidString)")
        let text = "посмотри @comp и скажи"
        s.update(text: text, cursor: 14)
        for _ in 0..<50 where !s.isOpen {                    // дерево файлов читается в фоне
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(s.items.first?.id, "@src/Composer.swift")
        let r = try XCTUnwrap(s.accept())
        XCTAssertEqual(r.text, "посмотри @src/Composer.swift и скажи")
        XCTAssertEqual(r.cursor, 9 + "@src/Composer.swift ".count, "курсор после пробела, который уже стоял")
    }

    private func project(_ files: [String]) throws -> String {
        let root = NSTemporaryDirectory() + "sug-\(UUID().uuidString)"
        for f in files {
            try FileManager.default.createDirectory(atPath: (root + "/" + f as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try "x".write(toFile: root + "/" + f, atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return root
    }

    private func suggest(_ root: String) -> ComposerSuggest {
        let s = ComposerSuggest()
        s.configure(root: root, home: NSTemporaryDirectory() + "no-home-\(UUID().uuidString)")
        return s
    }

    /// Ждём по факту, а не по таймеру: под нагрузкой фон и FSEvents запаздывают.
    private func wait(_ what: String, timeout: TimeInterval = 10, _ cond: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > end { XCTFail("не дождались: \(what)"); return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func ids(_ s: ComposerSuggest) -> [String] { s.items.map(\.id) }

    func testSameTextAndCursorDoNotRefilter() async throws {
        let s = suggest(try project(["src/Composer.swift", "src/Main.swift"]))
        s.update(text: "@co", cursor: 3)
        try await wait("список файлов") { s.isOpen }
        let runs = s.fileFilterRuns
        s.update(text: "@co", cursor: 3)                  // правка и сдвиг курсора приходят от поля парой
        s.update(text: "@co", cursor: 3)
        XCTAssertEqual(s.fileFilterRuns, runs, "та же пара «текст, курсор» не пересчитывается")
        s.update(text: "@com", cursor: 4)
        XCTAssertEqual(s.fileFilterRuns, runs + 1)
    }

    func testLatestQueryWinsOverLateAnswer() async throws {
        let s = suggest(try project(["src/Alpha.swift", "src/Beta.swift"]))
        s.update(text: "@a", cursor: 2)
        try await wait("список файлов") { s.isOpen }
        s.update(text: "@al", cursor: 3)
        s.update(text: "@be", cursor: 3)
        try await wait("ответ на последний запрос") { ids(s) == ["@src/Beta.swift"] }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(ids(s), ["@src/Beta.swift"], "опоздавший ответ на «@al» список не перезаписал")
        s.update(text: "@be ", cursor: 4)
        XCTAssertFalse(s.isOpen, "пробел закрывает список сразу")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(s.isOpen)
    }

    /// Enter или Tab сразу после символа, до ответа фильтра: подставляется только путь с текущим запросом,
    /// а если такого в прежнем списке нет — список закрыт и Enter уходит как обычный ввод.
    func testEnterBeforeFilterAnswerTakesOnlyMatchingPath() async throws {
        let s = suggest(try project(["src/Alpha.swift", "src/Alpine.swift", "src/Beta.swift", "src/Albatross.swift"]))
        s.update(text: "@a", cursor: 2)
        try await wait("список файлов") { ids(s).count == 4 }
        s.move(1)
        XCTAssertEqual(s.items[s.selected].id, "@src/Alpine.swift", "имя с «a» в начале, короче — раньше")

        // Следующие вызовы идут без ожидания: фоновый ответ на главный поток прийти не успевает.
        s.update(text: "@alp", cursor: 4)
        XCTAssertEqual(ids(s).sorted(), ["@src/Alpha.swift", "@src/Alpine.swift"], "прежний список сужен до путей с «alp»")
        XCTAssertTrue(ids(s).allSatisfy { $0.lowercased().contains("alp") })
        XCTAssertEqual(s.items[s.selected].id, "@src/Alpine.swift", "уцелевший выбранный пункт остаётся выбранным")
        XCTAssertEqual(s.accept()?.text, "@src/Alpine.swift ", "Enter подставляет выбранный подходящий путь")

        s.update(text: "@alpz", cursor: 5)
        XCTAssertFalse(s.isOpen, "ничего не подходит: список закрыт, Enter — обычный ввод")
        XCTAssertNil(s.accept())

        s.update(text: "@alp", cursor: 4)
        try await wait("ответ фильтра") { ids(s) == ["@src/Alpha.swift", "@src/Alpine.swift"] }
    }

    /// Файл, созданный после первой «@», предлагается без перезапуска; удалённый — пропадает.
    func testFileListFollowsFSEvents() async throws {
        let root = try project(["src/Composer.swift", "src/Main.swift"])
        let s = suggest(root)
        s.update(text: "@comp", cursor: 5)
        try await wait("список файлов") { ids(s) == ["@src/Composer.swift"] }

        try "x".write(toFile: root + "/src/Compass.swift", atomically: true, encoding: .utf8)
        try await wait("новый файл в подсказке") { ids(s).contains("@src/Compass.swift") }
        XCTAssertEqual(ids(s), ["@src/Compass.swift", "@src/Composer.swift"])

        try FileManager.default.removeItem(atPath: root + "/src/Composer.swift")
        try await wait("удалённый файл ушёл из подсказки") { ids(s) == ["@src/Compass.swift"] }

        try FileManager.default.createDirectory(atPath: root + "/lib", withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: root + "/src", toPath: root + "/lib/src")
        try await wait("каталог переименован") { ids(s) == ["@lib/src/Compass.swift"] }
    }

    func testServiceDirsAndContentEditsDoNotReloadTree() async throws {
        let root = try project(["src/Composer.swift", ".git/HEAD"])
        let s = suggest(root)
        s.update(text: "@comp", cursor: 5)
        try await wait("список файлов") { s.isOpen }
        let loads = s.fileLoads
        try FileManager.default.createDirectory(atPath: root + "/.build/debug", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/.build/debug/Composer2.swift", atomically: false, encoding: .utf8)
        try "y".write(toFile: root + "/.git/HEAD", atomically: false, encoding: .utf8)
        try "правка".write(toFile: root + "/src/Composer.swift", atomically: false, encoding: .utf8)
        // Контрольное событие после шумных: когда новый файл виден, шумные события FSEvents уже доставлены.
        try "x".write(toFile: root + "/src/Comparator.swift", atomically: false, encoding: .utf8)
        try await wait("контрольный файл") { ids(s).contains("@src/Comparator.swift") }
        XCTAssertEqual(s.fileLoads, loads + 1, "дерево перечитано только ради нового файла")
        XCTAssertFalse(ids(s).contains { $0.contains(".build") })
    }
}
