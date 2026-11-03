import XCTest
import AppKit
@testable import Blackbird

/// A11Y-8 — `accessibilityString(for:)` must answer an absurdly long range
/// with `nil`, never trap.
///
/// Contract (stated by the accessor's own doc comment and pinned for the
/// non-overflowing cases by `AccessibilityTests.testStringForOutOfBoundsRangeReturnsNil`
/// and `testStringForRangePastEndReturnsNil`): a range that is not fully
/// inside `[0, accessibilityNumberOfCharacters()]` is out of bounds and the
/// answer is `nil`. `{0, 100}` on a 3-character value is `nil`; so is
/// `{0, Int.max}`. NSAccessibility clients choose the `NSRange` they send, so
/// the accessor cannot assume `location + length` fits in an `Int`.
///
/// The bug: for any `location >= 1` paired with `length == Int.max`
/// (`NSNotFound` is `Int.max` on the 64-bit-only platforms this app ships on),
/// `location + length` exceeds `Int.max`. Swift's checked arithmetic turns that
/// into a hardware trap and the whole Blackbird process (every tab, every
/// shell) dies. A third-party assistive or automation tool probing with a huge
/// length from a non-zero offset is enough to trigger it.
///
/// Why these tests fail on the buggy code: the arithmetic overflow is a
/// process-fatal trap, so the xctest host dies mid-test and xcodebuild reports
/// the run as failed ("Restarting after unexpected exit, crash, or test
/// timeout"). Each overflowing case is its own test so, once a fix lands, a
/// partial fix (say `{1, Int.max}` handled but `{count, Int.max}` not) is
/// pinpointed by name rather than hidden behind the first crash.
///
/// The control tests (`...NoOverflowControl...`, `...ValidInteriorRange...`)
/// pass before and after the fix: they pin that the fix does not turn the
/// out-of-bounds answer into a clamp and does not break well-formed
/// non-zero-offset reads.
///
/// Memory pre-flight: every test uses a two-row synthetic grid, 18 UTF-16
/// code units total; the exhaustive loops below iterate at most 18 locations
/// x 2 lengths. Wall time per test is well under 50 ms. No window, no PTY, no
/// shell, no BBTerm.
final class AccessibilityStringHugeLengthBlindTests: XCTestCase {

    /// Value is "hello world\nsecond": 11 + 1 + 6 = 18 UTF-16 code units, so
    /// offsets 1, 5, 17 and 18 are all legal locations (<= count) and
    /// `Int.max` is not a legal length at any of them.
    private static let rows: [String] = ["hello world", "second"]
    private static let expectedValue: String = "hello world\nsecond"
    private static let expectedCount: Int = 18

