import XCTest
import Combine
@testable import Blackbird

final class TerminalSessionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_resize_clampsOversizedDimensions() throws {
        // Paired with the Rust-side tests bb_term_resize_clamps_oversized_
        // dimensions and bb_term_new_clamps_oversized_dimensions. Swift's
        // TerminalSession.resize mirrors the core clamp at [2, 1000].
        // A caller passing UInt16.max must NOT crash and must land on
        // exactly the clamp ceiling.
        //
        // Memory budget: 1000 × max(1000, 10 000 scrollback) × 32B ≈
        // 320 MB allocation under alacritty reflow — well within a dev
        // machine's RAM. The test's pre-flight check: sanity on this.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        // Exactly 1000×1000 — the clamp ceiling. Waiting for the
        // SPECIFIC post-resize dimensions, not just "any sane value",
        // because the initial 80×24 snapshot already satisfies the
        // latter and would fulfil the expectation vacuously.
        let exp = expectation(description: "snapshot at clamped size 1000×1000")
        var gotExpected = false
        var c: AnyCancellable?
        c = session.$snapshot.compactMap { $0 }.sink { snap in
            if !gotExpected, snap.cols == 1000, snap.rows == 1000 {
                gotExpected = true
                c?.cancel()
                exp.fulfill()
            }
        }
        session.resize(to: .init(cols: UInt16.max, rows: UInt16.max))
        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    func test_osc52MaxBytes_isSetAndLarge() {
        // Pin the OSC 52 clipboard-write cap. A shrink silently
        // truncates every legitimate paste-forward scenario (1 MiB
        // covers log paste, code paste). A grow re-opens DoS.
        XCTAssertEqual(
            TerminalSession.osc52MaxBytes, 1 * 1024 * 1024,
            "OSC 52 payload cap must remain 1 MiB — Ghostty's default"
        )
    }

