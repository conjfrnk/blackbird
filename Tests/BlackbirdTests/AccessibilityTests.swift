import XCTest
@testable import Blackbird

/// NSAccessibility coverage for `TerminalView`. The contract is:
///
///  1. Role is `.textArea` (promoted from `.staticText` in v0.2 / F-S5-021)
///     so VoiceOver navigates by line / word / character. Label remains
///     "Terminal".
///  2. `accessibilityValue()` lines up with the grid — visible rows joined
///     by `\n`, trailing whitespace stripped per row, empty rows preserved
///     so layout structure survives.
///  3. The per-snapshot value cache short-circuits repeat reads.
///  4. `.textArea` accessors (number of characters, range-for-line,
///     line-for-index, range-for-index, string-for-range, visible-range,
///     frame-for-range) match VO's expectations and stay consistent across
///     identity changes.
///  5. The selection getter returns the empty range and the setter is a
///     no-op — `Selection`'s rectangular grid model can't be expressed as
///     a single character range without per-cell metrics that v0.2 doesn't
///     ship.
///
/// Memory pre-flight: every test below operates on small synthetic grids
/// (≤ 1 KB total characters across all rows). Wall time per test ≤ 50 ms.
final class AccessibilityTests: XCTestCase {

    // MARK: - Role / label

