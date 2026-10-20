import XCTest
@testable import AgentTeamCore

/// Образцы экранов — с живого claude 2.1.295; пути обезличены.
final class PermissionPromptTests: XCTestCase {
    private let rule = String(repeating: "─", count: 40)
    private let dashes = String(repeating: "╌", count: 40)

    private var permission: String {
        """
        ❯ Run the shell command: touch marker.txt
        \(rule)
         Bash command
         Create marker.txt in the working directory
        \(dashes)
         touch marker.txt && ls -l marker.txt
        \(dashes)
         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and always allow access to /work/project from
              this project
           3. Yes, and switch to auto mode
           4. No
         Esc to cancel · Tab to amend
        """
    }

    func testOptionsWrappedLabelAndHeading() throws {
        let p = try XCTUnwrap(PermissionPrompt.from(SGRParser.parse(permission)))
        XCTAssertEqual(p.question, "Do you want to proceed?")
        XCTAssertEqual(p.options.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(p.options[1].label, "Yes, and always allow access to /work/project from this project")
        XCTAssertTrue(p.options[0].selected)
        XCTAssertEqual(p.heading, "Bash command")
    }

    func testNotAPromptOnOrdinaryScreenTrustOrAskForm() {
        XCTAssertNil(PermissionPrompt.from(SGRParser.parse("⏺ Варианты:\n  1. Первый\n  2. Второй\n  Что выбрать?")))
        XCTAssertNil(PermissionPrompt.from(SGRParser.parse(" Do you trust the files in this folder?\n ❯ 1. Yes, I trust this folder\n   2. No, exit\n Esc to cancel")))
        let ask = "\(rule)\n ☐ Color\nWhich color?\n❯ 1. Red\n  2. Blue\nEnter to select · ↑/↓ to navigate · Esc to cancel"
        XCTAssertNil(PermissionPrompt.from(SGRParser.parse(ask)))
        XCTAssertTrue(AskForm.isOpen(SGRParser.parse(ask)))
        XCTAssertFalse(AskForm.isOpen(SGRParser.parse(permission)))
    }
}
