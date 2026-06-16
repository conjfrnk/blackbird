import XCTest
@testable import Blackbird

/// Blind contract tests for multi-row soft-wrapped URL reconstruction in
/// `URLDetector.scan`.
///
/// Background: a long no-space URL that exceeds the grid width SOFT-WRAPS
/// (autowrap) across consecutive rows. The detector reconstructs the full
/// href. Historically the join walked only ONE continuation row (row →
/// row+1), truncating URLs that wrapped across 3+ rows. The contract under
/// test here joins across ALL wrapped rows — with the SAME security guards
/// applied at EVERY row boundary, not just the first:
///   - host invariance: the joined URL's host must equal the host of the
///     FIRST-row portion (what the user sees underlined).
///   - port invariance: the joined URL's port must equal the first-row
///     portion's port.
///   - structure-leader stop: if a continuation row's first character is
///     one of `?` `#` `&` `@` `;` `:`, the walk STOPS before that row.
///   - trailing-punctuation trim: `.,;:]}>'"` on the FINAL joined row is
///     trimmed.
///   - highlight stays on the first row: `endCol` is clamped to the last
///     column of the first row; only `url` carries the full joined string.
///     So these tests assert on `url.absoluteString`, `line`, `startCol`
///     and deliberately do NOT expect `endCol` to span rows.
///   - no separate continuation fragments are emitted.
///
/// Fixtures feed a no-space string into a fresh `BBTerm` on a narrow grid so
/// it wraps naturally. `"https://example.com/"` is exactly 20 chars, so on a
/// 20-col grid it fills row 0 exactly; appended path chars spill into rows 1,
/// 2, … one cell each.
///
/// Memory note: every grid here is at most 24×24 = 576 cells × ~16 B ≈ 9 KB
/// of grid state. No PTY, no scrollback. Safe.
final class URLDetectorMultiRowWrapTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build a BBSnapshot by feeding `text` into a fresh BBTerm. We favour
    /// BBTerm directly (over TerminalSession) because it's synchronous and
    /// avoids shell I/O. Defaults to a narrow 20×24 grid so no-space URLs
    /// wrap predictably for these tests.
    private func snapshot(
        from text: String,
        cols: UInt16 = 20,
        rows: UInt16 = 24
    ) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)))
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    /// Return matches sorted by (line, startCol) so tests are insensitive to
    /// any internal ordering choices beyond spec-mandated "in order"
    /// semantics.
    private func sorted(_ matches: [URLMatch]) -> [URLMatch] {
        matches.sorted { a, b in
            if a.line != b.line { return a.line < b.line }
            return a.startCol < b.startCol
        }
    }

    // MARK: - 1. Three-row path wrap (KEY TEST)

    /// A URL whose path wraps across THREE rows must reconstruct the full
    /// 55-char href into a single match. `"https://example.com/"` (20 chars)
    /// fills row 0; 35 trailing `a`s fill row 1 (20) and row 2 (15). The
    /// old two-row join truncated this at 40 chars (rows 0+1 only) — that
    /// truncation is exactly what this test forbids.
    func test_scan_threeRowPathWrap_reconstructsFullURL() throws {
        let head = "https://example.com/"           // 20 chars → fills row 0
        let path = String(repeating: "a", count: 35)  // 20 on row 1, 15 on row 2
        let full = head + path                        // 55 chars across 3 rows
        XCTAssertEqual(full.count, 55, "setup: full URL is 55 chars")

        let snap = try snapshot(from: full, cols: 20, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        XCTAssertEqual(
            matches.count, 1,
            "three-row wrapped URL must produce exactly one match, got \(matches.map { $0.url.absoluteString })"
        )
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(
            m.url.absoluteString, full,
            "three-row wrapped URL must reconstruct the full 55-char href, not stop at the 40-char two-row boundary"
        )
        XCTAssertEqual(m.line, 0, "match anchors on the first wrapped row")
        XCTAssertEqual(m.startCol, 0, "URL begins at column 0 of the first row")
    }

    // MARK: - 2. Four-row wrap (no fixed 3-row cap)

    /// A longer variant that wraps across FOUR rows, proving the walk is not
    /// capped at three rows either. `"https://example.com/"` (20) fills row
    /// 0; 60 trailing `b`s fill rows 1, 2, 3 (20 each). Total 80 chars.
    func test_scan_fourRowPathWrap_reconstructsFullURL() throws {
        let head = "https://example.com/"           // 20 chars → fills row 0
        let path = String(repeating: "b", count: 60)  // rows 1,2,3 (20 each)
        let full = head + path                        // 80 chars across 4 rows
        XCTAssertEqual(full.count, 80, "setup: full URL is 80 chars")

        let snap = try snapshot(from: full, cols: 20, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        XCTAssertEqual(
            matches.count, 1,
            "four-row wrapped URL must produce exactly one match, got \(matches.map { $0.url.absoluteString })"
        )
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(
            m.url.absoluteString, full,
            "four-row wrapped URL must reconstruct the full 80-char href — no fixed 3-row cap"
        )
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.startCol, 0)
    }

    // MARK: - 3. Host injection blocked at the first boundary

    /// A continuation that changes the host across the first row boundary
    /// must NOT be joined. On a 16-col grid, row 0 is exactly
    /// `https://good.com` (16 chars); the autowrap puts `.evil.com/path` on
    /// row 1. The visible underline is the apex `https://good.com`, so the
    /// dispatched URL must be exactly that — never the cross-host join
    /// `https://good.com.evil.com/path`.
    func test_scan_hostInjection_blockedAtFirstBoundary() throws {
        let cols: UInt16 = 16
        let full = "https://good.com.evil.com/path"
        // Row 0 is exactly the first 16 chars: "https://good.com".
        let firstRow = "https://good.com"
        XCTAssertEqual(firstRow.count, Int(cols),
                       "setup: row 0 must be exactly `https://good.com`")

        let snap = try snapshot(from: full, cols: cols, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        let m = try XCTUnwrap(
            matches.first(where: { $0.url.absoluteString.contains("good.com") }),
            "expected a match covering the visible good.com apex, got \(matches.map { $0.url.absoluteString })"
        )
        XCTAssertEqual(
            m.url.absoluteString, firstRow,
            "host-changing continuation must NOT be joined — dispatched URL must stay the visible apex"
        )
        XCTAssertEqual(
            m.url.host, "good.com",
            "joined host must equal the first-row host the user saw"
        )
    }

    // MARK: - 4. Structure-leader stops the walk

    /// When a continuation row begins with a URL-structure leader (here `?`),
    /// the walk STOPS before that row — the query the user never saw must not
    /// be spliced on. Row 0 fills with `https://example.com/` (20), row 1
    /// fills with 20×`a`, and row 2 begins `?secret=1`. The reconstructed
    /// URL is rows 0+1 only (40 chars) and must NOT contain `?secret=1`.
    func test_scan_structureLeaderQuery_stopsTheWalk() throws {
        let head = "https://example.com/"           // 20 chars → row 0
        let mid = String(repeating: "a", count: 20)   // 20 chars → row 1
        let leaked = "?secret=1"                      // row 2 (starts with `?`)
        let expected = head + mid                      // 40 chars, rows 0+1
        XCTAssertEqual(expected.count, 40, "setup: expected join is 40 chars")

        let snap = try snapshot(from: head + mid + leaked, cols: 20, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        let m = try XCTUnwrap(
            matches.first(where: { $0.url.absoluteString.contains("example.com") }),
            "expected a match covering example.com, got \(matches.map { $0.url.absoluteString })"
        )
        XCTAssertEqual(
            m.url.absoluteString, expected,
            "walk must stop before a continuation row that starts with `?`"
        )
        XCTAssertFalse(
            m.url.absoluteString.contains("?secret=1"),
            "query introduced by a structure-leader continuation must not leak into the URL"
        )
        XCTAssertNil(
            m.url.query,
            "no query component should slip in from a `?`-leading continuation row"
        )
    }

    // MARK: - 5. Regression — partial second row still joins

    /// The pre-existing two-row behavior must survive: a URL whose path
    /// spills only PARTWAY into row 1 still joins into the full href.
    /// `https://example.com/` (20) fills row 0; 10×`a` partially fills row 1.
    func test_scan_partialSecondRow_stillJoins() throws {
        let head = "https://example.com/"           // 20 chars → row 0
        let path = String(repeating: "a", count: 10)  // 10 chars → partial row 1
        let full = head + path                        // 30 chars
        XCTAssertEqual(full.count, 30, "setup: full URL is 30 chars")

        let snap = try snapshot(from: full, cols: 20, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        XCTAssertEqual(
            matches.count, 1,
            "partial-second-row wrap must produce exactly one match, got \(matches.map { $0.url.absoluteString })"
        )
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(
            m.url.absoluteString, full,
            "partial second-row continuation must still join into the full 30-char href"
        )
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.startCol, 0)
    }

    // MARK: - 6. No double-emit on the multi-row positive case

    /// The three-row positive case must yield exactly ONE match — the
    /// continuation fragments on rows 1 and 2 must NOT be emitted as
    /// separate matches.
    func test_scan_threeRowWrap_noDoubleEmit() throws {
        let head = "https://example.com/"
        let path = String(repeating: "a", count: 35)
        let full = head + path                        // 55 chars across 3 rows

        let snap = try snapshot(from: full, cols: 20, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        XCTAssertEqual(
            matches.count, 1,
            "exactly one URLMatch expected for the three-row wrap (no per-continuation-row duplicates), got \(matches.map { $0.url.absoluteString })"
        )
        let joinedCount = matches.filter { $0.url.absoluteString == full }.count
        XCTAssertEqual(
            joinedCount, 1,
            "the full joined href must appear exactly once"
        )
    }

    // MARK: - 7. Port injection blocked at a multi-row boundary

    /// Companion to the host-invariance guard: across a multi-row wrap, a
    /// continuation that introduces a port the first-row portion didn't have
    /// must be rejected. Row 0 is exactly `https://example.com` (19 chars on
    /// a 19-col grid); the continuation `:8080/admin` autowraps to row 1.
    /// The dispatched URL must stay the port-less apex.
    func test_scan_portInjection_blockedAcrossWrap() throws {
        let cols: UInt16 = 19
        let firstRow = "https://example.com"          // 19 chars → fills row 0
        XCTAssertEqual(firstRow.count, Int(cols),
                       "setup: row 0 must be exactly `https://example.com`")
        let full = firstRow + ":8080/admin"

        let snap = try snapshot(from: full, cols: cols, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        let m = try XCTUnwrap(
            matches.first(where: { $0.url.absoluteString.contains("example.com") }),
            "expected a match covering example.com, got \(matches.map { $0.url.absoluteString })"
        )
        XCTAssertEqual(
            m.url.absoluteString, firstRow,
            "wrap-join must not introduce a port the user didn't see"
        )
        XCTAssertNil(
            m.url.port,
            "no port should appear on the dispatched URL"
        )
    }

    // MARK: - 8. Trailing punctuation trimmed on the final wrapped row

    /// Trailing prose punctuation on the FINAL joined row must be trimmed
    /// before the URL is formed. Row 0 fills with `https://example.com/`
    /// (20), row 1 fills with 20×`a`, and row 2 is `bbb),` — the `),` is
    /// trailing punctuation. The reconstructed href keeps `...aaabbb` and
    /// drops the `),`.
    func test_scan_multiRowWrap_trimsTrailingPunctuation() throws {
        let head = "https://example.com/"           // 20 chars → row 0
        let mid = String(repeating: "a", count: 20)   // 20 chars → row 1
        let tail = "bbb),"                            // row 2 with trailing `),`
        let expected = head + mid + "bbb"              // 43 chars, punctuation trimmed

        let snap = try snapshot(from: head + mid + tail, cols: 20, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        let m = try XCTUnwrap(
            matches.first(where: { $0.url.absoluteString.contains("example.com") }),
            "expected a match covering example.com, got \(matches.map { $0.url.absoluteString })"
        )
        XCTAssertEqual(
            m.url.absoluteString, expected,
            "trailing `)` and `,` on the final wrapped row must be trimmed"
        )
    }

    // MARK: - 9. Visible highlight stays clamped to the first row

    /// Across a multi-row wrap, the visible highlight extent (`endCol`) stays
    /// on the FIRST row: it is clamped to that row's last column even though
    /// `url` carries the full multi-row href. Locks in the trust-display
    /// contract (underline == what the first row shows).
    func test_scan_multiRowWrap_endColClampedToFirstRow() throws {
        let cols: UInt16 = 20
        let head = "https://example.com/"           // 20 chars → fills row 0
        let path = String(repeating: "a", count: 35)  // wraps into rows 1,2
        let full = head + path

        let snap = try snapshot(from: full, cols: cols, rows: 24)
        let matches = URLDetector.scan(snapshot: snap)

        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.line, 0, "highlight anchors on the first row")
        XCTAssertEqual(
            m.endCol, Int(cols) - 1,
            "endCol must clamp to the last column of the first row, not span continuation rows"
        )
        // The full joined string still rides on `url`.
        XCTAssertEqual(m.url.absoluteString, full)
    }
}
