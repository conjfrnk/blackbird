import XCTest
@testable import Blackbird

/// Blind regression tests for the URL detector's handling of parentheses at the
/// end of a URL (bug F6).
///
/// Convention (browsers, GitHub, iTerm2, VS Code, Markdown renderers): a closing
/// `)` at the end of a URL belongs to the URL when it balances an opening `(`
/// inside that same URL, e.g. `https://en.wikipedia.org/wiki/Rust_(programming_language)`.
/// A `)` that has no matching `(` inside the URL is surrounding prose
/// (`(see https://example.com)`) and stays excluded. Other trailing punctuation
/// (`. , ; : ] } > ' "`) keeps being trimmed.
///
/// Observable behaviour under test, via `URLDetector.scan(snapshot:)` on a real
/// `BBTerm` grid:
///   * the dispatched `url.absoluteString` (what ⌘-click opens),
///   * `startCol` / `endCol` (the ⌘-hover underline; `endCol` is inclusive),
///   * `URLDetector.match(at:in:)` at the final cell (hit-test used by hover/click).
///
/// Every fixture is escape-free ASCII fed to a fresh `BBTerm`, so the grid
/// geometry comes from the parser. Single-row cases use a 120×6 grid; the wrap
/// cases use 40×6 and 20×6 grids. All grids are at most 720 cells (~12 KB).
///
/// Written without reading `URLDetector.swift` bodies.
final class URLDetectorBalancedParenBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    private func snapshot(
        from text: String,
        cols: UInt16,
        rows: UInt16 = 6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)), file: file, line: line)
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot(), file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "fixture must be at the live bottom", file: file, line: line)
        return snap
    }

    private func describe(_ matches: [URLMatch]) -> String {
        matches
            .map { "L\($0.line)[\($0.startCol)...\($0.endCol)] \($0.url.absoluteString)" }
            .joined(separator: "; ")
    }

    /// Feed `text` (must fit on one row of a 120-col grid), then assert that the
    /// detector reports exactly one match whose URL, underline span and
    /// hit-test all agree with `expectedURL` (which must occur verbatim in
    /// `text`).
    private func assertDetects(
        text: String,
        expectedURL: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cols: UInt16 = 120
        // Fixture sanity (so a passing run cannot be vacuous).
        XCTAssertLessThan(text.count, Int(cols), "fixture must fit on one row", file: file, line: line)
        let range = try XCTUnwrap(text.range(of: expectedURL), "expected URL must occur in the fixture text", file: file, line: line)
        let expectedStart = text.distance(from: text.startIndex, to: range.lowerBound)
        let expectedEnd = expectedStart + expectedURL.count - 1

        let snap = try snapshot(from: text, cols: cols, file: file, line: line)
        let rowText = snap.visibleRowsAsText()
        XCTAssertEqual(
            rowText[0].trimmingCharacters(in: .whitespaces), text,
            "fixture precondition: row 0 must carry the typed text verbatim", file: file, line: line)

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "expected exactly one match; got: \(describe(matches))", file: file, line: line)
        guard let m = matches.first else { return }

        XCTAssertEqual(
            m.url.absoluteString, expectedURL,
            "dispatched URL for text \"\(text)\"", file: file, line: line)
        XCTAssertEqual(m.line, 0, "match row", file: file, line: line)
        XCTAssertEqual(m.startCol, expectedStart, "underline start for \"\(text)\"", file: file, line: line)
        XCTAssertEqual(
            m.endCol, expectedEnd,
            "underline end (inclusive) for \"\(text)\": measured \(m.endCol), expected \(expectedEnd)",
            file: file, line: line)

        // The cell under the final underlined column must be the URL's last char.
        let cells = Array(rowText[0])
        if expectedEnd < cells.count {
            XCTAssertEqual(
                String(cells[expectedEnd]), String(expectedURL.last!),
                "grid cell at the expected end column", file: file, line: line)
        }

        // Hit-test (hover/click) on the last cell must resolve to this URL.
        let hit = URLDetector.match(at: BufferPoint(line: 0, col: expectedEnd), in: matches)
        XCTAssertEqual(
            hit?.url.absoluteString, expectedURL,
            "hit-test at the final URL cell (col \(expectedEnd))", file: file, line: line)
    }

    // MARK: - The reported trigger

    func test_wikipediaRustURL_includesBalancedClosingParen() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        XCTAssertEqual(url.filter { $0 == "(" }.count, url.filter { $0 == ")" }.count,
                       "fixture precondition: the URL's parens must be balanced")
        try assertDetects(text: url, expectedURL: url)
    }

    func test_wikipediaRustURL_inProse_includesBalancedClosingParen() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        try assertDetects(text: "See \(url) for details", expectedURL: url)
    }

    func test_msdnStyleURL_includesBalancedClosingParen() throws {
        let url = "https://docs.microsoft.com/en-us/previous-versions/windows/desktop/legacy/aa365247(v=vs.85)"
        try assertDetects(text: url, expectedURL: url)
    }

    func test_balancedParenInQuery_includesClosingParen() throws {
        let url = "https://example.com/search?q=f(x)"
        try assertDetects(text: "open \(url)", expectedURL: url)
    }

    func test_multipleBalancedGroups_includesFinalClosingParen() throws {
        let url = "https://example.com/f(x)/g(y)"
        try assertDetects(text: url, expectedURL: url)
    }

    func test_nestedBalancedParens_includeBothClosingParens() throws {
        let url = "https://example.com/a_(b_(c))"
        try assertDetects(text: url, expectedURL: url)
    }

    // MARK: - Balanced paren interacting with surrounding punctuation / prose

    func test_balancedParen_followedBySentencePeriod_keepsParenDropsPeriod() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        try assertDetects(text: "Read \(url).", expectedURL: url)
    }

    func test_balancedParen_followedByComma_keepsParenDropsComma() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        try assertDetects(text: "\(url), then", expectedURL: url)
    }

    func test_balancedParen_insideProseParens_dropsOnlyOuterCloser() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        try assertDetects(text: "(\(url))", expectedURL: url)
    }

    func test_balancedParen_inMarkdownLink_dropsOnlyMarkdownCloser() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        try assertDetects(text: "[wiki](\(url))", expectedURL: url)
    }

    func test_extraClosingParen_afterBalancedGroup_endsAtFirstCloser() throws {
        // One `(`, two `)`: the first closer balances, the second is prose.
        let url = "https://example.com/a_(b)"
        try assertDetects(text: "\(url)) next", expectedURL: url)
    }

    // MARK: - Controls: unbalanced `)` must stay excluded (pass before AND after the fix)

    func test_control_proseWrappedPlainURL_excludesCloser() throws {
        let url = "https://example.com/plain"
        try assertDetects(text: "(\(url))", expectedURL: url)
    }

    func test_control_markdownLinkWithPlainURL_excludesCloser() throws {
        let url = "https://example.com/a"
        try assertDetects(text: "[t](\(url))", expectedURL: url)
    }

    func test_control_danglingCloserWithoutOpener_excluded() throws {
        let url = "https://example.com/a"
        try assertDetects(text: "See \(url)) rest", expectedURL: url)
    }

    // MARK: - Soft-wrapped URLs: balance is judged over the whole joined URL

    /// 40-col grid; the URL is 57 chars: the `(` sits on row 0 (col 35), the
    /// `)` is the last char of the continuation on row 1.
    func test_wrappedURL_openerOnFirstRow_closerOnSecondRow_keepsCloser() throws {
        let url = "https://en.wikipedia.org/wiki/Rust_(programming_language)"
        let cols: UInt16 = 40
        let snap = try snapshot(from: url, cols: cols)

        let rowText = snap.visibleRowsAsText()
        XCTAssertEqual(rowText[0], String(url.prefix(Int(cols))), "precondition: row 0 holds the first 40 chars")
        XCTAssertEqual(
            rowText[1].trimmingCharacters(in: .whitespaces), String(url.dropFirst(Int(cols))),
            "precondition: row 1 holds the wrapped remainder")
        XCTAssertTrue(rowText[0].contains("("), "precondition: opener on row 0")
        XCTAssertFalse(rowText[0].contains(")"), "precondition: closer is NOT on row 0")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "one joined match expected; got: \(describe(matches))")
        XCTAssertEqual(
            matches.first?.url.absoluteString, url,
            "joined URL must keep its balanced closing paren; got: \(describe(matches))")
        XCTAssertEqual(matches.first?.line, 0)
        XCTAssertEqual(matches.first?.startCol, 0)
    }

    /// 20-col grid; the URL is 47 chars across three rows. Row 0 is just
    /// `https://example.com/` (no parens at all); `(` is on row 1 and the `)` is
    /// the last char of row 2, so balance can only be judged over the joined URL.
    func test_wrappedURL_openerOnMiddleRow_closerOnLastRow_keepsCloser() throws {
        let url = "https://example.com/Rust_(programming_language)"
        let cols: UInt16 = 20
        let snap = try snapshot(from: url, cols: cols)

        let rowText = snap.visibleRowsAsText()
        XCTAssertEqual(rowText[0], "https://example.com/", "precondition: row 0 is the host+slash")
        XCTAssertEqual(rowText[1], "Rust_(programming_la", "precondition: row 1 holds the opener")
        XCTAssertEqual(rowText[2].trimmingCharacters(in: .whitespaces), "nguage)", "precondition: row 2 holds the closer")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "one joined match expected; got: \(describe(matches))")
        XCTAssertEqual(
            matches.first?.url.absoluteString, url,
            "joined URL must keep its balanced closing paren; got: \(describe(matches))")
        XCTAssertEqual(matches.first?.line, 0)
        XCTAssertEqual(matches.first?.startCol, 0)
    }

    /// Control for the wrap path: an unbalanced `)` at the end of the joined URL
    /// is still prose and must be dropped (passes before AND after the fix).
    func test_control_wrappedURL_danglingCloserOnLastRow_stillExcluded() throws {
        let url = "https://example.com/some_long_path_here"
        let cols: UInt16 = 20
        let snap = try snapshot(from: url + ")", cols: cols)

        let rowText = snap.visibleRowsAsText()
        XCTAssertEqual(rowText[0], "https://example.com/", "precondition: row 0 is the host+slash")
        XCTAssertEqual(rowText[1].trimmingCharacters(in: .whitespaces), "some_long_path_here)",
                       "precondition: row 1 holds the dangling closer")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "one joined match expected; got: \(describe(matches))")
        XCTAssertEqual(
            matches.first?.url.absoluteString, url,
            "a `)` with no matching `(` must stay excluded; got: \(describe(matches))")
    }
}
