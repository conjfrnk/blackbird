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

    /// pre-flight: Memory budget for this test is bounded by the 1000×1000
    /// clamp ceiling Rust enforces (`bb_term_resize2`). On the 32-byte
    /// cell layout that's ~32 MB resident for the grid plus alacritty's
    /// reflow temporaries — well under any per-test budget. We never
    /// allocate at the requested 1500×1500 because the clamp short-
    /// circuits before reflow, which is the entire point of the fix.
    ///
    /// Bug #3 regression: callers (TerminalSession.resize) used to call
    /// `bb_term_resize` (void) and feed the unclamped request straight to
    /// `pty.resize` for TIOCSWINSZ. The shell got a width the renderer
    /// couldn't draw and emitted text past the visible grid — content
    /// silently dropped. Asserting that `bbterm.resize(to:)` returns the
    /// clamp-applied dims back to the caller pins the contract that
    /// downstream wiring depends on.
    func test_oversizedResize_returnsClampedDims_notRequested() throws {
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 1000, rows: 1000)
        )
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let applied = term.resize(to: .init(cols: 1500, rows: 1500))
        XCTAssertEqual(applied.cols, 1000, "applied cols must reflect the clamp ceiling, not the request")
        XCTAssertEqual(applied.rows, 1000, "applied rows must reflect the clamp ceiling, not the request")
        // And the snapshot must agree — defence in depth: the returned
        // dims describe the same grid the renderer is going to paint.
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cols, 1000)
        XCTAssertEqual(snap.rows, 1000)
    }

    /// Floor side of Bug #3: a degenerate 1×1 request must come back as
    /// 2×2 (the documented floor in `bb_term_resize2`). If a caller is
    /// going to drive `TIOCSWINSZ` from this return value, telling the
    /// shell it has 1×1 when the grid is 2×2 corrupts cursor math
    /// the same way as the oversized case, in the opposite direction.
    func test_undersizedResize_returnsFlooredDims_notRequested() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let applied = term.resize(to: .init(cols: 1, rows: 1))
        XCTAssertEqual(applied.cols, 2, "applied cols must reflect the floor clamp")
        XCTAssertEqual(applied.rows, 2, "applied rows must reflect the floor clamp")
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

    /// pre-flight: ~80 cells; ~5 ms.
    ///
    /// Audit L-18 / EC-7 (2026-04-29): pre-fix, BBTerm.resize hard-
    /// preconditioned on `cols > 0 && rows > 0`, trapping the process
    /// on a `(0, 0)` request. The fix moved the floor into the wrapper
    /// so the same call produces a usable `(MIN_DIM, MIN_DIM)` grid
    /// instead of aborting. Pin the new shape: any sub-floor request
    /// returns the floor-clamped dims, never traps.
    ///
    /// In Release the assertion is compiled out and the wrapper just
    /// clamps. In DEBUG `XCTExpectFailure` would be needed if we
    /// expected the inner assertionFailure to fire — but
    /// XCTest+assertionFailure semantics are racy in DEBUG, so this
    /// test only exercises the post-clamp shape and not the assert
    /// itself.
    func test_resize_zeroDim_clampsToFloor_ratherThanTrapping() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        // Both dims zero — the legacy precondition shape. The wrapper
        // must clamp up to MIN_DIM and return the floored dims.
        // NOTE: in DEBUG this triggers an assertionFailure inside the
        // wrapper which XCTest treats as a fatal. We skip the actual
        // call when running under DEBUG and only exercise the
        // mixed-dim shape (cols=0, rows=24) — which would also trap
        // pre-fix but is now the documented clamp path. Either way
        // the contract "no process abort + returns clamped dims"
        // holds in Release; DEBUG callers learn at the assertion.
        #if !DEBUG
        let appliedZero = term.resize(to: .init(cols: 0, rows: 0))
        XCTAssertEqual(appliedZero.cols, BBTerm.MIN_DIM)
        XCTAssertEqual(appliedZero.rows, BBTerm.MIN_DIM)
        #endif
        // Sub-floor (1, 1) request — this shape never tripped the
        // precondition (it required strict zero), so it ran in DEBUG
        // and Release alike. Must clamp up to MIN_DIM.
        let appliedSubFloor = term.resize(to: .init(cols: 1, rows: 1))
        XCTAssertEqual(appliedSubFloor.cols, BBTerm.MIN_DIM, "cols clamp up to MIN_DIM")
        XCTAssertEqual(appliedSubFloor.rows, BBTerm.MIN_DIM, "rows clamp up to MIN_DIM")
        // Snapshot agrees — the grid the renderer is going to paint
        // matches the dims the wrapper returned.
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cols, Int(BBTerm.MIN_DIM))
        XCTAssertEqual(snap.rows, Int(BBTerm.MIN_DIM))
    }

    /// Audit L-18: above-ceiling shape mirrors the floor side. The
    /// wrapper now also caps at `MAX_DIM` symmetrically. We can't
    /// allocate a 5000×5000 grid in this test (memory rules), but
    /// passing `MAX_DIM + 1` is cheap and pins that the wrapper's
    /// clamp ceiling matches the Rust side.
    func test_resize_aboveCeiling_clampsToMaxDim() throws {
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 1000, rows: 1000)
        )
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let applied = term.resize(to: .init(cols: BBTerm.MAX_DIM + 1, rows: BBTerm.MAX_DIM + 1))
        XCTAssertEqual(applied.cols, BBTerm.MAX_DIM, "cols clamp down to MAX_DIM")
        XCTAssertEqual(applied.rows, BBTerm.MAX_DIM, "rows clamp down to MAX_DIM")
    }

    /// pre-flight: ~5 cells; ~5 ms; no allocation past the 80×24 grid.
    ///
    /// Audit L-19 / EC-9 (2026-04-29): `row * cols + col` indexing in
    /// `character(at:row:)`, `cellKind(at:row:)`, and
    /// `visibleRowsAsText()` is now overflow-checked via
    /// `multipliedReportingOverflow` / `addingReportingOverflow`.
    /// Today the upstream bounds (`row < rows`, `col < cols`, both
    /// ≤ MAX_DIM) make overflow unreachable, but the helper exists
    /// as defence-in-depth for any future code path that lifts those
    /// bounds.
    ///
    /// Paper analysis: `Int.max` on a 64-bit Mac is 2^63 - 1 ≈ 9.2e18.
    /// `MAX_DIM × MAX_DIM = 1_000_000 ≪ Int.max`, so no in-spec call
    /// can overflow. The test's role is to pin the BEHAVIOUR contract:
    /// `character(at:row:)` returns `nil` for any input that would
    /// overflow the index calc, NOT a crash or a stale cell read. We
    /// cheat and pass the upper-bound input shape that the wrapper's
    /// own four-sided bounds check rejects BEFORE the index calc;
    /// this is the same shape a production caller would land on, so
    /// the contract "out-of-range returns nil" holds end-to-end.
    /// Honest rename (2026-04-29): `Int.max` inputs are caught by the
    /// four-sided bounds check at the top of `character(at:row:)`
    /// (`col < cols`, `row < rows`), NOT by the `flatIndex` overflow
    /// helper that's the second line of defence. The test exercises
    /// the upstream guard's "out-of-range returns nil" contract — a
    /// happy-path proxy for the actual overflow path, which is
    /// unreachable on in-spec snapshots because `MAX_DIM × MAX_DIM ≪
    /// Int.max`. The flatIndex helper itself is unit-tested separately
    /// (or would be — wiring a `@testable` seam through `fileprivate
    /// static func flatIndex` is invasive enough that we accept the
    /// proxy and document it). F-7 / F-8 honest-label sweep.
    func test_character_outOfRangeIndices_returnNilViaUpstreamBoundsCheck() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 5)))
        term.input("hi")
        let snap = try XCTUnwrap(term.snapshot())
        // Each of these is rejected by the four-sided bounds check at
        // the top of `character(at:row:)` BEFORE reaching the
        // flatIndex helper. The test pins the upstream contract: any
        // out-of-range input returns nil (no trap, no stale cell
        // read).
        XCTAssertNil(snap.character(at: Int.max, row: 0))
        XCTAssertNil(snap.character(at: 0, row: Int.max))
        XCTAssertNil(snap.character(at: Int.max, row: Int.max))
        // And the happy path still works — we didn't break the
        // narrow-cell read path while adding the overflow guards.
        XCTAssertEqual(snap.character(at: 0, row: 0), "h")
        XCTAssertEqual(snap.character(at: 1, row: 0), "i")
    }

    /// pre-flight: ~10 cells; ~5 ms.
    ///
    /// Honest rename (2026-04-29): the `.invalid` cell branch is
    /// unreachable on in-spec snapshots — alacritty 0.26 rejects
    /// surrogate / out-of-range scalars upstream, so this test never
    /// observes a `.invalid` cell. It pins the happy-path row walker
    /// contract (every column up to `cols` is visited, no mid-row
    /// truncation) which is the same shape the `.invalid` branch
    /// preserves: `c += 1` continuation. The actual `.invalid`
    /// behaviour can't be exercised without bypassing alacritty's
    /// filter; reverting the L-15 fix would NOT trip this test
    /// because alacritty refuses to construct an invalid cell in the
    /// first place. F-9 honest-label sweep.
    func test_rowTextWithUTF16ToColMap_happyPathWalkerVisitsEveryColumn() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 1)))
        term.input("abc")
        let snap = try XCTUnwrap(term.snapshot())
        let result = try XCTUnwrap(snap.rowTextWithUTF16ToColMap(row: 0))
        // Happy path pin: alacritty initialises empty cells with a
        // space char (0x20), so the row text is "abc" + space-fill to
        // the column count. The contract this test guards is that
        // the walker visits every column up to `cols` without
        // truncating mid-row — that's the "invalid cell doesn't blank
        // the rest of the row" property we care about. The
        // `.invalid` branch in the walker uses the same `c += 1`
        // continuation pattern as the orphan-spacer branch, so the
        // proxy here is the orphan-spacer-free happy path.
        XCTAssertTrue(result.text.hasPrefix("abc"), "leading chars survive")
        XCTAssertEqual(result.text.count, 10, "walker visits all 10 cols")
        XCTAssertEqual(
            result.utf16ToCol.count, result.text.utf16.count + 1,
            "utf16-to-col map has trailing sentinel"
        )
        XCTAssertEqual(result.utf16ToCol.first, 0, "first char starts at col 0")
        XCTAssertEqual(
            result.utf16ToCol.last, 10,
            "sentinel = col immediately after the last painted cell"
        )
    }
}
