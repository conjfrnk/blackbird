import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the substring (non-regex) path of
/// `FindController.performSearch(query:)`.
///
/// Spec (observable behaviour, independent of how the scan is implemented):
///
///  - For every captured row the matches are exactly what Foundation's
///    `hay.range(of: query, options: [.caseInsensitive]?, range: cursor...)`
///    reports, advancing the cursor to the END of each match (matches never
///    overlap). Case-insensitive unless the find bar's `caseSensitive` is on.
///  - Matches are ordered by buffer line ascending, then by position in the row.
///  - Scanning stops once 10_000 matches have been collected, even mid-row.
///  - Viewport rows map UTF-16 offsets to grid columns through the row's
///    `utf16ToCol` (wide CJK/emoji occupy two cells); scrollback rows use the
///    legacy one-column-per-Character approximation
///    (`startCol = char offset`, `endCol = char offset of end - 1`).
///  - Case folding is Foundation's: A-Z/a-z fold to each other, but nothing
///    else folds to anything ASCII on the ASCII side ('[' != '{', '@' != '`').
///    Rows or queries with non-ASCII text (accents, CJK, combining marks,
///    Kelvin sign, sharp s, ligatures, emoji) must give EXACTLY the matches
///    Foundation gives.
///  - A query containing CR / CRLF never matches rows the terminal produced
///    (the grid cannot store a CR).
///
/// The oracle is a verbatim Foundation re-implementation of the above, run
/// over `captureRows(...)` output captured IMMEDIATELY before each
/// `performSearch` against the same `view.currentSnapshot`. `performSearch`
/// ends in `highlightCurrentMatch`, which scrolls the session, so nothing is
/// compared against rows captured after a search and no sequence IDs are
/// asserted.
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (no PTY, no
/// shell), 60x8 grid, synchronous feeds, snapshots taken directly. Largest
/// test feeds ~400 lines x 30 cells (~12 K cells); the random differential
/// feeds 300 lines x <= 50 cells. A few hundred KB at most.
final class FindAsciiFastPathBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    private typealias Match = (line: Int32, startCol: Int, endCol: Int)
    private typealias Row = (line: Int32, hay: String, utf16ToCol: [Int]?)

    private let cols: UInt16 = 60
    private let rows: UInt16 = 8

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: rows))
        view.session = session
        view.findController.installFindBar()
        return Rig(view: view, session: session)
    }

    /// Feed `lines` (each terminated with CRLF) synchronously and publish a
    /// fresh snapshot as the view's current one.
    @discardableResult
    private func feedLines(_ rig: Rig, _ lines: [String],
                           file: StaticString = #filePath, line: UInt = #line) throws -> BBSnapshot {
        var text = ""
        for l in lines { text += l + "\r\n" }
        rig.session.feedBytesForTests(Data(text.utf8))
        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        rig.view.currentSnapshot = snap
        return snap
    }

    private func setCaseSensitive(_ rig: Rig, _ on: Bool,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let bar = try XCTUnwrap(rig.view.findController.findBar, file: file, line: line)
        if bar.options.caseSensitive != on { bar.toggleCaseSensitive(nil) }
        XCTAssertEqual(bar.options.caseSensitive, on, "fixture: case-sensitivity option must be set", file: file, line: line)
        XCTAssertFalse(bar.options.regex, "fixture: regex must be off for the substring path", file: file, line: line)
    }

    private func captureNow(_ rig: Rig) throws -> [Row] {
        let snap = try XCTUnwrap(rig.view.currentSnapshot)
        return rig.view.findController.captureRows(
            topLine: -Int32(clamping: snap.historySize),
            bottomLine: Int32(clamping: snap.rows - 1),
            cols: snap.cols,
            session: rig.session,
            snap: snap
        )
    }

    /// Verbatim Foundation reference for the substring path.
    private func oracle(_ captured: [Row], query: String, caseSensitive: Bool, limit: Int = 10_000) -> [Match] {
        var out: [Match] = []
        var opts: String.CompareOptions = []
        if !caseSensitive { opts.insert(.caseInsensitive) }
        outer: for row in captured {
            let hay = row.hay
            var cursor = hay.startIndex
            while let r = hay.range(of: query, options: opts, range: cursor..<hay.endIndex) {
                let startCol: Int
                let endCol: Int
                if let map = row.utf16ToCol {
                    let lo16 = hay.utf16.distance(
                        from: hay.utf16.startIndex,
                        to: r.lowerBound.samePosition(in: hay.utf16) ?? hay.utf16.startIndex)
                    let hi16 = hay.utf16.distance(
                        from: hay.utf16.startIndex,
                        to: r.upperBound.samePosition(in: hay.utf16) ?? hay.utf16.endIndex)
                    let c = FindController.mapUTF16RangeToCols(lo: lo16, hi: hi16, utf16ToCol: map)
                    startCol = c.startCol
                    endCol = c.endCol
                } else {
                    startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                    endCol = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                }
                out.append((line: row.line, startCol: startCol, endCol: endCol))
                cursor = r.upperBound
                if out.count >= limit { break outer }
            }
        }
        return out
    }

    /// Capture, compute the oracle, run the real search, return both.
    private func search(_ rig: Rig, _ query: String, caseSensitive: Bool,
                        file: StaticString = #filePath, line: UInt = #line) throws -> (actual: [Match], expected: [Match]) {
        try setCaseSensitive(rig, caseSensitive, file: file, line: line)
        let captured = try captureNow(rig)
        let expected = oracle(captured, query: query, caseSensitive: caseSensitive)
        rig.view.findController.performSearch(query: query)
        return (rig.view.findController.findMatches, expected)
    }

    private func fmt(_ ms: [Match]) -> String {
        ms.prefix(12).map { "(\($0.line),\($0.startCol)-\($0.endCol))" }.joined(separator: " ")
            + (ms.count > 12 ? " ...(\(ms.count) total)" : "")
    }

    private func assertSame(_ actual: [Match], _ expected: [Match], _ what: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let same = actual.count == expected.count
            && zip(actual, expected).allSatisfy { $0.line == $1.line && $0.startCol == $1.startCol && $0.endCol == $1.endCol }
        XCTAssertTrue(same, "\(what()): got [\(fmt(actual))], Foundation oracle says [\(fmt(expected))]",
                      file: file, line: line)
    }

    private func assertMatches(_ actual: [Match], _ expected: [(Int32, Int, Int)], _ what: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let exp: [Match] = expected.map { (line: $0.0, startCol: $0.1, endCol: $0.2) }
        assertSame(actual, exp, what, file: file, line: line)
    }

    /// Deterministic RNG (SplitMix64) so failures reproduce.
    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    // MARK: - Fixture sanity

    func test_fixture_gridAndFindBarAreReady() throws {
        let rig = try makeRig()
        let snap = try feedLines(rig, ["hello"])
        XCTAssertEqual(snap.cols, Int(cols))
        XCTAssertEqual(snap.rows, Int(rows))
        XCTAssertEqual(try captureNow(rig).map(\.hay), ["hello"])
    }

    // MARK: - Hard-coded expectations (viewport, no history)

    func test_viewportRow_multipleMatchesCaseInsensitive_exactColumns() throws {
        let rig = try makeRig()
        try feedLines(rig, ["Hello HELLO hello", "nothing here", "xHeLLoy"])
        let r = try search(rig, "hello", caseSensitive: false)
        assertMatches(r.actual, [(0, 0, 4), (0, 6, 10), (0, 12, 16), (2, 1, 5)], "case-insensitive ASCII hits")
        assertSame(r.actual, r.expected, "matches the oracle")
    }

    func test_viewportRow_caseSensitive_onlyExactCase() throws {
        let rig = try makeRig()
        try feedLines(rig, ["Hello HELLO hello", "xHeLLoy"])
        let r = try search(rig, "hello", caseSensitive: true)
        assertMatches(r.actual, [(0, 12, 16)], "case-sensitive ASCII hit")
        let r2 = try search(rig, "HeLLo", caseSensitive: true)
        assertMatches(r2.actual, [(1, 1, 5)], "case-sensitive mixed-case query")
        let r3 = try search(rig, "HeLLo", caseSensitive: false)
        assertMatches(r3.actual, [(0, 0, 4), (0, 6, 10), (0, 12, 16), (1, 1, 5)], "mixed-case query, insensitive")
    }

    // MARK: - Non-overlapping advance

    func test_nonOverlapping_cursorAdvancesToMatchEnd() throws {
        let rig = try makeRig()
        try feedLines(rig, ["aaaaa", "aaaaaa", "abababa", "aAaAa"])
        let r = try search(rig, "aa", caseSensitive: false)
        assertMatches(r.actual,
                      [(0, 0, 1), (0, 2, 3),
                       (1, 0, 1), (1, 2, 3), (1, 4, 5),
                       (3, 0, 1), (3, 2, 3)],
                      "'aa' never reuses a character; abababa has none")
        let r2 = try search(rig, "aba", caseSensitive: false)
        assertMatches(r2.actual, [(2, 0, 2), (2, 4, 6)], "'aba' in abababa: 0..2 then 4..6, not 2..4")
        let r3 = try search(rig, "aaa", caseSensitive: false)
        assertMatches(r3.actual, [(0, 0, 2), (1, 0, 2), (1, 3, 5), (3, 0, 2)], "'aaa' non-overlapping")
        let r4 = try search(rig, "aA", caseSensitive: true)
        assertMatches(r4.actual, [(3, 0, 1), (3, 2, 3)], "case-sensitive 'aA' in aAaAa")
    }

    func test_nonOverlapping_scrollbackRowsToo() throws {
        let rig = try makeRig()
        let lines = (0..<40).map { _ in "aaaaaaa" }
        let snap = try feedLines(rig, lines)
        XCTAssertGreaterThan(snap.historySize, 20)
        let r = try search(rig, "aaa", caseSensitive: false)
        XCTAssertEqual(r.actual.count, 80, "40 rows x 2 non-overlapping 'aaa' in 'aaaaaaa'")
        XCTAssertTrue(r.actual.enumerated().allSatisfy { i, m in
            m.startCol == (i % 2 == 0 ? 0 : 3) && m.endCol == m.startCol + 2
        }, "columns must alternate 0-2 / 3-5; got [\(fmt(r.actual))]")
        assertSame(r.actual, r.expected, "matches the oracle")
    }

    // MARK: - ASCII fold boundaries

    /// Only A-Z fold. A fold that ORs 0x20 into every byte would equate
    /// '[' with '{', '@' with '`' and 'A'..'Z' neighbours.
    func test_asciiFold_onlyLettersFold() throws {
        let rig = try makeRig()
        try feedLines(rig, ["a{b[c@d`e", "AZaz[]{}@`", "Zz Aa"])
        for ci in [false, true] {
            for q in ["[", "{", "@", "`", "]", "}"] {
                let r = try search(rig, q, caseSensitive: ci)
                assertSame(r.actual, r.expected, "query '\(q)' caseSensitive=\(ci)")
                // '[' '{' '@' '`' occur once in each of rows 0 and 1; ']' '}' only in row 1.
                let want = ["]", "}"].contains(q) ? 1 : 2
                XCTAssertEqual(r.actual.count, want, "'\(q)' must match only itself, never its 0x20 partner")
            }
        }
        let r = try search(rig, "[", caseSensitive: false)
        assertMatches(r.actual, [(0, 3, 3), (1, 4, 4)], "'[' only")
        let r2 = try search(rig, "@", caseSensitive: false)
        assertMatches(r2.actual, [(0, 5, 5), (1, 8, 8)], "'@' only")
        let r3 = try search(rig, "z", caseSensitive: false)
        assertMatches(r3.actual, [(1, 1, 1), (1, 3, 3), (2, 0, 0), (2, 1, 1)], "'z' folds with 'Z'")
        let r4 = try search(rig, "Z", caseSensitive: true)
        assertMatches(r4.actual, [(1, 1, 1), (2, 0, 0)], "sensitive 'Z'")
    }

    // MARK: - Trailing spaces, edges

    func test_spacesInQuery_andTrailingSpacesNeverMatch() throws {
        let rig = try makeRig()
        try feedLines(rig, ["x  y   ", "ab", "end"])
        let r = try search(rig, " ", caseSensitive: false)
        assertMatches(r.actual, [(0, 1, 1), (0, 2, 2)], "trailing blanks are trimmed from the haystack")
        let r2 = try search(rig, "x  y", caseSensitive: false)
        assertMatches(r2.actual, [(0, 0, 3)], "query with inner blanks")
        let r3 = try search(rig, "y   ", caseSensitive: false)
        assertMatches(r3.actual, [], "trimmed trailing blanks cannot be matched")
    }

    func test_queryLongerThanRow_andWholeRowAndLastCell() throws {
        let rig = try makeRig()
        try feedLines(rig, ["abc", "xabc"])
        assertMatches(try search(rig, "abcd", caseSensitive: false).actual, [], "query longer than row")
        assertMatches(try search(rig, "abc", caseSensitive: false).actual, [(0, 0, 2), (1, 1, 3)], "match to end of row")
        assertMatches(try search(rig, "ABC", caseSensitive: false).actual, [(0, 0, 2), (1, 1, 3)], "upper-case query")
        assertMatches(try search(rig, "ABC", caseSensitive: true).actual, [], "case-sensitive miss")
        assertMatches(try search(rig, "c", caseSensitive: false).actual, [(0, 2, 2), (1, 3, 3)], "single-char at last cell")
    }

    func test_queryContainingCarriageReturn_neverMatchesTerminalRows() throws {
        let rig = try makeRig()
        try feedLines(rig, ["ab", "cd", "abcd", "a b"])
        for q in ["b\r", "\r", "ab\r\ncd", "\r\n", "b\rc", "a\r"] {
            for ci in [false, true] {
                let r = try search(rig, q, caseSensitive: ci)
                XCTAssertTrue(r.actual.isEmpty, "query \(q.debugDescription) must not match any row, got [\(fmt(r.actual))]")
                assertSame(r.actual, r.expected, "query \(q.debugDescription)")
            }
        }
        // Rows still match a normal query afterwards (no state left behind).
        assertMatches(try search(rig, "cd", caseSensitive: false).actual, [(1, 0, 1), (2, 2, 3)], "sane afterwards")
    }

    // MARK: - Viewport wide-char column mapping (hard-coded)

    func test_viewportWideChars_asciiMatchAfterCJK_usesCellColumns() throws {
        let rig = try makeRig()
        // "日本語" is 3 wide chars = 6 cells, then ' ' = col 6, "test" = cols 7...10.
        try feedLines(rig, ["日本語 test TEST"])
        let r = try search(rig, "test", caseSensitive: false)
        assertMatches(r.actual, [(0, 7, 10), (0, 12, 15)], "ASCII hits after wide chars map to cell columns")
        assertSame(r.actual, r.expected, "matches the oracle")
        let r2 = try search(rig, "日本", caseSensitive: false)
        assertMatches(r2.actual, [(0, 0, 3)], "CJK query: two wide cells each")
    }

    // MARK: - Mixed unicode: ASCII fast path must give Foundation semantics

    private let unicodeRows = [
        "cafe latte",
        "caf\u{E9} au lait",
        "cafe\u{301} noir",
        "CAF\u{C9} CAFE",
        "日本語 テスト test",
        "日本語日本語",
        "na\u{EF}ve NAIVE naive",
        "Stra\u{DF}e STRASSE strasse",
        "\u{212A}elvin kelvin KELVIN",
        "e\u{301}e\u{301} ee",
        "\u{1F600} smile \u{1F600}",
        "\u{FB01}ne fine FINE",
        "plain ascii row Test TEST test",
        "\u{C5}ngstr\u{F6}m angstrom",
    ]

    private let unicodeQueries = [
        "cafe", "caf\u{E9}", "CAFE", "CAF\u{C9}", "\u{E9}", "\u{C9}", "e", "E", "k", "K", "kelvin", "\u{212A}",
        "日本", "本語", "語日", "テスト", "test", "TEST", "Test", "ss", "SS", "\u{DF}", "stra", "naive", "NA\u{CF}VE",
        "\u{EF}", "fi", "\u{FB01}", "\u{1F600}", "smile", "ng", "\u{E5}", "angstrom", "ee", "e\u{301}", " ", "a",
        "cafe\u{301}", "caf\u{E9}e",
    ]

    func test_mixedUnicodeRows_matchFoundationOracleExactly() throws {
        let rig = try makeRig()
        try feedLines(rig, unicodeRows)
        let captured = try captureNow(rig)
        XCTAssertGreaterThanOrEqual(captured.count, unicodeRows.count - 1, "fixture: rows must not be dropped")
        XCTAssertTrue(captured.contains { $0.utf16ToCol == nil }, "fixture: need scrollback rows")
        XCTAssertTrue(captured.contains { $0.utf16ToCol != nil }, "fixture: need viewport rows")
        var nonEmpty = 0
        for ci in [false, true] {
            for q in unicodeQueries {
                let r = try search(rig, q, caseSensitive: ci)
                assertSame(r.actual, r.expected, "query \(q.debugDescription) caseSensitive=\(ci)")
                if !r.expected.isEmpty { nonEmpty += 1 }
            }
        }
        XCTAssertGreaterThan(nonEmpty, 30, "fixture sanity: most queries must hit something so the comparison is not vacuous")
    }

    /// 'cafe' must not match the precomposed 'café' row, and does match the
    /// ASCII row; case-insensitive 'CAFE' likewise (Foundation, no diacritic
    /// folding).
    func test_cafeVsCafeAccent_hardCoded() throws {
        let rig = try makeRig()
        try feedLines(rig, ["cafe latte", "caf\u{E9} au lait", "CAFE", "CAF\u{C9}"])
        let r = try search(rig, "cafe", caseSensitive: false)
        assertMatches(r.actual, [(0, 0, 3), (2, 0, 3)], "'cafe' hits only the unaccented rows")
        let r2 = try search(rig, "caf\u{E9}", caseSensitive: false)
        assertMatches(r2.actual, [(1, 0, 3), (3, 0, 3)], "'café' hits the accented rows (case-insensitively)")
        let r3 = try search(rig, "caf\u{E9}", caseSensitive: true)
        assertMatches(r3.actual, [(1, 0, 3)], "case-sensitive 'café'")
    }

    /// Unicode rows interleaved with ASCII rows in one search, in scrollback
    /// as well as the viewport.
    func test_interleavedAsciiAndUnicodeRows_inScrollbackAndViewport() throws {
        let rig = try makeRig()
        var lines: [String] = []
        for i in 0..<40 {
            switch i % 4 {
            case 0: lines.append("row \(i) Test test TEST")
            case 1: lines.append("行 \(i) tést test")
            case 2: lines.append("caf\u{E9} \(i) CAFE cafe")
            default: lines.append("plain \(i) tEsT")
            }
        }
        let snap = try feedLines(rig, lines)
        XCTAssertGreaterThan(snap.historySize, 20)
        for ci in [false, true] {
            for q in ["test", "Test", "tést", "cafe", "caf\u{E9}", "行", "t", "\(7)", "row 4"] {
                let r = try search(rig, q, caseSensitive: ci)
                assertSame(r.actual, r.expected, "query \(q.debugDescription) caseSensitive=\(ci)")
            }
        }
        let r = try search(rig, "test", caseSensitive: false)
        // 10 rows x 3 (Test test TEST) + 10 x 1 (tést test) + 10 x 1 (tEsT).
        XCTAssertEqual(r.actual.count, 50, "sanity: hits across history and viewport")
    }

    // MARK: - Randomised ASCII differential

    func test_randomAsciiCorpus_matchesOracle_bothCaseModes() throws {
        let rig = try makeRig()
        var rng = SplitMix64(state: 0xB1AC_4B1D)
        let alphabet = Array("aAbBzZ kK[]{}@`_-./:09 ")
        var lines: [String] = []
        for _ in 0..<300 {
            let n = rng.below(50)
            var s = ""
            for _ in 0..<n { s.append(alphabet[rng.below(alphabet.count)]) }
            lines.append(s)
        }
        let snap = try feedLines(rig, lines)
        XCTAssertGreaterThan(snap.historySize, 200)

        var queries = ["a", "A", "ab", "AB", "aB", "ba", "bb", "zz", "Zz", "k", "K", "[", "{", "@", "`", "[]", "{}", "a ", " a", "  ", "_-", "./:", "09", "aaa", "abab", "kK", "Kk"]
        for _ in 0..<12 {
            let n = 1 + rng.below(4)
            var q = ""
            for _ in 0..<n { q.append(alphabet[rng.below(alphabet.count)]) }
            queries.append(q)
        }
        var nonEmpty = 0
        for ci in [false, true] {
            for q in queries {
                let r = try search(rig, q, caseSensitive: ci)
                assertSame(r.actual, r.expected, "random corpus query \(q.debugDescription) caseSensitive=\(ci)")
                if !r.expected.isEmpty { nonEmpty += 1 }
            }
        }
        XCTAssertGreaterThan(nonEmpty, 40, "fixture sanity: comparison must not be vacuous")
    }

    func test_randomCorpusWithSprinkledUnicode_matchesOracle() throws {
        let rig = try makeRig()
        var rng = SplitMix64(state: 0x5EED_0002)
        let ascii = Array("aAeEtTsS kK.")
        let exotic: [Character] = ["\u{E9}", "\u{C9}", "日", "本", "\u{DF}", "\u{212A}", "\u{FB01}", "\u{301}", "\u{1F600}", "\u{EF}"]
        var lines: [String] = []
        for _ in 0..<200 {
            let n = rng.below(30)
            var s = ""
            for _ in 0..<n {
                // ~1 in 12 characters is non-ASCII so about 45% of rows stay pure ASCII.
                if rng.below(12) == 0 { s.append(exotic[rng.below(exotic.count)]) }
                else { s.append(ascii[rng.below(ascii.count)]) }
            }
            lines.append(s)
        }
        try feedLines(rig, lines)
        let queries = ["e", "E", "ae", "te", "TE", "ss", "SS", "s", "k", "K", "\u{E9}", "\u{C9}", "日", "本", "日本", "\u{DF}", "fi", "ti", "t.", ". ", "a ", "\u{212A}"]
        var nonEmpty = 0
        for ci in [false, true] {
            for q in queries {
                let r = try search(rig, q, caseSensitive: ci)
                assertSame(r.actual, r.expected, "sprinkled-unicode query \(q.debugDescription) caseSensitive=\(ci)")
                if !r.expected.isEmpty { nonEmpty += 1 }
            }
        }
        XCTAssertGreaterThan(nonEmpty, 25, "fixture sanity: comparison must not be vacuous")
    }

    // MARK: - 10_000 match cap

    /// 400 rows x 30 'a' = 12_000 possible hits; the scan stops at exactly
    /// 10_000, in the middle of row 334 (333 full rows = 9_990 hits, then 10).
    func test_matchCap_stopsAtExactlyTenThousand_midRow() throws {
        let rig = try makeRig()
        let row = String(repeating: "a", count: 30)
        let snap = try feedLines(rig, Array(repeating: row, count: 400))
        XCTAssertGreaterThan(snap.historySize, 300)
        let captured = try captureNow(rig)
        XCTAssertEqual(captured.count, 400, "fixture: every row captured")

        let r = try search(rig, "a", caseSensitive: false)
        XCTAssertEqual(r.actual.count, 10_000, "scan must stop at the match limit")
        assertSame(r.actual, r.expected, "capped list equals the oracle's capped list")
        let last = try XCTUnwrap(r.actual.last)
        XCTAssertEqual(last.line, captured[333].line, "limit lands in the 334th row")
        XCTAssertEqual(last.startCol, 9, "...after its tenth hit")
        XCTAssertEqual(last.endCol, 9)
        XCTAssertEqual(r.actual.first?.line, captured[0].line)
        XCTAssertEqual(r.actual.first?.startCol, 0)
    }

    func test_matchCap_exactBoundaryAndJustUnder() throws {
        let rig = try makeRig()
        // 500 rows x 20 'a' = exactly 10_000 hits: all kept, last is row 499 col 19.
        let snap = try feedLines(rig, Array(repeating: String(repeating: "a", count: 20), count: 500))
        XCTAssertGreaterThan(snap.historySize, 400)
        let captured = try captureNow(rig)
        let r = try search(rig, "A", caseSensitive: false)
        XCTAssertEqual(r.actual.count, 10_000)
        assertSame(r.actual, r.expected, "exactly-at-limit list equals the oracle")
        XCTAssertEqual(r.actual.last?.line, captured[499].line)
        XCTAssertEqual(r.actual.last?.startCol, 19)

        // Non-overlapping 'aa' -> 10 per row = 5_000 hits, well under the cap.
        let r2 = try search(rig, "aa", caseSensitive: false)
        XCTAssertEqual(r2.actual.count, 5_000, "500 rows x 10 non-overlapping 'aa'")
        assertSame(r2.actual, r2.expected, "under-limit list equals the oracle")
    }

    func test_matchCap_caseSensitiveMissAfterCapStillEmpty() throws {
        let rig = try makeRig()
        try feedLines(rig, Array(repeating: String(repeating: "a", count: 30), count: 400))
        let r = try search(rig, "A", caseSensitive: true)
        XCTAssertTrue(r.actual.isEmpty, "case-sensitive 'A' matches no lowercase row; got \(r.actual.count)")
        // And a following capped insensitive search starts clean (no carry-over).
        let r2 = try search(rig, "a", caseSensitive: false)
        XCTAssertEqual(r2.actual.count, 10_000)
    }

    // MARK: - Repeatability

    func test_sameSearchTwice_givesIdenticalMatchLists() throws {
        let rig = try makeRig()
        try feedLines(rig, unicodeRows + (0..<30).map { "Row \($0) Cafe cafe CAFE" })
        let a = try search(rig, "cafe", caseSensitive: false)
        let b = try search(rig, "cafe", caseSensitive: false)
        assertSame(a.actual, a.expected, "first run")
        assertSame(b.actual, b.expected, "second run")
        // (No cross-run equality: each search scrolls the session to its first
        // match, so the second capture legitimately sees a different state.)
        XCTAssertGreaterThan(a.actual.count, 60)
        XCTAssertGreaterThan(b.actual.count, 60)
    }
}
