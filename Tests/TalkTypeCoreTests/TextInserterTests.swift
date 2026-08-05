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

    func testKnownNonTextRolesReject() {
        XCTAssertFalse(TextInserter.roleAcceptsText("AXButton"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXStaticText"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXMenuItem"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXWindow"))
        XCTAssertFalse(TextInserter.roleAcceptsText("AXCheckBox"))
    }
}
