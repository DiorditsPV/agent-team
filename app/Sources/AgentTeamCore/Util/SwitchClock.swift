import Foundation
import QuartzCore

/// Замер переключения проекта: от клика до первой отрисовки панелей агентов и чата менеджера.
/// Включается параметром запуска `--timing <файл>`; без него ничего не пишет и не стоит.
@MainActor
public final class SwitchClock {
    public static let shared = SwitchClock()

    public struct Sample: Sendable {
        public var session: String
        public var label: String
        public var what: String
        public var ms: Double
    }

    public private(set) var samples: [Sample] = []
    private var path: String?
    private var started: [String: CFTimeInterval] = [:]
    private var labels: [String: String] = [:]
    private var marked: Set<String> = []

    public var enabled: Bool { path != nil }

    public func enable(logTo path: String) {
        self.path = path
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    /// Клик по проекту. `label` — что за переключение (например, «впервые» или «повторно»).
    public func begin(_ session: String, label: String) {
        guard enabled else { return }
        started[session] = CACurrentMediaTime()
        labels[session] = label
        marked = marked.filter { !$0.hasPrefix(session + "|") }
        markNow("click", session)
        mark("select", session)
    }

    /// Первая отрисовка части экрана. Время берётся после текущего прохода главного цикла: в нём SwiftUI
    /// отдаёт кадр на отрисовку.
    public func mark(_ what: String, _ session: String) {
        guard enabled, let t0 = started[session], marked.insert(session + "|" + what).inserted else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let ms = (CACurrentMediaTime() - t0) * 1000
                let s = Sample(session: session, label: self.labels[session] ?? "", what: what, ms: ms)
                self.samples.append(s)
                self.write(s)
            }
        }
    }

    /// Метка без ожидания кадра, со временем события (в том числе пойманным вне главного потока).
    public func markNow(_ what: String, _ session: String, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard enabled, let t0 = started[session], marked.insert(session + "|" + what).inserted else { return }
        let s = Sample(session: session, label: labels[session] ?? "", what: what, ms: (time - t0) * 1000)
        samples.append(s)
        write(s)
    }

    private var handle: FileHandle?

    private func write(_ s: Sample) {
        guard let path else { return }
        if handle == nil { handle = FileHandle(forWritingAtPath: path) }
        handle?.write(Data(String(format: "%@\t%@\t%@\t%.1f\n", s.session, s.label, s.what, s.ms).utf8))
    }
}
