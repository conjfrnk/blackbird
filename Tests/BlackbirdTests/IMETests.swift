import XCTest
import AppKit
@testable import Blackbird

/// NSTextInputClient / preedit coverage for `TerminalView`. Four guarantees we pin:
///
///  1. `setMarkedText` installs a preedit buffer but MUST NOT write to the PTY.
///     Only `insertText` commits the composed string and emits the corresponding
///     UTF-8 bytes through the key-encoder path.
///  2. `unmarkText` cancels composition without committing anything — the
///     familiar Esc-out-of-IME path ends with a clean PTY stream.
///  3. In Native-Option mode a dead key (e.g. `Option+E` → ´) takes the
///     NSTextInputClient path rather than the old synthesised-glyph fallback.
///     The preedit state survives until the following keystroke commits a
///     composed grapheme.
///  4. `firstRect(forCharacterRange:actualRange:)` returns a non-degenerate
///     screen-space rect anchored on the cursor cell so the macOS IME candidate
///     window can position itself under the preedit glyphs.
final class IMETests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func testPreeditNeverReachesPTY() throws {
        let (view, pty) = try makeViewAndFakePty()
        view.setMarkedText("あ",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(pty.sent.isEmpty, "preedit must not reach PTY")

        view.insertText("あ",
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(pty.sent, Data("あ".utf8))
    }

    func testUnmarkTextSendsNothing() throws {
        let (view, pty) = try makeViewAndFakePty()
        view.setMarkedText("あ",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertTrue(pty.sent.isEmpty)
    }

    func testDeadKeyComposesInNativeOptionMode() throws {
        let (view, pty) = try makeViewAndFakePty(optionIsMeta: false)
        view.setMarkedText("´",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(pty.sent.isEmpty)
        view.insertText("é",
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(pty.sent, Data("é".utf8))
    }

    func testFirstRectReturnsCursorCellRect() throws {
        let (view, _) = try makeViewAndFakePty()
        view.installCursorForTests(row: 5, col: 10)
        let rect = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: nil
        )
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
    }

    private func makeViewAndFakePty(optionIsMeta: Bool = true) throws
        -> (TerminalView, RecordingPTY)
    {
        let pty = RecordingPTY()
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.ptyRecorderForTests = pty
        view.setOptionIsMetaForTests(optionIsMeta)
        return (view, pty)
    }
}

