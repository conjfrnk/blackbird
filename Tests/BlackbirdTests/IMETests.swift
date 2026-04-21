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

    /// F1 regression: `firstRect(forCharacterRange:)` must honour a
    /// sub-range inside the marked text so the candidate popover anchors
    /// under the currently-highlighted clause, not the start of composition.
    /// A request at offset 3 should land ~3 cells to the right of offset 0.
    func testFirstRectOffsetTracksMarkedRangeLocation() throws {
        let (view, _) = try makeViewAndFakePty()
        view.installCursorForTests(row: 0, col: 0)
        view.setMarkedText("abcdef",
                           selectedRange: NSRange(location: 6, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        let base = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: 1),
            actualRange: nil
        )
        let offset = view.firstRect(
            forCharacterRange: NSRange(location: 3, length: 1),
            actualRange: nil
        )
        // Same row → same origin.y; offset request should be strictly to
        // the right of the base request by ~3 cell widths.
        XCTAssertEqual(base.origin.y, offset.origin.y, accuracy: 0.01)
        XCTAssertGreaterThan(offset.origin.x, base.origin.x)
        let cellWidth = view.metrics.cellWidth
        XCTAssertEqual(offset.origin.x - base.origin.x,
                       3 * cellWidth,
                       accuracy: 0.5)
    }

    /// F1 regression: out-of-range / sentinel requests must write
    /// NSNotFound back into `actualRange` and hand back the cursor rect.
    func testFirstRectNotFoundForOutOfRangeRequest() throws {
        let (view, _) = try makeViewAndFakePty()
        view.installCursorForTests(row: 0, col: 0)
        view.setMarkedText("abc",
                           selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: 0, length: 0)
        _ = view.firstRect(
            forCharacterRange: NSRange(location: NSNotFound, length: 0),
            actualRange: &actual
        )
        XCTAssertEqual(actual.location, NSNotFound)
        XCTAssertEqual(actual.length, 0)
    }

    /// F1 regression: `actualRange` must report the clamped range when
    /// the IME asks for "the whole marked text" with an intentionally-
    /// oversized length (common pattern: `(0, NSIntegerMax)`).
    func testFirstRectActualRangeClampsToMarkedExtent() throws {
        let (view, _) = try makeViewAndFakePty()
        view.installCursorForTests(row: 0, col: 0)
        view.setMarkedText("abcd",
                           selectedRange: NSRange(location: 4, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        var actual = NSRange(location: 0, length: 0)
        _ = view.firstRect(
            forCharacterRange: NSRange(location: 0, length: .max),
            actualRange: &actual
        )
        XCTAssertEqual(actual.location, 0)
        XCTAssertEqual(actual.length, 4)
    }

    /// F2 regression: when the hosting window resigns key the in-flight
    /// preedit must be discarded so it can't commit into the next-focused
    /// terminal after Cmd-Tab. The test exercises the production teardown
    /// path via `_testOnly_simulateWindowResignKey()` rather than
    /// synthesising an `NSWindow.didResignKeyNotification`, which the
    /// headless test host can't do reliably.
    func testCompositionClearedOnWindowResignKey() throws {
        let (view, pty) = try makeViewAndFakePty()
        view.setMarkedText("かん",
                           selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view._testOnly_simulateWindowResignKey()
        XCTAssertFalse(view.hasMarkedText(),
                       "preedit must be cleared on window resignKey")
        XCTAssertTrue(pty.sent.isEmpty,
                      "resignKey teardown must not commit into PTY")
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

