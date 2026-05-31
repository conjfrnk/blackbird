import XCTest
@testable import Blackbird

/// Regression for audit S3S-001: catastrophic (quadratic) backtracking in
/// the bare-email regex of `URLDetector`.
///
/// `URLDetector.scan(snapshot:)` runs on the MAIN THREAD during ⌘-hover.
/// The old email pattern used an unbounded greedy local part (`+`), so on a
/// line shaped like `x@` + a long alphanumeric run + a trailing `.` (one
/// `@`, a long run, no valid TLD) the engine re-scanned the whole run at
/// every start position looking for a viable `@`/TLD split — O(n²) per row.
/// Worse, the adversarial string contains BOTH `@` and `.`, so the cheap
/// `line.contains("@") && line.contains(".")` fast-path pre-check does NOT
/// gate it; the regex actually runs. A hostile remote that fills the visible
/// grid with such rows froze the UI for seconds.
///
/// The fix bounds the local part to `{1,64}+` (possessive) and every domain
/// label run to 63 chars, making each start position O(63) work — linear per
/// row. These tests pin that the scan stays fast AND that bounding the regex
/// didn't disable legitimate email detection.
final class URLDetectorReDoSTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build a BBSnapshot by feeding `text` into a fresh BBTerm. Synchronous,
    /// no shell I/O — mirrors `URLDetectorTests`. `cols`/`rows` default to a
    /// standard small grid; the ReDoS test overrides with a near-MAX_DIM grid.
    private func snapshot(
        from text: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)))
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    // MARK: - S3S-001 timing bound

    /// The adversarial grid: 150 rows, each a near-full 1000-col line of the
    /// form `x@` + 995 `a`s + `.` — one `@`, a long run, a trailing dot but
    /// no valid TLD. `MAX_DIM` is 1000 so this width is accepted verbatim
    /// (no clamp). 1000 × 150 ≈ 150k cells (~3-4 MB of grid state) — within
    /// the test-memory budget.
    ///
    /// A LINEAR implementation scans this grid in well under a second
    /// (~0.3 s release; inflated under the dev scheme's Debug + ASan/UBSan,
    /// but still sub-second). The old quadratic implementation took ~2.5 s+
    /// release and far more under ASan. The 3.0 s bound sits comfortably
    /// above the linear path on an instrumented/loaded runner (no false-fail)
    /// yet well below a quadratic regression (which is multiple seconds and
    /// dramatically worse under ASan). Audit S3S-001.
    func test_scan_adversarialEmailGrid_completesWithinLinearBudget() throws {
        // `MAX_DIM` (1000) is the cap; 1000 cols is accepted without clamping.
        XCTAssertEqual(BBTerm.MAX_DIM, 1000, "test assumes a 1000-col MAX_DIM grid")
        let cols: UInt16 = 1000
        let rows: UInt16 = 150
        // Each line nearly fills a 1000-col row: 2 (`x@`) + 995 (`a`) + 1 (`.`)
        // = 998 chars. `@` and `.` both present → the email fast-path does not
        // gate it, so the regex runs on every row.
        let line = "x@" + String(repeating: "a", count: 995) + "."
        let text = Array(repeating: line, count: Int(rows)).joined(separator: "\r\n")
        let snap = try snapshot(from: text, cols: cols, rows: rows)

        let start = Date()
        _ = URLDetector.scan(snapshot: snap)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(
            elapsed, 3.0,
            "scan of the S3S-001 adversarial grid took \(elapsed)s — a linear "
                + "implementation finishes well under a second; >3s indicates "
                + "the quadratic-backtracking regression has returned"
        )
    }

    // MARK: - Independent-oracle correctness

    /// Guards that the bounded/possessive regex didn't simply stop detecting
    /// real emails, and that the adversarial shape genuinely yields nothing.
    /// This is a second, non-timing signal so the suite isn't relying on a
    /// wall-clock assertion alone. Audit S3S-001.
    func test_scan_adversarialShape_yieldsNoMatches_butRealEmailStillMatches() throws {
        // (a) The adversarial line — `x@aaa….` with no valid TLD — must
        //     produce ZERO email matches. (A trailing dot with no letters
        //     after it is not a TLD.)
        let adversarial = "x@" + String(repeating: "a", count: 995) + "."
        let advSnap = try snapshot(from: adversarial, cols: 1000, rows: 4)
        let advMatches = URLDetector.scan(snapshot: advSnap)
        let advMailtos = advMatches.filter { $0.url.absoluteString.hasPrefix("mailto:") }
        XCTAssertEqual(
            advMailtos.count, 0,
            "`x@aaa….` has no valid TLD and must not match as an email, got "
                + "\(advMatches.map { $0.url.absoluteString })"
        )

        // (b) A real email in prose must still produce exactly one mailto
        //     match — proves the linear fix didn't disable email detection.
        let realSnap = try snapshot(from: "contact foo@bar.com now")
        let realMatches = URLDetector.scan(snapshot: realSnap)
        let realMailtos = realMatches.filter { $0.url.absoluteString.hasPrefix("mailto:") }
        XCTAssertEqual(
            realMailtos.count, 1,
            "expected exactly one mailto match for a real email, got "
                + "\(realMatches.map { $0.url.absoluteString })"
        )
        XCTAssertEqual(
            realMailtos.first?.url.absoluteString, "mailto:foo@bar.com",
            "the surviving match must be the real email as a mailto: URL"
        )
    }
}
