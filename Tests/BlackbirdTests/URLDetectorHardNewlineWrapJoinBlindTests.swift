import XCTest
@testable import Blackbird

/// Blind regression tests for `URLDetector.scan`: a URL whose last character
/// lands EXACTLY on the final column of its row, followed by a HARD newline
/// (`\r\n`), must not have the next row's text glued onto it.
///
/// Background. A soft-wrapped URL (the terminal wrapped it because the line
/// was longer than the grid) continues in column 0 of the next row, and the
/// detector joins the two rows so one click opens the whole URL. That feature
/// must stay. But a URL that merely happens to END at the last column and is
/// then followed by a real line break (`printf '...\r\n'`, command output,
/// `git remote -v`, a log line that is exactly `cols` wide) has NOT wrapped:
/// the next row is an unrelated line. Roughly one in `cols` line-alone URLs
/// is exactly that width, so the failure is common and invisible: the
/// underline covers only the real URL (cells `startCol...endCol`) while
/// cmd-click / Open Link / Copy Link use a different URL with the next row's
/// text appended, so the wrong page opens.
///
/// The observable contract pinned here, for every fixture below:
///   * `scan` reports the URL that is actually written in the cells, not the
///     URL plus text from a different logical line;
///   * the URL a match opens equals the text under its underline;
///   * a genuine soft wrap of the identical bytes (no newline) still joins.
///
/// Fixtures feed plain text (plus, for the alt-screen cases, a few CSI
/// sequences) into a fresh `BBTerm`. Largest grid is 132x6 = 792 cells; a few
/// KB in total, no PTY, no windows, no scrollback.
/// Sections 5 and 6 (multi-row walk, alt-screen fallback) were added with the
/// review fixes, after the implementation existed (not blind).
final class URLDetectorHardNewlineWrapJoinBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    private func snapshot(from text: String, cols: UInt16, rows: UInt16 = 6) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.displayOffset, 0, "fixture must sit at the live bottom")
        XCTAssertEqual(snap.cols, Int(cols), "fixture: grid width")
        return snap
    }

    private func sorted(_ matches: [URLMatch]) -> [URLMatch] {
        matches.sorted { a, b in
            a.line != b.line ? a.line < b.line : a.startCol < b.startCol
        }
    }

    private func urls(_ matches: [URLMatch]) -> [String] {
        sorted(matches).map { $0.url.absoluteString }
    }

    /// A URL of exactly `cols - startCol` characters, so that written at
    /// column `startCol` its last character lands on the final column. The
    /// path is plain lowercase ASCII, so `URL.absoluteString` round-trips it.
    private func lineAloneURL(scheme: String = "https", cols: Int, startCol: Int = 0) -> String {
        let head = "\(scheme)://example.com/"
        let fill = max(1, cols - startCol - head.count)
        return head + String(repeating: "a", count: fill)
    }

    /// Cell text of `row` over `from...through` (inclusive columns).
    private func cellText(_ snap: BBSnapshot, row: Int, from: Int, through: Int) -> String {
        var out = ""
        for col in from...through {
            out.append(snap.character(at: col, row: row) ?? "?")
        }
        return out
    }

    /// Prove the fixture has the shape the bug needs: the URL's last
    /// character is physically in the last column of row 0, and the next
    /// row's first cell holds the first character of `nextRow` (so the two
    /// rows are adjacent and the continuation is really sitting at col 0).
    private func assertShape(
        _ snap: BBSnapshot, url: String, startCol: Int, cols: Int, nextRow: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(startCol + url.count, cols,
                       "fixture: URL must end exactly at the last column", file: file, line: line)
        XCTAssertEqual(cellText(snap, row: 0, from: startCol, through: cols - 1), url,
                       "fixture: row 0 must hold the URL ending at the last column", file: file, line: line)
        XCTAssertEqual(snap.character(at: 0, row: 1), nextRow.first,
                       "fixture: row 1 must start with the next line's first character", file: file, line: line)
    }

    // MARK: - 1. The reported repro

    /// `printf 'https://example.com/%s\r\nDone\r\n' $(head -c 60 /dev/zero | tr '\0' a)`
    /// on an 80-column grid. The URL fills row 0 edge to edge; `Done` is a
    /// separate line. One match, the real URL, nothing appended.
    func test_hardNewline_afterUrlFillingRow_doesNotJoinNextLine() throws {
        let cols = 80
        let url = lineAloneURL(cols: cols)
        XCTAssertEqual(url.count, 80, "fixture: URL is exactly 80 chars")
        let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
        assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(urls(matches), [url],
                       "a hard newline ends the logical line; the opened URL must be only what was written on row 0")
        let m = try XCTUnwrap(matches.first, "expected the URL to be detected at all")
        XCTAssertEqual(m.line, 0, "match line")
        XCTAssertEqual(m.startCol, 0, "match startCol")
        XCTAssertEqual(m.endCol, cols - 1, "match endCol (underline stays on row 0)")
    }

    /// The URL does not have to start at column 0: it just has to end at the
    /// last column.
    func test_hardNewline_afterUrlStartingMidRow_doesNotJoinNextLine() throws {
        let cols = 40
        let startCol = 10
        let url = lineAloneURL(cols: cols, startCol: startCol)
        let text = String(repeating: " ", count: startCol) + url + "\r\nDone\r\n"
        let snap = try snapshot(from: text, cols: UInt16(cols))
        assertShape(snap, url: url, startCol: startCol, cols: cols, nextRow: "Done")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(urls(matches), [url],
                       "mid-row URL ending at the last column must not absorb the next line")
        let m = try XCTUnwrap(matches.first, "expected the URL to be detected at all")
        XCTAssertEqual(m.startCol, startCol, "match startCol")
        XCTAssertEqual(m.endCol, cols - 1, "match endCol")
    }

    /// The reported width-dependence: it must hold for any grid width, not
    /// just 80.
    func test_hardNewline_atEveryGridWidth_doesNotJoinNextLine() throws {
        var failures: [String] = []
        for cols in [24, 40, 80, 132] {
            let url = lineAloneURL(cols: cols)
            let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
            assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")
            let got = urls(URLDetector.scan(snapshot: snap))
            if got != [url] { failures.append("cols=\(cols): got \(got), want \([url])") }
        }
        XCTAssertTrue(failures.isEmpty,
                      "URLs that absorbed the next line at these widths:\n" + failures.joined(separator: "\n"))
    }

    /// http and ftp take the same path as https.
    func test_hardNewline_httpAndFtpSchemes_doNotJoinNextLine() throws {
        let cols = 60
        var failures: [String] = []
        for scheme in ["http", "ftp"] {
            let url = lineAloneURL(scheme: scheme, cols: cols)
            let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
            assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")
            let got = urls(URLDetector.scan(snapshot: snap))
            if got != [url] { failures.append("\(scheme): got \(got), want \([url])") }
        }
        XCTAssertTrue(failures.isEmpty,
                      "schemes that absorbed the next line:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 2. Every unblocked leader character

    /// The next line may start with any character that the join accepts as an
    /// entry condition: a letter, digit, `$`, `%`, `~`, `/`, `.`, `-` or `_`.
    /// A hard newline must stop the join for every one of them.
    func test_hardNewline_everyUnblockedLeader_doesNotJoinNextLine() throws {
        let cols = 50
        let url = lineAloneURL(cols: cols)
        let nextLines: [(label: String, text: String)] = [
            ("letter", "Done"),
            ("digit", "42nd"),
            ("dollar", "$HOME"),
            ("percent", "%41ab"),
            ("tilde", "~user"),
            ("slash", "/tmp/x"),
            ("dot", ".hidden"),
            ("hyphen", "-flag"),
            ("underscore", "_priv"),
        ]
        var failures: [String] = []
        for next in nextLines {
            let snap = try snapshot(from: "\(url)\r\n\(next.text)\r\n", cols: UInt16(cols))
            assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: next.text)
            let matches = URLDetector.scan(snapshot: snap)
            let got = urls(matches)
            if got != [url] {
                failures.append("\(next.label) '\(next.text)': got \(got), want \([url])")
            } else if matches.first?.endCol != cols - 1 {
                failures.append("\(next.label) '\(next.text)': endCol \(String(describing: matches.first?.endCol)), want \(cols - 1)")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "next-line leaders that were glued onto the URL:\n" + failures.joined(separator: "\n"))
    }

    /// A URL whose path itself ends in `/` at the last column (a directory
    /// style link) is the same bug with a different last character.
    func test_hardNewline_afterUrlEndingInSlashAtLastColumn_doesNotJoinNextLine() throws {
        let cols = 40
        let head = "https://example.com/"
        let url = head + String(repeating: "d/", count: (cols - head.count) / 2)
        XCTAssertEqual(url.count, cols, "fixture: slash-terminated URL fills the row")
        let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
        assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), [url],
                       "slash-terminated URL at the last column must not absorb the next line")
    }

    // MARK: - 3. Visible symptom and neighbours

    /// The user-visible symptom: whatever the detector says will be opened
    /// must equal the text that is underlined (the cells `startCol...endCol`
    /// of the match's row).
    func test_hardNewline_openedURLEqualsUnderlinedText() throws {
        let cols = 80
        let url = lineAloneURL(cols: cols)
        let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
        assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")

        let matches = URLDetector.scan(snapshot: snap)
        let m = try XCTUnwrap(matches.first, "expected the URL to be detected at all")
        let underlined = cellText(snap, row: Int(m.line), from: m.startCol, through: m.endCol)
        XCTAssertEqual(m.url.absoluteString, underlined,
                       "cmd-click would open a URL different from the underlined text (underlined \(underlined.count) cells, URL is \(m.url.absoluteString.count) chars)")
    }

    /// A URL on the next line must survive as its own match: the previous
    /// line's exactly-full URL must neither swallow it nor hide it from the
    /// per-row scan of row 1.
    func test_hardNewline_secondUrlOnNextLine_isItsOwnMatch() throws {
        let cols = 60
        let first = lineAloneURL(cols: cols)
        let second = "https://second.example/x"
        let snap = try snapshot(from: "\(first)\r\n\(second)\r\n", cols: UInt16(cols))
        assertShape(snap, url: first, startCol: 0, cols: cols, nextRow: second)

        let matches = sorted(URLDetector.scan(snapshot: snap))
        XCTAssertEqual(matches.map { $0.url.absoluteString }, [first, second],
                       "two URLs on two separate lines must be two separate matches")
        XCTAssertEqual(matches.map { Int($0.line) }, [0, 1], "match lines")
        XCTAssertEqual(matches.map { $0.startCol }, [0, 0], "match start columns")
    }

    /// The hover path rescans only damaged rows via `rows:`. It must give the
    /// same answer as the full scan.
    func test_hardNewline_rowSubsetScan_doesNotJoinNextLine() throws {
        let cols = 80
        let url = lineAloneURL(cols: cols)
        let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
        assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap, rows: [0])), [url],
                       "rows-restricted scan of the URL's row must not absorb the next line")
    }

    // MARK: - 4. Control: a genuine soft wrap still joins

    /// Same bytes without the line break: the terminal itself wraps `Done`
    /// onto row 1 (pending-wrap), which IS a continuation of the URL. The fix
    /// for the hard-newline case must not turn the wrap-join feature off.
    func test_softWrap_ofIdenticalBytes_stillJoinsContinuation() throws {
        let cols = 80
        let url = lineAloneURL(cols: cols)
        let snap = try snapshot(from: "\(url)Done", cols: UInt16(cols))
        assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(urls(matches), [url + "Done"],
                       "a genuinely soft-wrapped URL must still be reassembled across the row boundary")
        let m = try XCTUnwrap(matches.first, "expected the wrapped URL to be detected")
        XCTAssertEqual(m.line, 0, "wrapped match anchors on its first row")
        XCTAssertEqual(m.endCol, cols - 1, "first-row span ends at the last column")
    }

    // MARK: - 5. Multi-row walk: the gate applies at every row boundary

    /// An 80-char URL on a 40-col grid soft-wraps across rows 0 and 1; row 1
    /// is filled edge to edge, then a HARD newline starts `Done` on row 2.
    /// The walk may join row 1 (a real soft wrap) but must stop there: row 1
    /// ends in a line break, so row 2 is a different line.
    func test_multiRowWalk_hardNewlineAfterFullContinuationRow_stopsJoin() throws {
        let cols = 40
        let url = lineAloneURL(cols: 2 * cols)
        XCTAssertEqual(url.count, 2 * cols, "fixture: URL fills exactly two rows")
        let snap = try snapshot(from: "\(url)\r\nDone\r\n", cols: UInt16(cols))
        XCTAssertEqual(cellText(snap, row: 1, from: 0, through: cols - 1), String(url.suffix(cols)),
                       "fixture: row 1 holds the URL tail, filled to the last column")
        XCTAssertEqual(snap.character(at: 0, row: 2), "D", "fixture: row 2 starts the next line")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(urls(matches), [url],
                       "a hard newline after the last wrapped row must end the join; only the two soft-wrapped rows belong to the URL")
    }

    /// Control for the test above: the same bytes with no line break wrap
    /// all the way onto row 2, and the walk must still follow every row.
    func test_multiRowWalk_softWrapAcrossThreeRows_joinsAllRows() throws {
        let cols = 40
        let url = lineAloneURL(cols: 2 * cols)
        let snap = try snapshot(from: url + "Done", cols: UInt16(cols))
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), [url + "Done"],
                       "a URL soft-wrapped across three rows must still be reassembled in full")
    }

    // MARK: - 6. Alt screen: the soft-wrap bit cannot be known

    /// tmux, screen and full-screen TUIs on the alt screen (`?1049`) place
    /// every row with cursor addressing, so a URL they wrap across rows
    /// carries NO core soft-wrap bit even though it genuinely continues. The
    /// join must keep working there, otherwise every URL in a tmux pane
    /// would open truncated. Row 0 is filled to the last column, row 1 is
    /// placed with an explicit cursor move, and no printable character ever
    /// runs past the right margin.
    func test_altScreen_cursorAddressedWrap_stillJoins() throws {
        let cols = 80
        let head = lineAloneURL(cols: cols)
        let tail = "more/path"
        let text = "\u{1B}[?1049h\u{1B}[1;1H" + head + "\u{1B}[2;1H" + tail
        let snap = try snapshot(from: text, cols: UInt16(cols))
        XCTAssertTrue(snap.termMode.contains(.altScreen), "fixture: alt screen is active")
        XCTAssertFalse(snap.isSoftWrapped(row: 0),
                       "fixture: cursor addressing must not produce a soft-wrap bit")
        assertShape(snap, url: head, startCol: 0, cols: cols, nextRow: tail)

        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), [head + tail],
                       "alt-screen URL wrapped by cursor addressing must still be reassembled")
    }

    /// KNOWN_ISSUES.md ("A URL that ends at the last column of an alt-screen
    /// row still absorbs the next line"): on the alt screen a hard newline
    /// after a full-width URL is indistinguishable from a cursor-addressed
    /// wrap, so the join is still attempted. This pins that documented
    /// residual so the fallback and the KNOWN_ISSUES entry change together.
    func test_altScreen_hardNewlineAfterFullWidthUrl_documentedResidualStillJoins() throws {
        let cols = 80
        let url = lineAloneURL(cols: cols)
        let snap = try snapshot(from: "\u{1B}[?1049h" + url + "\r\nDone", cols: UInt16(cols))
        XCTAssertTrue(snap.termMode.contains(.altScreen), "fixture: alt screen is active")
        assertShape(snap, url: url, startCol: 0, cols: cols, nextRow: "Done")

        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), [url + "Done"],
                       "documented residual (KNOWN_ISSUES.md): alt-screen rows carry no wrap bit, so a full-width URL still joins the next line")
    }
}
