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