    /// Builds the headless view and asserts the preconditions that keep the
    /// tests from passing vacuously: if the snapshot injection silently failed
    /// the value would be empty, `location >= 1` would be past the end, and an
    /// early bounds guard would return nil without ever reaching the overflow.
    private func makeViewWithKnownValue() throws -> TerminalView {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "headless TerminalView rig must exist")
        view.installSnapshotForTests(rows: Self.rows)
        XCTAssertEqual(view.accessibilityValue() as? String, Self.expectedValue,
                       "precondition: injected grid must produce the known a11y value")
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), Self.expectedCount,
                       "precondition: location 1...18 must all be inside the value so the length is the only out-of-bounds part")
        return view
    }

    // MARK: - The trap: location >= 1, length == Int.max

    func testHugeLengthFromOffsetOneReturnsNil() throws {
        let view = try makeViewWithKnownValue()
        let range = NSRange(location: 1, length: Int.max)
        let result = view.accessibilityString(for: range)
        XCTAssertNil(result,
                     "accessibilityString(for: {1, Int.max}) must be nil (out of bounds), got \(String(describing: result))")
    }

    func testHugeLengthFromOffsetFiveReturnsNil() throws {
        let view = try makeViewWithKnownValue()
        let range = NSRange(location: 5, length: Int.max)
        let result = view.accessibilityString(for: range)
        XCTAssertNil(result,
                     "accessibilityString(for: {5, Int.max}) must be nil (out of bounds), got \(String(describing: result))")
    }

    func testNotFoundLengthFromNonZeroOffsetReturnsNil() throws {
        // NSNotFound is a common "unbounded" sentinel that automation clients
        // pass as a length. It equals Int.max on 64-bit, so it overflows the
        // same way; this test pins the intent independent of that detail.
        let view = try makeViewWithKnownValue()
        let range = NSRange(location: 3, length: NSNotFound)
        let result = view.accessibilityString(for: range)
        XCTAssertNil(result,
                     "accessibilityString(for: {3, NSNotFound=\(NSNotFound)}) must be nil (out of bounds), got \(String(describing: result))")
    }

    func testHugeLengthAtEndOfTextReturnsNil() throws {
        // location == count is the last legal location (the insertion point),
        // so it passes any "location <= count" guard and reaches the
        // overflowing addition. Length > 0 makes it out of bounds -> nil.
        let view = try makeViewWithKnownValue()
        let count = view.accessibilityNumberOfCharacters()
        let range = NSRange(location: count, length: Int.max)
        let result = view.accessibilityString(for: range)
        XCTAssertNil(result,
                     "accessibilityString(for: {\(count), Int.max}) must be nil (out of bounds), got \(String(describing: result))")
    }

    func testHugeLengthFromEveryLegalNonZeroOffsetReturnsNil() throws {
        // Exhaustive over every location in 1...count: each one overflows
        // `location + Int.max`. The first offender (if any) is named in the
        // failure message via the loop's own assertion text.
        let view = try makeViewWithKnownValue()
        let count = view.accessibilityNumberOfCharacters()
        for location in 1...count {
            let result = view.accessibilityString(for: NSRange(location: location, length: Int.max))
            XCTAssertNil(result,
                         "accessibilityString(for: {\(location), Int.max}) must be nil (out of bounds), got \(String(describing: result))")
        }
    }

    func testLengthJustOverflowingForEachOffsetReturnsNil() throws {
        // Exact overflow boundary: length = Int.max - location + 1 makes
        // location + length == Int.max + 1, i.e. the smallest overflowing sum.
        // (location >= 1 keeps the length itself a valid Int.)
        let view = try makeViewWithKnownValue()
        let count = view.accessibilityNumberOfCharacters()
        for location in 1...count {
            let length = Int.max - location + 1
            let result = view.accessibilityString(for: NSRange(location: location, length: length))
            XCTAssertNil(result,
                         "accessibilityString(for: {\(location), \(length)}) (sum = Int.max + 1) must be nil (out of bounds), got \(String(describing: result))")
        }
    }

    // MARK: - Controls that pass before and after the fix

    func testNoOverflowControlHugeLengthsReturnNil() throws {
        // Per the trigger notes, {0, Int.max} and {1, Int.max - 1} do not
        // overflow. They already return nil; the fix must keep them nil (not
        // clamp to the available text).
        let view = try makeViewWithKnownValue()
        let zeroOffset = view.accessibilityString(for: NSRange(location: 0, length: Int.max))
        XCTAssertNil(zeroOffset,
                     "accessibilityString(for: {0, Int.max}) must stay nil, got \(String(describing: zeroOffset))")
        let justUnder = view.accessibilityString(for: NSRange(location: 1, length: Int.max - 1))
        XCTAssertNil(justUnder,
                     "accessibilityString(for: {1, Int.max - 1}) must stay nil, got \(String(describing: justUnder))")
    }

    func testValidInteriorRangeFromNonZeroOffsetStillReturnsText() throws {
        // The fix must not break well-formed reads from a non-zero offset.
        let view = try makeViewWithKnownValue()
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 1, length: 4)), "ello",
                       "{1, 4} of \"hello world\\nsecond\"")
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 6, length: 5)), "world",
                       "{6, 5} of \"hello world\\nsecond\"")
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: 1, length: Self.expectedCount - 1)),
                       "ello world\nsecond",
                       "{1, count - 1} reaches exactly the end of the text and is in bounds")
        XCTAssertEqual(view.accessibilityString(for: NSRange(location: Self.expectedCount, length: 0)),
                       "",
                       "{count, 0} is the end-of-text insertion point and must stay \"\"")
    }
}
