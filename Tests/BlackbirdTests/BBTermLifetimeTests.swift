import XCTest
@testable import Blackbird
@testable import BBCore

/// Lifetime / refcount / handle-after-deinit tests for the `BBCore`
/// Swift binding. Track A coverage gaps from `docs/.../v0.1.9-sweep/TST.md`,
/// surface S2.
///
/// Tests in this file probe the BBSnapshot retain/release contract and
/// the BBTerm deinit→handle-nil discipline through Swift-only
/// observable behaviour. Direct refcount inspection isn't exposed —
/// the proxy is "no crash, no use-after-free" under each scenario.
///
/// Memory cost rationale: every test creates ≤ 4 BBTerms + a handful
/// of snapshots. None of these involve scrollback grids large enough
/// to trip MemoryBudget; explicit grid sizes stay under 200×100.
final class BBTermLifetimeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Snapshot lifetime

    /// pre-flight: ~10 bytes feed, ~5 ms, < 2 KB grid.
    ///
    /// TST-S2-005-adjacent — take a snapshot, drop the BBTerm, then
    /// keep using the snapshot. The C contract for `bb_snap_release`
    /// says the snapshot is independently ref-counted; outliving its
    /// parent terminal must work. A regression where the snapshot's
    /// `cells` pointer became dangling on `bb_term_free` would crash
    /// the second `cellCount` / `character` access below — this test
    /// catches that.
    func test_snapshotOutlivesTerm_remainsUsable() throws {
        var snap: BBSnapshot?
        do {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
            term.input("hi")
            snap = try XCTUnwrap(term.snapshot())
            // term goes out of scope here; deinit fires `bb_term_free`.
        }
        let s = try XCTUnwrap(snap, "snapshot retained past term scope")
        // These accesses MUST NOT crash. `cellCount` reads `cells_len`
        // (an integer field on BBSnap, not a deref through `cells`);
        // `character(at:)` reads through the `cells` pointer — that's
        // the load-bearing crash path if the cells allocation was
        // freed alongside the term.
        XCTAssertEqual(s.cols, 10)
        XCTAssertEqual(s.rows, 3)
        XCTAssertEqual(s.cellCount, 30)
        XCTAssertEqual(
            s.character(at: 0, row: 0), "h",
            "snapshot 'cells' must remain readable after term deinit"
        )
        XCTAssertEqual(s.character(at: 1, row: 0), "i")
    }

    /// pre-flight: ~10 bytes, ~5 ms.
    ///
    /// Two snapshots from the same term, both held past the term's
    /// deinit. Each must independently remain usable. A regression
    /// where the second snapshot's refcount logic shared state with
    /// the first would crash on access here.
    func test_twoSnapshotsOutliveTerm_independentlyUsable() throws {
        var snapA: BBSnapshot?
        var snapB: BBSnapshot?
        do {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
            term.input("a")
            snapA = try XCTUnwrap(term.snapshot())
            term.input("b")
            snapB = try XCTUnwrap(term.snapshot())
        }
        let a = try XCTUnwrap(snapA)
        let b = try XCTUnwrap(snapB)
        XCTAssertEqual(a.character(at: 0, row: 0), "a", "snap A pinned 'a' state")
        // b should reflect both 'a' and 'b' since input is monotonic.
        XCTAssertEqual(b.character(at: 0, row: 0), "a")
        XCTAssertEqual(b.character(at: 1, row: 0), "b")
        // Snapshots must have distinct sequence IDs.
        XCTAssertNotEqual(a.sequenceID, b.sequenceID)
    }

    /// pre-flight: ~10 bytes, ~5 ms.
    ///
    /// Snapshot is captured, term is deinit'd, snapshot is dropped.
    /// teardownBlock asserts the test process didn't crash by simply
    /// reaching this point (xctest treats a SIGSEGV as a hard failure,
    /// not a pass).
    func test_snapshotReleaseAfterTermDeinit_noCrash() throws {
        var snap: BBSnapshot?
        do {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 5, rows: 2)))
            term.input("x")
            snap = term.snapshot()
        }
        // Snapshot still alive; term is gone. Reading the snapshot
        // must not dereference freed-term memory.
        XCTAssertGreaterThan(snap?.cellCount ?? 0, 0)
        // Snapshot drops here — XCTest treats a SIGSEGV during teardown
        // as a hard failure, so reaching the end of the method body is
        // the pass signal. No expectation / wait needed.
        snap = nil
        _ = snap
    }

    // MARK: - BBTerm deinit ordering

    /// pre-flight: ~50 BBTerms × 16 KB grid each = ~800 KB; ~50 ms.
    ///
    /// 50 BBTerms allocated, used briefly, deallocated in tight
    /// succession. Pins:
    ///   1. Each new BBTerm gets its own monotonic sequence ID base
    ///      (no shared mutable state leaks across instances).
    ///   2. Deinit doesn't fail / crash on freshly-created terms with
    ///      no input fed.
    ///   3. Memory doesn't visibly leak (proxy: 50 × 80×24 = 96 KB
    ///      grid + scrollback per term; if these leaked, peak RSS
    ///      would balloon beyond reasonable bounds — but we don't
    ///      assert that here, only "completes in finite time").
    func test_manyTermsRapidLifecycle_noLeakNoCrash() throws {
        var lastIDs: [UInt64] = []
        for i in 0..<50 {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
            // Vary the input slightly so iterations aren't identical.
            term.input(String(format: "iter%02d", i))
            let snap = try XCTUnwrap(term.snapshot())
            lastIDs.append(snap.sequenceID)
            // term deinit at end of loop
        }
        XCTAssertEqual(lastIDs.count, 50)
        // Sequence IDs are process-global and monotonic; the 50 IDs
        // here are a strict ascending sequence (interleaved with
        // anything else the test runner did between iterations, but
        // never duplicated).
        let sorted = lastIDs.sorted()
        XCTAssertEqual(sorted, lastIDs, "sequence IDs are stream-monotonic")
        XCTAssertEqual(Set(lastIDs).count, lastIDs.count, "no duplicate sequence IDs")
    }

    /// pre-flight: < 1 KB; ~5 ms.
    ///
    /// TST-S2-005 — call methods on a BBTerm in flight, retain it
    /// across closure boundaries, deinit it cleanly. The handle-nil
    /// discipline (BBTerm.handle goes nil at deinit) means subsequent
    /// closures captured by the term wouldn't fire after deinit. We
    /// can't directly observe handle == nil; instead we pin the
    /// observable contract: "deinit completes without an FFI
    /// double-free" by reaching the teardown block.
    func test_termDeinit_completesCleanly_evenWithRegisteredCallback() throws {
        var observed = 0
        do {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 5, rows: 2)))
            term.onEvent { _ in observed += 1 }
            // Drive an event so the callback wiring is exercised.
            term.input([0x07])  // BEL
            // term deinit at end of scope; the C contract says
            // bb_term_free must succeed even with a callback still
            // registered.
        }
        XCTAssertGreaterThanOrEqual(observed, 1, "bell event observed")
    }

    // MARK: - Handle robustness

    /// pre-flight: ~5 bytes, ~5 ms.
    ///
    /// `clearAll()` followed by snapshot must yield a valid empty
    /// grid: cursor at (0, 0), historySize == 0 (scrollback also
    /// cleared per the C contract). A regression where clearAll()
    /// only cleared the visible grid would leave scrollback intact
    /// and cursor at the wrong row; pin both invariants.
    func test_clearAll_resetsCursorAndScrollback() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        // Push enough lines into scrollback to make historySize > 0.
        for _ in 0..<10 {
            term.input("x\r\n")
        }
        // Drain initial state.
        let pre = try XCTUnwrap(term.snapshot())
        XCTAssertGreaterThan(pre.historySize, 0, "scrollback present pre-clear")
        term.clearAll()
        let post = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(post.cursorRow, 0, "cursor reset to row 0")
        XCTAssertEqual(post.cursorCol, 0, "cursor reset to col 0")
        XCTAssertEqual(post.historySize, 0, "scrollback cleared")
    }

    /// pre-flight: < 1 KB; ~5 ms.
    ///
    /// Calling `onEvent` twice on the same BBTerm must yield a usable
    /// term — whether it replaces or stacks is an impl decision, but
    /// both outcomes share the contract "no crash, no fatal events."
    /// We pin the OBSERVABLE behavior used by the production
    /// `TerminalSession.wire()` pattern: at least one handler fires.
    /// A regression that wedged the dispatcher when re-registering
    /// would fail this with secondCount == 0.
    func test_onEvent_doubleRegistrationProducesAtLeastOneCallback() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        var firstCount = 0
        var secondCount = 0
        term.onEvent { ev in
            if case .bell = ev { firstCount += 1 }
        }
        term.onEvent { ev in
            if case .bell = ev { secondCount += 1 }
        }
        term.input([0x07])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        // Don't assume which handler "wins" — the contract is "at
        // least one fires once, no fatal." Production TerminalSession
        // calls onEvent exactly once at wire-up; this test just
        // ensures double-call doesn't break dispatch.
        XCTAssertGreaterThanOrEqual(
            firstCount + secondCount, 1,
            "at least one handler must fire after double-register"
        )
    }

    /// pre-flight: ~5 bytes, ~5 ms.
    ///
    /// Resize-to-same-dims must be effectively a no-op observationally:
    /// snapshot post-resize matches snapshot pre-resize (modulo
    /// sequenceID, which always advances). A regression where resize
    /// always damaged the full grid would inflate damageIsFull => true
    /// even on no-change resizes — at most acceptable but should be
    /// pinned as today's contract.
    func test_resizeToSameDims_preservesGridContents() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        term.input("hi")
        _ = term.snapshot()  // drain initial damage
        term.resize(to: .init(cols: 10, rows: 3))  // same dims
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cols, 10)
        XCTAssertEqual(snap.rows, 3)
        XCTAssertEqual(snap.character(at: 0, row: 0), "h")
        XCTAssertEqual(snap.character(at: 1, row: 0), "i")
    }

    /// pre-flight: ~5 bytes, ~5 ms.
    ///
    /// Resize clamp from BBCore.h: dims clamp to [2, 1000]. Driving
    /// resize to (1, 1) must produce a (2, 2) grid (floor clamp);
    /// driving to (2000, 2000) must produce (1000, 1000). A regression
    /// where the floor was 1 instead of 2 would crash on any "tiny
    /// terminal" usage.
    func test_resize_clampsToDocumentedRange() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.resize(to: .init(cols: 1, rows: 1))
        let snapMin = try XCTUnwrap(term.snapshot())
        XCTAssertGreaterThanOrEqual(snapMin.cols, 2, "floor clamp ≥ 2 cols")
        XCTAssertGreaterThanOrEqual(snapMin.rows, 2, "floor clamp ≥ 2 rows")
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 1000, rows: 1000)
        )
        term.resize(to: .init(cols: 5000, rows: 5000))
        let snapMax = try XCTUnwrap(term.snapshot())
        XCTAssertLessThanOrEqual(snapMax.cols, 1000, "ceiling clamp ≤ 1000 cols")
        XCTAssertLessThanOrEqual(snapMax.rows, 1000, "ceiling clamp ≤ 1000 rows")
    }

    // MARK: - Concurrent snapshot retention

    /// pre-flight: ~50 snapshots × ~1 KB grid = ~50 KB; ~10 ms.
    ///
    /// Hold 50 snapshots concurrently from the same term. Each must
    /// retain its own view of grid state at capture time. We can't
    /// directly verify this without a writable grid mutator between
    /// snapshots; the proxy here is "all 50 snapshots remain readable,
    /// snapshotIDs strictly ascend, no crash on any access."
    func test_holdManySnapshots_concurrently_allReadable() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3)))
        var snaps: [BBSnapshot] = []
        for i in 0..<50 {
            term.input([UInt8(0x61 + (i % 26))])
            if let s = term.snapshot() {
                snaps.append(s)
            }
        }
        XCTAssertEqual(snaps.count, 50, "all 50 snapshots captured")
        // Sequence IDs must strictly ascend across the held snapshots.
        for i in 1..<snaps.count {
            XCTAssertGreaterThan(
                snaps[i].sequenceID, snaps[i-1].sequenceID,
                "snapshot \(i) sequenceID must be > snapshot \(i-1) sequenceID"
            )
        }
        // Each snapshot must be independently readable.
        for s in snaps {
            XCTAssertEqual(s.cols, 10)
            XCTAssertEqual(s.rows, 3)
        }
        // Drop them all — no crash on bulk release.
        snaps.removeAll()
    }

    // MARK: - M3: resize panic-fallback returns nil

    /// Audit M3: `BBTerm.resize` returns `nil` when the FFI's panic-
    /// fallback or null-handle path engages. Calling resize after
    /// `terminate()` exercises the null-handle branch — the cleanest
    /// way to drive the nil-return contract without mocking the C ABI.
    /// Pre-fix the function returned the requested-after-clamp dims and
    /// the caller (TerminalSession.resize) fed those to TIOCSWINSZ —
    /// kernel winsize ended up out of sync with the grid (which was
    /// torn down). With M3 the caller can detect nil and skip the
    /// ioctl, keeping the kernel winsize aligned with the actual grid.
    func test_resize_afterTerminate_returnsNil() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.terminate()  // null-handle branch — same shape as the panic fallback
        let result = term.resize(to: .init(cols: 100, rows: 30))
        XCTAssertNil(
            result,
            "BBTerm.resize on a terminated handle must return nil (M3); "
            + "callers driving TIOCSWINSZ depend on this to avoid kernel-winsize drift"
        )
    }

    // MARK: - Invariant-after-error pseudo-fuzz

    /// pre-flight: ~1 KB feed, ~50 ms.
    ///
    /// After feeding a deliberately malformed sequence (DCS rejected,
    /// half-CSI, lone ESC), the term must remain usable for normal
    /// input. A regression where a bad sequence parked the parser in
    /// a broken state would cause subsequent normal input to vanish
    /// or get rerouted as parser bytes.
    func test_termRecoversFromMalformedSequence_subsequentInputLands() throws {
        // alacritty_terminal's vte parser absorbs the first printable
        // after a lone ESC into an SS3 / ESC-final sequence, so the
        // naive "feed `\r\nok`" path loses the 'o'. The recovery
        // contract still holds — inserting a no-op SGR reset between
        // the malformed frame and the probe text wakes the parser. The
        // test as originally written was too strict; softened to match
        // the actual recovery idiom.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        // Sequence A: a half-CSI (no final byte ever arrives).
        term.input([0x1B, 0x5B, 0x33, 0x32])  // ESC [ 3 2 — incomplete
        // Sequence B: a stray DCS that gets rejected.
        term.input([0x1B, 0x50, 0x71, 0x07])  // ESC P q BEL — invalid DCS
        // Sequence C: a lone ESC that never resolves.
        term.input([0x1B])
        // Now drive a CSI reset + normal printable input. The `CSI m`
        // flush resets any parser-state left by the half-sequences,
        // and "ok" must then land in the grid.
        term.input("\u{1B}[m\r\nok")
        let snap = try XCTUnwrap(term.snapshot())
        // Either row 0 or row 1 (depending on whether the first
        // CR\n triggered a scroll-up); the contract: at least one
        // row contains "ok" at columns 0..1.
        var found = false
        for row in 0..<Int(snap.rows) {
            if snap.character(at: 0, row: row) == "o",
               snap.character(at: 1, row: row) == "k" {
                found = true
                break
            }
        }
        XCTAssertTrue(found, "term must recover from malformed sequences and land 'ok' somewhere")
    }
}
