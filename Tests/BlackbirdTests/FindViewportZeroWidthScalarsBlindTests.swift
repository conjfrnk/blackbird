import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for: the text of the VIEWPORT (find haystack and
/// VoiceOver value) silently drops every zero-width scalar, so it diverges
/// from the text of the same row once it has scrolled into history, and from
/// what Copy extracts.
///
/// Spec (observable behaviour, independent of how the fix is built):
///
///  - A terminal cell holds a base scalar plus any zero-width scalars that
///    were printed after it: combining marks (NFD accents), VS16 (U+FE0F),
///    ZWJ (U+200D), Thai / Indic vowel signs, tone marks and viramas,
///    conjoining Hangul jamo. They are CONTENT. The core keeps them: the
///    text of a row read through the copy path (`session.textRange`) and
///    the text of a row that has scrolled into history both contain them,
///    scalar for scalar.
///  - So the text of a row that is still on screen must contain them too,
///    wherever the app reads it:
///      1. `BBSnapshot.visibleRowsAsText()` (the accessibility source);
///      2. `FindController.captureRows` (the find haystack);
///      3. a find for text typed or pasted exactly as shown must match the
///         visible row (one match, at the right column, and selecting the
///         match selects exactly that text);
///      4. Edit > Find > Use Selection for Find (Cmd-E) on a selected row
///         must find the row it was taken from;
///      5. `TerminalView.accessibilityValue()` and the per-line strings
///         VoiceOver reads (`accessibilityString(for:)`).
///  - Text AFTER a zero-width scalar must keep matching at its own column
///    (the fix must not shift the match-to-cell mapping).
///  - The same query must give the same answer for the same row after it has
///    scrolled into history.
///
/// Controls (they pass before and after the fix and guard against a fix
/// that "passes" by breaking something else): the copy text of the row, the
/// scrollback haystack, the scrollback find, and the find of an ASCII token
/// that follows the zero-width scalar.
///
/// Scalars are compared as scalar arrays, never with `==` on `String`,
/// because Swift string equality is canonical-equivalence and would blur the
/// very distinction under test (and mask a lone U+FE0F or U+200D).
///
/// Fixture: headless `TerminalView` + headless `TerminalSession` (real
/// BBTerm, no PTY, no shell, no window), 40x8 grid, six sample rows (one per
/// script), synchronous feeds, no runloop pumping (non-regex find is
/// synchronous). At most 26 short lines (~1 KB). One view + one session per
/// test.
final class FindViewportZeroWidthScalarsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Samples

    /// One printed row per sample. `zeroWidthQuery` is a run of the row that
    /// contains zero-width scalars; `tail` is an ASCII token that is the last
    /// word of the row and is unique across all rows (so a case-insensitive
    /// substring search for it can only hit its own row). No row shares a
    /// scalar with another row's `zeroWidthQuery`.
    private struct Sample {
        let name: String
        let row: String
        let zeroWidthQuery: String
        let tail: String
    }

    private static let samples: [Sample] = [
        // "cafe" + U+0301 COMBINING ACUTE ACCENT (NFD, as in `printf 'cafe\xcc\x81 menu'`).
        Sample(name: "nfd-combining-acute",
               row: "cafe\u{0301} menu",
               zeroWidthQuery: "cafe\u{0301}",
               tail: "menu"),
        // U+2764 HEAVY BLACK HEART + U+FE0F VS16 (as in `printf 'x \xe2\x9d\xa4\xef\xb8\x8f y'`).
        Sample(name: "vs16-heart",
               row: "x \u{2764}\u{FE0F} y",
               zeroWidthQuery: "\u{2764}\u{FE0F}",
               tail: "y"),
        // Thai "ทีนี่": THO THAHAN + SARA II, NO NU + SARA II + MAI EK.
        Sample(name: "thai-vowel-and-tone",
               row: "\u{0E17}\u{0E35}\u{0E19}\u{0E35}\u{0E48} ok",
               zeroWidthQuery: "\u{0E17}\u{0E35}\u{0E19}\u{0E35}\u{0E48}",
               tail: "ok"),
        // WOMAN + ZWJ + PERSONAL COMPUTER (technologist).
        Sample(name: "zwj-technologist",
               row: "a \u{1F469}\u{200D}\u{1F4BB} b",
               zeroWidthQuery: "\u{1F469}\u{200D}\u{1F4BB}",
               tail: "b"),
        // Conjoining Hangul jamo: choseong HIEUH + jungseong A + jongseong NIEUN.
        Sample(name: "hangul-conjoining-jamo",
               row: "k \u{1112}\u{1161}\u{11AB} z",
               zeroWidthQuery: "\u{1112}\u{1161}\u{11AB}",
               tail: "z"),
        // Devanagari "हिन्दी": HA + I sign, NA + VIRAMA, DA + II sign.
        Sample(name: "devanagari-matra-and-virama",
               row: "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940} q",
               zeroWidthQuery: "\u{0939}\u{093F}\u{0928}\u{094D}\u{0926}\u{0940}",
               tail: "q"),
    ]

    private func sampleIndex(named name: String) -> Int {
        Self.samples.firstIndex { (s: Sample) -> Bool in s.name == name } ?? 0
    }

    // MARK: - Fixture

    private typealias Match = (line: Int32, startCol: Int, endCol: Int)

    private let cols: UInt16 = 40
    private let rows: UInt16 = 8

    private enum Placement {
        /// The six sample rows are on screen (buffer lines 0...5).
        case viewport
        /// The same six rows followed by 20 filler lines, so the samples have
        /// all scrolled into history (buffer lines -historySize...).
        case scrollback
    }

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let snap: BBSnapshot
        /// Buffer line of sample 0. Sample `i` is at `firstLine + i`. The
        /// samples are the first lines ever printed, so sample 0 is the oldest
        /// retained line in both placements.
        let firstLine: Int32
        var fc: FindController { view.findController }
        func line(of index: Int) -> Int32 { firstLine + Int32(index) }
    }

    private func makeRig(_ placement: Placement,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: cols, rows: rows))
        view.session = session
        view.findController.installFindBar()

        var text = Self.samples.map { (s: Sample) -> String in s.row }.joined(separator: "\r\n")
        if placement == .scrollback {
            let filler = (0..<20).map { (i: Int) -> String in String(format: "row %03d", i) }
            text += "\r\n" + filler.joined(separator: "\r\n")
        }
        session.feedBytesForTests(Data(text.utf8))
        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "snapshot must be available", file: file, line: line)
        view.currentSnapshot = snap

        // Fixture preconditions: the grid is the size we asked for, the rows
        // are where the test thinks they are, and the core's copy path holds
        // every sample row scalar for scalar (so "the expected text" is what
        // the terminal really holds, not just what this file wrote down).
        XCTAssertEqual(snap.cols, Int(cols), "fixture: grid must be \(cols) columns wide", file: file, line: line)
        XCTAssertEqual(snap.rows, Int(rows), "fixture: grid must be \(rows) rows tall", file: file, line: line)
        XCTAssertEqual(snap.displayOffset, 0, "fixture: the view is not scrolled back", file: file, line: line)
        switch placement {
        case .viewport:
            XCTAssertEqual(snap.historySize, 0,
                           "fixture: six rows in an eight-row grid must not scroll anything into history",
                           file: file, line: line)
        case .scrollback:
            XCTAssertGreaterThanOrEqual(snap.historySize, Self.samples.count,
                                        "fixture: all six sample rows must have scrolled into history",
                                        file: file, line: line)
        }
        let rig = Rig(view: view, session: session, snap: snap, firstLine: -Int32(snap.historySize))
        for (i, s) in Self.samples.enumerated() {
            assertSameScalars(copyText(rig, line: rig.line(of: i)), s.row,
                              "fixture (\(placement)): core copy text of sample '\(s.name)' on line \(rig.line(of: i))",
                              file: file, line: line)
        }
        return rig
    }

    // MARK: - Helpers

    private func hex(_ s: String) -> [String] {
        s.unicodeScalars.map { (u: Unicode.Scalar) -> String in String(format: "U+%04X", u.value) }
    }

    private func assertSameScalars(_ actual: String, _ expected: String, _ what: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(hex(actual), hex(expected),
                       "\(what): scalars must match exactly; actual \"\(actual)\", expected \"\(expected)\"",
                       file: file, line: line)
    }

    /// `s` without its trailing run of spaces / CR / LF (scalar-level).
    private func trimTrailingBlanks(_ s: String) -> String {
        var scalars = Array(s.unicodeScalars)
        while let last = scalars.last, last.value == 0x20 || last.value == 0x0A || last.value == 0x0D {
            scalars.removeLast()
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// What Copy extracts for the whole of buffer line `line` (the core's own
    /// text path), trailing blanks trimmed.
    private func copyText(_ rig: Rig, line: Int32) -> String {
        trimTrailingBlanks(
            rig.session.textRange(from: BufferPoint(line: line, col: 0),
                                  to: BufferPoint(line: line, col: Int(cols) - 1),
                                  rectangular: false))
    }

    /// Reference column for `needle` on `line`: the first column from which
    /// the core's copy text of the rest of the row starts with `needle`'s
    /// scalars. Independent of Find, so the tests pin the column without
    /// hard-coding terminal width tables.
    private func referenceColumn(of needle: String, line: Int32, _ rig: Rig) -> Int? {
        let want = needle.unicodeScalars.map { (u: Unicode.Scalar) -> UInt32 in u.value }
        for c in 0..<Int(cols) {
            let rest = trimTrailingBlanks(
                rig.session.textRange(from: BufferPoint(line: line, col: c),
                                      to: BufferPoint(line: line, col: Int(cols) - 1),
                                      rectangular: false))
            let got = rest.unicodeScalars.map { (u: Unicode.Scalar) -> UInt32 in u.value }
            if got.count >= want.count && Array(got.prefix(want.count)) == want { return c }
        }
        return nil
    }

    private func fmt(_ ms: [Match]) -> String {
        "[" + ms.prefix(12).map { (m: Match) -> String in "(\(m.line),\(m.startCol)-\(m.endCol))" }.joined(separator: " ")
            + (ms.count > 12 ? " ...(\(ms.count) total)" : "") + "]"
    }

    private func positions(_ ms: [Match]) -> [[Int]] {
        ms.map { (m: Match) -> [Int] in [Int(m.line), m.startCol] }
    }

    /// Non-regex, case-insensitive (the bar's defaults) substring search, as
    /// if the query were typed or pasted into the Cmd-F field.
    private func search(_ rig: Rig, _ query: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> [Match] {
        let bar = try XCTUnwrap(rig.fc.findBar, "fixture: find bar must be installed", file: file, line: line)
        XCTAssertFalse(bar.options.regex, "fixture: regex must be off for the substring path", file: file, line: line)
        rig.view.selection = nil
        rig.fc.performSearch(query: query)
        return rig.fc.findMatches
    }

    /// The query `query`, found on sample row `index`: exactly one match, at
    /// the column the core's copy path puts it, and the highlighted match
    /// selects exactly `query`.
    private func assertFoundOnce(_ rig: Rig, sample index: Int, query: String, what: String,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let s = Self.samples[index]
        let target = rig.line(of: index)
        let col = try XCTUnwrap(referenceColumn(of: query, line: target, rig),
                                "\(s.name): fixture oracle must locate '\(query)' on line \(target)",
                                file: file, line: line)
        let ms = try search(rig, query, file: file, line: line)
        XCTAssertEqual(positions(ms), [[Int(target), col]],
                       "\(s.name) / \(what): query \(hex(query)) must match exactly once, starting at "
                       + "(line \(target), col \(col)); got \(fmt(ms))",
                       file: file, line: line)
        assertSameScalars(rig.view.selectedStringForServices() ?? "<no selection>", query,
                          "\(s.name) / \(what): the highlighted match must select exactly the query text",
                          file: file, line: line)
    }

    // MARK: - Fixture sanity

    func test_fixture_copyTextKeepsEveryZeroWidthScalar_onScreenAndInHistory() throws {
        // makeRig asserts the preconditions for every sample row.
        let onScreen = try makeRig(.viewport)
        XCTAssertEqual(onScreen.firstLine, 0, "fixture: sample 0 is buffer line 0 while on screen")
        let inHistory = try makeRig(.scrollback)
        XCTAssertLessThan(inHistory.line(of: Self.samples.count - 1), 0,
                          "fixture: the last sample row must be in history, not on screen")
    }

    // MARK: - 1. Accessibility source (BBSnapshot.visibleRowsAsText)

    func test_visibleRowsAsText_keepsZeroWidthScalars() throws {
        let rig = try makeRig(.viewport)
        let text = rig.snap.visibleRowsAsText()
        XCTAssertGreaterThanOrEqual(text.count, Self.samples.count,
                                    "the snapshot must report at least the six printed rows; got \(text.count)")
        for (i, s) in Self.samples.enumerated() {
            let actual = text.indices.contains(i) ? trimTrailingBlanks(text[i]) : "<missing row>"
            assertSameScalars(actual, s.row, "visibleRowsAsText()[\(i)] (\(s.name))")
        }
    }

    // MARK: - 2. Find haystack (FindController.captureRows)

    private func captureAll(_ rig: Rig) -> [(line: Int32, hay: String, utf16ToCol: [Int]?)] {
        rig.fc.captureRows(
            topLine: -Int32(rig.snap.historySize),
            bottomLine: Int32(rig.snap.rows - 1),
            cols: rig.snap.cols,
            session: rig.session,
            snap: rig.snap
        )
    }

    func test_captureRows_viewportHay_keepsZeroWidthScalars() throws {
        let rig = try makeRig(.viewport)
        let captured = captureAll(rig)
        for (i, s) in Self.samples.enumerated() {
            let target = rig.line(of: i)
            let hay = captured.first { (r: (line: Int32, hay: String, utf16ToCol: [Int]?)) -> Bool in r.line == target }?.hay
            assertSameScalars(hay.map { trimTrailingBlanks($0) } ?? "<row omitted>", s.row,
                              "captureRows hay for on-screen line \(target) (\(s.name))")
        }
    }

    /// Control: once the row is in history the haystack already carries the
    /// scalars. Must keep doing so.
    func test_captureRows_scrollbackHay_keepsZeroWidthScalars_control() throws {
        let rig = try makeRig(.scrollback)
        let captured = captureAll(rig)
        for (i, s) in Self.samples.enumerated() {
            let target = rig.line(of: i)
            let hay = captured.first { (r: (line: Int32, hay: String, utf16ToCol: [Int]?)) -> Bool in r.line == target }?.hay
            assertSameScalars(hay.map { trimTrailingBlanks($0) } ?? "<row omitted>", s.row,
                              "captureRows hay for history line \(target) (\(s.name))")
        }
    }

    // MARK: - 3. Find: query typed / pasted exactly as shown

    func test_viewportFind_combiningAccent_isFound() throws {
        let rig = try makeRig(.viewport)
        let i = sampleIndex(named: "nfd-combining-acute")
        try assertFoundOnce(rig, sample: i, query: Self.samples[i].zeroWidthQuery, what: "visible 'cafe'+U+0301")
    }

    func test_viewportFind_vs16Emoji_isFound() throws {
        let rig = try makeRig(.viewport)
        let i = sampleIndex(named: "vs16-heart")
        try assertFoundOnce(rig, sample: i, query: Self.samples[i].zeroWidthQuery, what: "visible U+2764 U+FE0F")
    }

    func test_viewportFind_thaiVowelAndToneMarks_isFound() throws {
        let rig = try makeRig(.viewport)
        let i = sampleIndex(named: "thai-vowel-and-tone")
        try assertFoundOnce(rig, sample: i, query: Self.samples[i].zeroWidthQuery, what: "visible Thai 'ทีนี่'")
    }

    func test_viewportFind_zwjSequence_isFound() throws {
        let rig = try makeRig(.viewport)
        let i = sampleIndex(named: "zwj-technologist")
        try assertFoundOnce(rig, sample: i, query: Self.samples[i].zeroWidthQuery, what: "visible woman+ZWJ+computer")
    }

    func test_viewportFind_conjoiningJamo_isFound() throws {
        let rig = try makeRig(.viewport)
        let i = sampleIndex(named: "hangul-conjoining-jamo")
        try assertFoundOnce(rig, sample: i, query: Self.samples[i].zeroWidthQuery, what: "visible conjoining jamo")
    }

    func test_viewportFind_devanagariMatraAndVirama_isFound() throws {
        let rig = try makeRig(.viewport)
        let i = sampleIndex(named: "devanagari-matra-and-virama")
        try assertFoundOnce(rig, sample: i, query: Self.samples[i].zeroWidthQuery, what: "visible Devanagari 'हिन्दी'")
    }

    /// The whole printed row as the query: it starts at column 0, ends after
    /// the ASCII tail that FOLLOWS the zero-width scalars, so a match that
    /// found only the head, or lost the column alignment after the
    /// zero-width scalar, selects the wrong text.
    func test_viewportFind_wholeRowAsQuery_matchesAndSelectsTheWholeRow() throws {
        let rig = try makeRig(.viewport)
        for (i, s) in Self.samples.enumerated() {
            try assertFoundOnce(rig, sample: i, query: s.row, what: "the whole row as the query")
        }
    }

    // MARK: - 3b. Control: text after a zero-width scalar keeps its own column

    func test_viewportFind_asciiTokenAfterZeroWidthScalar_matchesAtItsOwnColumn_control() throws {
        let rig = try makeRig(.viewport)
        for (i, s) in Self.samples.enumerated() {
            try assertFoundOnce(rig, sample: i, query: s.tail, what: "ASCII token after the zero-width scalar")
        }
    }

    // MARK: - 3c. Control: the same row in history

    func test_scrollbackFind_zeroWidthQuery_isFound_control() throws {
        for (i, s) in Self.samples.enumerated() {
            // A fresh rig per sample: revealing a history match scrolls the
            // live display, and this headless rig does not refresh its
            // snapshot afterwards, so a second search on the same rig would
            // read a stale viewport. 4 KB per rig, ~10 ms each.
            let rig = try makeRig(.scrollback)
            let target = rig.line(of: i)
            let col = try XCTUnwrap(referenceColumn(of: s.zeroWidthQuery, line: target, rig),
                                    "\(s.name): fixture oracle must locate the query on history line \(target)")
            let ms = try search(rig, s.zeroWidthQuery)
            XCTAssertEqual(positions(ms), [[Int(target), col]],
                           "\(s.name): query \(hex(s.zeroWidthQuery)) must match once in history at "
                           + "(line \(target), col \(col)); got \(fmt(ms))")
        }
    }

    // MARK: - 3d. Regex mode: a match that ends between a base and its zero-width scalars

    /// ICU matches on code points, so a regex can end right after a base
    /// scalar and before the combining mark / VS16 / Thai tone mark that the
    /// terminal keeps on the same cell. The match covers that whole cell (and
    /// both halves of a wide base), not the cell before it.
    private struct RegexCase {
        let sample: String
        /// Regex pattern; ends on the base scalar of its last cell.
        let pattern: String
        /// What the match covers: whole cells, marks included.
        let matched: String
        /// The text that starts on the cell right after the match.
        let following: String
    }

    private static let regexCases: [RegexCase] = [
        RegexCase(sample: "nfd-combining-acute", pattern: "cafe",
                  matched: "cafe\u{0301}", following: " menu"),
        RegexCase(sample: "nfd-combining-acute", pattern: "caf.",
                  matched: "cafe\u{0301}", following: " menu"),
        RegexCase(sample: "vs16-heart", pattern: "\u{2764}",
                  matched: "\u{2764}\u{FE0F}", following: " y"),
        RegexCase(sample: "thai-vowel-and-tone", pattern: "\u{0E17}\u{0E35}\u{0E19}",
                  matched: "\u{0E17}\u{0E35}\u{0E19}\u{0E35}\u{0E48}", following: " ok"),
        RegexCase(sample: "devanagari-matra-and-virama", pattern: "\u{0939}\u{093F}\u{0928}",
                  matched: "\u{0939}\u{093F}\u{0928}\u{094D}", following: "\u{0926}\u{0940} q"),
        // Control: a pattern that already spans the marks ends on the cell it always did.
        RegexCase(sample: "nfd-combining-acute", pattern: "cafe\u{0301}",
                  matched: "cafe\u{0301}", following: " menu"),
        RegexCase(sample: "vs16-heart", pattern: "\u{2764}\u{FE0F}",
                  matched: "\u{2764}\u{FE0F}", following: " y"),
    ]

    /// Type `pattern` into the bar in regex mode and wait for the async scan
    /// to publish exactly one match.
    private func regexSearch(_ rig: Rig, _ pattern: String,
                             file: StaticString = #filePath, line: UInt = #line) throws -> [Match] {
        let bar = try XCTUnwrap(rig.fc.findBar, "fixture: find bar must be installed", file: file, line: line)
        if !bar.options.regex { bar.toggleRegexMode(nil) }
        XCTAssertTrue(bar.options.regex, "fixture: regex mode must be on", file: file, line: line)
        rig.view.selection = nil
        bar.setQuery(pattern)
        let deadline = Date(timeIntervalSinceNow: 3.0)
        while Date() < deadline, rig.fc.findMatches.isEmpty {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return rig.fc.findMatches
    }

    func test_viewportRegexFind_matchEndingBeforeZeroWidthScalars_coversTheWholeCell() throws {
        for rc in Self.regexCases {
            // A fresh rig per case: one view + one session, ~4 KB, ~10 ms.
            let rig = try makeRig(.viewport)
            let i = sampleIndex(named: rc.sample)
            XCTAssertEqual(Self.samples[i].name, rc.sample, "fixture: sample '\(rc.sample)' must exist")
            let target = rig.line(of: i)
            let startCol = try XCTUnwrap(referenceColumn(of: rc.matched, line: target, rig),
                                         "\(rc.sample): fixture oracle must locate \(hex(rc.matched)) on line \(target)")
            let nextCol = try XCTUnwrap(referenceColumn(of: rc.following, line: target, rig),
                                        "\(rc.sample): fixture oracle must locate \(hex(rc.following)) on line \(target)")
            let ms = try regexSearch(rig, rc.pattern)
            XCTAssertEqual(ms.count, 1,
                           "\(rc.sample) /\(rc.pattern)/: must match exactly once; got \(fmt(ms))")
            guard let m = ms.first else { continue }
            XCTAssertEqual([Int(m.line), m.startCol, m.endCol], [Int(target), startCol, nextCol - 1],
                           "\(rc.sample) /\(rc.pattern)/: the match must cover cols \(startCol)...\(nextCol - 1) of line "
                           + "\(target) (every cell up to the one the next text starts on); got \(fmt(ms))")
            assertSameScalars(rig.view.selectedStringForServices() ?? "<no selection>", rc.matched,
                              "\(rc.sample) /\(rc.pattern)/: the highlighted match must select whole cells, marks included")
        }
    }

    // MARK: - 4. Cmd-E (Use Selection for Find)

    /// Select the whole row, press Cmd-E: the query it seeds is the row's
    /// text, and that text is on screen, so it must be found at the row it
    /// came from.
    func test_cmdE_onSelectedVisibleRow_findsThatRow() throws {
        let rig = try makeRig(.viewport)
        for (i, s) in Self.samples.enumerated() {
            let target = rig.line(of: i)
            rig.view.selection = Selection(
                anchor: BufferPoint(line: target, col: 0),
                cursor: BufferPoint(line: target, col: Int(cols) - 1),
                mode: .character)
            assertSameScalars(trimTrailingBlanks(rig.view.selectedStringForServices() ?? "<no selection>"), s.row,
                              "\(s.name): precondition, the selected text of the row")

            rig.view.useSelectionForFind(nil)

            assertSameScalars(rig.fc.findQuery, s.row,
                              "\(s.name): Cmd-E must seed the query with the selected row's text")
            XCTAssertEqual(positions(rig.fc.findMatches), [[Int(target), 0]],
                           "\(s.name): the Cmd-E query \(hex(s.row)) is the visible row, so it must match once "
                           + "at (line \(target), col 0); got \(fmt(rig.fc.findMatches))")
        }
    }

    // MARK: - 5. VoiceOver (accessibilityValue and its per-line strings)

    private func scalarLines(_ s: String) -> [String] {
        s.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { (part: Substring.UnicodeScalarView) -> String in
                var joined = String.UnicodeScalarView()
                joined.append(contentsOf: part)
                return String(joined)
            }
    }

    func test_accessibilityValue_visibleRows_keepZeroWidthScalars() throws {
        let rig = try makeRig(.viewport)
        let value = (rig.view.accessibilityValue() as? String) ?? "<accessibilityValue was not a String>"
        let lines = scalarLines(value)
        XCTAssertGreaterThanOrEqual(lines.count, Self.samples.count,
                                    "accessibilityValue must carry at least the six printed rows; got \(lines.count)")
        for (i, s) in Self.samples.enumerated() {
            let actual = lines.indices.contains(i) ? lines[i] : "<missing line>"
            assertSameScalars(actual, s.row, "accessibilityValue line \(i) (\(s.name))")
        }
    }

    func test_accessibilityLineStrings_visibleRows_keepZeroWidthScalars() throws {
        let rig = try makeRig(.viewport)
        for (i, s) in Self.samples.enumerated() {
            let range = rig.view.accessibilityRange(forLine: i)
            let text = rig.view.accessibilityString(for: range) ?? "<nil>"
            assertSameScalars(text, s.row,
                              "accessibilityString(for: accessibilityRange(forLine: \(i)) = \(range)) (\(s.name))")
        }
    }
}
