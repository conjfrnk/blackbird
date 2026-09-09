import XCTest
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for `MetalRenderer.decideRebuildRows`, written
/// from the v0.8.1 spec without sight of the implementation.
///
/// Contract under test (return value is the set of screen rows whose
/// instances must be rebuilt; `nil` means "rebuild everything"):
///  - `nil` when `cacheCompatible` is false, when `snap.damageIsFull`,
///    when `snapshotCoalesced`, or when
///    `damagedRows.count >= (rows + 1) / 2`.
///  - EMPTY damage must yield a NON-nil set: `[]` if the cursor did not
///    move, else the previous and current cursor screen rows
///    (`row + displayOffset`, only those within `0..<rows`).
///  - Small non-empty damage yields those rows, plus the cursor rows when
///    the cursor moved.
///
/// Damage comes from a real `BBTerm`. The first snapshot of a fresh
/// terminal is full damage; feeding text to a row damages that row.
///
/// **Empty damage is harder to obtain than the spec suggests.** A second
/// snapshot with no input in between still reports the cursor's own row
/// as damaged while the cursor is on screen (`damagedRows == [0]` on a
/// fresh 20 × 8 grid — observed, see the blind-test report). Genuinely
/// empty damage appears once the cursor is off the visible screen, i.e.
/// after the viewport is scrolled into history. `emptyDamageSnapshot()`
/// first tries a hidden cursor and falls back to the scrolled viewport;
/// every expectation is computed from the snapshot's real `displayOffset`
/// so the tests pin the spec's formula regardless of which fixture wins.
///
/// Memory / time pre-flight: one 20 × 8 `BBTerm` (`scrollback: 32`) and
/// one `MetalRenderer` per test. The renderer is constructed, never asked
/// to draw. Wall time dominated by `MTLCreateSystemDefaultDevice()` +
/// pipeline load. <2 MB, <200 ms per test.
final class RebuildRowsDecisionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private let cols: UInt16 = 20
    private let rows: UInt16 = 8
    private var halfRows: Int { (Int(rows) + 1) / 2 }

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

    /// The spec's cursor-row formula: `row + displayOffset`, kept only when
    /// inside `0..<rows`.
    private func cursorRows(prev: Int32, cur: Int32, offset: Int) -> Set<Int> {
        Set([Int(prev), Int(cur)].map { $0 + offset }.filter { $0 >= 0 && $0 < Int(rows) })
    }

    private func decide(
        _ r: MetalRenderer, _ snap: BBSnapshot,
        cacheCompatible: Bool = true, coalesced: Bool = false,
        cursorMoved: Bool = false, prevRow: Int32 = 0, prevCol: Int32 = 0, curRow: Int32 = 0
    ) -> Set<Int>? {
        r.decideRebuildRows(
            snap: snap, cacheCompatible: cacheCompatible, snapshotCoalesced: coalesced,
            cursorMoved: cursorMoved, prevCursorRow: prevRow, prevCursorCol: prevCol, curRow: curRow
        )
    }

    // MARK: - nil ("rebuild everything") cases

    func test_cacheIncompatible_returnsNil_evenWithEmptyDamage() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        XCTAssertNil(decide(r, f.snap, cacheCompatible: false))
        XCTAssertNil(decide(r, f.snap, cacheCompatible: false, cursorMoved: true, prevRow: 1, curRow: 2))
    }

    func test_fullDamage_returnsNil() throws {
        let r = try makeRenderer()
        let term = try makeTerm()
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertTrue(snap.damageIsFull, "precondition: first snapshot of a fresh term is full damage")
        XCTAssertNil(decide(r, snap))
        XCTAssertNil(decide(r, snap, cursorMoved: true, prevRow: 0, curRow: 1))
    }

    func test_snapshotCoalesced_returnsNil_evenWithEmptyDamage() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        XCTAssertNil(decide(r, f.snap, coalesced: true))
        XCTAssertNil(decide(r, f.snap, coalesced: true, cursorMoved: true, prevRow: 1, curRow: 2))
    }

    func test_damageAtLeastHalfTheRows_returnsNil() throws {
        let r = try makeRenderer()
        let term = try makeSettledTerm()
        // Touch rows 0…3: four of eight rows, which is exactly (8+1)/2 = 4.
        term.input("a\r\nb\r\nc\r\nd")
        let snap = try XCTUnwrap(term.snapshot())
        if !snap.damageIsFull {
            XCTAssertGreaterThanOrEqual(snap.damagedRows.count, halfRows,
                                        "precondition: four distinct rows written → ≥ \(halfRows) damaged rows, got \(snap.damagedRows)")
        }
        XCTAssertNil(decide(r, snap), "damage covering ≥ half the rows must fall back to a full rebuild")
    }

    // MARK: - Empty damage must NOT be nil

    func test_emptyDamage_cursorStill_returnsEmptySet() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        let result = decide(r, f.snap, cursorMoved: false, prevRow: 3, prevCol: 5, curRow: 3)
        XCTAssertNotNil(result, "empty damage with a still cursor must NOT trigger a full rebuild")
        XCTAssertEqual(result, [], "nothing changed → nothing to rebuild")
    }

    func test_emptyDamage_cursorMoved_returnsPrevAndCurrentRows() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        let expected = cursorRows(prev: 1, cur: 4, offset: f.offset)
        XCTAssertFalse(expected.isEmpty, "fixture: at least one cursor row must land on screen (offset \(f.offset))")
        let result = decide(r, f.snap, cursorMoved: true, prevRow: 1, prevCol: 0, curRow: 4)
        XCTAssertEqual(result, expected,
                       "a cursor hop must rebuild exactly the row it left and the row it landed on (offset \(f.offset))")
    }

    func test_emptyDamage_cursorMovedWithinRow_returnsThatRowOnce() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        let expected = cursorRows(prev: 2, cur: 2, offset: f.offset)
        XCTAssertEqual(expected.count, 1, "fixture: row 2 + offset \(f.offset) must be on screen")
        let result = decide(r, f.snap, cursorMoved: true, prevRow: 2, prevCol: 0, curRow: 2)
        XCTAssertEqual(result, expected, "a horizontal move rebuilds the one row the cursor is on")
    }

    func test_emptyDamage_cursorRowsOutsideScreen_areExcluded() throws {
        let r = try makeRenderer()
        let f = try emptyDamageSnapshot()
        let off = f.offset
        // Previous row past the last screen row even before the offset.
        XCTAssertEqual(decide(r, f.snap, cursorMoved: true, prevRow: Int32(rows), curRow: 2),
                       cursorRows(prev: Int32(rows), cur: 2, offset: off))
        XCTAssertEqual(decide(r, f.snap, cursorMoved: true, prevRow: 100, curRow: 2),
                       cursorRows(prev: 100, cur: 2, offset: off))
        // Far-negative previous row (e.g. no previous cursor yet).
        XCTAssertEqual(decide(r, f.snap, cursorMoved: true, prevRow: -50, curRow: 1),
                       cursorRows(prev: -50, cur: 1, offset: off))
        // Both out of range → non-nil, empty.
        let both = decide(r, f.snap, cursorMoved: true, prevRow: -50, curRow: 100)
        XCTAssertNotNil(both, "out-of-range cursor rows are dropped, not escalated to a full rebuild")
        XCTAssertEqual(both, [])
    }

    func test_emptyDamage_cursorRowsShiftByDisplayOffset() throws {
        // Force the scrolled route so a non-zero offset is exercised even
        // when the hidden-cursor route would have produced empty damage.
        let r = try makeRenderer()
        let term = try makeTerm()
        term.input(String(repeating: "x\r\n", count: 12))
        _ = try XCTUnwrap(term.snapshot())
        term.scroll(delta: 2)
        var snap = try XCTUnwrap(term.snapshot())
        if snap.displayOffset == 0 {
            term.scroll(delta: -4)
            snap = try XCTUnwrap(term.snapshot())
        }
        let off = snap.displayOffset
        XCTAssertGreaterThan(off, 0, "precondition: viewport must be scrolled into history")
        let settled = try XCTUnwrap(term.snapshot())
        XCTAssertFalse(settled.damageIsFull, "precondition: second snapshot at the same offset is a delta")
        XCTAssertEqual(settled.damagedRows, [], "precondition: empty damage")
        XCTAssertEqual(settled.displayOffset, off)

        let result = decide(r, settled, cursorMoved: true, prevRow: 0, curRow: 1)
        XCTAssertEqual(result, Set([off, 1 + off].filter { $0 < Int(rows) }),
                       "cursor rows are grid rows; on screen they sit at row + displayOffset (\(off))")
        // A grid row that the offset pushes past the bottom is dropped.
        let bottom = Int32(rows) - 1
        XCTAssertEqual(decide(r, settled, cursorMoved: true, prevRow: bottom, curRow: bottom), [],
                       "grid row \(bottom) + offset \(off) is below the screen and must be excluded")
    }

    // MARK: - Small damage

    func test_smallDamage_cursorStill_returnsExactlyDamagedRows() throws {
        let r = try makeRenderer()
        let term = try makeSettledTerm()
        term.input("hello")
        let snap = try XCTUnwrap(term.snapshot())
        try XCTSkipIf(snap.damageIsFull, "parser reported full damage for a single-row write; the small-damage path is untestable with this input")
        XCTAssertFalse(snap.damagedRows.isEmpty, "precondition: writing text damages at least one row")
        XCTAssertTrue(snap.damagedRows.contains(0), "precondition: the text landed on row 0, got \(snap.damagedRows)")
        XCTAssertLessThan(snap.damagedRows.count, halfRows, "precondition: below the half-rows threshold")

        let result = decide(r, snap, cursorMoved: false, prevRow: 0, curRow: 0)
        XCTAssertEqual(result, Set(snap.damagedRows), "small damage rebuilds exactly the damaged rows")
    }

    func test_smallDamage_cursorMoved_unionsCursorRows() throws {
        let r = try makeRenderer()
        let term = try makeSettledTerm()
        term.input("\r\n\r\nQ") // lands on row 2
        let snap = try XCTUnwrap(term.snapshot())
        try XCTSkipIf(snap.damageIsFull, "parser reported full damage for a two-row cursor move; the small-damage path is untestable with this input")
        XCTAssertTrue(snap.damagedRows.contains(2), "precondition: row 2 damaged, got \(snap.damagedRows)")
        XCTAssertLessThan(snap.damagedRows.count, halfRows, "precondition: below the half-rows threshold")

        // Cursor rows disjoint from the damage (6 and 7) so the union is
        // observable, not masked by rows that were damaged anyway.
        let result = decide(r, snap, cursorMoved: true, prevRow: 6, prevCol: 0, curRow: 7)
        XCTAssertEqual(result, Set(snap.damagedRows).union([6, 7]),
                       "small damage + cursor move rebuilds the damaged rows AND both cursor rows")
    }

    func test_noInput_visibleCursor_decisionIsDamageUnionCursorRows() throws {
        // Documents the observed core behaviour that motivated the fixture
        // above: with the cursor on screen a no-input snapshot may still
        // carry the cursor row as damage. Whatever the parser reports, the
        // decision must be that damage ∪ the cursor rows — never nil while
        // damage stays below the half-rows threshold.
        let r = try makeRenderer()
        let term = try makeSettledTerm()
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertFalse(snap.damageIsFull, "precondition: no input → not full damage")
        XCTAssertLessThan(snap.damagedRows.count, halfRows,
                          "precondition: a no-input snapshot must not damage half the screen, got \(snap.damagedRows)")
        XCTAssertEqual(decide(r, snap, cursorMoved: false), Set(snap.damagedRows))
        XCTAssertEqual(decide(r, snap, cursorMoved: true, prevRow: 5, curRow: 6),
                       Set(snap.damagedRows).union([5, 6]))
    }
}
