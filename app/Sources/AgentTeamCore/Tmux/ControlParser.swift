import Foundation

/// Событие потока tmux control mode.
public enum ControlEvent: Equatable, Sendable {
    /// Ответ на команду: блок `%begin … %end|%error`. `flags & 1` — команда этого клиента.
    case response(number: Int, flags: Int, ok: Bool, lines: [String])
    /// Панель что-то вывела (`%output` или `%extended-output`). Данные не разбираются как терминал —
    /// это только сигнал «панель изменилась».
    case output(pane: String)
    case pause(pane: String)
    case resumed(pane: String)
    /// Прочие уведомления: имя без `%` и аргументы через пробел.
    case notification(name: String, args: [String])
    case exit(reason: String?)
}

/// Разбор потока control mode по строкам. Поток читается байтами и режется по `\n`:
/// внутри ответа `capture-pane -e` встречаются ESC-последовательности и произвольный текст панели.
public struct ControlParser: Sendable {
    private var buffer = Data()
    private var block: (number: Int, flags: Int, lines: [String])?

    public init() {}

    public mutating func feed(_ data: Data) -> [ControlEvent] {
        buffer.append(data)
        var events: [ControlEvent] = []
        // Строки режутся проходом по буферу; обработанная часть удаляется один раз в конце.
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            var lineData = buffer[start..<nl]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            let line = String(decoding: lineData, as: UTF8.self)
            if let e = consume(line) { events.append(e) }
            start = buffer.index(after: nl)
        }
        if start > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<start) }
        return events
    }

    private mutating func consume(_ line: String) -> ControlEvent? {
        if var b = block {
            // Блок закрывает только %end/%error с тем же номером команды: строка панели
            // внутри ответа может сама начинаться с «%end».
            if let (kind, number, flags) = Self.guardLine(line), kind != "begin", number == b.number {
                block = nil
                return .response(number: number, flags: flags, ok: kind == "end", lines: b.lines)
            }
            b.lines.append(line)
            block = b
            return nil
        }
        guard line.hasPrefix("%") else { return nil }
        if let (kind, number, flags) = Self.guardLine(line), kind == "begin" {
            block = (number, flags, [])
            return nil
        }
        let body = line.dropFirst()
        let name: Substring
        let rest: Substring
        if let sp = body.firstIndex(of: " ") {
            name = body[body.startIndex..<sp]
            rest = body[body.index(after: sp)...]
        } else {
            name = body
            rest = ""
        }
        switch name {
        case "output", "extended-output":
            let pane = rest.prefix { $0 != " " }
            return .output(pane: String(pane))
        case "pause":
            return .pause(pane: String(rest))
        case "continue":
            return .resumed(pane: String(rest))
        case "exit":
            return .exit(reason: rest.isEmpty ? nil : String(rest))
        default:
            let args = rest.split(separator: " ").map(String.init)
            return .notification(name: String(name), args: args)
        }
    }

    /// `%begin|%end|%error <время> <номер> <флаги>`.
    static func guardLine(_ line: String) -> (String, Int, Int)? {
        guard line.hasPrefix("%begin ") || line.hasPrefix("%end ") || line.hasPrefix("%error ") else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 4, let number = Int(parts[2]), let flags = Int(parts[3]), Int(parts[1]) != nil else { return nil }
        return (String(parts[0].dropFirst()), number, flags)
    }
}

/// Цели команд tmux.
public enum TmuxTarget {
    /// Цель «сессия целиком»: точное имя и двоеточие после него, как у CLI (`tmuxctl._session_target`). Без двоеточия
    /// tmux читает точку в имени (проект `tmp.XXXX` из mktemp) как разделитель окна и панели и сессию не находит.
    public static func session(_ name: String) -> String { "=" + name + ":" }
}

public enum TmuxQuote {
    /// Слово для командного парсера tmux: в одинарных кавычках нет ни `$`, ни `#{}`, ни `;`.
    /// Одинарная кавычка внутри — закрыть, экранировать, открыть снова.
    /// Перевод строки завершает команду tmux даже в кавычках, поэтому \n и \r заменяются пробелом.
    public static func word(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return "'" + flat.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Восьмеричные escape-коды из `%output` (`\015`, `\134`) — в байты.
    public static func unescapeOutput(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(s.utf8)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x5C, i + 3 < bytes.count {
                let digits = bytes[(i + 1)...(i + 3)]
                if digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x37 }) {
                    let v = digits.reduce(0) { $0 * 8 + Int($1 - 0x30) }
                    out.append(UInt8(v & 0xFF))
                    i += 4
                    continue
                }
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }
}
