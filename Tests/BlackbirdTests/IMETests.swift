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

    // MARK: - Audit swift-tests-input F12 additions

    /// Canonical dead-key case called out in the audit: the user types
    /// Option+E (which produces the combining acute-accent preedit "e"),
    /// then commits with "é". The marked state must clear on commit and
    /// only the final composed grapheme reaches the PTY — not "e" + "é"
    /// duplicated, and not the intermediate "e" at all.
    func testInsertTextAfterMarkedTextClearsMarkedState() throws {
        let (view, pty) = try makeViewAndFakePty(optionIsMeta: false)
        view.setMarkedText("e",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(),
                      "preedit must install after setMarkedText")
        XCTAssertTrue(pty.sent.isEmpty,
                      "preedit 'e' must not reach PTY before commit")
        view.insertText("é",
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText(),
                       "commit must clear marked state")
        XCTAssertEqual(
            pty.sent, Data("é".utf8),
            "only the final composed grapheme reaches the PTY — not 'e' + 'é'"
        )
    }

    /// Multi-character composition (representative of Pinyin / Romaji IMEs):
    /// the user types several keys that form a composing buffer, then
    /// commits a different grapheme. No byte of the composing buffer may
    /// reach the PTY; only the final commit does.
    func testLongCompositionNoByteLeaksBeforeCommit() throws {
        let (view, pty) = try makeViewAndFakePty()
        // Step through a multi-key composition — each setMarkedText call
        // extends the preedit buffer. All of these must stay off the PTY.
        view.setMarkedText("n",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(pty.sent.isEmpty, "'n' preedit must not reach PTY")
        view.setMarkedText("ni",
                           selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(pty.sent.isEmpty, "'ni' preedit must not reach PTY")
        view.setMarkedText("nih",
                           selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(pty.sent.isEmpty, "'nih' preedit must not reach PTY")
        // Commit to "你" (CJK character, 3 bytes UTF-8: 0xE4 0xBD 0xA0).
        view.insertText("你",
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(
            pty.sent, Data("你".utf8),
            "only the committed grapheme reaches the PTY, not any preedit byte"
        )
    }

    /// Replacing one marked buffer with another must leave `hasMarkedText`
    /// true and still not leak any composing bytes. Corresponds to the
    /// common IME pattern where the candidate list narrows the composition
    /// and the preedit text changes in place.
    func testMarkedTextReplacementKeepsCompositionNoLeak() throws {
        let (view, pty) = try makeViewAndFakePty()
        view.setMarkedText("か",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        // Replace with a different marked buffer — candidate narrowing.
        view.setMarkedText("かん",
                           selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(),
                      "replacement must leave composition active")
        XCTAssertTrue(pty.sent.isEmpty,
                      "no preedit byte of either 'か' or 'かん' may reach PTY")
        // Empty marked-text string is the conventional "clear composition"
        // signal (see `setMarkedText` at TerminalView+IME.swift line 144).
        view.setMarkedText("",
                           selectedRange: NSRange(location: 0, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText(),
                       "empty marked-text must clear composition")
        XCTAssertTrue(pty.sent.isEmpty,
                      "clearing composition via empty marked-text must not commit")
    }

    /// `setMarkedText` accepting an `NSAttributedString` (the common case
    /// for IMEs that colour segmented clauses) must behave identically to
    /// the plain-string form. The preedit string is not sent, and a commit
    /// through `insertText(NSAttributedString, ...)` commits the plain
    /// string form.
    func testAttributedMarkedTextAndAttributedCommit() throws {
        let (view, pty) = try makeViewAndFakePty()
        let marked = NSAttributedString(
            string: "abc",
            attributes: [.markedClauseSegment: 0]
        )
        view.setMarkedText(marked,
                           selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertTrue(pty.sent.isEmpty)

        let commit = NSAttributedString(string: "ABC")
        view.insertText(commit,
                        replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(pty.sent, Data("ABC".utf8))
    }

    // MARK: - terminalCellWidth: VS-16 + keycap promotion (audit L5)

    /// `❤️` is `U+2764 U+FE0F`. The base scalar U+2764 isn't in the wide
    /// ranges, but VS-16 forces emoji presentation so the rendered grapheme
    /// occupies two cells. Without the VS-16 promotion the preedit overlay
    /// under-sizes by 50% and theme-bg leaks through the right half.
    func testTerminalCellWidth_vs16HeartIsTwo() {
        XCTAssertEqual(TerminalView.terminalCellWidth(of: "❤️"), 2)
    }

    /// `#️⃣` is `U+0023 U+FE0F U+20E3` — keycap. Neither U+0023 nor U+20E3
    /// lives in the wide ranges, so the table-only path returns 1.
    /// VS-16 + COMBINING ENCLOSING KEYCAP must promote to 2.
    func testTerminalCellWidth_keycapHashIsTwo() {
        XCTAssertEqual(TerminalView.terminalCellWidth(of: "#️⃣"), 2)
    }

    /// Plain ASCII regression — one cell.
    func testTerminalCellWidth_asciiIsOne() {
        XCTAssertEqual(TerminalView.terminalCellWidth(of: "a"), 1)
    }

    /// CJK regression — already-wide scalar (U+4E2D) must still report 2.
    /// Pins the existing wide-range path so the VS-16/keycap promotion
    /// can't accidentally regress it.
    func testTerminalCellWidth_cjkIsTwo() {
        XCTAssertEqual(TerminalView.terminalCellWidth(of: "中"), 2)
    }

    /// Regression: `characterIndex(for:)` maps a screen point to a UTF-16
    /// index inside the active composition. The previous implementation fed
    /// a finite-but-absurd or non-finite pixel coordinate straight into an
    /// unclamped `Int(Double)` cast, which traps (`SIGTRAP`) on values
    /// outside `Int`'s range or on `.infinity`/`.nan` — crashing the whole
    /// app. The sibling hit-test sites (Selection.swift,
    /// TerminalView+Mouse.swift) already clamp to a 1_000_000 pixel ceiling
    /// before any `Int(Double)`; this pins the same robustness here.
    ///
    /// The core assertion is simply that the call *returns* (does not trap)
    /// for each pathological point, and that whatever it returns is a valid
    /// index: `NSNotFound`, or `0...markedUTF16Count` (the end offset is a
    /// valid insertion point, hence the inclusive upper bound).
    ///
    /// Cost: trivially cheap — one 3-char marked string, no allocation
    /// beyond it, no real PTY session, <1 ms wall.
    func test_characterIndex_absurdOrNonFinitePoint_doesNotTrap() throws {
        let (view, _) = try makeViewAndFakePty()
        // `characterIndex(for:)` early-returns NSNotFound when the view
        // has no window (it maps the screen point via
        // `window?.convertPoint(fromScreen:)`). `makeHeadlessForTests`
        // produces a windowless view, so host it in a transient offscreen
        // window — otherwise the pathological points short-circuit at the
        // window guard and never reach the screen→cell index computation,
        // and the test would pass without exercising the cast at all.
        // No run-loop pumping and no PTY session: this is a synchronous
        // coordinate-math call. Mirrors the windowing pattern in
        // TerminalViewTests. Cost: ~50 KB transient window, <1 ms.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer {
            window.contentView = nil
            window.close()
        }
        view.installCursorForTests(row: 5, col: 10)
        view.setMarkedText("あいう",
                           selectedRange: NSRange(location: 3, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        let markedUTF16Count = "あいう".utf16.count

        // Each of these once trapped via an unclamped `Int(Double)` cast.
        // Reaching the assertion at all proves the call returned instead of
        // crashing the process — that is the regression being guarded.
        // `x` is typed CGFloat so the NSPoint init is unambiguous (CGPoint
        // has Double / CGFloat / Int initializers).
        let pathological: [(String, CGFloat)] = [
            ("finite-but-absurd +x", 1e300),
            ("+infinity x",          .infinity),
            ("finite-but-absurd -x", -1e300),
            ("nan x",                .nan),
        ]

        for (label, x) in pathological {
            let result = view.characterIndex(for: NSPoint(x: x, y: 0))
            XCTAssertTrue(
                result == NSNotFound
                    || (result >= 0 && result <= markedUTF16Count),
                "\(label): characterIndex must return a valid index "
                    + "(NSNotFound or 0...\(markedUTF16Count)), got \(result)"
            )
        }
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

