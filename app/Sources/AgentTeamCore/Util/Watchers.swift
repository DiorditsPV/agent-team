import CoreServices
import Foundation

/// Хвост JSONL-файла по kqueue: при старте — последние `initialBytes`, дальше — с позиции последнего чтения.
/// Неполная последняя строка ждёт следующего чтения. При замене файла (rename/delete) файл открывается заново.
public final class JSONLTail: @unchecked Sendable {
    public typealias LinesHandler = @Sendable ([Substring]) -> Void

    public let url: URL
    private let initialBytes: UInt64
    private let queue = DispatchQueue(label: "agentteam.tail")
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var onLines: LinesHandler?
    private var dirWatch: DirWatch?
    /// Файл, с которого читали (номер узла): при возобновлении другой файл читается с начала.
    private var fileID: UInt64?
    private var suspended = false

    public init(url: URL, initialBytes: UInt64 = 3 << 20) {
        self.url = url
        self.initialBytes = initialBytes
    }

    public func start(_ handler: @escaping LinesHandler) {
        queue.async {
            self.onLines = handler
            self.open(initial: true)
        }
    }

    public func stop() {
        queue.sync {
            self.onLines = nil
            self.dirWatch?.stop()
            self.dirWatch = nil
            self.close()
        }
    }

    /// Приостановка без потери места: kqueue и файл закрываются, позиция и обработчик остаются.
    public func suspend() {
        queue.sync {
            self.suspended = true
            self.dirWatch?.stop()
            self.dirWatch = nil
            self.close()
        }
    }

    /// Продолжить с места остановки: дописанное за паузу приходит одной пачкой.
    public func resume() {
        queue.async {
            guard self.suspended, self.onLines != nil else { return }
            self.suspended = false
            guard let fh = try? FileHandle(forReadingFrom: self.url) else {
                self.waitForFile(initial: self.fileID == nil)
                return
            }
            let id = Self.inode(fh)
            try? fh.close()
            if let known = self.fileID, known == id {
                self.open(initial: false, keepOffset: true)
            } else {
                self.open(initial: self.fileID == nil)
            }
        }
    }

    public var isSuspended: Bool { queue.sync { suspended } }

    private static func inode(_ fh: FileHandle) -> UInt64? {
        var st = stat()
        return fstat(fh.fileDescriptor, &st) == 0 ? UInt64(st.st_ino) : nil
    }

    deinit { source?.cancel() }

    private func open(initial: Bool, keepOffset: Bool = false) {
        close()
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            waitForFile(initial: initial)
            return
        }
        dirWatch?.stop()
        dirWatch = nil
        handle = fh
        fileID = Self.inode(fh)
        let size = (try? fh.seekToEnd()) ?? 0
        if keepOffset {
            readNew(skipFirstPartial: false)
        } else if initial {
            offset = size > initialBytes ? size - initialBytes : 0
            remainder = Data()
            let skipPartial = offset > 0
            readNew(skipFirstPartial: skipPartial)
        } else {
            offset = 0
            remainder = Data()
            readNew(skipFirstPartial: false)
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fh.fileDescriptor,
                                                            eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = src.data
            if ev.contains(.delete) || ev.contains(.rename) {
                self.open(initial: false)
            } else {
                self.readNew(skipFirstPartial: false)
            }
        }
        // Дескриптор закрывается после отмены источника, а не раньше: иначе kqueue держит закрытый fd, а номер может
        // достаться другому файлу (так же в TranscriptFollower).
        src.setCancelHandler { try? fh.close() }
        src.resume()
        source = src
    }

    /// Файла ещё нет — ждём его по kqueue на ближайшем существующем каталоге, без таймера.
    /// Появился промежуточный каталог — наблюдение переносится глубже.
    private func waitForFile(initial: Bool) {
        let dir = DirWatch.nearestExisting(url.deletingLastPathComponent().path)
        dirWatch?.stop()
        dirWatch = DirWatch(path: dir, queue: queue) { [weak self] in
            guard let self, self.handle == nil, !self.suspended else { return }
            if FileManager.default.fileExists(atPath: self.url.path) {
                self.open(initial: initial)
            } else if DirWatch.nearestExisting(self.url.deletingLastPathComponent().path) != dir {
                self.waitForFile(initial: initial)
            }
        }
    }

    private func close() {
        if let source {
            source.cancel()                 // дескриптор закроет обработчик отмены
        } else {
            try? handle?.close()
        }
        source = nil
        handle = nil
    }

    private func readNew(skipFirstPartial: Bool) {
        guard let fh = handle else { return }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset {   // файл усечён
            offset = 0
            remainder = Data()
        }
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        guard var data = try? fh.read(upToCount: Int(size - offset)) else { return }
        offset += UInt64(data.count)
        if skipFirstPartial, let nl = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: nl)...]
        }
        remainder.append(data)
        guard let lastNL = remainder.lastIndex(of: 0x0A) else { return }
        let complete = remainder[remainder.startIndex..<lastNL]
        remainder = Data(remainder[remainder.index(after: lastNL)...])
        let text = String(decoding: complete, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if !lines.isEmpty { onLines?(lines) }
    }
}

