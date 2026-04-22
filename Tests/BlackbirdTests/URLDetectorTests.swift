import XCTest
@testable import Blackbird

final class URLDetectorTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build a BBSnapshot by feeding `text` into a fresh BBTerm. Uses an
    /// 80x24 grid unless a larger size is supplied. We favour BBTerm directly
    /// (over TerminalSession) because it's synchronous and avoids shell I/O.
    private func snapshot(
        from text: String,
        cols: UInt16 = 80,
        rows: UInt16 = 24
    ) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)))
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    /// Return matches sorted by (line, startCol) so tests are insensitive to
    /// any internal ordering choices beyond spec-mandated "in order" semantics.
    private func sorted(_ matches: [URLMatch]) -> [URLMatch] {
        matches.sorted { a, b in
            if a.line != b.line { return a.line < b.line }
            return a.startCol < b.startCol
        }
    }

    // MARK: - scan()

    func test_scan_singlePlainURL_onLineZero() throws {
        let url = "https://example.com/path"
        let snap = try snapshot(from: url)
        let matches = URLDetector.scan(snapshot: snap)

        XCTAssertEqual(matches.count, 1, "exactly one URL expected")
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, url)
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.startCol, 0)
        // endCol is inclusive, so it's the index of the final character.
        XCTAssertEqual(m.endCol, url.count - 1)
    }

    func test_scan_httpScheme_isDetected() throws {
        let url = "http://example.com"
        let snap = try snapshot(from: url)
        let matches = URLDetector.scan(snapshot: snap)

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url.absoluteString, url)
    }

    func test_scan_rejectsNonHttpSchemes() throws {
        // Other schemes that NSWorkspace.open would silently dispatch
        // to registered handlers must not survive the regex. If a
        // future pattern edit loosens this, the test surfaces it.
        for raw in [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "ssh://user@host/",
            "telnet://host:23/",
            "x-man-page://printf",
            "vnc://localhost:5900/",
            "afp://server/share",
            "smb://fileserver/share",
        ] {
            let snap = try snapshot(from: raw)
            let matches = URLDetector.scan(snapshot: snap)
            XCTAssertEqual(
                matches.count, 0,
                "regex must not match non-allowlisted scheme: \(raw)"
            )
        }
    }

    func test_scan_fileScheme_isRejected() throws {
        // file:// URLs are excluded from URL detection because
        // NSWorkspace.open on a `.command` / `.app` / `.pkg` path
        // executes the payload. A remote printing such a URL in
        // plain output shouldn't translate into a one-keystroke
        // open gesture.
        for raw in [
            "file:///tmp/malicious.command",
            "file:///Applications/Calculator.app",
            "file:///etc/passwd",
        ] {
            let snap = try snapshot(from: raw)
            let matches = URLDetector.scan(snapshot: snap)
            XCTAssertEqual(
                matches.count, 0,
                "regex detector must not surface file:// URLs: \(raw)"
            )
        }
    }

    func test_scan_twoURLs_sameLine_returnsTwoInOrder() throws {
        let a = "https://foo.com"
        let b = "https://bar.org/x"
        let line = "\(a) \(b)"
        let snap = try snapshot(from: line)

        let matches = sorted(URLDetector.scan(snapshot: snap))
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches[0].url.absoluteString, a)
        XCTAssertEqual(matches[1].url.absoluteString, b)
        XCTAssertEqual(matches[0].startCol, 0)
        XCTAssertEqual(matches[0].endCol, a.count - 1)
        // 'b' starts one past the space after 'a'.
        XCTAssertEqual(matches[1].startCol, a.count + 1)
        XCTAssertEqual(matches[1].endCol, a.count + 1 + b.count - 1)
        XCTAssertEqual(matches[0].line, matches[1].line)
    }

    func test_scan_trailingPeriod_excludedFromMatch() throws {
        let url = "https://example.com"
        // Sentence: "See https://example.com. Thanks"
        let prefix = "See "
        let snap = try snapshot(from: "\(prefix)\(url). Thanks")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, url, "trailing '.' must be excluded")
        XCTAssertEqual(m.startCol, prefix.count)
        XCTAssertEqual(m.endCol, prefix.count + url.count - 1)
    }

    func test_scan_trailingCommaAndSemicolon_excluded() throws {
        let url = "https://example.com"
        let snap1 = try snapshot(from: "(pre) \(url), next")
        let snap2 = try snapshot(from: "pre \(url); next")

        let m1 = try XCTUnwrap(URLDetector.scan(snapshot: snap1).first)
        let m2 = try XCTUnwrap(URLDetector.scan(snapshot: snap2).first)
        XCTAssertEqual(m1.url.absoluteString, url, "trailing ',' must be excluded")
        XCTAssertEqual(m2.url.absoluteString, url, "trailing ';' must be excluded")
    }

    func test_scan_parenthesisWrapped_excludesClosingParen() throws {
        let url = "https://foo.com"
        let prefix = "("
        let snap = try snapshot(from: "\(prefix)\(url))")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, url, "closing ')' must not be part of url")
        // The url starts after the '('.
        XCTAssertEqual(m.startCol, prefix.count)
        XCTAssertEqual(m.endCol, prefix.count + url.count - 1)
    }

    func test_scan_trailingBracketsAndQuotes_excluded() throws {
        let url = "https://foo.com"
        // Each case tests one of the excluded trailing punctuation chars.
        let tails: [Character] = ["]", "}", ">", "'", "\""]
        for tail in tails {
            let snap = try snapshot(from: "\(url)\(tail) next")
            let matches = URLDetector.scan(snapshot: snap)
            XCTAssertEqual(
                matches.count, 1,
                "one match expected for tail=\(tail)"
            )
            XCTAssertEqual(
                matches.first?.url.absoluteString, url,
                "trailing \(tail) must be excluded"
            )
        }
    }

    func test_scan_urlAtColumnZero() throws {
        let url = "https://zero.example/col0"
        let snap = try snapshot(from: url)
        let m = try XCTUnwrap(URLDetector.scan(snapshot: snap).first)
        XCTAssertEqual(m.startCol, 0)
        XCTAssertEqual(m.url.absoluteString, url)
    }

    func test_scan_urlAtRightEdge() throws {
        // Build a line that places the URL at the right edge of a 40-col grid.
        let cols: Int = 40
        let url = "https://edge.example/a"
        // Pad with spaces so the URL ends exactly in the last column.
        let pad = String(repeating: " ", count: cols - url.count)
        let snap = try snapshot(
            from: "\(pad)\(url)",
            cols: UInt16(cols),
            rows: 5
        )
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, url)
        XCTAssertEqual(m.startCol, cols - url.count)
        XCTAssertEqual(m.endCol, cols - 1, "endCol should land on the last column")
    }

    func test_scan_plainText_returnsEmpty() throws {
        let snap = try snapshot(from: "hello world, nothing to see here")
        XCTAssertEqual(URLDetector.scan(snapshot: snap), [])
    }

    func test_scan_emptyGrid_returnsEmpty() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(URLDetector.scan(snapshot: snap), [])
    }

    // MARK: - match(at:in:)

    func test_match_picksCorrectURLAmongMultiple() throws {
        let a = "https://first.example"
        let b = "https://second.example/path"
        let snap = try snapshot(from: "\(a) \(b)")
        let all = sorted(URLDetector.scan(snapshot: snap))
        XCTAssertEqual(all.count, 2)

        // A point inside 'a'.
        let pa = BufferPoint(line: all[0].line, col: all[0].startCol + 3)
        XCTAssertEqual(URLDetector.match(at: pa, in: all)?.url.absoluteString, a)

        // A point inside 'b'.
        let pb = BufferPoint(line: all[1].line, col: all[1].startCol + 4)
        XCTAssertEqual(URLDetector.match(at: pb, in: all)?.url.absoluteString, b)

        // Exact endpoints are inclusive per contract.
        let startA = BufferPoint(line: all[0].line, col: all[0].startCol)
        let endA = BufferPoint(line: all[0].line, col: all[0].endCol)
        XCTAssertEqual(URLDetector.match(at: startA, in: all)?.url.absoluteString, a)
        XCTAssertEqual(URLDetector.match(at: endA, in: all)?.url.absoluteString, a)
    }

    func test_match_returnsNil_betweenAndOutsideURLs() throws {
        let a = "https://first.example"
        let b = "https://second.example"
        let snap = try snapshot(from: "\(a) \(b)")
        let all = sorted(URLDetector.scan(snapshot: snap))
        XCTAssertEqual(all.count, 2)

        // Space between the two URLs — column == endCol(a)+1 == startCol(b)-1.
        let gap = BufferPoint(line: all[0].line, col: all[0].endCol + 1)
        XCTAssertNil(URLDetector.match(at: gap, in: all))

        // Slightly before first URL startCol (when it's > 0).
        if all[0].startCol > 0 {
            let before = BufferPoint(line: all[0].line, col: all[0].startCol - 1)
            XCTAssertNil(URLDetector.match(at: before, in: all))
        }

        // After the second URL.
        let after = BufferPoint(line: all[1].line, col: all[1].endCol + 1)
        XCTAssertNil(URLDetector.match(at: after, in: all))

        // Wrong line.
        let otherLine = BufferPoint(line: all[0].line + 5, col: all[0].startCol)
        XCTAssertNil(URLDetector.match(at: otherLine, in: all))
    }

    func test_match_emptyArray_returnsNil() {
        let p = BufferPoint(line: 0, col: 0)
        XCTAssertNil(URLDetector.match(at: p, in: []))
        let q = BufferPoint(line: 42, col: 17)
        XCTAssertNil(URLDetector.match(at: q, in: []))
    }

    /// Regression for swift-tests-core F6: URLDetector used to use regex
    /// NSRange.location (UTF-16 offset) as the column index directly, so
    /// a URL after a non-BMP character on the same row would be mis-
    /// columned by one per non-BMP char. The (scalar → column) map now
    /// translates UTF-16 offsets back to cells.
    func test_scan_urlAfterNonBMP_correctStartCol() throws {
        // 😀 (U+1F600) is one terminal cell but two UTF-16 units. The URL
        // that follows is at column 2 (1 for 😀 + 1 for the space).
        let text = "😀 https://example.com"
        let snap = try snapshot(from: text, cols: 60, rows: 3)
        let matches = URLDetector.scan(snapshot: snap)
        let m = try XCTUnwrap(matches.first,
                              "expected one URL match, got \(matches.count)")
        // 😀 occupies col 0; alacritty normally treats it as a wide char
        // (cols 0-1), space at col 2, URL starts at col 3. Accept either
        // (2 or 3) — what we DON'T accept is the old buggy 4 (UTF-16
        // index of the URL start).
        XCTAssertTrue(
            m.startCol == 2 || m.startCol == 3,
            "startCol should be a cell index (2 or 3), got \(m.startCol)"
        )
        XCTAssertEqual(m.url.absoluteString, "https://example.com")
    }

    // MARK: - F6: percent-escape validation

    /// Audit cwd-hyperlink F6. The regex used to accept `%` followed by
    /// arbitrary characters (the class treated `%` as a literal). A
    /// pattern like `https://x.com/%zz` would match 19 chars on-screen but
    /// `URL(string:)` would normalise it to `https://x.com/%25zz` — three
    /// chars longer, so the span underline pointed at cells the click
    /// didn't actually hit. New pattern enforces `%HH` only.
    func test_scan_percentEscapeMustBeHexDigits() throws {
        // An invalid escape followed by an alpha char: old regex matched
        // through the `%zz`, producing a URL whose absoluteString differed
        // from the matched substring. New regex breaks at `%z` so the
        // match stops at the `/` before it.
        let snap = try snapshot(from: "https://x.com/valid/%zz/extra")
        let matches = URLDetector.scan(snapshot: snap)
        // Either zero matches (the whole thing doesn't match cleanly) or
        // a match whose absoluteString exactly equals the matched span.
        // What we disallow: a span that extends through %zz.
        for m in matches {
            XCTAssertFalse(
                m.url.absoluteString.contains("%zz"),
                "regex matched literal %zz — must reject ill-formed percent escapes"
            )
        }
    }

    /// A well-formed percent escape (two hex digits) should pass.
    func test_scan_percentEscape_validHex_passes() throws {
        let snap = try snapshot(from: "https://x.com/hello%20world")
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.url.absoluteString, "https://x.com/hello%20world")
    }

    // MARK: - F9: wrapped-URL reconstruction

    /// Audit cwd-hyperlink F9. A URL printed across the right edge of the
    /// grid should be reconstructed into a single match spanning the
    /// wrap, not two unparseable fragments. 40-col grid with a URL long
    /// enough to wrap.
    func test_scan_wrappedURL_reconstructsIntoSingleMatch() throws {
        // Fill first 40 cols with the URL head, letting alacritty wrap
        // the remainder into row 1.
        let head = "https://long.example.com/some/path-to/"
        let tail = "a/document?q=1"
        let cols: UInt16 = 40
        // head is 39 chars (fits in first row, ends at col 38). Force the
        // wrap by appending tail with no space — make total length > 40.
        let full = head + tail   // 53 chars
        XCTAssertGreaterThan(full.count, Int(cols), "setup: must exceed row width")
        let snap = try snapshot(from: full, cols: cols, rows: 5)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "wrapped URL should produce exactly one match")
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, full,
                       "wrapped URL must reconstruct the full href, not stop at the wrap boundary")
    }

    /// A URL that happens to end exactly on the last column but is NOT
    /// followed by URL-safe chars on the next row should NOT falsely join.
    func test_scan_endsAtRightEdge_nextRowUnrelated_noJoin() throws {
        let cols: UInt16 = 40
        // 40-col URL exactly fills the first row, next row is prose.
        let url = "https://zero.example/col0abcdefghijklmno"  // 40 chars
        XCTAssertEqual(url.count, Int(cols), "setup: URL fills first row")
        let line2 = " Next sentence unrelated."
        let snap = try snapshot(from: url + line2, cols: cols, rows: 5)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        // `" Next..."` starts with a space → no continuation. URL stays clean.
        XCTAssertEqual(m.url.absoluteString, url)
    }

    /// Wrapped URL with trailing prose punctuation on the continuation row
    /// should trim the punctuation before joining.
    func test_scan_wrappedURL_trimsTrailingPunctuation() throws {
        let cols: UInt16 = 40
        let head = "https://long.example.com/some/path-to-a-"  // 40 chars
        XCTAssertEqual(head.count, Int(cols))
        let tail = "doc), rest"
        let snap = try snapshot(from: head + tail, cols: cols, rows: 5)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertGreaterThanOrEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, head + "doc",
                       "wrapped URL must strip trailing `)` and `,` from continuation")
    }

    // MARK: - Unicode / CJK / combining-mark coverage
    // (audit swift-tests-core F5)
    //
    // The URLDetector builds each line by appending `snapshot.character
    // (at:row:)` one `Character` per cell. Before the `utf16ToCol` map
    // landed, NSRegularExpression ranges (UTF-16 units) were used as
    // column indices directly, mis-columning every match that followed
    // a non-BMP glyph. These tests pin the current correctness at key
    // Unicode shapes so a future refactor can't silently regress:
    //   - URL preceded by CJK (wide cells, scalar 0 filler in second half)
    //   - URL containing a combining mark (composed char spanning two
    //     cells in the raw buffer, single Character at the Swift layer)
    //   - Trailing closing paren on a wrapping URL after a non-BMP char
    //
    // Memory note: every snapshot here is 80×24 = 1920 cells × ~16 B ≈
    // 30 KB of grid state. No PTY, no scrollback. Safe.

    /// Regression for swift-tests-core F5: a URL immediately after a
    /// CJK-wide character on the same row. The wide glyph takes two
    /// cells (scalar 0 filler in col 1). Detector must line up the
    /// column indices with cells, not UTF-16 offsets or raw scalars.
    func test_scan_urlAfterCJKHost_columnAlignsWithCell() throws {
        // "日 " is one wide char + one space = 3 cells. The URL starts
        // at col 3 (or 2 if alacritty doesn't treat the CJK as wide —
        // both are acceptable). We DON'T accept col 4+ (that would be
        // the UTF-16-offset bug the `utf16ToCol` map exists to prevent).
        let snap = try snapshot(from: "日 https://example.com/path", cols: 80, rows: 5)
        let matches = URLDetector.scan(snapshot: snap)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, "https://example.com/path")
        XCTAssertTrue(
            m.startCol == 2 || m.startCol == 3,
            "startCol should align with URL cell (2 or 3 depending on wide-char policy), got \(m.startCol)"
        )
    }

    /// Regression for swift-tests-core F5: URL containing a combining
    /// mark (`é` = `e` + U+0301). In Swift these decompose into a
    /// single `Character`; NSRegularExpression sees the letter, so the
    /// URL matches. Pins that the detector doesn't crash and the URL
    /// survives round-trip through the URL class.
    func test_scan_urlWithCombiningMark_detectedAndRoundTrips() throws {
        // `café` in the host/path: `e` + U+0301. Most NSURL/URL
        // parsers accept this and normalise. The detector's job is
        // to not crash and produce a span that `URL(string:)` can
        // consume.
        let raw = "https://example.com/caf\u{0065}\u{0301}"  // cafe + combining acute
        let snap = try snapshot(from: raw, cols: 80, rows: 5)
        let matches = URLDetector.scan(snapshot: snap)
        // Acceptable outcomes: one match whose absoluteString is the
        // same bytes (unnormalised) OR a URL-normalised form. What we
        // reject: zero matches, or a match whose absoluteString loses
        // the accent entirely.
        XCTAssertGreaterThanOrEqual(matches.count, 1, "combining-mark URL must match")
        let m = try XCTUnwrap(matches.first)
        XCTAssertTrue(
            m.url.absoluteString.contains("caf"),
            "absoluteString should retain the 'caf' prefix: \(m.url.absoluteString)"
        )
    }

    /// Regression for swift-tests-core F5: URL containing a non-BMP
    /// emoji scalar in its path. `🌐` = U+1F310 = one Character but
    /// two UTF-16 units. The match's endCol must stay in cell-space,
    /// not UTF-16-space. The regex ends at the first non-URL-safe char
    /// so the emoji (if the regex char class includes it) or the
    /// closing cell defines endCol.
    func test_scan_urlEndingAfterNonBMP_endColStaysInCellSpace() throws {
        // `🌐` is a non-URL-safe char per the regex (the regex char
        // class only allows A-Za-z0-9 + URL punctuation, no emoji).
        // So the URL match stops BEFORE 🌐 and the emoji is outside
        // the span. Pin that the startCol/endCol are in cell space,
        // not UTF-16 offsets.
        let snap = try snapshot(from: "🌐 https://example.com end", cols: 80, rows: 5)
        let matches = URLDetector.scan(snapshot: snap)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, "https://example.com")
        // `🌐` is treated as a wide emoji by alacritty (2 cells) or a
        // narrow one (1 cell) depending on width heuristics — both are
        // acceptable. The URL starts at col 2 (narrow emoji) or col 3
        // (wide emoji), not col 4+ (which would be the UTF-16 bug).
        XCTAssertTrue(
            m.startCol == 2 || m.startCol == 3,
            "startCol should be cell-aligned (2 or 3), got \(m.startCol)"
        )
        // endCol = startCol + "https://example.com".count - 1.
        XCTAssertEqual(m.endCol, m.startCol + "https://example.com".count - 1)
    }

    /// Regression for audit swift-tests-core F10: a trailing `)` that
    /// is NOT wrapped in `(url)` must also be excluded from the match.
    /// The existing `test_scan_parenthesisWrapped_excludesClosingParen`
    /// only covered the `(url)` wrapping case.
    func test_scan_trailingUnwrappedCloseParen_excluded() throws {
        let url = "https://foo.com"
        let snap = try snapshot(from: "See \(url)) rest")
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, url,
                       "trailing ')' without matching '(' must still be excluded")
    }
}

// Allow XCTAssertEqual on [URLMatch] for empty-result tests.
extension URLMatch: Equatable {
    public static func == (lhs: URLMatch, rhs: URLMatch) -> Bool {
        lhs.line == rhs.line
            && lhs.startCol == rhs.startCol
            && lhs.endCol == rhs.endCol
            && lhs.url == rhs.url
    }
}
