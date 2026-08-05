import XCTest
@testable import TalkTypeCore

/// The beep-suppression gate is a blacklist: only roles that definitely cannot take
/// typed text are skipped. Anything unknown must still paste — a wrong guess on a
/// self-drawn terminal would otherwise swallow the transcript.
final class TextInserterTests: XCTestCase {

    func testKnownTextRolesAccept() {
        XCTAssertTrue(TextInserter.roleAcceptsText("AXTextArea"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXTextField"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXComboBox"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXSearchField"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXWebArea"))
    }

    func testUnknownRolesAccept() {
        // Ghostty/kitty/Alacritty/WezTerm/Emacs report roles like these.
        XCTAssertTrue(TextInserter.roleAcceptsText("AXUnknown"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXGroup"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXSplitGroup"))
    }

    /// Window/table/outline/list roles look non-textual but many apps (games, Qt/Java,
    /// spreadsheets with a selected cell) accept keys while focused there — pasting must
    /// not be skipped for them.
    func testBorderlineRolesAccept() {
        XCTAssertTrue(TextInserter.roleAcceptsText("AXWindow"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXTable"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXOutline"))
        XCTAssertTrue(TextInserter.roleAcceptsText("AXList"))
    }

    func testKnownNonTextRolesReject() {
        XCTAssertFalse(TextInserter.roleAcceptsText("AXButton"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXStaticText"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXMenuItem"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXCheckBox"))
    }
}
