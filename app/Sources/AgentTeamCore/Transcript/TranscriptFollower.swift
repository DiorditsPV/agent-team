import Foundation

/// Транскрипт сессии с конца файла и дальше вживую, плюс более ранние страницы по запросу.
///
/// Первая страница — последние `pageBytes` до последней целой строки; новые строки — по kqueue с запомненного
/// конца, без таймеров; `loadEarlier()` читает страницу перед самой ранней прочитанной строкой. Граница между
/// страницами — точное смещение в байтах: ни одна строка не приходит дважды и ни одна не теряется.
/// `suspend()` снимает kqueue и закрывает файл, но помнит смещения; `resume()` дочитывает то, что дописано за паузу,
/// а если файл за паузу заменили или усекли — открывает его заново.
/// `JSONLTail` для этого не годится: он не сообщает, с какого смещения начал, а дочитывать назад с перекрытием
/// нельзя — разбор склеивает соседние блоки ответа, и повторная строка задвоила бы текст.
public final class TranscriptFollower: @unchecked Sendable {
    public enum Event: Sendable {
        /// Файла нет; наблюдатель ждёт его появления.
        case waiting
        /// Файл открыт (или открыт заново после замены): последняя страница целиком.
        case opened(lines: [String], hasEarlier: Bool)
        /// Дописанные строки.
        case appended([String])
        /// Страница перед самой ранней прочитанной строкой.
        case earlier(lines: [String], hasEarlier: Bool)
    }

    public typealias Handler = @Sendable (Event) -> Void

    public let url: URL
    private let pageBytes: UInt64
    /// Размер первой страницы: у чата менеджера она больше, чтобы история ввода и сверки видели ту же глубину, что прежний хвост.
    private let firstPageBytes: UInt64
    private let queue = DispatchQueue(label: "agentteam.transcript")
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var dirWatch: DirWatch?
    private var handler: Handler?
    /// До какого байта дочитан конец файла.
    private var liveOffset: UInt64 = 0
    /// Неполная последняя строка.
    private var remainder = Data()
    /// Начало самой ранней прочитанной строки.
    private var headOffset: UInt64 = 0
    /// Файл, который открыт сейчас (устройство и inode): по нему `resume()` узнаёт, что файл за паузу заменили.
    private var fileID: FileID?
    /// Последние байты до `liveOffset`: по ним заменённый файл узнаётся как продолжение прежнего (тот же текст и
    /// дописанное), и лента не сбрасывается.
    private var mark = Data()
    private static let markBytes = 4096
    private var suspended = false

    struct FileID: Equatable { var device: UInt64; var inode: UInt64 }

    public init(url: URL, pageBytes: UInt64 = 256 << 10, firstPageBytes: UInt64? = nil) {
        self.url = url
        self.pageBytes = max(pageBytes, 1)
        self.firstPageBytes = max(firstPageBytes ?? pageBytes, 1)
    }

    /// `handler` вызывается на очереди наблюдателя, по порядку событий.
    public func start(_ handler: @escaping Handler) {
        queue.async {
            self.handler = handler
            self.open()
        }
    }

    public func loadEarlier() {
        queue.async {
            guard self.handler != nil, !self.suspended, self.handle != nil, self.headOffset > 0 else { return }
            let (lines, start) = self.lines(before: self.headOffset, page: self.pageBytes)
            self.headOffset = start
            self.handler?(.earlier(lines: lines, hasEarlier: start > 0))
        }
    }

    /// Снимает наблюдение: после возврата событий больше нет, файл закрыт.
    public func stop() {
        queue.sync {
            self.handler = nil
            self.suspended = false
            self.dirWatch?.stop()
            self.dirWatch = nil
            self.close()
        }
    }

    /// Пауза: событий нет, kqueue снят, файл закрыт; прочитанное и смещения сохраняются.
    public func suspend() {
        queue.sync {
            guard self.handler != nil, !self.suspended else { return }
            self.suspended = true
            self.dirWatch?.stop()
            self.dirWatch = nil
            self.close()
        }
    }

    /// Снятие паузы: дописанное за паузу приходит одним `.appended`. Файл заменили или усекли — `.opened` заново;
    /// файла нет — `.waiting`.
    public func resume() {
        queue.async {
            guard self.handler != nil, self.suspended else { return }
            self.suspended = false
            self.reattach()
        }
    }

    public var isSuspended: Bool { queue.sync { suspended } }

    deinit { source?.cancel() }

