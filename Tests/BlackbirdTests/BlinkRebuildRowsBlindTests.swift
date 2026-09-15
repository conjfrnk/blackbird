import XCTest
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the `blinkChanged:` parameter of
/// `MetalRenderer.decideRebuildRows`, written from the spec without sight
/// of the implementation.
///
/// Background: the cursor-blink phase used to be part of the row-cache
/// key, so every blink flip (twice a second) forced a FULL grid rebuild.
/// The phase is now excluded from the key and the decision function
/// gains `blinkChanged: Bool` (after `cursorMoved:`). New signature:
///
///     decideRebuildRows(snap:, cacheCompatible:, snapshotCoalesced:,
///                       cursorMoved:, blinkChanged:,
///                       prevCursorRow:, prevCursorCol:, curRow:) -> Set<Int>?
///
/// Contract under test (`nil` means "rebuild everything"):
///  1. `blinkChanged: true`, cache compatible, empty damage, cursor still
///     → exactly `{ screenCursorRow }` where
///     `screenCursorRow = curRow + snap.displayOffset`, when that lies in
///     `0..<snap.rows`.
///  2. Same but the cursor row is off screen → the EMPTY set, not `nil`.
///  3. `blinkChanged: false` → identical to the pre-change behaviour
///     (representative cases from `RebuildRowsDecisionBlindTests` are
///     re-run here with the new parameter to pin no regression).
///  4. `blinkChanged: true` + partial damage → damaged rows ∪ { cursor row }.
///  5. `blinkChanged: true` + `cacheCompatible: false` (or full damage /
///     coalesced / damage ≥ half) → `nil`; the full rebuild still wins.
///  6. `blinkChanged: true` + `cursorMoved: true` → { prevScreenRow,
///     newScreenRow } (the blink row IS the new row, so the union adds
///     nothing).
///
/// Damage comes from a real `BBTerm`. The empty-damage fixture is copied
/// from `RebuildRowsDecisionBlindTests` (kept self-contained on purpose):
/// a no-input snapshot with the cursor on screen still reports the cursor
/// row as damaged, so genuinely empty damage comes from either a hidden
/// cursor or a viewport scrolled into history. Every expectation is
/// computed from the snapshot's real `displayOffset`, so the tests pin
/// the spec's formula regardless of which fixture route wins.
///
/// Memory / time pre-flight: one 20 × 8 `BBTerm` (`scrollback: 32`, 160
/// cells) and one `MetalRenderer` per test. The renderer is constructed,
/// never asked to draw; the function under test is pure. Wall time is
/// dominated by `MTLCreateSystemDefaultDevice()` + pipeline load.
/// <2 MB, <200 ms per test.
final class BlinkRebuildRowsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private let cols: UInt16 = 20
    private let rows: UInt16 = 8
    private var halfRows: Int { (Int(rows) + 1) / 2 }

    // MARK: - Rig (mirrors RebuildRowsDecisionBlindTests)

    private func makeRenderer() throws -> MetalRenderer {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        return try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
    }

    private func makeTerm() throws -> BBTerm {
        try XCTUnwrap(BBTerm(size: .init(cols: cols, rows: rows), scrollback: 32))
    }

    /// Fresh term with its initial full-damage snapshot consumed, so the
    /// next snapshot is a delta.
    private func makeSettledTerm() throws -> BBTerm {
        let term = try makeTerm()
        _ = try XCTUnwrap(term.snapshot(), "initial snapshot")
        return term
    }

    /// A snapshot with `damageIsFull == false` and `damagedRows == []`,
    /// plus the term that owns it (kept alive alongside).
    private struct EmptyDamageFixture {
        let term: BBTerm
        let snap: BBSnapshot
        var offset: Int { snap.displayOffset }
    }

    private func emptyDamageSnapshot(file: StaticString = #filePath, line: UInt = #line) throws -> EmptyDamageFixture {
        // Attempt 1: hidden cursor, no input. Two snapshots so the DECTCEM
        // change itself has been consumed.
        let hidden = try makeSettledTerm()
        hidden.input("\u{1B}[?25l")
        _ = try XCTUnwrap(hidden.snapshot(), file: file, line: line)
        let hiddenSnap = try XCTUnwrap(hidden.snapshot(), file: file, line: line)
        if !hiddenSnap.damageIsFull && hiddenSnap.damagedRows.isEmpty {
            return EmptyDamageFixture(term: hidden, snap: hiddenSnap)
        }

        // Attempt 2: scroll the viewport into history so the cursor row is
        // off screen. 12 lines into 8 rows puts ≥ 4 lines in history.
        let term = try makeTerm()
        term.input(String(repeating: "x\r\n", count: 12))
        _ = try XCTUnwrap(term.snapshot(), file: file, line: line)
        term.scroll(delta: 2)
        var scrolled = try XCTUnwrap(term.snapshot(), file: file, line: line)
        if scrolled.displayOffset == 0 {
            // Sign convention of `scroll(delta:)` is not part of this spec;
            // try the other direction before giving up.
            term.scroll(delta: -4)
            scrolled = try XCTUnwrap(term.snapshot(), file: file, line: line)
        }
        XCTAssertGreaterThan(scrolled.displayOffset, 0,
                             "precondition: viewport must be scrolled into history", file: file, line: line)
        let settled = try XCTUnwrap(term.snapshot(), file: file, line: line)
        XCTAssertFalse(settled.damageIsFull,
                       "precondition: a no-input snapshot at a fixed offset must be a delta", file: file, line: line)
        XCTAssertEqual(settled.damagedRows, [],
                       "precondition: could not obtain an empty-damage snapshot by either route "
                       + "(hidden cursor gave \(hiddenSnap.damagedRows))", file: file, line: line)
        XCTAssertEqual(settled.displayOffset, scrolled.displayOffset, file: file, line: line)
        return EmptyDamageFixture(term: term, snap: settled)
    }

    /// The spec's screen-row formula: `row + displayOffset`, kept only
    /// when inside `0..<rows`.
    private func screenRows(_ gridRows: [Int32], offset: Int) -> Set<Int> {
        Set(gridRows.map { Int($0) + offset }.filter { $0 >= 0 && $0 < Int(rows) })
    }

    /// A grid row whose screen row (`row + offset`) is guaranteed on
    /// screen for any fixture offset in `0..<rows`: grid row 0 maps to
    /// screen row `offset`, which is `< rows` whenever the viewport is
    /// less than a full screen into history.
    private let onScreenGridRow: Int32 = 0

    private func decide(
        _ r: MetalRenderer, _ snap: BBSnapshot,
        cacheCompatible: Bool = true, coalesced: Bool = false,
        cursorMoved: Bool = false, blinkChanged: Bool = false,
        prevRow: Int32 = 0, prevCol: Int32 = 0, curRow: Int32 = 0
    ) -> Set<Int>? {
        r.decideRebuildRows(
            snap: snap, cacheCompatible: cacheCompatible, snapshotCoalesced: coalesced,
            cursorMoved: cursorMoved, blinkChanged: blinkChanged,
            prevCursorRow: prevRow, prevCursorCol: prevCol, curRow: curRow
        )
    }

    // MARK: - 1. Blink flip alone rebuilds exactly the cursor row

    func test_blinkChanged_emptyDamage_cursorStill_returnsOnlyCursorScreenRow() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        let cur = onScreenGridRow
        let expected = screenRows([cur], offset: f.offset)
        XCTAssertEqual(expected.count, 1,
                       "fixture: grid row \(cur) + offset \(f.offset) must be on screen")

        let result = decide(r, f.snap, cursorMoved: false, blinkChanged: true,
                            prevRow: cur, prevCol: 3, curRow: cur)
        XCTAssertEqual(result, expected,
                       "a blink flip with nothing else changed rebuilds exactly the cursor's screen row "
                       + "(grid \(cur) + offset \(f.offset))")
    }

    // MARK: - 2. Blink flip with the cursor off screen rebuilds nothing

    func test_blinkChanged_cursorRowOffScreen_returnsEmptySetNotNil() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()

        // Far past the bottom regardless of offset.
        let below = decide(r, f.snap, blinkChanged: true, prevRow: 100, curRow: 100)
        XCTAssertEqual(below, [], "cursor below the screen → nothing to rebuild for a blink flip")

        // Far above the top (negative screen row).
        let above = decide(r, f.snap, blinkChanged: true, prevRow: -50, curRow: -50)
        XCTAssertEqual(above, [], "cursor above the screen → nothing to rebuild for a blink flip")

        // Exactly one row past the bottom edge (`rows + offset`), the
        // boundary of the half-open range.
        let edge = Int32(Int(rows) - f.offset)
        let atEdge = decide(r, f.snap, blinkChanged: true, prevRow: edge, curRow: edge)
        XCTAssertEqual(atEdge, [], "screen row \(Int(edge) + f.offset) == rows is outside 0..<rows and must be excluded")

        // When the viewport is scrolled, the bottom grid row is pushed off
        // the visible screen too.
        if f.offset > 0 {
            let bottom = Int32(rows) - 1
            XCTAssertEqual(decide(r, f.snap, blinkChanged: true, prevRow: bottom, curRow: bottom), [],
                           "grid row \(bottom) + offset \(f.offset) is below the screen and must be excluded")
        }
    }

    // MARK: - 3. blinkChanged: false → no regression against the existing contract

    func test_blinkUnchanged_emptyDamage_matchesPreChangeBehaviour() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()

        // Cursor still → empty set (not nil, not the cursor row).
        let still = decide(r, f.snap, cursorMoved: false, blinkChanged: false,
                           prevRow: onScreenGridRow, prevCol: 5, curRow: onScreenGridRow)
        XCTAssertEqual(still, [], "no blink, no damage, no move → nothing to rebuild")

        // Cursor moved → prev + current screen rows only.
        let moved = decide(r, f.snap, cursorMoved: true, blinkChanged: false,
                           prevRow: 1, prevCol: 0, curRow: 4)
        let expectedMoved = screenRows([1, 4], offset: f.offset)
        XCTAssertFalse(expectedMoved.isEmpty, "fixture: at least one cursor row must land on screen (offset \(f.offset))")
        XCTAssertEqual(moved, expectedMoved, "a cursor hop rebuilds the row it left and the row it landed on")

        // Both cursor rows off screen → non-nil, empty.
        let both = decide(r, f.snap, cursorMoved: true, blinkChanged: false, prevRow: -50, curRow: 100)
        XCTAssertEqual(both, [], "out-of-range cursor rows are dropped, not escalated to a full rebuild")
    }

    func test_blinkUnchanged_partialDamage_matchesPreChangeBehaviour() throws {
        let r = try makeRenderer()
        let term = try makeSettledTerm()
        term.input("hello") // row 0
        let snap = try XCTUnwrap(term.snapshot())
        try XCTSkipIf(snap.damageIsFull, "parser reported full damage for a single-row write; the small-damage path is untestable with this input")
        XCTAssertTrue(snap.damagedRows.contains(0), "precondition: the text landed on row 0, got \(snap.damagedRows)")
        XCTAssertLessThan(snap.damagedRows.count, halfRows, "precondition: below the half-rows threshold")

        XCTAssertEqual(decide(r, snap, cursorMoved: false, blinkChanged: false, prevRow: 0, curRow: 0),
                       Set(snap.damagedRows),
                       "small damage, still cursor, no blink → exactly the damaged rows")
        XCTAssertEqual(decide(r, snap, cursorMoved: true, blinkChanged: false, prevRow: 6, curRow: 7),
                       Set(snap.damagedRows).union(screenRows([6, 7], offset: snap.displayOffset)),
                       "small damage + cursor move → damaged rows ∪ both cursor rows")
    }

    func test_blinkUnchanged_fullRebuildCases_stillReturnNil() throws {
        let r = try makeRenderer()

        // cacheCompatible: false and snapshotCoalesced: true, on empty damage.
        let f = try emptyDamageSnapshot()
        XCTAssertNil(decide(r, f.snap, cacheCompatible: false, blinkChanged: false))
        XCTAssertNil(decide(r, f.snap, coalesced: true, blinkChanged: false))

        // Full damage (first snapshot of a fresh term).
        let fresh = try makeTerm()
        let full = try XCTUnwrap(fresh.snapshot())
        XCTAssertTrue(full.damageIsFull, "precondition: first snapshot of a fresh term is full damage")
        XCTAssertNil(decide(r, full, blinkChanged: false))

        // Damage ≥ half the rows (rows 0…3 of 8, exactly (8+1)/2 = 4).
        let term = try makeSettledTerm()
        term.input("a\r\nb\r\nc\r\nd")
        let half = try XCTUnwrap(term.snapshot())
        if !half.damageIsFull {
            XCTAssertGreaterThanOrEqual(half.damagedRows.count, halfRows,
                                        "precondition: four distinct rows written → ≥ \(halfRows) damaged rows, got \(half.damagedRows)")
        }
        XCTAssertNil(decide(r, half, blinkChanged: false),
                     "damage covering ≥ half the rows must fall back to a full rebuild")
    }

    // MARK: - 4. Blink flip + partial damage → damaged rows ∪ cursor row

    func test_blinkChanged_partialDamage_unionsCursorScreenRow() throws {
        let r = try makeRenderer()
        let term = try makeSettledTerm()
        term.input("hello") // row 0
        let snap = try XCTUnwrap(term.snapshot())
        try XCTSkipIf(snap.damageIsFull, "parser reported full damage for a single-row write; the small-damage path is untestable with this input")
        XCTAssertTrue(snap.damagedRows.contains(0), "precondition: the text landed on row 0, got \(snap.damagedRows)")
        XCTAssertLessThan(snap.damagedRows.count, halfRows, "precondition: below the half-rows threshold")

        // Cursor on a row disjoint from the damage so the union is
        // observable rather than masked by an already-damaged row.
        let cur: Int32 = 5
        let cursorRow = screenRows([cur], offset: snap.displayOffset)
        XCTAssertEqual(cursorRow.count, 1, "fixture: grid row \(cur) + offset \(snap.displayOffset) must be on screen")
        XCTAssertTrue(cursorRow.isDisjoint(with: snap.damagedRows),
                      "fixture: cursor row \(cursorRow) must not already be damaged (\(snap.damagedRows))")

        let result = decide(r, snap, cursorMoved: false, blinkChanged: true, prevRow: cur, curRow: cur)
        XCTAssertEqual(result, Set(snap.damagedRows).union(cursorRow),
                       "blink flip + small damage rebuilds the damaged rows AND the cursor row, nothing more")
    }

    // MARK: - 5. Full-rebuild conditions still dominate a blink flip

    func test_blinkChanged_fullRebuildCases_returnNil() throws {
        let r = try makeRenderer()

        let f = try emptyDamageSnapshot()
        XCTAssertNil(decide(r, f.snap, cacheCompatible: false, blinkChanged: true,
                            prevRow: onScreenGridRow, curRow: onScreenGridRow),
                     "an incompatible cache forces a full rebuild even when only the blink changed")
        XCTAssertNil(decide(r, f.snap, coalesced: true, blinkChanged: true,
                            prevRow: onScreenGridRow, curRow: onScreenGridRow),
                     "a coalesced snapshot forces a full rebuild even when only the blink changed")

        let fresh = try makeTerm()
        let full = try XCTUnwrap(fresh.snapshot())
        XCTAssertTrue(full.damageIsFull, "precondition: first snapshot of a fresh term is full damage")
        XCTAssertNil(decide(r, full, blinkChanged: true), "full damage + blink flip → full rebuild")

        let term = try makeSettledTerm()
        term.input("a\r\nb\r\nc\r\nd")
        let half = try XCTUnwrap(term.snapshot())
        if !half.damageIsFull {
            XCTAssertGreaterThanOrEqual(half.damagedRows.count, halfRows,
                                        "precondition: four distinct rows written → ≥ \(halfRows) damaged rows, got \(half.damagedRows)")
        }
        XCTAssertNil(decide(r, half, blinkChanged: true, prevRow: 6, curRow: 6),
                     "damage ≥ half the rows + blink flip → full rebuild")
    }

    // MARK: - 6. Blink flip + cursor move → exactly { prev, new }

    func test_blinkChanged_cursorMoved_returnsPrevAndNewScreenRowsOnly() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        let prev: Int32 = 0
        let cur: Int32 = 2
        let expected = screenRows([prev, cur], offset: f.offset)
        XCTAssertEqual(expected.count, 2,
                       "fixture: grid rows \(prev) and \(cur) + offset \(f.offset) must both be on screen")

        let result = decide(r, f.snap, cursorMoved: true, blinkChanged: true,
                            prevRow: prev, prevCol: 0, curRow: cur)
        XCTAssertEqual(result, expected,
                       "blink flip + cursor hop rebuilds the row left and the row landed on; the blink row is the "
                       + "landing row so the union adds nothing")

        // Same-row horizontal move: still exactly one row.
        let sameRow = decide(r, f.snap, cursorMoved: true, blinkChanged: true,
                             prevRow: cur, prevCol: 0, curRow: cur)
        XCTAssertEqual(sameRow, screenRows([cur], offset: f.offset),
                       "a horizontal move plus a blink flip rebuilds the one row the cursor is on")
    }
}
