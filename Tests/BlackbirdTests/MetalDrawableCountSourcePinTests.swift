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

    /// Pin the rationale comment so a future refactor that strips the
    /// "why" also trips a test. We don't pin exact whitespace or line
    /// breaks — just the load-bearing substrings ("ProMotion" or
    /// "120 Hz", plus "maximumDrawableCount = 3") inside the doc-comment
    /// block immediately above `public final class TerminalView`.
    func test_terminalView_promotionRationaleCommentIsPreserved() throws {
        let url = try Self.locateTerminalViewSwift()
        let src = try String(contentsOf: url, encoding: .utf8)

        // Extract the contiguous run of `///` doc-comment lines that
        // precede the class declaration. Whitespace + line breaks are
        // collapsed to single spaces so the substring checks tolerate
        // a future re-flow of the comment.
        let block = Self.extractClassDocComment(from: src)
        XCTAssertFalse(
            block.isEmpty,
            "Doc-comment block above `public final class TerminalView` not found — file shape changed; update this test."
        )
        let flat = block.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        XCTAssertTrue(
            flat.contains("ProMotion") || flat.contains("120 Hz"),
            """
            TerminalView class doc-comment no longer mentions "ProMotion" or \
            "120 Hz". This rationale is the only signal a future engineer \
            has that the `maximumDrawableCount = 3` value below is load-bearing. \
            Restore the explanation. Memory file: \
            `project_blackbird_promotion_locked_60hz.md`.
            Doc-comment found:
            \(block)
            """
        )

        XCTAssertTrue(
            flat.contains("maximumDrawableCount = 3"),
            """
            TerminalView class doc-comment no longer mentions \
            `maximumDrawableCount = 3`. This rationale is the only signal a \
            future engineer has that the 3 (vs Apple's "tune for latency" \
            advice of 2) is intentional. Restore the explanation. Memory \
            file: `project_blackbird_promotion_locked_60hz.md`.
            Doc-comment found:
            \(block)
            """
        )
    }

    /// Walk lines of `src` and return the contiguous `///` doc-comment
    /// block that immediately precedes the `public final class TerminalView`
    /// declaration. Returns `""` if the class isn't found.
    private static func extractClassDocComment(from src: String) -> String {
        let lines = src.components(separatedBy: "\n")
        guard let classIdx = lines.firstIndex(where: {
            $0.contains("public final class TerminalView")
        }) else {
            return ""
        }
        var i = classIdx - 1
        var collected: [String] = []
        while i >= 0 {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("///") {
                collected.append(trimmed)
                i -= 1
                continue
            }
            // Tolerate at most no other shape: a non-doc-comment line
            // (blank, code, `//` comment) ends the block.
            break
        }
        return collected.reversed().joined(separator: "\n")
    }
}
