import XCTest
@testable import Blackbird

/// NSAccessibility coverage for `TerminalView`. Three guarantees we pin here:
///
///  1. The view reports itself as `NSAccessibilityStaticText` with the
///     "Terminal" label, so VoiceOver picks it up immediately without
///     needing an explicit element walk.
///  2. `accessibilityValue()` lines up with the grid — visible rows joined
///     by `\n`, trailing whitespace stripped per row (matches the shape the
///     screen-reader expects), empty rows preserved so structure survives.
///  3. The per-snapshot cache actually short-circuits: hammering
///     `accessibilityValue()` against the same snapshot must not walk the
///     grid more than once.
final class AccessibilityTests: XCTestCase {

    func testStaticTextRole() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .staticText)
        XCTAssertEqual(view.accessibilityLabel(), "Terminal")
    }

    func testAccessibilityValueReflectsGrid() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["hello   ", "world   ", "        "])
        // Trailing whitespace stripped per row, rows joined with \n,
        // fully-blank rows kept as empty entries so layout structure
        // survives in the readout.
        XCTAssertEqual(view.accessibilityValue() as? String,
                       "hello\nworld\n")
    }

    func testValueCachesPerSnapshotGeneration() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        view.installSnapshotForTests(rows: ["one"])
        _ = view.accessibilityValue()
        let before = view.accessibilityCacheStatsForTests.computations
        for _ in 0..<100 { _ = view.accessibilityValue() }
        let after = view.accessibilityCacheStatsForTests.computations
        XCTAssertEqual(before, after, "cache must not recompute on same snap")
    }
}
