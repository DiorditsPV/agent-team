import XCTest
@testable import AgentTeamCore

/// Основной репозиторий worktree по файлу `.git`: путь `gitdir` бывает абсолютным и относительным.
final class WorktreeGitdirTests: XCTestCase {
    func testAbsoluteAndRelativeGitdir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agtest-gd-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let wt = root + "/shop-wt/dev"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "gitdir: \(root)/shop/.git/worktrees/dev\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectDiscovery.mainRepo(ofWorktree: wt), root + "/shop")
        try "gitdir: ../../shop/.git/worktrees/dev\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectDiscovery.mainRepo(ofWorktree: wt).map { ($0 as NSString).standardizingPath },
                       (root as NSString).standardizingPath + "/shop")
    }
}
