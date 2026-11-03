import XCTest
import AppKit
@testable import Blackbird

/// Blind regression pins for "the IME preedit width model must agree with the
/// width the Rust grid gives the SAME text once it is committed".
///
/// The preedit overlay (`refreshPreeditOverlay`), the candidate-popover anchor
/// (`firstRect(forCharacterRange:actualRange:)`) and the click mapping
/// (`characterIndex(for:)`) all convert marked text into terminal cells through
/// the Swift-side `CellWidth` model, because the composing string is not in the
/// grid yet. Once the user commits, the Rust core lays the text out with its own
/// per-scalar rules and the cursor advances by *that* many cells. If the two
/// models disagree, the popover and overlay sit a cell or more away from where
/// the committed text lands, and a click on the preedit maps to the wrong
/// offset.
///
/// Truth for these tests is the real grid: `gridWidth(of:)` feeds the text to a
/// fresh `BBTerm` at the home position and reads back how far the cursor
/// advanced. `test_gridOracle_...` pins the fixture table to that oracle (and to
/// the Unicode conventions the fixtures were chosen from), so every other test
/// in this file can compare against `Fixture.cells` and fail only because the
/// Swift model disagrees with the grid, never because the table is wrong.
///
/// Fixture families (each is its own test so a failure names the family):
///  - wide symbols/emoji that are East-Asian-Wide in the grid (U+2705 U+2B50
///    U+2B55 U+2728 U+26A1 U+1FAE0 ...) -- the Japanese-IME candidates
///    まる→⭕, ほし→⭐, ちぇっく→✅;
///  - text-default pictographs in U+1F300..1F6FF (🌡 🖥 ...) that the grid lays
///    out in ONE cell;
///  - spacing combining marks (Hindi कि, Thai กำ) that the grid gives their own
///    cell although Swift segments them into the base's grapheme;
///  - controls that agree today (ASCII, CJK, Mn-only combining marks, VS16),
///    which prove the harness measures real differences instead of constants.
///
/// Cost: one tiny `BBTerm` (80x24, ~60 KB) per fixture for the oracle test, one
/// headless `TerminalView` + one offscreen non-tabbed `NSWindow` per test, no
/// PTY, no real shell, no run-loop pumping. Wall time well under a second per
/// test.
final class IMEPreeditGridWidthParityBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private struct Fixture {
        /// Marked text under test.
        let text: String
        /// Human label for assertion messages.
        let label: String
        /// Number of terminal cells the Rust grid advances the cursor by.
        let cells: Int
    }

    /// East-Asian-Wide / Emoji_Presentation=Yes scalars the grid draws in two
    /// cells but which are NOT in the "obvious" CJK/emoji blocks: the Japanese
    /// IME symbol/emoji candidates plus other very common emoji.
    private static let wideSymbols: [Fixture] = [
        Fixture(text: "\u{2B55}", label: "heavy large circle (まる→⭕)", cells: 2),
        Fixture(text: "\u{2B50}", label: "white medium star (ほし→⭐)", cells: 2),
        Fixture(text: "\u{2705}", label: "white heavy check mark (ちぇっく→✅)", cells: 2),
        Fixture(text: "\u{2728}", label: "sparkles", cells: 2),
        Fixture(text: "\u{26A1}", label: "high voltage", cells: 2),
        Fixture(text: "\u{1FAE0}", label: "melting face (Emoji 14)", cells: 2),
        Fixture(text: "\u{274C}", label: "cross mark", cells: 2),
        Fixture(text: "\u{2753}", label: "black question mark ornament", cells: 2),
        Fixture(text: "\u{2614}", label: "umbrella with rain drops", cells: 2),
        Fixture(text: "\u{231A}", label: "watch", cells: 2),
    ]

    /// Pictographs in U+1F300..1F6FF whose default presentation is text: East
    /// Asian Width Neutral, so the grid gives them ONE cell.
    private static let textDefaultSymbols: [Fixture] = [
        Fixture(text: "\u{1F321}", label: "thermometer", cells: 1),
        Fixture(text: "\u{1F5A5}", label: "desktop computer", cells: 1),
        Fixture(text: "\u{1F336}", label: "hot pepper", cells: 1),
        Fixture(text: "\u{1F3CB}", label: "weight lifter", cells: 1),
        Fixture(text: "\u{1F6E0}", label: "hammer and wrench", cells: 1),
        Fixture(text: "\u{1F5E1}", label: "dagger knife", cells: 1),
    ]

    /// Spacing combining marks (Mc) / SARA AM: the grid advances one cell for
    /// each of these scalars, while a Swift `Character` folds them into the
    /// base's grapheme cluster.
    private static let spacingMarks: [Fixture] = [
        Fixture(text: "\u{0915}\u{093F}", label: "Devanagari ka + vowel sign i (कि)", cells: 2),
        Fixture(text: "\u{0915}\u{0940}", label: "Devanagari ka + vowel sign ii (की)", cells: 2),
        Fixture(text: "\u{0E01}\u{0E33}", label: "Thai ko kai + sara am (กำ)", cells: 2),
        Fixture(text: "\u{0E19}\u{0E49}\u{0E33}", label: "Thai no nu + mai tho + sara am (น้ำ)", cells: 2),
    ]

    /// Cases the Swift model already gets right. They must keep agreeing with
    /// the grid, and they prove the measurements below are real (a model that
    /// returned a constant would fail them).
    private static let controls: [Fixture] = [
        Fixture(text: "a", label: "ASCII letter", cells: 1),
        Fixture(text: "abc", label: "ASCII word", cells: 3),
        Fixture(text: "\u{3042}", label: "hiragana a", cells: 2),
        Fixture(text: "\u{6F22}\u{5B57}", label: "CJK ideographs", cells: 4),
        Fixture(text: "\u{D55C}", label: "Hangul syllable", cells: 2),
        Fixture(text: "e\u{0301}", label: "e + combining acute", cells: 1),
        Fixture(text: "\u{0628}\u{064E}", label: "Arabic ba + fatha (Mn only)", cells: 1),
        Fixture(text: "\u{05E9}\u{05C1}\u{05B8}", label: "Hebrew shin + shin dot + qamats (Mn only)", cells: 1),
        Fixture(text: "\u{0E01}\u{0E48}", label: "Thai ko kai + mai ek tone mark (Mn only)", cells: 1),
        Fixture(text: "\u{26A0}\u{FE0F}", label: "warning sign + VS16", cells: 2),
        Fixture(text: "\u{2764}\u{FE0F}", label: "red heart + VS16", cells: 2),
    ]

    private static var bugFixtures: [Fixture] {
        wideSymbols + textDefaultSymbols + spacingMarks
    }

    // MARK: - Helpers

    private func scalars(_ text: String) -> String {
        text.unicodeScalars
            .map { (s: Unicode.Scalar) -> String in String(format: "U+%04X", s.value) }
            .joined(separator: " ")
    }

    /// Ground truth: how many cells the Rust grid advances the cursor when
    /// `text` is printed at the home position of a fresh terminal.
    private func gridWidth(of text: String) throws -> Int {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24), scrollback: 100))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cursorRow, 0,
                       "oracle precondition: \(scalars(text)) must not wrap in an 80-column grid")
        return snap.cursorCol
    }

    /// A headless view hosted in a transient offscreen, NON-tabbed window (the
    /// IME mapping from screen points needs a window). Same pattern as
    /// `IMETests.test_characterIndex_emojiPresentationGraphemeCountsTwoCells`.
    private func makeHostedView() throws -> (view: TerminalView, window: NSWindow) {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock {
            window.contentView = nil
            window.close()
        }
        view.installCursorForTests(row: 0, col: 0)
        return (view, window)
    }

    private func mark(_ view: TerminalView, _ text: String) {
        view.setMarkedText(
            text,
            selectedRange: NSRange(location: text.utf16.count, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    // MARK: - Oracle pin

    /// The fixture table is the contract for every other test here. Pin it to
    /// the real Rust grid so a wrong table entry cannot masquerade as an IME
    /// bug (this test is about the core, and passes on a correct core).
    func test_gridOracle_agreesWithFixtureTable() throws {
        let all = Self.bugFixtures + Self.controls
        XCTAssertEqual(all.count, 31, "fixture table size drifted; re-audit it")
        for fixture in all {
            XCTAssertEqual(
                try gridWidth(of: fixture.text), fixture.cells,
                "Rust grid advanced the cursor by the wrong amount for "
                    + "\(fixture.label) [\(scalars(fixture.text))]; fixture expectation is stale"
            )
        }
        // A composed Japanese clause: チェック✅ = 4 wide katakana + 1 wide emoji.
        XCTAssertEqual(try gridWidth(of: "チェック✅"), 10,
                       "grid width of チェック✅ [\(scalars("チェック✅"))]")
    }

    // MARK: - CellWidth vs grid (unit level)

    private func assertCellWidthMatchesGrid(_ fixtures: [Fixture],
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        for fixture in fixtures {
            XCTAssertEqual(
                CellWidth.terminalCellWidth(of: fixture.text), fixture.cells,
                "CellWidth.terminalCellWidth disagrees with the grid for "
                    + "\(fixture.label) [\(scalars(fixture.text))]: the grid lays it out "
                    + "in \(fixture.cells) cell(s)",
                file: file, line: line
            )
        }
    }

    func test_cellWidth_wideSymbolsCountTwoCellsLikeTheGrid() {
        assertCellWidthMatchesGrid(Self.wideSymbols)
    }

    func test_cellWidth_textDefaultPictographsCountOneCellLikeTheGrid() {
        assertCellWidthMatchesGrid(Self.textDefaultSymbols)
    }

    func test_cellWidth_spacingMarksCountOneCellEachLikeTheGrid() {
        assertCellWidthMatchesGrid(Self.spacingMarks)
    }

    func test_cellWidth_controlsStillAgreeWithGrid() {
        assertCellWidthMatchesGrid(Self.controls)
    }

    // MARK: - ZWJ / modifier graphemes (unit level)

    /// A ZWJ outside an emoji sequence is NOT collapsed to one glyph: the Hindi
    /// conjunct ka + virama + ZWJ + ssa is laid out scalar by scalar (1 + 0 + 0
    /// + 1) by the grid, and the preedit model must agree whichever way the
    /// runtime's grapheme segmentation splits it. Skin-tone modifiers and flags
    /// WITHOUT a ZWJ are likewise summed per scalar, as the grid does.
    func test_cellWidth_nonEmojiZwjAndModifierGraphemesFollowGrid() throws {
        let samples: [(label: String, text: String)] = [
            ("Devanagari ka + virama + ZWJ + ssa", "\u{0915}\u{094D}\u{200D}\u{0937}"),
            ("Devanagari ka + virama + ssa", "\u{0915}\u{094D}\u{0937}"),
            ("thumbs up + skin tone (no ZWJ)", "\u{1F44D}\u{1F3FD}"),
            ("regional indicators U+1F1FA U+1F1F8 (flag)", "\u{1F1FA}\u{1F1F8}"),
        ]
        for sample in samples {
            XCTAssertEqual(
                CellWidth.terminalCellWidth(of: sample.text), try gridWidth(of: sample.text),
                "CellWidth disagrees with the grid for \(sample.label) [\(scalars(sample.text))]"
            )
        }
    }

    /// An emoji ZWJ sequence is drawn as a single 2-cell glyph (modifiers
    /// included), and the grid advances the cursor the same 2 cells.
    func test_cellWidth_emojiZwjSequenceIsOneGlyphWideDespiteGridSum() throws {
        let womanTechnologist = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
        XCTAssertEqual(CellWidth.terminalCellWidth(of: womanTechnologist), 2,
                       "[\(scalars(womanTechnologist))] is one 2-cell glyph")
    }

    // MARK: - firstRect(forCharacterRange:) anchors (IME level)

    /// The candidate popover for a clause that FOLLOWS the symbol must be
    /// anchored where the committed clause will land: `cells` columns to the
    /// right of the composition's left edge.
    private func assertFollowingClauseAnchoredAtGridColumn(_ fixtures: [Fixture],
                                                           file: StaticString = #filePath,
                                                           line: UInt = #line) throws {
        let (view, _) = try makeHostedView()
        let cw = view.metrics.cellWidth
        XCTAssertGreaterThan(cw, 1, "precondition: cell width must be a real measurement",
                             file: file, line: line)
        for fixture in fixtures {
            let composition = fixture.text + "X"
            mark(view, composition)
            XCTAssertTrue(view.hasMarkedText(), "precondition: composition active",
                          file: file, line: line)
            let xIndex = fixture.text.utf16.count
            XCTAssertEqual((composition as NSString).length, xIndex + 1,
                           "fixture sanity: X is the last UTF-16 unit", file: file, line: line)

            let origin = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1),
                                        actualRange: nil)
            let rectX = view.firstRect(forCharacterRange: NSRange(location: xIndex, length: 1),
                                       actualRange: nil)
            XCTAssertEqual(origin.origin.y, rectX.origin.y, accuracy: 0.5,
                           "preedit stays on one row for \(fixture.label)", file: file, line: line)
            let measuredCells = (rectX.origin.x - origin.origin.x) / cw
            XCTAssertEqual(
                rectX.origin.x - origin.origin.x, CGFloat(fixture.cells) * cw, accuracy: 0.5,
                "firstRect for the character after \(fixture.label) [\(scalars(fixture.text))] "
                    + "is \(measuredCells) cells from the preedit origin; the grid will place "
                    + "committed text \(fixture.cells) cells away",
                file: file, line: line
            )
        }
    }

    func test_firstRect_afterWideSymbol_isAnchoredTwoCellsOver() throws {
        try assertFollowingClauseAnchoredAtGridColumn(Self.wideSymbols)
    }

    func test_firstRect_afterTextDefaultPictograph_isAnchoredOneCellOver() throws {
        try assertFollowingClauseAnchoredAtGridColumn(Self.textDefaultSymbols)
    }

    func test_firstRect_afterSpacingMarkCluster_isAnchoredTwoCellsOver() throws {
        try assertFollowingClauseAnchoredAtGridColumn(Self.spacingMarks)
    }

    func test_firstRect_afterControls_staysAnchoredAtGridColumn() throws {
        try assertFollowingClauseAnchoredAtGridColumn(Self.controls)
    }

    /// A realistic Japanese conversion: "チェック✅完了" (check + ✅ + "done").
    /// The clause "完了" begins after 4 wide katakana and the 2-cell ✅, i.e.
    /// 10 cells in; the candidate window for it must sit there.
    func test_firstRect_japaneseClauseAfterCheckEmoji_isAnchoredAtColumnTen() throws {
        let (view, _) = try makeHostedView()
        let cw = view.metrics.cellWidth
        let composition = "チェック✅完了"
        mark(view, composition)
        XCTAssertEqual(composition.utf16.count, 7, "fixture sanity: all BMP, 7 UTF-16 units")
        let origin = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1),
                                    actualRange: nil)
        let clause = view.firstRect(forCharacterRange: NSRange(location: 5, length: 2),
                                    actualRange: nil)
        XCTAssertEqual(origin.origin.y, clause.origin.y, accuracy: 0.5,
                       "preedit stays on one row")
        XCTAssertEqual(
            (clause.origin.x - origin.origin.x) / cw, 10, accuracy: 0.05,
            "the 完了 clause starts 10 grid cells into チェック✅完了 "
                + "[\(scalars(composition))]; popover is anchored \((clause.origin.x - origin.origin.x) / cw) cells in"
        )
    }

    /// The popover anchored to the symbol clause itself spans the cells the
    /// committed symbol will occupy.
    func test_firstRect_symbolClauseWidth_spansGridCells() throws {
        let (view, _) = try makeHostedView()
        let cw = view.metrics.cellWidth
        XCTAssertGreaterThan(cw, 1, "precondition: cell width must be a real measurement")
        for fixture in Self.bugFixtures + Self.controls {
            mark(view, fixture.text)
            let whole = view.firstRect(
                forCharacterRange: NSRange(location: 0, length: fixture.text.utf16.count),
                actualRange: nil
            )
            XCTAssertEqual(
                whole.width, CGFloat(fixture.cells) * cw, accuracy: 0.5,
                "firstRect width for the whole clause \(fixture.label) "
                    + "[\(scalars(fixture.text))] is \(whole.width / cw) cells; the grid "
                    + "lays it out in \(fixture.cells)"
            )
        }
    }

    // MARK: - characterIndex(for:) click mapping (IME level)

    /// A click in the middle of the cell that holds the character AFTER the
    /// symbol (grid column `cells`) must map to that character's UTF-16 index.
    private func assertClickAfterSymbolMapsToFollowingChar(_ fixtures: [Fixture],
                                                           file: StaticString = #filePath,
                                                           line: UInt = #line) throws {
        let (view, window) = try makeHostedView()
        let cw = max(view.metrics.cellWidth, 1)
        for fixture in fixtures {
            let composition = fixture.text + "X"
            mark(view, composition)
            XCTAssertTrue(view.hasMarkedText(), "precondition: composition active",
                          file: file, line: line)
            let cellRect = view.cursorCellRectInView()
            let local = NSPoint(x: cellRect.minX + (CGFloat(fixture.cells) + 0.5) * cw,
                                y: cellRect.midY)
            let screenPoint = window.convertPoint(toScreen: view.convert(local, to: nil))
            let expected = fixture.text.utf16.count
            XCTAssertEqual(
                view.characterIndex(for: screenPoint), expected,
                "a click in grid column \(fixture.cells) (the cell holding 'X') after "
                    + "\(fixture.label) [\(scalars(fixture.text))] must map to UTF-16 index "
                    + "\(expected), the 'X'",
                file: file, line: line
            )
        }
    }

    func test_characterIndex_clickAfterWideSymbol_mapsToFollowingChar() throws {
        try assertClickAfterSymbolMapsToFollowingChar(Self.wideSymbols)
    }

    func test_characterIndex_clickAfterTextDefaultPictograph_mapsToFollowingChar() throws {
        try assertClickAfterSymbolMapsToFollowingChar(Self.textDefaultSymbols)
    }

    func test_characterIndex_clickAfterSpacingMarkCluster_mapsToFollowingChar() throws {
        try assertClickAfterSymbolMapsToFollowingChar(Self.spacingMarks)
    }

    func test_characterIndex_clicksAfterControls_stillMapToFollowingChar() throws {
        try assertClickAfterSymbolMapsToFollowingChar(Self.controls)
    }

    // MARK: - refreshPreeditOverlay sizing (IME level)

    /// The overlay must cover exactly the cells the committed text will
    /// occupy. Calibrated against ASCII compositions of the same cell count
    /// (1 cell per char, correct today) so any inset/padding in the overlay's
    /// frame cancels out.
    func test_preeditOverlay_widthMatchesGridCells() throws {
        let (view, _) = try makeHostedView()
        let cw = view.metrics.cellWidth
        XCTAssertGreaterThan(cw, 1, "precondition: cell width must be a real measurement")

        func overlayWidth(_ text: String) throws -> CGFloat {
            mark(view, text)
            let overlay = try XCTUnwrap(view.preeditOverlay,
                                        "overlay must exist while composing \(scalars(text))")
            return overlay.frame.width
        }

        // Precondition: the overlay really is sized per cell (ASCII 1 cell/char).
        let w3 = try overlayWidth("aaa")
        let w4 = try overlayWidth("aaaa")
        XCTAssertEqual(w4 - w3, cw, accuracy: 0.5,
                       "precondition: overlay grows by one cell per ASCII char "
                           + "(w3=\(w3), w4=\(w4), cellWidth=\(cw))")

        for fixture in Self.bugFixtures + Self.controls {
            let measured = try overlayWidth(fixture.text)
            let reference = try overlayWidth(String(repeating: "a", count: fixture.cells))
            XCTAssertEqual(
                measured, reference, accuracy: 0.5,
                "preedit overlay for \(fixture.label) [\(scalars(fixture.text))] is "
                    + "\(measured) pt wide; the grid lays the committed text out in "
                    + "\(fixture.cells) cells = \(reference) pt"
            )
        }
    }
}
