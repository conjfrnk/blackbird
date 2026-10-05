import XCTest
@testable import Blackbird

/// Blind behaviour tests for `URLDetector.scan` pinning two observable
/// contracts that must survive an internal optimisation pass:
///
///  1. The wrapped-URL continuation alphabet. A character on the row after a
///     URL that ends at the right edge joins the URL if (and only if) it is
///     one of `A-Z a-z 0-9 - . _ ~ : / ? # [ ] @ ! $ & ' ( ) * + , ; = %`.
///     Every member of that set must still join; printable ASCII just outside
///     it (`" < > \ ^ ` { | }` and space) and non-ASCII scalars must not.
///  2. Scheme gating. A row with no `:` can never hold an `http(s)://` /
///     `ftp://` URL, but still yields bare-email `mailto:` matches. Rows with
///     a scheme `:` are detected exactly as before, and wrapped-URL joins at
///     row ends are unchanged (including when the continuation row itself has
///     no `:`).
///
/// Fixtures feed escape-free text into a fresh `BBTerm`. Largest grid is
/// 200x4 = 800 cells; every other grid is at most 24x24. A few KB at most,
/// no PTY, no scrollback, no windows.
final class URLDetectorContinuationAndColonGateBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    private func snapshot(from text: String, cols: UInt16, rows: UInt16 = 24) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows)))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.displayOffset, 0, "fixture must sit at the live bottom")
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

    /// Foundation normalises some characters (e.g. `[` -> `%5B`) in
    /// `absoluteString`; compare against what `URL(string:)` makes of the
    /// expected joined text rather than the raw text.
    private func normalized(_ s: String) -> String {
        URL(string: s)?.absoluteString ?? s
    }

    // MARK: - 1. Continuation alphabet

    /// The 85-member continuation alphabet, spelled out independently of the
    /// implementation.
    private let continuationAlphabet: [Character] = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
        "abcdefghijklmnopqrstuvwxyz" +
        "0123456789" +
        "-._~:/?#[]@!$&'()*+,;=%"
    )

    /// First characters of a continuation row that stop the join (phishing
    /// guard). They are alphabet members but must not be consumed at col 0.
    private let leaderStoppers: Set<Character> = ["?", "#", "&", "@", ";", ":"]

    /// Printable ASCII and a few non-ASCII scalars outside the alphabet.
    /// Each is a single scalar occupying exactly one cell.
    private let outsideAlphabet: [Character] = [
        " ", "\"", "<", ">", "\\", "^", "`", "{", "|", "}",
        "\u{00E9}",  // e-acute
        "\u{00FC}",  // u-umlaut
        "\u{00B7}",  // middle dot
        "\u{2013}",  // en dash
        "\u{00A0}",  // no-break space
        "\u{0394}",  // Greek capital delta
    ]

    private let head = "https://example.com/"   // exactly 20 cols

    /// Row 0 = head (fills 20 cols), row 1 = `contRow`. Returns scan matches.
    private func scanWrapped(contRow: String) throws -> [URLMatch] {
        XCTAssertEqual(head.count, 20, "fixture: head must fill the 20-col row")
        let snap = try snapshot(from: head + contRow, cols: 20)
        return URLDetector.scan(snapshot: snap)
    }

    /// Every alphabet member sitting mid-row on the continuation row is
    /// consumed into the joined URL, together with the text after it.
    func test_wrapJoin_everyAlphabetCharacter_midRow_joins() throws {
        XCTAssertEqual(continuationAlphabet.count, 85, "fixture: alphabet size")
        var failures: [String] = []
        for c in continuationAlphabet {
            let cont = "ab\(c)00"
            let matches = try scanWrapped(contRow: cont)
            let got = urls(matches)
            let want = [normalized(head + cont)]
            if got != want { failures.append("'\(c)': got \(got), want \(want)") }
        }
        XCTAssertTrue(failures.isEmpty, "alphabet chars that failed to join:\n" + failures.joined(separator: "\n"))
    }

    /// Every non-leader alphabet member as the FIRST cell of the continuation
    /// row is accepted as the wrap-continuation entry condition.
    func test_wrapJoin_everyNonLeaderAlphabetCharacter_atRowStart_joins() throws {
        var failures: [String] = []
        for c in continuationAlphabet where !leaderStoppers.contains(c) {
            let cont = "\(c)ab00"
            let matches = try scanWrapped(contRow: cont)
            let got = urls(matches)
            let want = [normalized(head + cont)]
            if got != want { failures.append("'\(c)': got \(got), want \(want)") }
        }
        XCTAssertTrue(failures.isEmpty, "row-start chars that failed to join:\n" + failures.joined(separator: "\n"))
    }

    /// The six structure leaders are members of the alphabet but stop the
    /// join when they are the first cell of the continuation row: the match
    /// stays the first-row URL alone, and no fragment is emitted.
    func test_wrapJoin_structureLeadersAtRowStart_doNotJoin() throws {
        for c in leaderStoppers.sorted() {
            let matches = try scanWrapped(contRow: "\(c)ab00")
            XCTAssertEqual(urls(matches), [head], "leader '\(c)' must not join")
            XCTAssertEqual(matches.first?.endCol, 19, "leader '\(c)': highlight stays on row 0")
        }
    }

    /// A character outside the alphabet mid-row ends the continuation run:
    /// only the text before it joins, and nothing after it does.
    func test_wrapJoin_charactersOutsideAlphabet_midRow_endTheRun() throws {
        var failures: [String] = []
        for c in outsideAlphabet {
            let matches = try scanWrapped(contRow: "ab\(c)00")
            let got = urls(matches)
            let want = [head + "ab"]
            if got != want { failures.append("U+\(String(c.unicodeScalars.first!.value, radix: 16)): got \(got), want \(want)") }
        }
        XCTAssertTrue(failures.isEmpty, "outside-alphabet chars that wrongly joined:\n" + failures.joined(separator: "\n"))
    }

    /// A character outside the alphabet as the FIRST cell of the continuation
    /// row means the URL does not wrap at all.
    func test_wrapJoin_charactersOutsideAlphabet_atRowStart_doNotJoin() throws {
        var failures: [String] = []
        for c in outsideAlphabet {
            let matches = try scanWrapped(contRow: "\(c)ab00")
            let got = urls(matches)
            if got != [head] { failures.append("U+\(String(c.unicodeScalars.first!.value, radix: 16)): got \(got)") }
            if matches.first?.endCol != 19 { failures.append("endCol \(String(describing: matches.first?.endCol))") }
        }
        XCTAssertTrue(failures.isEmpty, "outside-alphabet row-start chars that wrongly joined:\n" + failures.joined(separator: "\n"))
    }

    /// A blank continuation row never joins.
    func test_wrapJoin_blankContinuationRow_doesNotJoin() throws {
        let snap = try snapshot(from: head + "\r\n\r\nzz", cols: 20)
        // head fills row 0 (pending wrap), CRLF moves to row 1 (blank), then row 2.
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(urls(matches), [head])
    }

    // MARK: - 2. Colon gate: rows without ':'

    func test_noColonRow_withoutEmail_yieldsNothing() throws {
        let snap = try snapshot(
            from: "see www.example.com/path and example.org plus https//missing.colon/x",
            cols: 100, rows: 4
        )
        XCTAssertTrue(URLDetector.scan(snapshot: snap).isEmpty)
    }

    func test_noColonRow_withEmail_stillYieldsMailtoMatch() throws {
        let snap = try snapshot(from: "mail bob@corp.com now", cols: 60, rows: 4)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, "mailto:bob@corp.com")
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.startCol, 5)
        XCTAssertEqual(m.endCol, 16)
    }

    func test_noColonRow_multipleEmails_allDetected() throws {
        let snap = try snapshot(from: "a@x.io, b.c@y.example.org", cols: 60, rows: 4)
        XCTAssertEqual(
            urls(URLDetector.scan(snapshot: snap)),
            ["mailto:a@x.io", "mailto:b.c@y.example.org"]
        )
    }

    /// '@' and '.' both present, no ':' and no valid TLD/domain: nothing.
    func test_noColonRow_adversarialAtDotShape_yieldsNothing() throws {
        let line = "x@" + String(repeating: "a", count: 150) + "."
        let snap = try snapshot(from: line, cols: 200, rows: 4)
        XCTAssertTrue(URLDetector.scan(snapshot: snap).isEmpty)
    }

    /// Colons that are not part of a scheme separator never produce a URL.
    func test_colonPresentButNoScheme_yieldsNoURL() throws {
        let snap = try snapshot(
            from: "time 12:30 and host:8080/path and javascript:alert(1) and https//x.com",
            cols: 100, rows: 4
        )
        XCTAssertTrue(URLDetector.scan(snapshot: snap).isEmpty)
    }

    /// `file://` stays excluded.
    func test_fileScheme_isNeverDetected() throws {
        let snap = try snapshot(from: "open file:///tmp/x.command now", cols: 80, rows: 4)
        XCTAssertTrue(URLDetector.scan(snapshot: snap).isEmpty)
    }

    /// An email whose row also contains an unrelated colon is still found.
    func test_emailOnRowWithUnrelatedColon_isDetected() throws {
        let snap = try snapshot(from: "note: write to bob@corp.com", cols: 60, rows: 4)
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), ["mailto:bob@corp.com"])
    }

    // MARK: - 3. Scheme rows still detected

    func test_schemeURLs_stillDetected_withColumns() throws {
        let snap = try snapshot(
            from: "go http://a.example/x then ftp://f.example/file.txt ok",
            cols: 80, rows: 4
        )
        let matches = sorted(URLDetector.scan(snapshot: snap))
        XCTAssertEqual(matches.map { $0.url.absoluteString },
                       ["http://a.example/x", "ftp://f.example/file.txt"])
        XCTAssertEqual(matches[0].startCol, 3)
        XCTAssertEqual(matches[0].endCol, 20)
        XCTAssertEqual(matches[1].startCol, 27)
    }

    func test_uppercaseScheme_stillDetected() throws {
        let snap = try snapshot(from: "HTTPS://EXAMPLE.COM/PATH", cols: 60, rows: 4)
        XCTAssertEqual(URLDetector.scan(snapshot: snap).count, 1)
    }

    func test_trailingPunctuationTrim_unchanged() throws {
        let snap = try snapshot(from: "(see https://example.com/a).", cols: 60, rows: 4)
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), ["https://example.com/a"])
    }

    /// `https://user:pass@host.com` yields one URL match, not an extra mailto.
    func test_urlContainingUserinfoEmailShape_yieldsSingleMatch() throws {
        let snap = try snapshot(from: "https://user:pass@host.com/x", cols: 60, rows: 4)
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), ["https://user:pass@host.com/x"])
    }

    /// Mixed rows: colon-free email row, scheme row, colon-free blank row,
    /// then a row with both a URL and an email.
    func test_mixedRows_eachRowDetectedIndependently() throws {
        let text = "bob@corp.com\r\nhttp://a.example/x\r\nnothing here\r\nhttp://b.example/y eve@mail.org"
        let snap = try snapshot(from: text, cols: 60, rows: 8)
        let matches = sorted(URLDetector.scan(snapshot: snap))
        XCTAssertEqual(matches.map { $0.url.absoluteString }, [
            "mailto:bob@corp.com",
            "http://a.example/x",
            "http://b.example/y",
            "mailto:eve@mail.org",
        ])
        XCTAssertEqual(matches.map { Int($0.line) }, [0, 1, 3, 3])
    }

    func test_rowsSubset_colonFreeEmailRow_andSchemeRow() throws {
        let text = "bob@corp.com\r\nhttp://a.example/x\r\nnothing"
        let snap = try snapshot(from: text, cols: 60, rows: 8)
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap, rows: [0])), ["mailto:bob@corp.com"])
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap, rows: [1])), ["http://a.example/x"])
        XCTAssertTrue(URLDetector.scan(snapshot: snap, rows: [2]).isEmpty)
    }

    // MARK: - 4. Wrapped-URL joins unchanged

    /// The continuation rows carry no ':' of their own yet still join, and
    /// the fragments are not re-emitted as separate matches.
    func test_wrap_continuationRowsWithoutColon_stillJoin_noFragmentMatches() throws {
        let full = head + String(repeating: "a", count: 35)  // 55 chars, 3 rows
        let snap = try snapshot(from: full, cols: 20)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1)
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, full)
        XCTAssertEqual(m.line, 0)
        XCTAssertEqual(m.startCol, 0)
        XCTAssertEqual(m.endCol, 19)
    }

    /// An email on the (colon-free) continuation row after the consumed
    /// prefix is still reported; the consumed prefix is not.
    func test_wrap_emailAfterConsumedPrefixOnContinuationRow_isDetected() throws {
        let cont = "path/x bob@corp.com"
        // 20-col grid: head fills row 0, `cont` soft-wraps onto row 1.
        let wrapSnap = try snapshot(from: head + cont, cols: 20)
        let matches = sorted(URLDetector.scan(snapshot: wrapSnap))
        XCTAssertEqual(matches.map { $0.url.absoluteString },
                       [head + "path/x", "mailto:bob@corp.com"])
        XCTAssertEqual(matches[0].line, 0)
        XCTAssertEqual(matches[1].line, 1)
        XCTAssertEqual(matches[1].startCol, 7)
    }

    /// Host-injection guard still holds with the colon gate in play: a
    /// continuation beginning `.evil.com/...` would change the host.
    func test_wrap_hostChangingContinuation_stillRejected() throws {
        let h = "https://apple.com"  // 17 chars
        let snap = try snapshot(from: h + ".evil.com/login", cols: 17)
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(urls(matches), [h])
    }

    /// Port-injection guard unchanged: `:8080` leader is refused.
    func test_wrap_portInjectionContinuation_stillRejected() throws {
        let snap = try snapshot(from: head + ":8080/admin", cols: 20)
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), [head])
    }

    /// Trailing punctuation on the final continuation row is still trimmed.
    func test_wrap_trailingPunctuationOnFinalRow_trimmed() throws {
        let snap = try snapshot(from: head + "abc.", cols: 20)
        XCTAssertEqual(urls(URLDetector.scan(snapshot: snap)), [head + "abc"])
    }
}
