import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for: Find cannot match text that spans a
/// soft-wrapped row boundary.
///
/// Spec (observable behaviour, independent of how the scan is implemented):
///
///  - A shell line longer than the terminal width soft-wraps onto the next
///    row. The wrap is purely visual: the text is ONE logical line, the core
///    already extracts it that way (prose extraction joins WRAPLINE rows with
///    no '\n' and preserves a space that lands in the last column). Find must
///    treat it the same way: a query that straddles the right edge ("nee" on
///    row 0 + "dle" on row 1) matches "needle", in the viewport AND in
///    scrollback, with substring AND regex search.
///  - A match that begins on row R at column C is reported with
///    `line == R`, `startCol == C` (the first cell of the match). The tuple
///    `findMatches` carries no spec'd shape for the continuation on the next
///    row, so these tests only pin where the match STARTS and allow a
///    continuation segment to start at column 0 of the following wrapped
///    row(s); they additionally require that nothing else matches.
///  - Partial fragments keep matching on their own row exactly as before
///    ("nee" at (0, 37..39), "dle" at (1, 0..2)).
///  - A HARD newline is not a soft wrap: "nee" at the end of a full-width
///    row followed by CRLF and "dle" must NOT match "needle". (Control tests:
///    these pass before and after the fix and guard against a fix that
///    joins every full-width row.)
///
/// Selection oracle: highlighting a match selects it, so for the viewport
/// substring case the text under `view.selection` must be exactly the
/// query ("needle"), proving the reported match is usable end to end.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real
/// BBTerm, no PTY, no shell, no window), 40x6 grid, default scrollback.
/// Synchronous feeds; regex tests pump the main runloop (<= ~3 s worst case,
/// ~0.5 s typical) for the off-main scan to publish. Largest feed is ~15
/// short lines; memory trivial. One view + one session per test.
final class FindWrappedLineMatchBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        var fc: FindController { view.findController }
    }

    private typealias Match = (line: Int32, startCol: Int, endCol: Int)
    private typealias Pos = (line: Int32, col: Int)

    private let cols: UInt16 = 40
    private let rows: UInt16 = 6

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: rows))
        view.session = session
        view.findController.installFindBar()
        return Rig(view: view, session: session)
    }

    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    /// Feed raw text synchronously, let the asynchronous publish land, then
    /// make a fresh snapshot the view's current one.
    @discardableResult
    private func feed(_ rig: Rig, _ text: String,
                      file: StaticString = #filePath, line: UInt = #line) throws -> BBSnapshot {
        rig.session.feedBytesForTests(Data(text.utf8))
        settle(0.15)
        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        rig.view.currentSnapshot = snap
        XCTAssertEqual(snap.cols, Int(cols), "fixture: grid must be \(cols) columns wide", file: file, line: line)
        XCTAssertEqual(snap.rows, Int(rows), "fixture: grid must be \(rows) rows tall", file: file, line: line)
        return snap
    }

    private func visibleRows(_ rig: Rig) -> [String] {
        rig.view.currentSnapshot?.visibleRowsAsText() ?? []
    }

    /// Text of the buffer between two points through the core (the same
    /// call Copy uses), trailing spaces trimmed.
    private func coreText(_ rig: Rig, from: Pos, to: Pos) -> String {
        FindController.trimmingTrailingSpaces(
            rig.session.textRange(from: BufferPoint(line: from.line, col: from.col),
                                  to: BufferPoint(line: to.line, col: to.col),
                                  rectangular: false))
    }

    private func fmt(_ ms: [Match]) -> String {
        "[" + ms.prefix(12).map { "(\($0.line),\($0.startCol)-\($0.endCol))" }.joined(separator: " ")
            + (ms.count > 12 ? " ...(\(ms.count) total)" : "") + "]"
    }

    // MARK: - Searching

    /// Substring (non-regex) search, case-insensitive (the bar's default).
    private func substringSearch(_ rig: Rig, _ query: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> [Match] {
        let bar = try XCTUnwrap(rig.fc.findBar, file: file, line: line)
        XCTAssertFalse(bar.options.regex, "fixture: regex must be off for the substring path", file: file, line: line)
        XCTAssertFalse(bar.options.caseSensitive, "fixture: default is case-insensitive", file: file, line: line)
        rig.fc.performSearch(query: query)
        return rig.fc.findMatches
    }

    /// Regex search through the bar (async off-main scan); waits for the
    /// publish and returns the published matches.
    private func regexSearch(_ rig: Rig, _ query: String,
                             file: StaticString = #filePath, line: UInt = #line) throws -> [Match] {
        let fc = rig.fc
        let bar = try XCTUnwrap(fc.findBar, file: file, line: line)
        if !bar.options.regex { bar.toggleRegexMode(nil) }
        XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        bar.setQuery(query)
        pump(until: 3.0) { !fc.findMatches.isEmpty || fc.findMatchesSeq != nil }
        settle(0.3) // let any further publish land
        return fc.findMatches
    }

    // MARK: - Assertions

    /// Exactly one match starts at `start`; no match starts anywhere other
    /// than `start` or one of the allowed continuation starts.
    private func assertOneMatch(_ ms: [Match], startingAt start: Pos, continuations: [Pos] = [],
                                _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let atStart = ms.filter { $0.line == start.line && $0.startCol == start.col }
        XCTAssertEqual(atStart.count, 1,
                       "\(what): exactly one match must start at (line \(start.line), col \(start.col)); got \(fmt(ms))",
                       file: file, line: line)
        let unexpected = ms.filter { m in
            !(m.line == start.line && m.startCol == start.col)
                && !continuations.contains { $0.line == m.line && $0.col == m.startCol }
        }
        XCTAssertEqual(unexpected.count, 0,
                       "\(what): no match may start anywhere but the match start or its wrapped continuation; got \(fmt(ms))",
                       file: file, line: line)
    }

    // MARK: - Fixture sanity + the fragment behaviour that already works

    /// 40 cols: 37 'a' + "needle" = 43 cells -> row 0 = 37 a + "nee", row 1 = "dle".
    func test_fixture_wrappedLineIsOneLogicalLine_andFragmentsMatchOnTheirOwnRow() throws {
        let rig = try makeRig()
        try feed(rig, String(repeating: "a", count: 37) + "needle")

        let r = visibleRows(rig)
        XCTAssertEqual(r.first, String(repeating: "a", count: 37) + "nee",
                       "fixture: row 0 must be 37 a + 'nee' filling all 40 columns; rows=\(r.prefix(3))")
        XCTAssertTrue(r.count > 1 && r[1].hasPrefix("dle"),
                      "fixture: 'dle' must wrap onto row 1; rows=\(r.prefix(3))")
        let joined = coreText(rig, from: (0, 0), to: (1, Int(cols) - 1))
        XCTAssertEqual(joined, String(repeating: "a", count: 37) + "needle",
                       "fixture: the core must see ONE soft-wrapped logical line (no newline at the wrap)")

        // Pre-existing, must keep working after the fix.
        let nee = try substringSearch(rig, "nee")
        XCTAssertEqual(nee.map { [Int($0.line), $0.startCol, $0.endCol] }, [[0, 37, 39]],
                       "'nee' must match on row 0 cols 37-39; got \(fmt(nee))")
        let dle = try substringSearch(rig, "dle")
        XCTAssertEqual(dle.map { [Int($0.line), $0.startCol, $0.endCol] }, [[1, 0, 2]],
                       "'dle' must match on row 1 cols 0-2; got \(fmt(dle))")
    }

    // MARK: - Substring, viewport

    func test_substring_viewport_needleStraddlingWrap_isFound() throws {
        let rig = try makeRig()
        try feed(rig, String(repeating: "a", count: 37) + "needle")

        let ms = try substringSearch(rig, "needle")
        assertOneMatch(ms, startingAt: (0, 37), continuations: [(1, 0)], "substring 'needle' across the row-0/row-1 wrap")

        // The highlighted match must be exactly the query text.
        let sel = rig.view.selectedStringForServices()
        XCTAssertEqual(sel, "needle",
                       "the current match is selected; the selected text must be exactly 'needle'; selection=\(String(describing: rig.view.selection)) matches=\(fmt(ms))")
    }

    func test_substring_viewport_caseInsensitive_straddlingWrap() throws {
        let rig = try makeRig()
        try feed(rig, String(repeating: "a", count: 37) + "NEEDLE")
        let r = visibleRows(rig)
        XCTAssertEqual(r.first, String(repeating: "a", count: 37) + "NEE", "fixture: rows=\(r.prefix(3))")

        let ms = try substringSearch(rig, "needle")
        assertOneMatch(ms, startingAt: (0, 37), continuations: [(1, 0)],
                       "case-insensitive 'needle' vs 'NEEDLE' across the wrap")
    }

    /// One needle fully inside row 0 AND one straddling the wrap: both found,
    /// each exactly once, in buffer order.
    func test_substring_viewport_plainAndWrappedMatchesInOneLogicalLine_bothFound() throws {
        let rig = try makeRig()
        // "needle" (0-5) + 31 'b' (6-36) + "needle" (37-42): row 0 ends "...nee", row 1 = "dle".
        try feed(rig, "needle" + String(repeating: "b", count: 31) + "needle")
        let r = visibleRows(rig)
        XCTAssertEqual(r.first, "needle" + String(repeating: "b", count: 31) + "nee", "fixture: rows=\(r.prefix(3))")
        XCTAssertTrue(r.count > 1 && r[1].hasPrefix("dle"), "fixture: rows=\(r.prefix(3))")

        let ms = try substringSearch(rig, "needle")
        let starts = ms.filter { !($0.line == 1 && $0.startCol == 0) } // drop an optional continuation segment
        XCTAssertEqual(starts.map { [Int($0.line), $0.startCol] }, [[0, 0], [0, 37]],
                       "matches must start at the plain needle (0,0) then the wrapped one (0,37), each once, in order; got \(fmt(ms))")
    }

    /// The space sits in the LAST column of row 0 and "world" starts row 1.
    /// The core preserves that space when extracting the wrapped line, so
    /// "hello world" is on screen as one phrase and must match.
    func test_substring_viewport_spaceInLastColumnOfWrappedRow_isPartOfTheMatch() throws {
        let rig = try makeRig()
        // 34 'a' (0-33) + "hello" (34-38) + ' ' (39) | "world" row 1 cols 0-4.
        try feed(rig, String(repeating: "a", count: 34) + "hello world")
        let r = visibleRows(rig)
        XCTAssertTrue(r.count > 1 && r[1].hasPrefix("world"), "fixture: 'world' must start row 1; rows=\(r.prefix(3))")
        let joined = coreText(rig, from: (0, 0), to: (1, Int(cols) - 1))
        XCTAssertEqual(joined, String(repeating: "a", count: 34) + "hello world",
                       "fixture: the core keeps the wrap-boundary space and adds no newline")

        let ms = try substringSearch(rig, "hello world")
        assertOneMatch(ms, startingAt: (0, 34), continuations: [(1, 0)],
                       "'hello world' with the space in the last column of row 0")
    }

    /// A 100-cell logical line wraps over three rows; a 49-char query covers
    /// the end of row 0, all of row 1 and the start of row 2.
    func test_substring_viewport_matchSpanningThreeRows_isFound() throws {
        let rig = try makeRig()
        let tokens = (0..<20).map { String(format: "w%03d-", $0) } // 5 cells each, 100 total
        try feed(rig, tokens.joined())
        let r = visibleRows(rig)
        XCTAssertTrue(r.count > 2 && r[2].hasPrefix("w016-"), "fixture: three wrapped rows expected; rows=\(r.prefix(4))")

        // tokens 7...16 = cells 35..84 (minus the trailing '-'): rows 0, 1 and 2.
        let query = (7...16).map { String(format: "w%03d", $0) }.joined(separator: "-")
        let ms = try substringSearch(rig, query)
        assertOneMatch(ms, startingAt: (0, 35), continuations: [(1, 0), (2, 0)],
                       "49-char query '\(query)' spanning rows 0-2")
    }

    /// Wide char that does not fit in the last column moves, whole, to the
    /// next row (the last column keeps a spacer). "a" + "日" is adjacent text.
    func test_substring_viewport_wideCharPushedToNextRow_matchesAcrossWrap() throws {
        let rig = try makeRig()
        try feed(rig, String(repeating: "a", count: 39) + "日本")
        let r = visibleRows(rig)
        XCTAssertTrue(r.first?.hasPrefix(String(repeating: "a", count: 39)) == true,
                      "fixture: row 0 must hold 39 'a'; rows=\(r.prefix(3))")
        XCTAssertTrue(r.count > 1 && r[1].hasPrefix("日本"),
                      "fixture: the wide chars must wrap whole onto row 1; rows=\(r.prefix(3))")

        let ms = try substringSearch(rig, "a日")
        assertOneMatch(ms, startingAt: (0, 38), continuations: [(1, 0)],
                       "'a日' where the wide char wrapped to the next row")
    }

    // MARK: - Substring, scrollback

    /// Feed a logical line (no newline), a CRLF, then enough filler to push
    /// the whole line into history. Returns the buffer line of its first row.
    private func feedLineIntoHistory(_ rig: Rig, logical: String, wrappedRows: Int,
                                     file: StaticString = #filePath, line: UInt = #line) throws -> Int32 {
        var text = logical + "\r\n"
        for i in 0..<12 { text += String(format: "filler %02d\r\n", i) }
        let snap = try feed(rig, text, file: file, line: line)
        let first = -Int32(snap.historySize)
        XCTAssertLessThan(first + Int32(wrappedRows) - 1, 0,
                          "fixture: all \(wrappedRows) wrapped rows must be in scrollback (historySize=\(snap.historySize))",
                          file: file, line: line)
        let text0 = coreText(rig, from: (first, 0), to: (first + Int32(wrappedRows) - 1, Int(cols) - 1))
        XCTAssertEqual(text0, logical,
                       "fixture: the oldest history rows must be the soft-wrapped logical line, joined without a newline",
                       file: file, line: line)
        return first
    }

    func test_substring_scrollback_needleStraddlingWrap_isFound() throws {
        let rig = try makeRig()
        let first = try feedLineIntoHistory(rig, logical: String(repeating: "a", count: 37) + "needle", wrappedRows: 2)

        let ms = try substringSearch(rig, "needle")
        assertOneMatch(ms, startingAt: (first, 37), continuations: [(first + 1, 0)],
                       "scrollback substring 'needle' across the wrap (first history line \(first))")
    }

    // MARK: - Regex

    func test_regex_viewport_needleStraddlingWrap_isFound() throws {
        let rig = try makeRig()
        try feed(rig, String(repeating: "a", count: 37) + "needle")

        let ms = try regexSearch(rig, "needle")
        assertOneMatch(ms, startingAt: (0, 37), continuations: [(1, 0)], "regex 'needle' across the row-0/row-1 wrap")
    }

    /// A pattern (not a literal) whose match begins on row 0 col 0 and ends
    /// on row 1: the whole wrapped line is one match.
    func test_regex_viewport_quantifiedPatternRunningAcrossWrap_isFound() throws {
        let rig = try makeRig()
        try feed(rig, String(repeating: "a", count: 37) + "needle")

        let ms = try regexSearch(rig, "a+ne{2}dle")
        assertOneMatch(ms, startingAt: (0, 0), continuations: [(1, 0)], "regex 'a+ne{2}dle' across the wrap")
    }

    func test_regex_scrollback_needleStraddlingWrap_isFound() throws {
        let rig = try makeRig()
        let first = try feedLineIntoHistory(rig, logical: String(repeating: "a", count: 37) + "needle", wrappedRows: 2)

        let ms = try regexSearch(rig, "needle")
        assertOneMatch(ms, startingAt: (first, 37), continuations: [(first + 1, 0)],
                       "scrollback regex 'needle' across the wrap (first history line \(first))")
    }

    /// A scrollback row that is NOT soft-wrapped but whose text holds
    /// zero-width scalars: 30 cells of "e" + U+0301 (60 UTF-16 units, 30
    /// cells), then "needle" at cells 30-35. The regex scan reports a raw
    /// UTF-16 offset (60) as the start column for such a row, which exceeds
    /// the 40-column grid width even though the row never wrapped. The match
    /// must stay on its own buffer line; only the column is approximate.
    func test_regex_scrollback_unwrappedRowWithZeroWidthMarks_staysOnItsOwnLine() throws {
        let rig = try makeRig()
        let logical = String(repeating: "e\u{301}", count: 30) + "needle"
        let first = try feedLineIntoHistory(rig, logical: logical, wrappedRows: 1)
        XCTAssertGreaterThan(logical.utf16.count, Int(cols),
                             "fixture: the row's UTF-16 length must exceed the grid width")

        let ms = try regexSearch(rig, "needle")
        XCTAssertEqual(ms.count, 1, "exactly one 'needle'; got \(fmt(ms))")
        XCTAssertEqual(ms.first?.line, first,
                       "the row never wrapped, so the match is on its own buffer line (\(first)), not the next; got \(fmt(ms))")
    }

    /// Substring counterpart: its scrollback columns are Character offsets
    /// (below the grid width), so the match was always on the right line.
    func test_substring_scrollback_unwrappedRowWithZeroWidthMarks_staysOnItsOwnLine() throws {
        let rig = try makeRig()
        let logical = String(repeating: "e\u{301}", count: 30) + "needle"
        let first = try feedLineIntoHistory(rig, logical: logical, wrappedRows: 1)

        let ms = try substringSearch(rig, "needle")
        XCTAssertEqual(ms.count, 1, "exactly one 'needle'; got \(fmt(ms))")
        XCTAssertEqual(ms.first?.line, first,
                       "the row never wrapped, so the match is on its own buffer line (\(first)), not the next; got \(fmt(ms))")
    }

    // MARK: - Controls: a HARD newline is not a soft wrap (pass before AND after the fix)

    private func feedHardBreakAfterFullRow(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        // Row 0 is filled to the last column ("...nee"), then CRLF, then "dle".
        try feed(rig, String(repeating: "a", count: 37) + "nee\r\ndle")
        let r = visibleRows(rig)
        XCTAssertEqual(r.first, String(repeating: "a", count: 37) + "nee",
                       "fixture: row 0 must be full-width 'nee'; rows=\(r.prefix(3))", file: file, line: line)
        XCTAssertTrue(r.count > 1 && r[1].hasPrefix("dle"),
                      "fixture: 'dle' must start row 1; rows=\(r.prefix(3))", file: file, line: line)
        let joined = coreText(rig, from: (0, 0), to: (1, Int(cols) - 1))
        XCTAssertEqual(joined.filter { $0 == "\n" }.count, 1,
                       "fixture: the core must see a hard line break between the rows; got \(joined.debugDescription)",
                       file: file, line: line)
    }

    func test_control_hardNewlineAfterFullWidthRow_doesNotJoin_substring() throws {
        let rig = try makeRig()
        try feedHardBreakAfterFullRow(rig)

        let ms = try substringSearch(rig, "needle")
        XCTAssertEqual(ms.count, 0, "'nee' + hard newline + 'dle' is two lines; 'needle' must not match; got \(fmt(ms))")
        let nee = try substringSearch(rig, "nee")
        XCTAssertEqual(nee.count, 1, "control: 'nee' still matches on its row; got \(fmt(nee))")
    }

    func test_control_hardNewlineAfterFullWidthRow_doesNotJoin_regex() throws {
        let rig = try makeRig()
        try feedHardBreakAfterFullRow(rig)

        let ms = try regexSearch(rig, "needle")
        XCTAssertEqual(ms.count, 0, "'nee' + hard newline + 'dle' is two lines; regex 'needle' must not match; got \(fmt(ms))")
        let nee = try regexSearch(rig, "nee")
        XCTAssertEqual(nee.count, 1, "control: regex 'nee' still matches on its row; got \(fmt(nee))")
    }
}