    func testRoleIsTextArea() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea,
                       "v0.2 promoted from .staticText to .textArea so VO can navigate (F-S5-021)")
        XCTAssertEqual(view.accessibilityLabel(), "Terminal")
    }

    // MARK: - Value cache (existing contract, unchanged)

    func testAccessibilityValueReflectsGrid() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["hello   ", "world   ", "        "])
        XCTAssertEqual(view.accessibilityValue() as? String,
                       "hello\nworld\n",
                       "trailing whitespace stripped per row, rows joined with \\n, blank rows preserved")
    }

    func testValueCachesPerSnapshotGeneration() throws {
        // Memory: <1 KB. Wall: ~10 ms (100 iterations of cache lookup).
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["one"])
        _ = view.accessibilityValue()
        let before = view.accessibilityCacheStatsForTests.computations
        for _ in 0..<100 { _ = view.accessibilityValue() }
        let after = view.accessibilityCacheStatsForTests.computations
        XCTAssertEqual(before, after, "cache must not recompute on same snapshot identity")
    }

    // MARK: - Number of characters / visible range

    func testNumberOfCharactersMatchesValue() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc", "def"])
        let value = (view.accessibilityValue() as? String) ?? ""
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), value.utf16.count)
    }

    func testVisibleCharacterRangeIsFullValue() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["x"])
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(),
                       NSRange(location: 0, length: 1))
    }

    func testNumberOfCharactersZeroOnEmptySnapshot() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: [""])
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), 0)
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(),
                       NSRange(location: 0, length: 0))
    }

    // MARK: - String for range

    func testStringForFullRange() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc", "def"])
        // value = "abc\ndef" (length 7).
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 0, length: 7)),
                       "abc\ndef")
    }

    func testStringForFirstWord() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["alpha bravo", "charlie"])
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 0, length: 5)),
                       "alpha")
    }

    func testStringForOutOfBoundsRangeReturnsNil() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        // Past the end — must return nil rather than crash.
        XCTAssertNil(view.accessibilityString(for: NSRange(location: 10, length: 5)))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: 0, length: 100)))
    }

    // MARK: - Range for line

    func testRangeForLineFirst() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa", "bb", "cc"])
        // value = "aa\nbb\ncc"; line 0 = "aa" at offset 0 length 2.
        XCTAssertEqual(view.accessibilityRange(forLine: 0),
                       NSRange(location: 0, length: 2))
    }

    func testRangeForLineSecondExcludesNewline() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa", "bb", "cc"])
        // value = "aa\nbb\ncc"; line 1 = "bb" at offset 3 length 2.
        XCTAssertEqual(view.accessibilityRange(forLine: 1),
                       NSRange(location: 3, length: 2))
    }

    func testRangeForLineLast() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa", "bb"])
        // value = "aa\nbb"; line 1 = "bb" at offset 3 length 2.
        XCTAssertEqual(view.accessibilityRange(forLine: 1),
                       NSRange(location: 3, length: 2))
    }

    func testRangeForLineOutOfRangeReturnsNotFound() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa"])
        let r = view.accessibilityRange(forLine: 7)
        XCTAssertEqual(r.location, NSNotFound,
                       "out-of-range line must return {NSNotFound, 0} (NSTextView contract)")
    }

    // MARK: - Line for index

    func testLineForIndexInFirstLine() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aaa", "bbb"])
        // value = "aaa\nbbb". index 0, 1, 2 → line 0.
        XCTAssertEqual(view.accessibilityLine(for: 0), 0)
        XCTAssertEqual(view.accessibilityLine(for: 2), 0)
    }

    func testLineForIndexInSecondLine() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa", "bb"])
        // value = "aa\nbb". index 4 = 'b' on line 1.
        XCTAssertEqual(view.accessibilityLine(for: 4), 1)
    }

    func testLineForIndexClampsToLastLine() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa", "bb"])
        // index past end clamps to the last valid line.
        XCTAssertEqual(view.accessibilityLine(for: 99), 1)
    }

    // MARK: - Range for index

    func testRangeForIndexSingleCharacter() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        XCTAssertEqual(view.accessibilityRange(for: 0),
                       NSRange(location: 0, length: 1))
        XCTAssertEqual(view.accessibilityRange(for: 2),
                       NSRange(location: 2, length: 1))
    }

    func testRangeForIndexOutOfRangeReturnsNotFound() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["a"])
        XCTAssertEqual(view.accessibilityRange(for: 10).location, NSNotFound)
        XCTAssertEqual(view.accessibilityRange(for: -1).location, NSNotFound)
    }

    // MARK: - Frame for range (smoke — full impl pinned in v1.0)

    func testFrameForRangeIsZeroWhenNotInWindow() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        // Headless test view has no window, so the frame falls back to .zero.
        XCTAssertEqual(view.accessibilityFrame(for: NSRange(location: 0, length: 1)),
                       .zero)
    }

    // MARK: - Boundary cases for accessibilityString(for:)

    func testStringForRangeAtEndIsEmptyString() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // {location: count, length: 0} is the canonical "insertion point at
        // end" range that NSTextView returns "" for. Pin it explicitly.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        let count = view.accessibilityNumberOfCharacters()
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: count, length: 0)),
                       "",
                       "end-of-text insertion-point range must return empty string, not nil")
    }

    func testStringForRangePastEndReturnsNil() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        let count = view.accessibilityNumberOfCharacters()
        // Length extending past end → out-of-bounds → nil.
        XCTAssertNil(view.accessibilityString(for: NSRange(location: count - 1, length: 100)))
        // Negative length → out-of-bounds → nil.
        XCTAssertNil(view.accessibilityString(for: NSRange(location: 0, length: -1)))
    }

    // MARK: - Boundary cases for accessibilityRange(forLine:)

    func testRangeForLineOnEmptyValueReturnsNotFound() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // An empty grid produces an empty value. accessibilityValue() on a
        // single-row blank snapshot returns "" — no lines exist.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: [""])
        XCTAssertEqual(view.accessibilityRange(forLine: 0).location, NSNotFound,
                       "empty value has zero lines; line 0 must be NSNotFound")
    }

    func testRangeForLineOnSingleLineNoTrailingNewline() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // value = "abc" (no trailing \n). Line 0 spans the full string;
        // no further lines.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        XCTAssertEqual(view.accessibilityRange(forLine: 0),
                       NSRange(location: 0, length: 3))
        XCTAssertEqual(view.accessibilityRange(forLine: 1).location, NSNotFound)
    }

    // MARK: - Astral-codepoint preservation (regression: emoji + CJK Ext-B)

    func testStringForRangeKeepsEmoji() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // Pre-fix `accessibilityString(for:)` used `compactMap { Unicode.Scalar($0) }`
        // which dropped UTF-16 surrogate halves, silently corrupting emoji
        // and any astral codepoint VO scrubbed across.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["a😀b"])
        let value = (view.accessibilityValue() as? String) ?? ""
        // value is "a😀b" — UTF-16: ['a', highSurr, lowSurr, 'b'] (4 units).
        let fullRange = NSRange(location: 0, length: value.utf16.count)
        XCTAssertEqual(view.accessibilityString(for: fullRange), "a😀b",
                       "astral codepoints must round-trip through accessibilityString(for:)")
        // The emoji range alone (locations 1..2) round-trips intact.
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 1, length: 2)), "😀")
    }

    // MARK: - Snapshot identity invalidates the line-offsets cache

    func testLineOffsetsInvalidateOnSnapshotChange() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        // Builds the line-offsets cache against snapshot A, swaps to B,
        // asserts that range-for-line / line-for-index reflect B and not
        // a stale A.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["aa", "bb"])
        // Build cache with A.
        XCTAssertEqual(view.accessibilityRange(forLine: 1),
                       NSRange(location: 3, length: 2))
        // Swap to B (single 7-char line).
        view.installSnapshotForTests(rows: ["xxxxxxx"])
        XCTAssertEqual(view.accessibilityRange(forLine: 0),
                       NSRange(location: 0, length: 7),
                       "line 0 must reflect snapshot B's content, not A's stale offsets")
        XCTAssertEqual(view.accessibilityRange(forLine: 1).location, NSNotFound,
                       "line 1 doesn't exist in B; must return NSNotFound, not A's stale offset")
    }

    // MARK: - Selection contract (getter empty, setter no-op)

    func testSelectedRangeIsEmpty() throws {
        // Memory: <1 KB. Wall: ~5 ms.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        XCTAssertEqual(view.accessibilitySelectedTextRange(),
                       NSRange(location: 0, length: 0),
                       "v0.2 ships getter as empty — Selection's grid model can't be expressed as a single character range cleanly")
    }

    func testSetSelectedRangeDoesNotCrashAcrossManyCalls() throws {
        // Memory: <1 KB. Wall: ~10 ms.
        // Pinning the no-op-AND-doesn't-blow-up contract: the setter is
        // documented as a no-op + one-shot log. A regression that grew
        // the setter into "let me try to mutate Selection" would surface
        // either as a crash or as an assertion violation in Selection.
        // Exercise the path 50× to also catch any one-shot latch shape
        // that accidentally re-fires (which would log spam, not crash —
        // but the log latch is process-wide, so re-firing here would
        // also fire from the prior test's log emission and isn't a
        // meaningful pin in xctest).
        TerminalView._resetSelectionSetterLogForTests()
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["abc"])
        for offset in 0..<50 {
            view.setAccessibilitySelectedTextRange(NSRange(location: offset % 4, length: 1))
        }
        // The post-condition "getter still returns empty" is vacuous
        // because the getter is hardcoded to NSRange(0, 0). Don't assert
        // it — the meaningful assertion is "we got here without
        // crashing", which XCTest implicitly checks.
    }
}