    private func open() {
        close()
        guard handler != nil else { return }
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            fileID = nil
            mark = Data()                   // лента сброшена — продолжать прежнее не с чего
            handler?(.waiting)
            waitForFile()
            return
        }
        dirWatch?.stop()
        dirWatch = nil
        handle = fh
        fileID = Self.identity(fh)
        let size = (try? fh.seekToEnd()) ?? 0
        let end = lastLineEnd(size: size)
        remainder = end < size ? read(end, size) : Data()
        liveOffset = size
        mark = read(size > UInt64(Self.markBytes) ? size - UInt64(Self.markBytes) : 0, size)
        let (lines, start) = lines(before: end, page: firstPageBytes)
        headOffset = start
        handler?(.opened(lines: lines, hasEarlier: start > 0))
        watch(fh)
    }

    /// После паузы: тот же файл и не короче прочитанного — дочитать хвост; иначе открыть заново.
    private func reattach() {
        guard let known = fileID, let fh = try? FileHandle(forReadingFrom: url), Self.identity(fh) == known else {
            replaced()
            return
        }
        let size = (try? fh.seekToEnd()) ?? 0
        guard size >= liveOffset else {
            try? fh.close()
            open()
            return
        }
        handle = fh
        watch(fh)
        readNew()
    }

    private static func identity(_ fh: FileHandle) -> FileID? {
        var st = stat()
        guard fstat(fh.fileDescriptor, &st) == 0 else { return nil }
        return FileID(device: UInt64(st.st_dev), inode: UInt64(st.st_ino))
    }

    private func watch(_ fh: FileHandle) {
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fh.fileDescriptor,
                                                            eventMask: [.write, .extend, .delete, .rename], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, self.handle != nil else { return }
            let ev = src.data
            if ev.contains(.delete) || ev.contains(.rename) { self.replaced() } else { self.readNew() }
        }
        // Дескриптор закрывается после отмены источника, а не раньше: иначе kqueue держит закрытый fd.
        src.setCancelHandler { try? fh.close() }
        src.resume()
        source = src
    }

    /// Файл заменили (запись через временный файл и переименование) или удалили. Новый файл, который начинается тем
    /// же текстом, — продолжение: смещения остаются, дочитывается дописанное, подгруженные страницы целы. Иначе —
    /// открытие заново (`.opened`). Файла пока нет — ждём его появления, ленту не сбрасывая.
    private func replaced() {
        guard !mark.isEmpty else { open(); return }
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            close()
            waitForFile()
            return
        }
        let size = (try? fh.seekToEnd()) ?? 0
        let k = UInt64(mark.count)
        var same = false
        if size >= liveOffset, liveOffset >= k {
            try? fh.seek(toOffset: liveOffset - k)
            same = (try? fh.read(upToCount: Int(k))) == mark
        }
        guard same else {
            try? fh.close()
            open()
            return
        }
        close()
        dirWatch?.stop()
        dirWatch = nil
        handle = fh
        fileID = Self.identity(fh)
        watch(fh)
        readNew()
    }

    private func close() {
        if let source {
            source.cancel()
        } else {
            try? handle?.close()
        }
        source = nil
        handle = nil
    }

    /// Файла ещё нет — ждём его по kqueue на ближайшем существующем каталоге.
    private func waitForFile() {
        let dir = DirWatch.nearestExisting(url.deletingLastPathComponent().path)
        dirWatch?.stop()
        dirWatch = DirWatch(path: dir, queue: queue) { [weak self] in
            guard let self, self.handler != nil, !self.suspended, self.handle == nil else { return }
            if FileManager.default.fileExists(atPath: self.url.path) {
                self.replaced()
            } else if DirWatch.nearestExisting(self.url.deletingLastPathComponent().path) != dir {
                self.waitForFile()
            }
        }
    }

    private func readNew() {
        guard let fh = handle else { return }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < liveOffset {          // файл усечён — читаем заново
            open()
            return
        }
        guard size > liveOffset else { return }
        let chunk = read(liveOffset, size)
        remainder.append(chunk)
        liveOffset = size
        mark = Data((mark + chunk).suffix(Self.markBytes))
        guard let nl = remainder.lastIndex(of: 0x0A) else { return }
        let lines = Self.split(remainder[remainder.startIndex..<nl])
        remainder = Data(remainder[remainder.index(after: nl)...])
        if !lines.isEmpty { handler?(.appended(lines)) }
    }

    /// Смещение сразу за последним переводом строки до `size` (0 — целых строк нет).
    private func lastLineEnd(size: UInt64) -> UInt64 {
        var chunk = pageBytes
        while true {
            let a = size > chunk ? size - chunk : 0
            let data = read(a, size)
            if let nl = data.lastIndex(of: 0x0A) { return a + UInt64(data.distance(from: data.startIndex, to: nl)) + 1 }
            if a == 0 { return 0 }
            chunk *= 2
        }
    }

    /// Целые строки, которые заканчиваются ровно на `end` (сразу за переводом строки), и смещение первой из них.
    /// Страница — `pageBytes`; если в неё не влезает ни одной целой строки, она растёт вдвое.
    private func lines(before end: UInt64, page: UInt64) -> ([String], UInt64) {
        guard end > 0 else { return ([], 0) }
        var chunk = page
        while true {
            let a = end > chunk ? end - chunk : 0
            let data = read(a, end)
            if a == 0 { return (Self.split(data[...]), 0) }
            // Всё до первого перевода строки — хвост более ранней строки.
            if let nl = data.firstIndex(of: 0x0A), data.index(after: nl) < data.endIndex {
                let start = a + UInt64(data.distance(from: data.startIndex, to: nl)) + 1
                return (Self.split(data[data.index(after: nl)...]), start)
            }
            chunk *= 2
        }
    }

    private func read(_ a: UInt64, _ b: UInt64) -> Data {
        guard let fh = handle, b > a else { return Data() }
        try? fh.seek(toOffset: a)
        return (try? fh.read(upToCount: Int(b - a))) ?? Data()
    }

    private static func split(_ data: Data.SubSequence) -> [String] {
        String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
