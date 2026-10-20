import Foundation

/// Поиск проектов без ручного подключения: каталоги недавних сессий Claude Code.
///
/// В `~/.claude/projects/<slug>/` лежат транскрипты сессий; каждая запись несёт `cwd`. От каждой папки читается
/// только начало самого свежего файла, от его `cwd` вверх ищется `agents/team.yaml`. Сканирование запускается
/// при старте и по кнопке, без таймера.
public enum ProjectDiscovery {
    public static var claudeProjects: String { TranscriptParser.claudeHome + "/.claude/projects" }

    /// Репозитории проектов `team`, найденные по недавним сессиям; по одному на путь, в порядке свежести.
    public static func scan(root: String = claudeProjects, headBytes: Int = 64 << 10) -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var found: [(repo: String, date: Date)] = []
        var seen = Set<String>()
        for d in dirs {
            let dir = (root as NSString).appendingPathComponent(d)
            guard let (file, date) = newestTranscript(in: dir),
                  let cwd = cwd(fromHead: head(of: file, bytes: headBytes)),
                  !isClaudeServiceDir(cwd),
                  let repo = repo(containing: cwd),
                  seen.insert(repo).inserted else { continue }
            found.append((repo, date))
        }
        return found.sorted { $0.date > $1.date }.map(\.repo)
    }

    /// Каталоги самого Claude Code (фоновые задачи, временные копии) — не проекты владельца.
    static func isClaudeServiceDir(_ path: String) -> Bool {
        path.hasPrefix(NSHomeDirectory() + "/.claude/")
    }

    static func newestTranscript(in dir: String) -> (String, Date)? {
        let url = URL(fileURLWithPath: dir)
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                         options: [.skipsHiddenFiles]) else { return nil }
        var best: (String, Date)?
        for u in items where u.pathExtension == "jsonl" {
            let date = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if best == nil || date > best!.1 { best = (u.path, date) }
        }
        return best
    }

    static func head(of path: String, bytes: Int) -> Data {
        guard let fh = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: bytes)) ?? Data()
    }

    /// Первое поле `cwd` в начале транскрипта. Первые строки бывают без него (summary, снимок истории файлов),
    /// а строка может не уместиться в прочитанный кусок — поэтому поиск по тексту, а не разбор строк целиком.
    public static func cwd(fromHead data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: #""cwd"\s*:\s*"((?:[^"\\]|\\.)*)""#, options: .regularExpression) else { return nil }
        let match = String(text[r])
        guard let colon = match.firstIndex(of: ":") else { return nil }
        let literal = match[match.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        guard let value = try? JSONDecoder().decode(String.self, from: Data(literal.utf8)), value.hasPrefix("/") else { return nil }
        return value
    }

    /// Каталог проекта вверх от `cwd`: тот, где есть `agents/team.yaml`. Worktree (у него `.git` — файл)
    /// проектом не считается: это рабочая копия роли, вместо неё берётся основной репозиторий.
    public static func repo(containing cwd: String) -> String? {
        let fm = FileManager.default
        var dir = (cwd as NSString).standardizingPath
        while dir.count > 1 {
            if fm.fileExists(atPath: dir + "/agents/team.yaml") {
                guard let main = mainRepo(ofWorktree: dir) else { return dir }
                return fm.fileExists(atPath: main + "/agents/team.yaml") ? main : nil
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Основной репозиторий worktree: `.git` — файл со строкой `gitdir: <repo>/.git/worktrees/<имя>` (путь бывает
    /// и относительным).
    static func mainRepo(ofWorktree dir: String) -> String? {
        var isDir: ObjCBool = false
        let git = dir + "/.git"
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isDir), !isDir.boolValue,
              let text = try? String(contentsOfFile: git, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        // git 2.48+ с worktree.useRelativePaths пишет путь относительно каталога worktree.
        if !gitdir.hasPrefix("/") { gitdir = ((dir as NSString).appendingPathComponent(gitdir) as NSString).standardizingPath }
        guard let r = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitdir[..<r.lowerBound])
    }
}
