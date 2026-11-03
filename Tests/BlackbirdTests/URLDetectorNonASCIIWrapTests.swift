import XCTest
@testable import Blackbird

/// Follow-up coverage for bug uni-4 (URL detector stopped at the first
/// non-ASCII scalar). `URLDetectorNonASCIIBlindTests` pins the single-row
/// behaviour; this file pins the parts that review found missing:
///
///  * a soft-WRAPPED IRI must join across rows exactly like the same IRI on
///    one row, whether the non-ASCII scalar starts the continuation row, sits
///    mid-row, or is a double-width glyph (spacer cells, the blank pad left
///    when a wide glyph does not fit),
///  * the wrap join's alphabet (`isURLContinuationChar`) must agree with the
///    single-row regex,
///  * the terminators the detector documents (fullwidth punctuation, symbols,
///    ideographic space, emoji) still end a URL, the authority stays ASCII,
///    and the documented prose-glued-to-path trade-off is pinned so a change to
///    it is deliberate.
///
/// These were written by the fixer in response to review findings, with the
/// expectations taken from the behaviour spec (a wrapped URL opens the same
/// target as its one-row form), not from the implementation.
///
/// Every grid is at most 100x6 = 600 cells.
final class URLDetectorNonASCIIWrapTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    private func snapshot(_ text: String, cols: UInt16, rows: UInt16 = 6) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.displayOffset, 0, "fixture must be at the live bottom")
        return snap
    }

    private func decoded(_ url: URL) -> String {
        url.absoluteString.removingPercentEncoding ?? "<undecodable: \(url.absoluteString)>"
    }

    private func describe(_ matches: [URLMatch]) -> String {
        matches
            .map { "L\($0.line)[\($0.startCol)...\($0.endCol)] \($0.url.absoluteString)" }
            .joined(separator: "; ")
    }

    /// Scan and require exactly one match whose percent-decoded target is `iri`.
    private func singleMatch(
        _ snap: BBSnapshot, decodesTo iri: String,
        file: StaticString = #filePath, line: UInt = #line
    ) -> URLMatch? {
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(
            matches.count, 1, "expected exactly one match; got: \(describe(matches))",
            file: file, line: line)
        guard let m = matches.first else { return nil }
        XCTAssertEqual(
            decoded(m.url), iri, "⌘-click target (raw: \(m.url.absoluteString))",
            file: file, line: line)
        return m
    }

    // MARK: - Wrapped IRIs: the non-ASCII scalar starts the continuation row

    /// The soft wrap falls just before `ü`: row 0 ends `…/wiki/B`, row 1 starts
    /// `ücher`. Before the fix the join gate rejected `ü` and ⌘-click opened
    /// `…/wiki/B`.
    func test_wrap_nonASCIILetterStartsContinuationRow_joinsWholeIRI() throws {
        let iri = "https://de.wikipedia.org/wiki/B\u{FC}cher"
        let snap = try snapshot(iri, cols: 31)
        XCTAssertEqual(snap.cellKind(at: 30, row: 0), .character("B"), "grid precondition: B in the last column")
        XCTAssertEqual(snap.cellKind(at: 0, row: 1), .character("\u{FC}"), "grid precondition: ü starts row 1")
        XCTAssertTrue(snap.isSoftWrapped(row: 0), "grid precondition: row 0 soft-wrapped")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.startCol, 0)
        XCTAssertEqual(m.endCol, 30, "the underline stays on the first row")
    }

    /// Non-ASCII letters part-way along a continuation row: the run must not
    /// end at the `é`, and the parameter after it must survive.
    func test_wrap_nonASCIIMidContinuationRow_keepsTheRestOfTheQuery() throws {
        let head = "https://example.com/"  // fills the 20-col row
        let tail = "search?q=caf\u{E9}&x=1"
        XCTAssertEqual(head.count, 20, "fixture precondition")
        let snap = try snapshot(head + tail, cols: 20)
        XCTAssertEqual(snap.cellKind(at: 0, row: 1), .character("s"), "grid precondition: tail starts row 1")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: head + tail))
        XCTAssertEqual(m.endCol, 19)
        let items = URLComponents(url: m.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(
            items.map { "\($0.name)=\($0.value ?? "<nil>")" }, ["q=caf\u{E9}", "x=1"],
            "decoded query items of \(m.url.absoluteString)")
    }

    /// A run of full-width CJK rows: every continuation row is filled edge to
    /// edge with double-width glyphs (the run must reach the right edge through
    /// the spacer cells), and a third row continues it.
    func test_wrap_edgeFilledWideRow_continuesOntoTheNextRow() throws {
        let head = "https://example.com/"
        let wideRow = "\u{4E00}\u{4E8C}\u{4E09}\u{56DB}\u{4E94}\u{516D}\u{4E03}\u{516B}\u{4E5D}\u{5341}"  // 一二三四五六七八九十
        let tail = "\u{4E01}ab"  // 丁ab
        let iri = head + wideRow + tail
        let snap = try snapshot(iri, cols: 20)
        XCTAssertEqual(snap.cellKind(at: 18, row: 1), .character("\u{5341}"), "grid precondition: 十 owns cols 18-19")
        XCTAssertEqual(snap.cellKind(at: 19, row: 1), .spacer, "grid precondition: 十's spacer ends row 1")
        XCTAssertTrue(snap.isSoftWrapped(row: 1), "grid precondition: row 1 soft-wrapped")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.endCol, 19)
    }

    // MARK: - Wrapped IRIs: wide glyphs at the row boundary

    /// `日` fills the last two columns of row 0, `本` wraps to row 1. The match
    /// covers 日's spacer and joins 本.
    func test_wrap_wideGlyphFillsLastColumns_joinsTheNextGlyph() throws {
        let iri = "https://ja.wikipedia.org/wiki/\u{65E5}\u{672C}"  // 日本
        let snap = try snapshot(iri, cols: 32)
        XCTAssertEqual(snap.cellKind(at: 30, row: 0), .character("\u{65E5}"), "grid precondition: 日 at col 30")
        XCTAssertEqual(snap.cellKind(at: 31, row: 0), .spacer, "grid precondition: 日's spacer at col 31")
        XCTAssertEqual(snap.cellKind(at: 0, row: 1), .character("\u{672C}"), "grid precondition: 本 starts row 1")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
        XCTAssertEqual(m.startCol, 0)
        XCTAssertEqual(m.endCol, 31, "the underline covers the whole glyph including its spacer")
    }

    /// Only one column is left on row 0, so `日` does not fit: row 0 ends with
    /// a blank pad (`LEADING_WIDE_CHAR_SPACER`) and `日本` sits on row 1. The
    /// URL still joins; the underline stops at the last real cell rather than
    /// covering the blank pad.
    func test_wrap_wideGlyphDoesNotFit_blankPadDoesNotBreakTheJoin() throws {
        let iri = "https://ja.wikipedia.org/wiki/\u{65E5}\u{672C}"
        let snap = try snapshot(iri, cols: 31)
        XCTAssertEqual(snap.cellKind(at: 29, row: 0), .character("/"), "grid precondition: last ASCII char at col 29")
        XCTAssertEqual(snap.cellKind(at: 30, row: 0), .spacer, "grid precondition: blank pad at col 30")
        XCTAssertTrue(snap.isSoftWrapped(row: 0), "grid precondition: row 0 soft-wrapped")
        XCTAssertEqual(snap.cellKind(at: 0, row: 1), .character("\u{65E5}"), "grid precondition: 日 starts row 1")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
        XCTAssertEqual(m.startCol, 0)
        XCTAssertEqual(m.endCol, 29, "the underline stops at the last real cell, not the blank pad")
        XCTAssertNil(
            URLDetector.match(at: BufferPoint(line: 0, col: 30), in: [m]),
            "the blank pad is not part of the link")
    }

    /// The same blank pad, but the wrapped glyph is a terminator (ideographic
    /// full stop): nothing may be joined onto the URL.
    func test_wrap_wideTerminatorAfterBlankPad_doesNotJoin() throws {
        let url = "https://ja.wikipedia.org/wiki/"
        let snap = try snapshot(url + "\u{3002}", cols: 31)  // 。
        XCTAssertEqual(snap.cellKind(at: 30, row: 0), .spacer, "grid precondition: blank pad at col 30")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: url))
        XCTAssertEqual(m.endCol, 29)
    }

    /// Trailing `)` and `.` after a wrapped wide glyph are trimmed like they
    /// are on one row, and the column maths survive the double-width cells.
    func test_wrap_trailingPunctuationAfterWideGlyph_isTrimmed() throws {
        let iri = "https://ja.wikipedia.org/wiki/\u{65E5}\u{672C}"
        let snap = try snapshot("(" + iri + ").", cols: 33)
        XCTAssertEqual(snap.cellKind(at: 31, row: 0), .character("\u{65E5}"), "grid precondition: 日 at col 31")
        XCTAssertEqual(snap.cellKind(at: 0, row: 1), .character("\u{672C}"), "grid precondition: 本 starts row 1")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
        XCTAssertEqual(m.startCol, 1)
        XCTAssertEqual(m.endCol, 32)
    }

    /// The columns recorded as consumed on a continuation row are COLUMNS, not
    /// glyph counts: eight double-width glyphs (16 columns) are followed by
    /// `http://x`, which lies inside the joined URL and must not be emitted a
    /// second time as its own match.
    func test_wrap_consumedPrefixIsInColumns_noDuplicateFragmentMatch() throws {
        let head = "https://example.com/abcd"  // fills the 24-col row
        let wide = String(repeating: "\u{65E5}", count: 8)
        let fragment = "http://x"
        XCTAssertEqual(head.count, 24, "fixture precondition")
        XCTAssertEqual(fragment.count, 8, "fixture precondition")
        let iri = head + wide + fragment
        let snap = try snapshot(iri, cols: 24)
        XCTAssertEqual(snap.cellKind(at: 16, row: 1), .character("h"), "grid precondition: fragment starts at col 16")

        _ = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
    }

    /// A second URL after the joined fragment on the continuation row is still
    /// found, at its true column.
    func test_wrap_urlAfterWideContinuation_isFoundAtItsColumn() throws {
        let head = "https://example.com/abcdefghij"  // fills the 30-col row
        let wide = "\u{65E5}\u{672C}\u{8A9E}"  // 日本語, 6 columns
        let other = "https://b.example/y"
        XCTAssertEqual(head.count, 30, "fixture precondition")
        let snap = try snapshot(head + wide + " " + other, cols: 30)

        let matches = URLDetector.scan(snapshot: snap)
        let sorted = matches.sorted { (a: URLMatch, b: URLMatch) -> Bool in
            a.line != b.line ? a.line < b.line : a.startCol < b.startCol
        }
        XCTAssertEqual(sorted.count, 2, "expected the joined URL and the second URL; got: \(describe(matches))")
        guard sorted.count == 2 else { return }
        XCTAssertEqual(decoded(sorted[0].url), head + wide)
        XCTAssertEqual(sorted[0].line, 0)
        XCTAssertEqual(decoded(sorted[1].url), other)
        XCTAssertEqual(sorted[1].line, 1)
        XCTAssertEqual(sorted[1].startCol, 7, "after 日本語 (6 cols) and a space")
        XCTAssertEqual(sorted[1].endCol, 7 + other.count - 1)
    }

    // MARK: - The wrap alphabet agrees with the single-row regex

    /// Non-ASCII scalars the single-row regex accepts (letters, marks, numbers).
    private let accepted: [Character] = [
        "\u{E9}", "\u{FC}", "\u{394}", "\u{416}", "\u{627}", "\u{939}",     // Latin, Greek, Cyrillic, Arabic, Devanagari
        "\u{65E5}", "\u{3042}", "\u{30AB}", "\u{D55C}", "\u{20BB7}",        // Han, Hiragana, Katakana, Hangul, non-BMP Han
        "\u{AA}", "\u{2B0}", "\u{1C5}",                                     // Lo, Lm, Lt
        "\u{661}", "\u{B2}", "\u{2167}",                                    // Nd, No, Nl
        "\u{301}", "\u{93F}", "\u{20DD}",                                   // Mn, Mc, Me
    ]

    /// Non-ASCII scalars both must reject: punctuation, symbols, separators,
    /// format/bidi scalars, and the invisible Hangul filler letters.
    private let rejected: [Character] = [
        "\u{20AC}", "\u{A9}", "\u{2192}", "\u{1F600}",                      // currency, symbol, arrow, emoji
        "\u{AB}", "\u{B7}", "\u{2013}", "\u{2026}",                         // guillemet, middle dot, en dash, ellipsis
        "\u{FF0C}", "\u{3002}", "\u{3001}", "\u{FF08}", "\u{300C}",         // fullwidth comma/stop/paren, ideographic comma, corner bracket
        "\u{A0}", "\u{2003}", "\u{3000}", "\u{2028}",                       // NBSP, em space, ideographic space, line separator
        "\u{200B}", "\u{202E}", "\u{FEFF}",                                 // ZWSP, RLO, BOM (format)
        "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}",                     // Hangul fillers
    ]

    /// Whether the single-row regex takes `c` as a URL body character, asked
    /// through the shipped pattern (`forEachURLRange`) on `http://h/<c>z`.
    private func regexAcceptsInPath(_ c: Character) -> Bool {
        let text = "http://h/\(c)z"
        let ns = text as NSString
        var matched: String?
        URLDetector.forEachURLRange(in: text, nsLine: ns) { (r: NSRange, stop: UnsafeMutablePointer<ObjCBool>) -> Void in
            matched = ns.substring(with: r)
            stop.pointee = true
        }
        return matched == text
    }

    func test_continuationPredicate_agreesWithRegex_onNonASCII() {
        var failures: [String] = []
        let groups: [(chars: [Character], expected: Bool)] = [(accepted, true), (rejected, false)]
        for group in groups {
            let expected = group.expected
            for c in group.chars {
                var tag = "U+"
                for scalar in c.unicodeScalars { tag += String(scalar.value, radix: 16, uppercase: true) }
                let viaRegex = regexAcceptsInPath(c)
                let viaPredicate = URLDetector.isURLContinuationChar(c)
                if viaRegex != expected { failures.append("\(tag): regex says \(viaRegex), want \(expected)") }
                if viaPredicate != expected { failures.append("\(tag): wrap predicate says \(viaPredicate), want \(expected)") }
            }
        }
        XCTAssertTrue(failures.isEmpty, "regex / wrap-join disagreement:\n" + failures.joined(separator: "\n"))
    }

    func test_continuationPredicate_agreesWithRegex_onPrintableASCII() {
        var failures: [String] = []
        // `%` is excluded: the regex needs two hex digits after it, the wrap
        // alphabet has always taken a bare `%` (pinned by the continuation tests).
        for value in 0x20...0x7E where value != 0x25 {
            guard let scalar = Unicode.Scalar(UInt32(value)) else { continue }
            let c = Character(scalar)
            let viaRegex = regexAcceptsInPath(c)
            let viaPredicate = URLDetector.isURLContinuationChar(c)
            if viaRegex != viaPredicate {
                failures.append("'\(c)': regex \(viaRegex), wrap predicate \(viaPredicate)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "regex / wrap-join disagreement:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - Terminators and the authority (single row)

    /// What ends a URL even though non-ASCII letters now continue one.
    func test_terminators_endTheURL() throws {
        let base = "https://example.com/a"
        let cases: [(text: String, why: String)] = [
            (base + "\u{FF0C}b", "fullwidth comma"),
            (base + "\u{3002}b", "ideographic full stop"),
            (base + "\u{3001}b", "ideographic comma"),
            ("\u{FF08}" + base + "\u{FF09}b", "fullwidth parens around the URL"),
            (base + "\u{3000}b", "ideographic space"),
            (base + "\u{2192}b", "arrow"),
            (base + "\u{20AC}b", "currency symbol"),
            (base + "\u{1F600}b", "emoji"),
        ]
        for (text, why) in cases {
            let snap = try snapshot(text, cols: 60)
            let matches = URLDetector.scan(snapshot: snap)
            XCTAssertEqual(matches.count, 1, "\(why): expected one match; got: \(describe(matches))")
            guard let m = matches.first else { continue }
            XCTAssertEqual(decoded(m.url), base, "\(why): target (raw: \(m.url.absoluteString))")
            XCTAssertEqual(
                snap.cellKind(at: m.endCol, row: 0), .character("a"),
                "\(why): the underline must end on the final `a`")
        }
    }

    /// Prose glued straight onto the host: the host link survives (the
    /// authority is ASCII-only), where letting letters into the authority would
    /// turn the host into `github.com中文` and leave no link at all.
    func test_hostFollowedDirectlyByCJKProse_keepsTheCleanHostLink() throws {
        let url = "https://github.com"
        let snap = try snapshot("\u{8BBF}\u{95EE}" + url + "\u{4E2D}\u{6587}", cols: 60)  // 访问…中文
        XCTAssertEqual(snap.cellKind(at: 4, row: 0), .character("h"), "grid precondition: URL starts at col 4")

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: url))
        XCTAssertEqual(m.startCol, 4)
        XCTAssertEqual(m.endCol, 4 + url.count - 1)
    }

    /// Non-ASCII after the host and a `?`/`#` is path-side and still joins.
    func test_nonASCIIAfterQueryAndFragmentMarkers_stillJoins() throws {
        for iri in ["https://example.com?q=\u{E9}", "https://example.com#\u{E9}"] {
            let snap = try snapshot(iri, cols: 60)
            _ = try XCTUnwrap(singleMatch(snap, decodesTo: iri))
        }
    }

    /// DOCUMENTED TRADE-OFF (see the comment on `URLDetector.regex`): prose
    /// written directly after a path with no space or punctuation is part of
    /// the URL, because `/wiki/日本` and `/docs/を参照` cannot be told apart
    /// without a language model. This test pins that so changing it is a
    /// deliberate act. A space or fullwidth punctuation still ends the URL
    /// (see `test_terminators_endTheURL`).
    func test_documentedTradeoff_proseGluedToPath_isAbsorbed() throws {
        let url = "https://example.com/docs/"
        let prose = "\u{3092}\u{53C2}\u{7167}\u{3057}\u{3066}\u{304F}\u{3060}\u{3055}\u{3044}"  // を参照してください
        let snap = try snapshot("\u{8A73}\u{7D30}\u{306F}" + url + prose, cols: 100)  // 詳細は…

        let m = try XCTUnwrap(singleMatch(snap, decodesTo: url + prose))
        XCTAssertEqual(m.startCol, 6, "after 詳細は (3 double-width glyphs)")
    }
}
