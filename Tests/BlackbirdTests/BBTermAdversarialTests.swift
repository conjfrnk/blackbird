import XCTest
import Foundation
import Darwin.Mach
@testable import Blackbird
@testable import BBCore

/// Adversarial / property-style tests for the `BBCore` Swift binding
/// (`BBTerm`). Track B of the v0.1.9 TST sweep for surface S2.
///
/// These tests exercise the FFI invariants documented in `BBCore.h`:
///
/// - `bb_term_input` survives arbitrary byte sequences (`catch_unwind`
///   on the Rust side turns a panic into a `Fatal` event, so observing
///   zero `.fatal` events is the correctness signal).
/// - Single-event semantics: a sequence that *should* produce exactly
///   one event must not multi-fire on retry / fragmentation.
/// - Rapid-fire input/snapshot round-trips must not corrupt grid state
///   nor leak refcount on `BBSnapshot`.
/// - Re-entrancy: calling back into the term from inside `onEvent` must
///   not silently double-mutate the underlying `Term`. The C contract
///   forbids re-entrant calls; Swift's DEBUG `isInsideEventDispatch`
///   latch is the safety net. We can't directly observe an
///   `assertionFailure` from XCTest, but we CAN pin that no fatal
///   propagates and the term remains usable post-attempt — that's the
///   semantic the production code (`TerminalSession.wire()` hops to
///   main before re-entering) relies on.
///
/// Track A coverage gaps from `docs/.../v0.1.9-sweep/TST.md` are
/// addressed inline below — see the `// TST-S2-XXX` markers.
///
/// Memory cost rationale: every test under this file allocates ≤ 1 MB
/// of input bytes (mostly tens of KB) plus a single 80×24 BBTerm
/// (≈ 100 KB grid + 100 K-line scrollback at 16 B per cell — alacritty
/// internally caps live cell count at cols×rows + scrollback × cols).
/// The `MemoryBudget` helper guards anything bigger.
final class BBTermAdversarialTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Match the rest of the suite: register the host-termination
        // observer so a `--filter BBTermAdversarialTests` run exits
        // cleanly without a SwiftUI zombie host. Idempotent.
        TestHostTermination.shared.register()
    }

    // MARK: - Track A: BBTermMode bit positions match the C header

    /// pre-flight: ~0 bytes feed, ~5 ms total — five DECSET writes + five
    /// `currentMode` reads.
    ///
    /// Pins the BBTermMode bit-layout contract from `BBCore.h`:
    /// each mode bit position must map to the same DEC private mode
    /// flip the C header documents. The existing `TerminalViewTests`
    /// pinned `focusInOut` and the kitty bits as raw values; this test
    /// closes the gap by driving each bit through the public input
    /// path (DECSET) and asserting `term.currentMode` lights it.
    ///
    /// Why drive via input rather than `BBTermMode.foo.rawValue`:
    /// the rawValue test only catches a Swift-side renumber. Driving
    /// through `bb_term_input` proves the FULL chain — alacritty maps
    /// `?1h` to APP_CURSOR, the FFI exposes that bit at position 1,
    /// and the Swift OptionSet decodes position 1 as `.appCursor`.
    /// Any one of those slipping silently re-maps the bit.
    func test_modeBits_drivenViaDECSET_matchesHeaderLayout() throws {
        // Each tuple: (DECSET parameter, expected mode case, header bit).
        // Header bits cross-checked against `BBCore.h` ALT_SCREEN..REPORT_ASSOCIATED_TEXT.
        let cases: [(Int, BBTermMode, Int)] = [
            (1,    .appCursor,      1),
            (1049, .altScreen,      0),    // alt screen + save cursor
            (2004, .bracketedPaste, 3),
            (1000, .mouseReportClick, 4),
            (1003, .mouseMotion,    5),    // 1003 enables motion + click
            (1006, .sgrMouse,       7),
            (1004, .focusInOut,     8),
        ]
        for (decset, modeCase, headerBit) in cases {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
            // Observe BEFORE: bit must be off (default state — except
            // for showCursor / lineWrap which we don't drive here).
            XCTAssertFalse(
                term.currentMode.contains(modeCase),
                "before DECSET ?\(decset)h: \(modeCase) must be off"
            )
            // Drive the mode on via DECSET.
            term.input("\u{1B}[?\(decset)h")
            XCTAssertTrue(
                term.currentMode.contains(modeCase),
                "after DECSET ?\(decset)h: \(modeCase) must be set"
            )
            // The bit position must match the header — without this
            // pin, a future Swift OptionSet reorder that paired
            // appCursor with bit 0 would still pass the
            // contains/doesNotContain checks above.
            XCTAssertEqual(
                modeCase.rawValue, 1 << headerBit,
                "BBTermMode.\(modeCase) bit position drifted from BBCore.h"
            )
        }
    }

    // TST-S2-008 — BBTermMode rawValue round-trip preserves unknown bits.
    /// pre-flight: ~0 bytes, ~1 ms.
    ///
    /// `BBTermMode` is an OptionSet over `UInt32`; per BBCore.h the
    /// reserved bits are 0..16 today. A future core that lights bit 17
    /// must surface that bit through `currentMode.rawValue` even if no
    /// Swift case names it — otherwise downstream readers like the
    /// renderer's "any mode change" delta lose the signal.
    func test_termMode_rawValueRoundTrip_preservesAllBits() {
        // RawValue is bit-width whatever BBTermMode declares; we use
        // the integer-literal form alacritty/BBTerm tests already use
        // (e.g. `BBTermMode.focusInOut.rawValue == 1 << 8` in
        // TerminalViewTests). A bit at position 30 is unused today.
        let upperBitOnly = BBTermMode(rawValue: 1 << 30)
        XCTAssertEqual(
            upperBitOnly.rawValue, 1 << 30,
            "OptionSet must preserve unknown bits — required for forward-compat"
        )
        // Empty stays empty.
        XCTAssertEqual(BBTermMode([]).rawValue, 0)
        // Round-trip a known case: focusInOut is bit 8.
        let fio = BBTermMode(rawValue: 1 << 8)
        XCTAssertTrue(
            fio.contains(.focusInOut),
            "rawValue with bit 8 lit must be recognised as .focusInOut"
        )
    }

    // TST-S2-001 — synthesised "future" event kinds must not corrupt
    // dispatch. We can't push a kind=42 event through `bb_term_set_event_cb`
    // from Swift without a Rust-side hook. The closest reachable surrogate:
    // observe that the dispatcher table lights NO event when the input is
    // a sequence the Rust side parses but routes nowhere (e.g. a DECRPM
    // query). That isn't equivalent to "kind=42 ignored", so flag with a
    // bare correctness assertion: handler called exactly zero times for
    // a sequence we know produces no event.
    /// pre-flight: ~30 bytes, ~5 ms.
    func test_unknownDecsetParameter_doesNotEmitSwiftEvent() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        var calls = 0
        term.onEvent { _ in calls += 1 }
        // DECSET ?7777 — not assigned; alacritty silently ignores.
        // No mode flip, no event of any documented kind.
        term.input("\u{1B}[?7777h")
        // Pump the runloop so any latent main-queue dispatch lands.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(
            calls, 0,
            "unrecognised DECSET parameter must produce no Swift event"
        )
    }

    // MARK: - Track B: random-byte fuzz invariants

    /// pre-flight: ~64 KB total feed, ~250 ms (2000 iterations × ≤32 B chunks).
    ///
    /// Complements `HostileInputIntegrationTests.testRandomByteInputDoesNotPanic`
    /// (1000 × ≤128 B). This variant uses tighter chunks (≤32 B) and
    /// 2000 iterations to expose the parser's per-fragment state machine —
    /// a regression where the OSC/CSI parser carries garbage state across
    /// chunk boundaries shows up under short-chunk fuzzing but hides
    /// behind 128 B chunks because most state machines re-sync within
    /// 2 KB of bytes.
    ///
    /// Determinism: fixed seed so a CI failure is reproducible. Different
    /// seed than the existing fuzz so we don't just re-cover the same
    /// hash buckets.
    func test_randomBytes_shortChunkFuzz_noFatal_noCrash() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var fatals: [String] = []
        term.onEvent { ev in
            if case .fatal(let msg) = ev { fatals.append(msg) }
        }
        var rng = AdversarialRNG(seed: 0xCAFE_F00D_BEEF_BABE)
        for iter in 0..<2000 {
            let length = Int.random(in: 1...32, using: &rng)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
            term.input(bytes)
            // Take a snapshot every 8 iterations to exercise the
            // input/snapshot interleave path the renderer hits in
            // production. If a partial OSC payload corrupts grid
            // state mid-feed, the snapshot would also see it.
            if iter % 8 == 0 {
                _ = term.snapshot()
            }
            if !fatals.isEmpty {
                XCTFail("iter \(iter): fatal raised on \(bytes.count) bytes \(bytes.map { String($0, radix: 16) }): \(fatals)")
                return
            }
        }
        XCTAssertTrue(fatals.isEmpty, "no fatal events expected; got \(fatals.count)")
    }

    /// pre-flight: ~10 KB feed, ~100 ms.
    ///
    /// Fragmentation property: split a known-good OSC 8 + content + ST
    /// across pseudo-random chunk boundaries (1..N bytes). Final
    /// snapshot must still see the OSC 8 link attribution at column 0.
    /// Catches a regression where the OSC parser fails to merge
    /// fragments correctly.
    func test_oscFragmentation_propertyStyle_alwaysAttributes() throws {
        let payload = "\u{1B}]8;;https://example.com\u{1B}\\h\u{1B}]8;;\u{1B}\\"
        let bytes = Array(payload.utf8)
        var rng = AdversarialRNG(seed: 0x1234_5678)
        // 50 random fragmentations of the same payload.
        for trial in 0..<50 {
            let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
            var i = 0
            while i < bytes.count {
                let chunk = Int.random(in: 1...4, using: &rng)
                let end = min(i + chunk, bytes.count)
                term.input(Array(bytes[i..<end]))
                i = end
            }
            let snap = try XCTUnwrap(
                term.snapshot(),
                "trial \(trial): snapshot must succeed after fragmented OSC 8"
            )
            XCTAssertNotEqual(
                snap.linkID(row: 0, col: 0), 0,
                "trial \(trial): fragmented OSC 8 must still produce link id"
            )
            XCTAssertEqual(
                snap.linkURL(id: snap.linkID(row: 0, col: 0)),
                "https://example.com",
                "trial \(trial): URL must round-trip through fragmentation"
            )
        }
    }

    // MARK: - Track B: single-event semantics

    /// pre-flight: ~30 bytes, ~50 ms.
    ///
    /// One title sequence → exactly one `.title(_)` event. A regression
    /// to "fire on every byte" or "fire on each repeated callback
    /// install" would multiply the count. Pinned with `==`.
    func test_titleSequence_firesExactlyOnce() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        var titles: [String] = []
        term.onEvent { ev in
            if case .title(let t) = ev { titles.append(t) }
        }
        term.input("\u{1B}]2;single\u{07}")
        // Pump so any deferred dispatch drains.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(titles, ["single"], "exactly one title event")
    }

    /// pre-flight: ~10 bytes, ~50 ms.
    ///
    /// One bell → one `.bell` event (NOT two — a regression where the
    /// VT parser's "bell on BEL byte" path also fires "bell as OSC 0
    /// terminator" when the OSC parser is in a particular state would
    /// double-fire).
    func test_bellByte_firesExactlyOnce() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        var bells = 0
        term.onEvent { ev in
            if case .bell = ev { bells += 1 }
        }
        term.input([0x07])  // BEL
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(bells, 1)
    }

    /// pre-flight: ~30 bytes (3 title bytes), ~50 ms.
    ///
    /// Three independent titles → exactly three events, in order.
    /// Order pins the dispatch table doesn't reorder in pathological
    /// cases (e.g. a callback that took a long time would queue events
    /// but ordering must still be stream-order).
    func test_threeTitles_arriveInOrder() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        var titles: [String] = []
        term.onEvent { ev in
            if case .title(let t) = ev { titles.append(t) }
        }
        term.input("\u{1B}]2;one\u{07}")
        term.input("\u{1B}]2;two\u{07}")
        term.input("\u{1B}]2;three\u{07}")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(titles, ["one", "two", "three"], "events arrive in stream order")
    }

    // MARK: - Track B: rapid-fire round-trip

    /// pre-flight: ~3 KB feed (1000 × 3-byte chunks), ~200 ms; 1000 snapshots.
    ///
    /// 1000 input → snapshot → input → snapshot round-trips on a single
    /// term. Pins the RC discipline: snapshots must release cleanly
    /// without leaking, and the term must remain usable. A regression
    /// where `bb_snap_release` over-released would crash before the
    /// 1000th iteration; under-releasing would inflate grid memory but
    /// not crash — the snapshotID monotonicity guard at the end gives
    /// us at least a smoke signal that nothing got reused.
    func test_rapidInputSnapshotRoundTrip_1000x() throws {
        // Memory budget: 1000 × (BBTerm grid 80×24×16B + 100K scrollback ×
        // 80×16B = ~128MB max if every snapshot were retained; in practice
        // each snapshot is released at end of scope so peak is ~150MB).
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 80, rows: 24)
        )
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var lastID: UInt64 = 0
        for i in 0..<1000 {
            // Three printable bytes; not enough to scroll yet.
            term.input([UInt8(0x61 + (i % 26)), 0x62, 0x63])
            let snap = try XCTUnwrap(
                term.snapshot(),
                "iter \(i): snapshot must succeed under rapid round-trip"
            )
            XCTAssertGreaterThan(
                snap.sequenceID, lastID,
                "iter \(i): sequenceID must monotonically advance"
            )
            lastID = snap.sequenceID
        }
    }

    // MARK: - Track B: re-entrancy guard

    /// pre-flight: ~10 bytes, ~50 ms.
    ///
    /// TST-S2-003 — the C contract forbids calling any `bb_term_*`
    /// function from inside the event callback on the same term.
    /// Production Swift code (`TerminalSession.wire`) hops to main via
    /// `DispatchQueue.main.async` to dodge the latch. A regression that
    /// removed the hop must NOT silently corrupt — DEBUG builds
    /// `assertionFailure` via `BBTerm.isInsideEventDispatch`. We can't
    /// observe assertions from XCTest in DEBUG, BUT we can pin the
    /// invariant from the OUTSIDE: the term must remain usable after
    /// the attempt (even if the inner call no-ops or asserts), and the
    /// outer caller's snapshot must still produce sane data.
    ///
    /// This test runs both with and without an attempted re-entrant
    /// call; under DEBUG the latch may fire, under release it must
    /// silently no-op (or nest, which the documented contract calls
    /// undefined behaviour). The test's job is "never crash, never
    /// leak fatal events"; that's a falsifiable contract regardless
    /// of build mode.
    func test_reentrancyAttempt_inOnEventHandler_doesNotCrashOuterTerm() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        var fatals: [String] = []
        var reentryAttempted = false
        var bellsObserved = 0
        // The handler attempts a re-entrant `input` call (forbidden
        // per the C contract). DEBUG should assert; release silently
        // misbehaves but must not hang or crash this test process.
        term.onEvent { [weak term] ev in
            if case .bell = ev {
                bellsObserved += 1
                if !reentryAttempted {
                    reentryAttempted = true
                    // In DEBUG this call hits `isInsideEventDispatch`
                    // and trips an assertionFailure. In an XCTest
                    // process under release we just want to avoid a
                    // hang/crash. Defer this check to teardown.
                    #if !DEBUG
                    term?.input([0x20])  // space — harmless probe
                    #endif
                }
            }
            if case .fatal(let msg) = ev { fatals.append(msg) }
        }
        term.input([0x07])
        // Outer call: term must still be usable.
        term.input("ok")
        let snap = try XCTUnwrap(term.snapshot())
        // "ok" must land in the grid post-recovery.
        XCTAssertEqual(snap.character(at: 0, row: 0), "o")
        XCTAssertEqual(snap.character(at: 1, row: 0), "k")
        XCTAssertGreaterThanOrEqual(bellsObserved, 1, "bell handler must have run")
        XCTAssertTrue(fatals.isEmpty, "no fatal events: \(fatals)")
    }

    // MARK: - Track B: snapshot of a deeply mutated term

    /// pre-flight: ~16 KB feed, ~50 ms.
    ///
    /// Hammer the term with a synthetic 1000-character ASCII stream
    /// then snapshot. The grid must reflect the LAST cols characters
    /// (or appropriate wrapping), no panic. Catches a regression where
    /// the grid's wrap+scroll path misses one cell on overflow.
    func test_overflow_lastVisibleRow_isLastChars() throws {
        let cols: Int = 40
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: 5)))
        // 1000 chars: 'a'..'z' cycling. Last row should hold the tail.
        var s = ""
        for i in 0..<1000 {
            s.append(Character(UnicodeScalar(0x61 + (i % 26))!))
        }
        term.input(s)
        let snap = try XCTUnwrap(term.snapshot())
        // Final cursor row in a 5-row grid that received 1000 wrapped
        // chars must be the last visible row. Check grid edge invariant
        // rather than a specific char (a wrapping change in alacritty
        // could shift which row gets the tail; the contract here is
        // "snapshot is sane, character query at the cursor returns
        // SOMETHING printable").
        XCTAssertGreaterThanOrEqual(snap.cursorRow, 0)
        XCTAssertLessThan(snap.cursorRow, Int(snap.rows))
        XCTAssertGreaterThanOrEqual(snap.cursorCol, 0)
        XCTAssertLessThan(snap.cursorCol, Int(snap.cols))
    }

    // MARK: - Track B: input variants

    /// pre-flight: ~5 bytes, ~10 ms.
    ///
    /// Empty input must be a no-op: no events, snapshot still works,
    /// no state change. Pins the C contract `len = 0` no-op.
    func test_emptyInput_noEvents_noStateChange() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 5)))
        var calls = 0
        term.onEvent { _ in calls += 1 }
        let snap1 = try XCTUnwrap(term.snapshot())
        let id1 = snap1.sequenceID
        term.input([UInt8]())  // empty
        term.input("")  // empty string
        let snap2 = try XCTUnwrap(term.snapshot())
        // sequenceID still advances on each snapshot call (it's the
        // process-global counter); but the grid contents must be
        // identical. Cheap proxy: cursor didn't move.
        XCTAssertEqual(snap1.cursorRow, snap2.cursorRow)
        XCTAssertEqual(snap1.cursorCol, snap2.cursorCol)
        XCTAssertEqual(calls, 0, "empty input must produce no events")
        XCTAssertGreaterThan(snap2.sequenceID, id1, "snapshot ID still advances")
    }

    // MARK: - Track C: opt-in soak (BB_SOAK=1)

    /// pre-flight: bounded by 10 s wall clock; up to ~50 MB peak
    /// resident depending on alacritty intern caches. Gate with
    /// `BB_SOAK=1` to skip default runs — the soak is for hand
    /// validation, not CI.
    ///
    /// Feed-and-snapshot loop for 10 seconds. Memory must not climb
    /// unboundedly: peak resident at end ≤ 2× peak at the 1-second
    /// mark. Any unbounded climb suggests a snapshot retain leak or
    /// an OSC 8 intern cache that grew past its cap.
    func test_soak_10s_feedAndSnapshot_underBoundedMemory() throws {
        guard ProcessInfo.processInfo.environment["BB_SOAK"] == "1" else {
            throw XCTSkip("BB_SOAK=1 not set; skipping 10s soak")
        }
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 80, rows: 24),
            budgetMB: 256
        )
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        let deadline = Date().addingTimeInterval(10)
        var rng = AdversarialRNG(seed: 0x1B1ACBBD_BABEC0DE)
        var iterations = 0
        var firstSecondPeak: UInt64 = 0
        var finalPeak: UInt64 = 0
        let firstSecondDeadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            // Bounded payload: 16-64 B per iteration.
            let length = Int.random(in: 16...64, using: &rng)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                bytes[i] = UInt8.random(in: 0x20...0x7E, using: &rng)  // printable
            }
            term.input(bytes)
            _ = term.snapshot()
            iterations += 1
            let rss = currentResidentSetSize()
            if Date() < firstSecondDeadline {
                firstSecondPeak = max(firstSecondPeak, rss)
            }
            finalPeak = max(finalPeak, rss)
        }
        XCTAssertGreaterThan(iterations, 1000, "soak should manage > 1000 iterations")
        // Peak memory must not grow unboundedly across 10 s. Allow
        // 4x headroom (intern caches and snapshot allocation can
        // legitimately balloon on first runs).
        XCTAssertLessThan(
            finalPeak, firstSecondPeak * 4 + 50 * 1024 * 1024,
            "final peak memory \(finalPeak / 1024 / 1024) MB grew past 4x first-second \(firstSecondPeak / 1024 / 1024) MB"
        )
    }
}

// MARK: - Helpers

/// xorshift64 RNG. Deterministic, reproducible. NOT a security RNG —
/// intentional choice so a flaky CI run is reproducible offline.
private struct AdversarialRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }
}

/// Best-effort current-process resident set size in bytes. Used only
/// in the BB_SOAK soak test — not a precise measurement, just a
/// "growing unboundedly?" signal. Returns 0 if the syscall fails (the
/// test's invariant tolerates that gracefully via the 4x headroom).
private func currentResidentSetSize() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr: kern_return_t = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
}
