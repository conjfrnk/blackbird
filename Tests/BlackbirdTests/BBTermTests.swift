import XCTest
@testable import Blackbird

final class BBTermTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_initAndDeinit() {
        let term = BBTerm(size: .init(cols: 80, rows: 24))
        XCTAssertNotNil(term)
        // deinit runs when scope exits
    }

    func test_initFailsWithZeroDimensions() {
        XCTAssertNil(BBTerm(size: .init(cols: 0, rows: 24)))
        XCTAssertNil(BBTerm(size: .init(cols: 80, rows: 0)))
    }

    func test_inputIsVisibleInSnapshot() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("hello")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.character(at: 0, row: 0), "h")
        XCTAssertEqual(snap.character(at: 4, row: 0), "o")
    }

    func test_resizeUpdatesSnapshotDimensions() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.resize(to: .init(cols: 120, rows: 40))
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cols, 120)
        XCTAssertEqual(snap.rows, 40)
    }

    func test_character_atRowColumn_rejectsNegativeIndices() throws {
        // Regression guard for e66f383: character(at:row:) previously
        // only bounded the upper end. A caller passing negative coords
        // (easy to hit via an unclamped `screenRow - displayOffset`)
        // would produce `row * cols + col < 0`, trapping on the cells
        // array's bounds assertion. Must return nil instead.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 5)))
        term.input("hello")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertNil(snap.character(at: -1, row: 0), "negative col must return nil")
        XCTAssertNil(snap.character(at: 0, row: -1), "negative row must return nil")
        XCTAssertNil(snap.character(at: -5, row: -5), "both negative must return nil")
    }

    func test_snapshot_sequenceIDIsMonotonic() throws {
        // Frame-skip in MetalRenderer uses `BBSnapshot.sequenceID` as a
        // content-change token. If two snapshots ever shared an id — via
        // wraparound, reset, or a re-used counter — the renderer would
        // silently skip a repaint. Pin that the counter only moves up.
        // Also: 0 is reserved as the "no snapshot" sentinel in FrameKey,
        // so no real snapshot must ever get id 0.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let a = try XCTUnwrap(term.snapshot())
        let b = try XCTUnwrap(term.snapshot())
        let c = try XCTUnwrap(term.snapshot())
        XCTAssertGreaterThan(a.sequenceID, 0, "id 0 is reserved — no real snapshot may use it")
        XCTAssertLessThan(a.sequenceID, b.sequenceID)
        XCTAssertLessThan(b.sequenceID, c.sequenceID)
    }

    func test_snapshot_sequenceIDsUniqueAcrossTerms() throws {
        // The counter is process-global, not per-BBTerm. Two independent
        // terminals share the monotonic sequence. Confirm the ids still
        // interleave strictly — two terminals each taking a snapshot must
        // not collide on id.
        let t1 = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let t2 = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let s1 = try XCTUnwrap(t1.snapshot())
        let s2 = try XCTUnwrap(t2.snapshot())
        let s1Again = try XCTUnwrap(t1.snapshot())
        XCTAssertNotEqual(s1.sequenceID, s2.sequenceID)
        XCTAssertNotEqual(s2.sequenceID, s1Again.sequenceID)
        XCTAssertNotEqual(s1.sequenceID, s1Again.sequenceID)
    }

    func test_bellEventFires() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        let exp = expectation(description: "bell")
        term.onEvent { ev in
            if case .bell = ev { exp.fulfill() }
        }
        term.input([0x07])  // BEL
        wait(for: [exp], timeout: 1.0)
    }

    func test_cursorCoordinatesExposed() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("abc")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cursorRow, 0)
        XCTAssertEqual(snap.cursorCol, 3)  // cursor advances after 3 chars
    }

    func test_titleEventFires() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        let exp = expectation(description: "title")
        var received: String?
        term.onEvent { ev in
            if case .title(let t) = ev {
                received = t
                exp.fulfill()
            }
        }
        // OSC 2 ; my-title ST  — alacritty accepts either ST (ESC \) or BEL as terminator
        term.input("\u{1B}]2;my-title\u{07}")
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, "my-title")
    }

    // OSC 52 clipboard-store is gated off by default (rust-core audit F10):
    // `alacritty_terminal`'s `Osc52` config is configured to `Disabled`
    // inside `bb_term_new`, so the PTY cannot stuff the user's clipboard
    // without the user first opting in via a Swift-side toggle. This
    // test pins the secure-by-default contract — if a future refactor
    // re-enables OSC 52 at the Rust layer, the Swift test catches it.
    func test_osc52Store_disabledByDefault_noEventEmitted() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 5)))
        var sawEvent = false
        term.onEvent { ev in
            if case .osc52Clipboard = ev {
                sawEvent = true
            }
        }
        // OSC 52 ; c ; base64("hello") ST. Valid store payload — must be
        // silently dropped. aGVsbG8= is base64("hello").
        term.input("\u{1B}]52;c;aGVsbG8=\u{07}")
        // Pump the runloop briefly so any queued event dispatch lands.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertFalse(
            sawEvent,
            "OSC 52 store must be inert by default; Osc52Clipboard fired"
        )
    }

    func test_modeExposedInSnapshot() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        // Send DECSET 1 (enable application cursor keys).
        term.input("\u{1B}[?1h")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertTrue(snap.termMode.contains(.appCursor), "APP_CURSOR should be set after DECSET 1")
        // Default modes — show cursor and line wrap are on at startup.
        XCTAssertTrue(snap.termMode.contains(.showCursor), "SHOW_CURSOR should be on by default")
        XCTAssertTrue(snap.termMode.contains(.lineWrap), "LINE_WRAP should be on by default")
    }

    /// Swift-side regression test for the palette slot panic the fuzzer found.
    /// A hand-edited UserDefaults or a misbehaving theme pipeline could hand
    /// BBTerm.setColor an out-of-range slot (u16); the whole chain down to
    /// alacritty must survive without aborting the process. BBTerm wraps
    /// bb_term_set_named_color which now clamps via alacritty::term::color::COUNT
    /// in the Rust FFI layer.
    func test_setColor_outOfRangeSlotDoesNotCrash() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 5, rows: 2)))
        // Below-valid-range slots that used to panic through alacritty.
        term.setColor(slot: 3598, rgb: 0xDE_ADBE)
        term.setColor(slot: 9999, rgb: 0xC0_FFEE)
        term.setColor(slot: 65535, rgb: 0xBE_EF00)
        // A legit slot still applies — sanity that we didn't break the
        // happy path while adding the clamp.
        term.setColor(slot: 257, rgb: 0x22_3344)
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(
            snap.cols * snap.rows,
            snap.cellCount,
            "snapshot still produced; setColor didn't corrupt term state"
        )
    }
}
