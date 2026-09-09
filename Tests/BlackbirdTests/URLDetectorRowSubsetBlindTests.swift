import XCTest
@testable import Blackbird

/// Blind behaviour tests for the `rows:` parameter of
/// `URLDetector.scan(snapshot:rows:)`.
///
/// Contract:
///   * `rows: nil` (the default) scans the whole visible grid.
///   * A non-nil set restricts the scan to those screen rows; `[]` finds
///     nothing.
///   * A URL wrapped from row N into row N+1 is reported as ONE joined match
///     when row N is scanned, and the row-N+1 fragment must never surface as
///     a separate `https://` match when only row N+1 is scanned.
///
/// The fixture is a real 80×24 `BBTerm` fed with escape-free text, so the
/// grid geometry (and the hard wrap at column 80) comes from the parser
/// rather than from the test.
///
/// Written without reading `URLDetector.swift` beyond `URLMatch` + the
/// `scan` signature.
final class URLDetectorRowSubsetBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private let cols: UInt16 = 80
    private let rows: UInt16 = 24

    private let urlA = "https://a.example/x"
    private let urlB = "https://b.example/y"

    /// Row 2 is filled exactly to its last column with the head of URL C;
    /// the tail continues on row 3.
    private let urlCHead: String = {
        let prefix = "https://c.example/"
        return prefix + String(repeating: "p", count: 80 - prefix.count)
    }()
    private let urlCTail = "qrs"
    private var urlC: String { urlCHead + urlCTail }

    /// Grid layout (80×24):
    ///   row 0: (blank)
    ///   row 1: https://a.example/x
    ///   row 2: https://c.example/ppp…p   (80 cells, pending-wrap)
    ///   row 3: qrs                       (continuation of row 2)
    ///   row 4: (blank)
    ///   row 5: https://b.example/y
    private func makeSnapshot(file: StaticString = #filePath, line: UInt = #line) throws -> BBSnapshot {
        XCTAssertEqual(urlCHead.count, Int(cols), "fixture: head must fill row 2 exactly", file: file, line: line)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)), file: file, line: line)
        // No "\r\n" between head and tail: the tail lands on row 3 via the
        // terminal's own auto-wrap, exactly as a real wrapped line would.
        term.input("\r\n" + urlA + "\r\n" + urlCHead + urlCTail + "\r\n\r\n" + urlB)
        let snap = try XCTUnwrap(term.snapshot(), file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "fixture must be at the live bottom", file: file, line: line)
        return snap
    }

    private func urls(_ matches: [URLMatch]) -> Set<String> {
        Set(matches.map { $0.url.absoluteString })
    }

    private func describe(_ matches: [URLMatch]) -> String {
        matches.map { "L\($0.line)[\($0.startCol)...\($0.endCol)] \($0.url.absoluteString)" }
            .joined(separator: "; ")
    }

    // MARK: - Fixture preconditions

    func test_precondition_fixtureRowsCarryExpectedText() throws {
        let snap = try makeSnapshot()
        let text = snap.visibleRowsAsText()
        XCTAssertEqual(text.count, Int(rows))
        XCTAssertEqual(text[1].trimmingCharacters(in: .whitespaces), urlA)
        XCTAssertEqual(text[2].trimmingCharacters(in: .whitespaces), urlCHead)
        XCTAssertEqual(text[3].trimmingCharacters(in: .whitespaces), urlCTail)
        XCTAssertEqual(text[5].trimmingCharacters(in: .whitespaces), urlB)
    }

    // MARK: - Whole-grid scans

    func test_defaultScan_findsAAndB() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertTrue(urls(matches).isSuperset(of: [urlA, urlB]), "got: \(describe(matches))")
        XCTAssertEqual(matches.filter { $0.line == 1 }.count, 1, "got: \(describe(matches))")
        XCTAssertEqual(matches.filter { $0.line == 5 }.count, 1, "got: \(describe(matches))")
    }

    func test_nilRows_isWholeGrid() throws {
        let snap = try makeSnapshot()
        let all = URLDetector.scan(snapshot: snap)
        let nilRows = URLDetector.scan(snapshot: snap, rows: nil)
        XCTAssertEqual(urls(nilRows), urls(all))
        XCTAssertTrue(urls(nilRows).isSuperset(of: [urlA, urlB]), "got: \(describe(nilRows))")
    }

    // MARK: - Row subsets

    func test_rowsFive_findsOnlyB() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap, rows: [5])
        XCTAssertEqual(matches.count, 1, "got: \(describe(matches))")
        XCTAssertEqual(matches.first?.url.absoluteString, urlB)
        XCTAssertEqual(matches.first?.line, 5)
        XCTAssertEqual(matches.first?.startCol, 0)
        XCTAssertEqual(matches.first?.endCol, urlB.count - 1)
    }

    func test_rowsOne_findsOnlyA() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap, rows: [1])
        XCTAssertEqual(matches.count, 1, "got: \(describe(matches))")
        XCTAssertEqual(matches.first?.url.absoluteString, urlA)
        XCTAssertEqual(matches.first?.line, 1)
    }

    func test_emptyRows_findsNothing() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap, rows: [])
        XCTAssertTrue(matches.isEmpty, "got: \(describe(matches))")
    }

    func test_blankRow_findsNothing() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap, rows: [0])
        XCTAssertTrue(matches.isEmpty, "got: \(describe(matches))")
    }

    // MARK: - Wrapped URL across the row 2 → 3 boundary

    func test_rowsTwo_findsJoinedWrappedURL() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap, rows: [2])
        let joined = matches.filter { $0.url.absoluteString == urlC }
        XCTAssertEqual(joined.count, 1,
                       "rows:[2] must report the wrapped URL once, joined with its row-3 tail; got: \(describe(matches))")
        XCTAssertEqual(joined.first?.line, 2, "the joined match anchors on the row where it starts")
        XCTAssertEqual(joined.first?.startCol, 0)
        // Nothing truncated: the head-only string must not be reported.
        XCTAssertFalse(urls(matches).contains(urlCHead),
                       "the row-2 head must not be reported as its own URL; got: \(describe(matches))")
    }

    func test_rowsThree_neverReportsTailFragmentAsSeparateURL() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap, rows: [3])
        // Whatever rows:[3] chooses to report (nothing, or the joined URL
        // via its neighbour), it must not manufacture an https:// match
        // out of the bare "qrs" tail, and it must not report a URL that
        // is not a complete fixture URL.
        let known: Set<String> = [urlA, urlB, urlC]
        for m in matches {
            XCTAssertTrue(known.contains(m.url.absoluteString),
                          "rows:[3] reported a non-fixture URL (fragment?): \(describe([m]))")
            XCTAssertNotEqual(m.line, 3,
                              "no match may start on row 3 — that row holds only the tail; got: \(describe([m]))")
        }
        XCTAssertFalse(matches.contains { $0.url.absoluteString.hasSuffix("://" + urlCTail) },
                       "tail fragment surfaced as a URL: \(describe(matches))")
    }

    func test_defaultScan_reportsWrappedURLExactlyOnce() throws {
        let snap = try makeSnapshot()
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.filter { $0.url.absoluteString == urlC }.count, 1,
                       "whole-grid scan must report the wrapped URL once; got: \(describe(matches))")
        XCTAssertEqual(matches.filter { $0.line == 3 }.count, 0,
                       "row 3 holds only the tail; got: \(describe(matches))")
    }

    func test_subsetResults_areSubsetOfWholeGridResults() throws {
        let snap = try makeSnapshot()
        let all = urls(URLDetector.scan(snapshot: snap))
        for rows: Set<Int> in [[1], [5], [2], [1, 5], [2, 3], [0, 4]] {
            let sub = urls(URLDetector.scan(snapshot: snap, rows: rows))
            XCTAssertTrue(sub.isSubset(of: all),
                          "rows:\(rows.sorted()) reported URLs a whole-grid scan does not: \(sub.subtracting(all))")
        }
    }
}
