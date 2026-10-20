import XCTest
@testable import AgentTeamCore

/// Запуск процессов: срок ограничивает весь вызов, вывод не теряется и не перемешивается.
final class ShellRunTests: XCTestCase {
    func testOutputComplete() async {
        let r = await Shell.run("/bin/sh", ["-c", "i=0; while [ $i -lt 2000 ]; do echo line$i; i=$((i+1)); done; echo err >&2"])
        XCTAssertEqual(r.status, 0)
        XCTAssertFalse(r.timedOut)
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2000)
        XCTAssertEqual(lines.last, "line1999")
        XCTAssertEqual(r.stderr, "err\n")
    }

    /// Процесс вышел, а потомок унаследовал канал вывода и держит его: вызов не ждёт конца вывода дольше срока.
    func testTimeoutBoundsCallWhenChildHoldsPipe() async {
        let started = Date()
        let r = await Shell.run("/bin/sh", ["-c", "sleep 6 & echo begun; exit 0"], timeout: 1)
        XCTAssertTrue(r.timedOut, "status \(r.status) out \(String(decoding: r.stdout, as: UTF8.self)) err \(r.stderr)")
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
    }

    /// Процесс не уложился в срок: остановлен, вызов вернулся к сроку с отметкой.
    func testTimeoutStopsSlowProcess() async {
        let started = Date()
        let r = await Shell.run("/bin/sh", ["-c", "exec sleep 6"], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
    }

    func testMissingExecutable() async {
        let r = await Shell.run("/nonexistent/tool", [])
        XCTAssertEqual(r.status, -1)
        XCTAssertFalse(r.timedOut)
    }
}