    func test_shellOutputAppearsInSnapshot() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "printf hello"],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "hello in snapshot")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if let ch = snap.character(at: 0, row: 0), ch == "h" {
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    func test_sendBytesReachesShell() throws {
        // Use /bin/cat: deterministic echo. Interactive /bin/sh was flaky
        // because sh's decision to echo depends on whether the kernel PTY
        // driver sees ECHO ON AND the shell has reached its read(2) — a
        // race. cat just echoes stdin after each newline, reliably.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "cat echoed back")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                for col in 0..<snap.cols {
                    if snap.character(at: col, row: 0) == "h" {
                        c?.cancel()
                        exp.fulfill()
                        return
                    }
                }
            }

        // cat echoes each line after newline.
        session.send(Data("hello\n".utf8))
        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    func test_titleEventUpdatesPublishedTitle() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "printf '\\033]2;my-title\\007'"],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "title set")
        var c: AnyCancellable?
        c = session.$title
            .compactMap { $0 }
            .sink { title in
                if title == "my-title" {
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    // Pin the scroll sign convention: positive delta reveals older content
    // (scrollback) by growing displayOffset. The mouseDragged autoscroll path
    // relies on this; a previous bug had the signs swapped.
    func test_scrollPositiveDeltaShowsOlderContent() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            // Enough newlines to push lines into scrollback beyond the 5-row grid.
            arguments: ["-c", "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo line$i; done; sleep 0.3"],
            size: .init(cols: 20, rows: 5)
        )

        // Wait until history has accumulated.
        let histExp = expectation(description: "history built")
        var c: AnyCancellable?
        c = session.$snapshot.sink { snap in
            if let snap, snap.historySize > 0 {
                c?.cancel()
                histExp.fulfill()
            }
        }
        wait(for: [histExp], timeout: 3.0)

        let before = session.snapshot?.displayOffset ?? 0
        session.scroll(delta: 1)
        let after = session.snapshot?.displayOffset ?? 0
        XCTAssertGreaterThan(
            after, before,
            "scroll(delta: 1) should advance displayOffset into scrollback (show older)"
        )

        // And the reverse brings us back toward the live grid.
        session.scroll(delta: -1)
        let afterBack = session.snapshot?.displayOffset ?? 0
        XCTAssertLessThan(
            afterBack, after,
            "scroll(delta: -1) should move displayOffset back toward the live grid"
        )

        session.terminate()
    }

    func test_resize_degenerateSizeClampsToMinimum() throws {
        // Caller passes a pathological 1×1. The Rust core clamps to 2×2 so
        // reflow doesn't explode; Swift must clamp before calling PTY so the
        // tty's TIOCSWINSZ matches what the grid will actually render into.
        // The snapshot's final cols/rows reflect the clamp — anything below 2
        // here would mean the PTY and grid disagree on dimensions.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "snapshot at clamped size")
        var gotExpected = false
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if snap.cols == 2, snap.rows == 2, !gotExpected {
                    gotExpected = true
                    c?.cancel()
                    exp.fulfill()
                }
            }

        session.resize(to: .init(cols: 1, rows: 1))

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    /// Bug #3 + Bug #9 regression: an oversized resize request must reach
    /// the PTY's TIOCSWINSZ as the clamped dims (≤ 1000), not as the raw
    /// request. We can't hook the ioctl directly from a unit test, but
    /// `stty size` reads winsize from the PTY slave and prints
    /// "rows cols" — that's the shell's view of what TerminalSession
    /// told the kernel. If the shell reports a number > 1000, the bug
    /// is back: TIOCSWINSZ was fed the unclamped request.
    ///
    /// Memory budget: 1000×1000 grid (post-clamp) at 32B/cell ≈ 32 MB,
    /// plus alacritty's reflow scratch — well within budget. We never
    /// allocate at the requested 1500×1500 because the clamp catches
    /// the request before reflow.
    func test_oversizedResize_pty_seesClampedDims_notRequested() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "sleep 0.2; stty size"],
            size: .init(cols: 80, rows: 24)
        )

        // Request 1500×1500 — well past the 1000×1000 clamp ceiling.
        // After the fix, both the grid AND the PTY's winsize must report
        // 1000×1000, not 1500×1500. `stty size` prints "rows cols".
        session.resize(to: .init(cols: 1500, rows: 1500))

        let exp = expectation(description: "stty reports clamped 1000 1000")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                var row0 = ""
                for col in 0..<snap.cols {
                    if let ch = snap.character(at: col, row: 0) {
                        row0.append(ch)
                    }
                }
                // Pre-fix this would print "1500 1500" because TIOCSWINSZ
                // got the unclamped request. Post-fix the shell sees the
                // clamped 1000×1000. Anything else (especially 1500) is
                // a regression.
                if row0.contains("1000 1000") {
                    c?.cancel()
                    exp.fulfill()
                } else if row0.contains("1500") {
                    XCTFail("PTY received unclamped winsize: stty saw '\(row0)'")
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 5.0)
        session.terminate()
    }

    func test_resizePropagatesToCoreAndPty() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "sleep 0.2; stty size"],
            size: .init(cols: 80, rows: 24)
        )

        session.resize(to: .init(cols: 120, rows: 40))

        let exp = expectation(description: "stty reports new size")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                var row0 = ""
                for col in 0..<snap.cols {
                    if let ch = snap.character(at: col, row: 0) {
                        row0.append(ch)
                    }
                }
                if row0.contains("40 120") {
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    /// Audit F1: feeds must coalesce to at most one main-queue snapshot
    /// write while main is busy, regardless of producer rate. We feed
    /// many small chunks synchronously via `feedBytesForTests` (which
    /// `coreQueue.sync`s) *before* spinning the runloop. Main cannot
    /// process any dispatched work during the feed loop, so with the
    /// coalescer the pending slot should be overwritten N-1 times and
    /// the `@Published snapshot` subscriber should fire a small bounded
    /// number of times after `wait(for:)` — NOT once per feed.
    ///
    /// Memory/time: 2000 iterations × 4-byte chunks ≈ 8 KB of input; each
    /// iteration runs `bb_term_input` on 4 bytes + takes a snapshot,
    /// well under a millisecond per iteration on a 2×2 grid. Total well
    /// under one second of runtime. Nowhere near the OOM-resize floor.
    func test_feedCoalescesMainPublishes() {
        let session = TerminalSession.makeHeadlessForTests()
        let sinkCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        sinkCount.initialize(to: 0)
        defer { sinkCount.deallocate() }

        var c: AnyCancellable?
        c = session.$snapshot
            .dropFirst()  // skip the initial-nil publish
            .sink { _ in
                // This fires on whatever thread the @Published was set
                // on — main, in our case, since the coalescer always
                // hops to main.
                sinkCount.pointee += 1
            }

        // 2000 tiny feeds back-to-back. Each one:
        //   - `coreQueue.sync` → `feed(_:)` → `bbterm.input` + snapshot
        //   - `publishPendingSnapshot` stores in the slot
        //   - first feed schedules a main dispatch; subsequent feeds
        //     overwrite the slot because `snapshotDispatchScheduled==true`
        // The test runs on main, so main can't drain between feeds.
        let chunk = Data("data".utf8)
        for _ in 0..<2000 {
            session.feedBytesForTests(chunk)
        }

        // Let main drain the (single) pending dispatch.
        let drained = expectation(description: "main drains")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3.0)

        c?.cancel()
        session.terminate()

        // With coalescing, we expect exactly 1 sink call (the single
        // coalesced dispatch). Allow up to 5 to absorb any main-queue
        // scheduler quirks (e.g. if one of the pre-feed blocks scheduled
        // during wire() got its own dispatch before the loop started).
        // Without coalescing, this would be 2000.
        XCTAssertLessThanOrEqual(
            sinkCount.pointee, 5,
            "expected coalesced publishes (≤ 5) for 2000 feeds, got \(sinkCount.pointee)"
        )
        XCTAssertGreaterThanOrEqual(
            sinkCount.pointee, 1,
            "at least one publish should have landed"
        )
    }

    /// Audit F11: after `terminate()`, queued feeds must not keep
    /// publishing snapshots. Simulate the post-exit race: feed, then
    /// terminate, then feed again. The second feed runs post-termination
    /// and must be a no-op on `@Published snapshot`.
    func test_terminateGatesFurtherFeeds() {
        let session = TerminalSession.makeHeadlessForTests()

        // Drain the wire() initial snapshot so we start from a known
        // baseline.
        let seed = expectation(description: "initial snapshot")
        var seedCancellable: AnyCancellable?
        seedCancellable = session.$snapshot
            .compactMap { $0 }
            .sink { _ in
                seedCancellable?.cancel()
                seed.fulfill()
            }
        wait(for: [seed], timeout: 3.0)

        // Now count post-terminate publishes.
        let postTerminateCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        postTerminateCount.initialize(to: 0)
        defer { postTerminateCount.deallocate() }

        session.terminate()

        var c: AnyCancellable?
        c = session.$snapshot
            .dropFirst()
            .sink { _ in
                postTerminateCount.pointee += 1
            }

        // Any feed here simulates a straggler that `coreQueue.async`
        // queued before termination. Post-terminate, the F11 gate must
        // early-return before publishing.
        for _ in 0..<50 {
            session.feedBytesForTests(Data("x".utf8))
        }

        // Spin main in case some stale dispatch is pending.
        let drained = expectation(description: "main drains")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 3.0)

        c?.cancel()
        XCTAssertEqual(
            postTerminateCount.pointee, 0,
            "feeds after terminate() must not publish snapshots"
        )
    }
}
