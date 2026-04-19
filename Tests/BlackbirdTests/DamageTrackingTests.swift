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
        // behavior.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        _ = term.snapshot()  // drain
        // Force scroll to produce Full damage
        term.input("A\r\nB\r\nC\r\nD\r\n")
        let snap = try XCTUnwrap(term.snapshot())
        if !snap.damageIsFull {
            for row in snap.damagedRows {
                XCTAssertLessThan(row, Int(snap.rows))
                XCTAssertGreaterThanOrEqual(row, 0)
            }
        }
    }
}
