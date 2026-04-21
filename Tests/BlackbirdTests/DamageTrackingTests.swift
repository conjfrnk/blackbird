import XCTest
@testable import Blackbird
import BBCore

/// Pins the Swift bridge over `bb_snap_damage_rows`. Rust-side tests cover
/// the parsing; these verify the `BBSnapshot.damageIsFull` /
/// `.damagedRows` accessors return sensible shape for common scenarios.
final class DamageTrackingTests: XCTestCase {

    func test_firstSnapshot_isFullDamage() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertTrue(snap.damageIsFull)
        XCTAssertEqual(snap.damagedRows, [])
    }

    func test_postInput_partialDamageReportsRowZero() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        // Consume the initial full-damage so the next snapshot is a delta.
        _ = term.snapshot()
        term.input("HI")
        let snap = try XCTUnwrap(term.snapshot())
        // Alacritty may report full damage or a specific row; both are
        // acceptable. The key invariant: if not full, row 0 MUST be in
        // the damaged set (that's where "HI" landed). Capture a
        // regression where damage drifts off to a wrong row.
        if !snap.damageIsFull {
            XCTAssertTrue(
                snap.damagedRows.contains(0),
                "expected row 0 in damage set, got \(snap.damagedRows)"
            )
        }
    }

    func test_damagedRows_capAtRowCount() throws {
        // Boundary check: the Swift wrapper allocates a buffer of size
        // rows. A future alacritty that reports a damaged row index >=
        // rows would write past the buffer without this cap. Pin the
        // behavior. Force a PARTIAL-damage scenario by writing to a
        // single row without scrolling — `A\r\nB\r\nC\r\nD\r\n`
        // scrolled the grid which produced damageIsFull=true and left
        // the bounds assertions in the `!snap.damageIsFull` branch as
        // dead code (audit swift-tests-core F4).
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        _ = term.snapshot()  // drain initial full-damage
        // Write only to row 0 (no \n, stays on the first visible row).
        // Alacritty reports partial damage for this; if it ever reports
        // Full we still pin *some* contract below.
        term.input("hi")
        let snap = try XCTUnwrap(term.snapshot())
        if snap.damageIsFull {
            XCTAssertEqual(
                snap.damagedRows, [],
                "full-damage must surface as empty damagedRows, not stray indices"
            )
        } else {
            XCTAssertFalse(
                snap.damagedRows.isEmpty,
                "partial damage must report at least one row; saw none"
            )
            for row in snap.damagedRows {
                XCTAssertLessThan(row, Int(snap.rows))
                XCTAssertGreaterThanOrEqual(row, 0)
            }
        }
    }
}
