import XCTest

// Source-pin regression test for the ProMotion 120 Hz fix.
//
// 2026-04-19: a ProMotion 120 Hz regression was traced to
// `CAMetalLayer.maximumDrawableCount = 2` in `TerminalView.swift`. macOS's
// display-coalescer reads a 2-deep drawable pool as "this app isn't keeping
// up" and refuses to promote the compositor past 60 Hz, even with
// `preferredFramesPerSecond = 120` set on the MTKView. Bumping the pool to
// 3 (Apple's documented default; what Ghostty uses) fixes it — verified
// 8.40 ms steady-state intervals on a built-in Liquid Retina XDR.
//
// Memory file: project_blackbird_promotion_locked_60hz.md.
//
// The fix is a single-literal-int change in production code, which means a
// future "latency tweak" PR can silently regress it back to 2 with no test
// failure (there's no runtime-observable proxy short of running on a
// ProMotion panel and watching CADisplayLink intervals). This file pins
// the literal at the source level, mirroring the M4 pattern in
// PreferencesTests.swift.

final class MetalDrawableCountSourcePinTests: XCTestCase {

    /// Resolve `Sources/Blackbird/Terminal/TerminalView.swift` from
    /// `#filePath`. xcodebuild's CWD lives inside DerivedData and never
    /// contains the source tree, so a CWD-relative lookup would XCTSkip
    /// every run. Walk three components up from this file:
    /// `Tests/BlackbirdTests/MetalDrawableCountSourcePinTests.swift` →
    /// `Tests/BlackbirdTests/` → `Tests/` → repo root.
    ///
    /// FAILS LOUD on resolution failure rather than `XCTSkip`-ing —
    /// this is the most critical regression in the ProMotion fix, and
    /// a green-via-skip presents as "the pin held" when the source
    /// pin actually didn't run at all. A future CI relocation that
    /// breaks `#filePath` arithmetic should surface as a failure so
    /// the relocation gets the path-resolution fix it needs, not
    /// shipped with the regression cover silently lifted.
    ///
    /// (`PreferencesTests.swift:109-111` still uses the same
    /// XCTSkip-on-not-found pattern; that's an established convention
    /// flagged for a follow-up audit, NOT changed in this batch.)
    private static func locateTerminalViewSwift(
        file: String = #filePath
    ) throws -> URL {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Blackbird/Terminal/TerminalView.swift")
        if !FileManager.default.fileExists(atPath: url.path) {
            XCTFail(
                "TerminalView.swift not found at \(url.path) — this is a CI-environment "
                + "break (not a code break), but failing is the right signal because the "
                + "source pin is the entire point of this test. If `#filePath` arithmetic "
                + "no longer resolves the repo's source tree under your build/test runner, "
                + "fix the path resolution; do NOT downgrade this to XCTSkip — see the "
                + "rationale on `locateTerminalViewSwift`."
            )
            // Throw to short-circuit the test body without forcing a
            // bogus URL through the file readers below.
            struct LocateFailed: Error {}
            throw LocateFailed()
        }
        return url
    }

    /// Pin the literal `metalLayer.maximumDrawableCount = 3` at the
    /// source level, and assert the regression value `= 2` is not
    /// present anywhere in the file (catches a literal regression even
    /// if someone added a new line setting it to 2).
    func test_terminalView_pinsMaximumDrawableCountToThree() throws {
        let url = try Self.locateTerminalViewSwift()
        let src = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            src.contains("metalLayer.maximumDrawableCount = 3"),
            """
            ProMotion 120 Hz pin BROKEN: `metalLayer.maximumDrawableCount = 3` \
            no longer present in TerminalView.swift. This single literal is \
            the root-cause fix for the 2026-04-19 ProMotion regression — \
            macOS's display-coalescer caps the layer at 60 Hz when the \
            drawable pool is < 3, regardless of `preferredFramesPerSecond`. \
            See memory file `project_blackbird_promotion_locked_60hz.md` \
            before changing this. If you intentionally moved the assignment, \
            update this test to match the new shape.
            """
        )

        XCTAssertFalse(
            src.contains("metalLayer.maximumDrawableCount = 2"),
            """
            ProMotion 120 Hz REGRESSION: `metalLayer.maximumDrawableCount = 2` \
            found in TerminalView.swift. This was the 2026-04-19 root cause; \
            macOS's display-coalescer caps at 60 Hz with a 2-deep pool. \
            Restore the value to 3. Memory file: \
            `project_blackbird_promotion_locked_60hz.md`.
            """
        )
    }
}
