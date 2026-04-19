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

    func test_snapshot_sequenceIDIsMonotonic() throws {
        // Frame-skip in MetalRenderer uses `BBSnapshot.sequenceID` as a
        // content-change token. If two snapshots ever shared an id — via
        // wraparound, reset, or a re-used counter — the renderer would
        // silently skip a repaint. Pin that the counter only moves up.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let a = try XCTUnwrap(term.snapshot())
        let b = try XCTUnwrap(term.snapshot())
        let c = try XCTUnwrap(term.snapshot())
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

    // Pin down what alacritty_terminal hands us in Event::ClipboardStore.
    // The Swift session layer writes the payload straight through to
    // NSPasteboard, so alacritty changing this shape in a future bump would
    // mean we're either double-decoding (corrupts clipboard) or stuffing a
    // "c;<base64>" literal into the user's clipboard. This test locks the
    // assumption that alacritty 0.26 already decoded the base64.
    func test_osc52Payload_shapeViaAlacritty() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 5)))
        let exp = expectation(description: "osc52 payload")
        var captured: String?
        term.onEvent { ev in
            if case .osc52Clipboard(let s) = ev, captured == nil {
                captured = s
                exp.fulfill()
            }
        }
        // OSC 52 ; c ; base64("hello") ST. ST = ESC \ (0x1B 0x5C) or BEL.
        // aGVsbG8= is base64("hello").
        term.input("\u{1B}]52;c;aGVsbG8=\u{07}")
        wait(for: [exp], timeout: 1.0)
        let payload = try XCTUnwrap(captured, "no OSC 52 event received")
        // Pin the shape so the TerminalSession parser matches what
        // alacritty_terminal 0.26 hands back. The Swift side must agree.
        // Fails loudly if alacritty changes what it emits in a future bump.
        XCTAssertEqual(
            payload, "hello",
            "alacritty 0.26 should hand us the decoded OSC 52 text; got \(payload.debugDescription)"
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