/// kqueue на каталог: срабатывает, когда в нём появляется, исчезает или переименовывается файл.
public final class DirWatch: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?

    public init(path: String, queue: DispatchQueue = .main, handler: @escaping @Sendable () -> Void) {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler(handler: handler)
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }

    /// Ближайший существующий каталог вверх по пути.
    public static func nearestExisting(_ path: String) -> String {
        var p = path
        var isDir: ObjCBool = false
        while p.count > 1, !(FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue) {
            p = (p as NSString).deletingLastPathComponent
        }
        return p
    }
}

/// Наблюдение за каталогами через FSEvents (рекурсивно, с объединением событий за `latency`).
public final class FSWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "agentteam.fsevents")
    private let lock = NSLock()
    private var _lastEventID: FSEventStreamEventId

    /// Последнее увиденное событие: новый наблюдатель с `since:` получит всё, что случилось после него.
    public var lastEventID: FSEventStreamEventId { lock.withLock { _lastEventID } }

    /// `since` — продолжить с события прежнего наблюдателя (изменения за паузу придут сразу).
    public init(paths: [String], latency: TimeInterval = 0.3, since: FSEventStreamEventId? = nil,
                handler: @escaping @Sendable ([String]) -> Void) {
        self.handler = handler
        _lastEventID = since ?? FSEventsGetCurrentEventId()
        // Поток событий держит не сам наблюдатель, а ссылку на него: колбэк на своей очереди может прийти, когда
        // наблюдатель уже освобождён с главного потока, — тогда ссылка пуста и колбэк ничего не делает.
        let ref = FSWatcherRef()
        ref.watcher = self
        var ctx = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(ref).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FSWatcherRef>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSWatcherRef>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info, let me = Unmanaged<FSWatcherRef>.fromOpaque(info).takeUnretainedValue().watcher else { return }
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            for i in 0..<count {
                // Маркер «история передана» — не изменение файла.
                if flags[i] & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 { continue }
                if i < arr.count { changed.append(arr[i]) }
            }
            if count > 0 { me.lock.withLock { me._lastEventID = max(me._lastEventID, ids[count - 1]) } }
            if !changed.isEmpty { me.handler(changed) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        let start = since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        stream = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, start, latency, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    deinit { stop() }
}

/// Слабая ссылка на наблюдатель FSEvents; её удерживает сам поток событий.
final class FSWatcherRef: @unchecked Sendable {
    weak var watcher: FSWatcher?
}

/// Ограничение частоты: не чаще одного вызова в `interval`; последний запрос не теряется.
@MainActor
public final class Throttle {
    public let interval: TimeInterval
    private var last: Date = .distantPast
    private var scheduled = false
    private let action: @MainActor () -> Void

    public init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    public func fire() {
        guard !scheduled else { return }
        let wait = interval - Date().timeIntervalSince(last)
        if wait <= 0 {
            last = Date()
            action()
        } else {
            scheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard let self else { return }
                self.scheduled = false
                self.last = Date()
                self.action()
            }
        }
    }
}
