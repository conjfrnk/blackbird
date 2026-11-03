import XCTest
@testable import Blackbird

/// Blind regression tests for bug uni-4: the URL detector must not stop at the
/// first non-ASCII character.
///
/// Convention (browsers, iTerm2, VS Code, GitHub, every terminal that prints
/// Wikipedia links): a URL typed or printed with Unicode in its path, query or
/// fragment (an IRI such as `https://de.wikipedia.org/wiki/Bücher`,
/// `...?q=café` or `https://ja.wikipedia.org/wiki/日本`) is ONE link. The
/// ⌘-hover underline covers all of it, and ⌘-click opens the full address — the
/// article, not the site root or a query-less search page. Whether the
/// dispatched `URL` carries the non-ASCII scalars verbatim or percent-encoded
/// (`B%C3%BCcher`) is Foundation's business; the tests therefore compare the
/// percent-DECODED form of `url.absoluteString`, and the decoded
/// `URLComponents.path` / `.queryItems`, against the typed text.
///
/// Observable behaviour under test, via `URLDetector.scan(snapshot:)` on a real
/// `BBTerm` grid:
///   * the dispatched `url` (what ⌘-click opens),
///   * `startCol` / `endCol` (the ⌘-hover underline; `endCol` is inclusive),
///   * `URLDetector.match(at:in:)` on cells inside the non-ASCII part and at
///     the final cell (the hit-test hover and click use).
///
/// Trailing sentence punctuation / prose parens keep being trimmed, and the URL
/// still ends at whitespace, so the controls guard against an over-greedy fix.
///
/// Every fixture is a single short row on a 120x6 grid (720 cells, ~12 KB).
///
/// Written without reading `URLDetector.swift` bodies.
final class URLDetectorNonASCIIBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    private static let gridCols: UInt16 = 120

    private func snapshot(
        from text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BBSnapshot {
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: Self.gridCols, rows: 6)), file: file, line: line)
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

    /// Percent-decoded `absoluteString` of what ⌘-click would open.
    private func decodedTarget(_ url: URL) -> String {
        url.absoluteString.removingPercentEncoding ?? "<undecodable: \(url.absoluteString)>"
    }

    /// Core assertion: `text` is typed on row 0 of a fresh grid; the detector
    /// must report exactly one match whose target decodes to `iri`, whose
    /// underline starts at `expectedStart` and ends (inclusive) within
    /// `expectedEnd`, and whose cells in `hitCols` all hit-test to the match.
    private func assertDetectsSingleLink(
        text: String,
        iri: String,
        expectedStart: Int,
        expectedEnd: ClosedRange<Int>,
        hitCols: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BBSnapshot {
        XCTAssertLessThan(text.count, Int(Self.gridCols), "fixture must fit on one row", file: file, line: line)
        XCTAssertTrue(text.contains(iri), "fixture precondition: the IRI must occur verbatim in the text", file: file, line: line)

        let snap = try snapshot(from: text, file: file, line: line)
        let rowText = snap.visibleRowsAsText()
        XCTAssertEqual(
            rowText[0].trimmingCharacters(in: .whitespaces), text,
            "fixture precondition: row 0 must carry the typed text verbatim", file: file, line: line)

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(
            matches.count, 1,
            "expected exactly one match for \"\(text)\"; got: \(describe(matches))", file: file, line: line)
        guard let m = matches.first else { return snap }

        XCTAssertEqual(
            decodedTarget(m.url), iri,
            "⌘-click target (percent-decoded) for \"\(text)\"; raw absoluteString: \(m.url.absoluteString)",
            file: file, line: line)
        XCTAssertEqual(m.line, 0, "match row", file: file, line: line)
        XCTAssertEqual(
            m.startCol, expectedStart,
            "underline start for \"\(text)\": measured \(m.startCol), expected \(expectedStart)",
            file: file, line: line)
        XCTAssertTrue(
            expectedEnd.contains(m.endCol),
            "underline end (inclusive) for \"\(text)\": measured \(m.endCol), expected \(expectedEnd)",
            file: file, line: line)

        for col in hitCols {
            let hit = URLDetector.match(at: BufferPoint(line: 0, col: col), in: matches)
            XCTAssertEqual(
                hit.map { decodedTarget($0.url) }, iri,
                "hit-test at col \(col) of \"\(text)\" (match spans \(m.startCol)...\(m.endCol))",
                file: file, line: line)
        }
        return snap
    }

    /// Narrow-cell fixtures (Latin, Cyrillic: one cell per character). Expected
    /// columns are derived from the text, and the grid is asked to confirm that
    /// the last URL character really sits in the derived last column so the
    /// column maths cannot be vacuous.
    private func assertDetectsNarrow(
        text: String,
        iri: String,
        hitOffsetsFromStart: [Int],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let range = try XCTUnwrap(
            text.range(of: iri), "IRI must occur in the fixture text", file: file, line: line)
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let end = start + iri.count - 1
        let snap = try assertDetectsSingleLink(
            text: text, iri: iri,
            expectedStart: start, expectedEnd: end...end,
            hitCols: hitOffsetsFromStart.map { start + $0 } + [end],
            file: file, line: line)
        XCTAssertEqual(
            snap.cellKind(at: end, row: 0), .character(iri.last!),
            "grid precondition: the IRI's last character must occupy column \(end)",
            file: file, line: line)
    }

    // MARK: - The reported trigger: non-ASCII in the path

    /// `https://de.wikipedia.org/wiki/Bücher` -- the underline stopped at `B`
    /// and ⌘-click opened `.../wiki/B`.
    func test_germanWikipediaPath_Buecher_isOneFullLink() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        let uIndex = "https://de.wikipedia.org/wiki/B".count
        XCTAssertEqual(iri.count, uIndex + 5, "fixture precondition: B, u-umlaut, c, h, e, r")
        // Hit-test on the ü itself, the letter after it, and the last cell.
        try assertDetectsNarrow(text: iri, iri: iri, hitOffsetsFromStart: [uIndex, uIndex + 1])
    }

    /// The dispatched URL's decoded path must be the article path.
    func test_germanWikipediaPath_Buecher_targetPathIsTheArticle() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        let snap = try snapshot(from: iri)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "expected one match; got: \(describe(matches))")
        let url = try XCTUnwrap(matches.first?.url)
        let comps = try XCTUnwrap(
            URLComponents(url: url, resolvingAgainstBaseURL: false),
            "dispatched URL must parse as URLComponents: \(url.absoluteString)")
        XCTAssertEqual(comps.host, "de.wikipedia.org", "host of \(url.absoluteString)")
        XCTAssertEqual(
            comps.path, "/wiki/B\u{FC}cher",
            "decoded path of the dispatched URL (\(url.absoluteString)); '/wiki/B' means the link was truncated at the first non-ASCII scalar")
    }

    func test_cyrillicWikipediaPath_isOneFullLink() throws {
        let iri = "https://ru.wikipedia.org/wiki/\u{41C}\u{43E}\u{441}\u{43A}\u{432}\u{430}"  // Москва
        XCTAssertEqual(iri.count, "https://ru.wikipedia.org/wiki/".count + 6, "fixture precondition: six Cyrillic letters")
        try assertDetectsNarrow(text: iri, iri: iri, hitOffsetsFromStart: [30, 32, 34])
    }

    // MARK: - Non-ASCII in the query and fragment

    /// `...?q=café` -- the click used to open the search page with `q=caf`.
    func test_queryEndingInNonASCII_isOneFullLink() throws {
        let iri = "https://example.com/search?q=caf\u{E9}"
        let eIndex = iri.count - 1
        try assertDetectsNarrow(text: iri, iri: iri, hitOffsetsFromStart: [eIndex])
    }

    /// Non-ASCII mid-query followed by more ASCII parameters: the stop must not
    /// happen at the `é`, and `lang=fr` must survive as a separate parameter.
    func test_nonASCIIMidQuery_keepsFollowingParameters() throws {
        let iri = "https://example.com/search?q=caf\u{E9}&lang=fr"
        try assertDetectsNarrow(text: "Suche: \(iri) fertig", iri: iri, hitOffsetsFromStart: [32, 33, 34])

        let snap = try snapshot(from: iri)
        let url = try XCTUnwrap(URLDetector.scan(snapshot: snap).first?.url)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            items.map { "\($0.name)=\($0.value ?? "<nil>")" }, ["q=caf\u{E9}", "lang=fr"],
            "decoded query items of \(url.absoluteString)")
    }

    func test_nonASCIIInFragment_isOneFullLink() throws {
        let iri = "https://example.com/doc#r\u{E9}sum\u{E9}"
        try assertDetectsNarrow(text: iri, iri: iri, hitOffsetsFromStart: ["https://example.com/doc#r".count])
    }

    // MARK: - CJK (double-width cells)

    /// `https://ja.wikipedia.org/wiki/日本` -- each of 日 and 本 occupies two
    /// cells (glyph + spacer). The spacer must not terminate the URL either,
    /// and the underline must reach the last glyph.
    func test_japaneseWikipediaPath_isOneFullLink() throws {
        let iri = "https://ja.wikipedia.org/wiki/\u{65E5}\u{672C}"  // 日本
        let asciiPrefix = "https://ja.wikipedia.org/wiki/".count
        XCTAssertEqual(asciiPrefix, 30, "fixture precondition: ASCII prefix is 30 cells")

        let snap = try assertDetectsSingleLink(
            text: iri, iri: iri,
            expectedStart: 0,
            // 本 owns cols 32 (glyph) and 33 (spacer); either is a defensible
            // inclusive end, but the underline must reach the final glyph.
            expectedEnd: 32...33,
            hitCols: [30, 32])

        // Grid preconditions: both CJK glyphs really are double-width.
        XCTAssertEqual(snap.cellKind(at: 30, row: 0), .character("\u{65E5}"), "col 30 holds 日")
        XCTAssertEqual(snap.cellKind(at: 31, row: 0), .spacer, "col 31 is 日's spacer")
        XCTAssertEqual(snap.cellKind(at: 32, row: 0), .character("\u{672C}"), "col 32 holds 本")
        XCTAssertEqual(snap.cellKind(at: 33, row: 0), .spacer, "col 33 is 本's spacer")
    }

    // MARK: - Context: trimming and boundaries still behave with Unicode in the URL

    func test_nonASCIIURL_inProse_dropsTrailingPeriod() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        try assertDetectsNarrow(
            text: "Siehe \(iri).", iri: iri,
            hitOffsetsFromStart: ["https://de.wikipedia.org/wiki/B".count])
    }

    func test_nonASCIIURL_inProseParens_dropsOuterCloser() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        try assertDetectsNarrow(text: "(\(iri))", iri: iri, hitOffsetsFromStart: [])
    }

    func test_nonASCIIURL_endsAtWhitespace() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        try assertDetectsNarrow(text: "\(iri) und mehr", iri: iri, hitOffsetsFromStart: [])
    }

    func test_nonASCIIProseBeforeURL_doesNotShiftColumns() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        try assertDetectsNarrow(text: "B\u{FC}cher: \(iri)", iri: iri, hitOffsetsFromStart: [31])
    }

    // MARK: - Controls (pass before AND after the fix)

    /// Plain ASCII URL: unchanged behaviour.
    func test_control_asciiURL_isOneFullLink() throws {
        let iri = "https://de.wikipedia.org/wiki/Buecher"
        try assertDetectsNarrow(text: iri, iri: iri, hitOffsetsFromStart: [5, 31])
    }

    /// Non-ASCII PROSE after whitespace is not part of the URL.
    func test_control_nonASCIIProseAfterSpace_isNotPartOfURL() throws {
        let iri = "https://example.com/path"
        try assertDetectsNarrow(text: "\(iri) caf\u{E9} cr\u{E8}me", iri: iri, hitOffsetsFromStart: [])
    }
}
