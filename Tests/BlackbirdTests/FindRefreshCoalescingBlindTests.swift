import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for the find bar's snapshot-driven re-search
/// coalescing (spec, not implementation):
///
///  - `FindController.refreshCoalesceInterval == 0.1`.
///  - With the bar open and a live query, two snapshots published ~10 ms
///    apart must trigger AT MOST ONE re-search within the following
///    80 ms — and the re-search must have run (against the latest
///    snapshot) by 300 ms. Observed through `findMatchesSeq`, which the
///    search stamps with the scanned snapshot's `sequenceID`.
///
/// Fixture: headless `TerminalView` bound to a headless `TerminalSession`
/// (real BBTerm, no PTY), grid 40×6. Snapshots are published through the
/// session's real feed → coalesced main publish → `view.render(snapshot:)`
/// path, so the runloop is pumped in ≤ 5 ms slices while waiting. Total
/// wall time ≈ 0.5 s; memory trivial (a handful of 6-row snapshots).
final class FindRefreshCoalescingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Interval pin

    func test_refreshCoalesceInterval_is100ms() {
        XCTAssertEqual(FindController.refreshCoalesceInterval, 0.1, accuracy: 0.0001,
                       "snapshot-driven find refresh must coalesce on a 100 ms window")
    }

    // MARK: - Fixture

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        view.session = session
        return Rig(view: view, session: session)
    }

    /// Pump the main runloop in 5 ms slices until `condition` holds or
    /// `timeout` elapses. Returns whether the condition was met.
    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    /// Feed one line through the session and wait for a publish that SHOWS
    /// it to land on the view (matching on content, not "any publish", so
    /// wire()'s initial blank snapshot or the resize publish can't satisfy
    /// the wait). Returns the new snapshot's sequence id.
    private func publish(_ rig: Rig, line text: String,
                         file: StaticString = #filePath, line: UInt = #line) throws -> UInt64 {
        rig.session.feedBytesForTests(Data((text + "\r\n").utf8))
        let landed = pump(until: 2.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix(text) }
        }
        XCTAssertTrue(landed, "session publish showing '\(text)' must reach view.currentSnapshot within 2 s",
                      file: file, line: line)
        return try XCTUnwrap(rig.view.currentSnapshot?.sequenceID, file: file, line: line)
    }

    // MARK: - Coalescing

    func test_twoSnapshotsTenMsApart_reSearchOnceAfterDebounce() throws {
        let rig = try makeRig()
        let fc = rig.view.findController

        // Seed the grid and the initial search so `findMatchesSeq` has a
        // known baseline that predates the two publishes under test.
        let seq0 = try publish(rig, line: "alpha one")
        fc.installFindBar()
        XCTAssertNotNil(fc.findBar, "find bar must be open for the refresh path to engage")
        fc.findQuery = "alpha"
        fc.performSearch(query: "alpha")
        XCTAssertEqual(fc.findMatchesSeq, seq0, "precondition: the initial search ran against the seed snapshot")
        XCTAssertEqual(fc.findMatches.count, 1, "precondition: one 'alpha' on the grid")

        // Publish #1, then #2 about 10 ms later.
        let t1 = Date()
        let seq1 = try publish(rig, line: "alpha two")
        pump(until: 0.010) { false }
        let seq2 = try publish(rig, line: "alpha three")
        let t2 = Date()
        XCTAssertNotEqual(seq1, seq2)
        XCTAssertEqual(rig.view.currentSnapshot?.sequenceID, seq2, "view must hold the latest snapshot")

        // Watch findMatchesSeq for the 80 ms after publish #2, counting
        // distinct values it takes on (each new value == one re-search).
        var observed: [UInt64?] = [fc.findMatchesSeq]
        var checkedAt50ms = false
        var seqAt50ms: UInt64? = nil
        let windowEnd = t2.addingTimeInterval(0.080)
        while Date() < windowEnd {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
            let now = fc.findMatchesSeq
            if now != observed.last! { observed.append(now) }
            if !checkedAt50ms, Date().timeIntervalSince(t2) >= 0.050 {
                checkedAt50ms = true
                seqAt50ms = now
            }
        }
        let reSearchesIn80ms = observed.count - 1
        XCTAssertLessThanOrEqual(
            reSearchesIn80ms, 1,
            "two snapshots 10 ms apart must trigger at most one re-search within 80 ms; "
            + "observed findMatchesSeq values \(observed.map { $0.map(String.init) ?? "nil" })"
        )

        // The debounce is 100 ms from the FIRST publish, so at ~50 ms after
        // the second the latest snapshot must not have been scanned yet.
        // Only meaningful if the harness landed both publishes fast enough
        // that the 50 ms mark still precedes the 100 ms debounce deadline.
        let gap = t2.timeIntervalSince(t1)
        if gap + 0.050 < 0.090 {
            XCTAssertTrue(checkedAt50ms, "50 ms checkpoint must have been sampled")
            XCTAssertNotEqual(
                seqAt50ms, seq2,
                "50 ms after the second publish the coalesced re-search must not have run yet "
                + "(debounce is 100 ms from the first publish, which landed \(Int(gap * 1000)) ms earlier)"
            )
        } else {
            // Harness too slow to make the "not yet" claim; the 300 ms
            // convergence check below is the only assertion for this run.
            print("FindRefreshCoalescingBlindTests: publish gap \(Int(gap * 1000)) ms too large for the 50 ms not-yet check; skipped")
        }

        // By 300 ms the re-search must have caught up to the latest snapshot.
        let converged = pump(until: max(0, 0.300 - Date().timeIntervalSince(t2))) {
            fc.findMatchesSeq == seq2
        }
        XCTAssertTrue(
            converged && fc.findMatchesSeq == seq2,
            "within 300 ms of the second publish findMatchesSeq must equal the latest snapshot's "
            + "sequenceID (\(seq2)); got \(fc.findMatchesSeq.map(String.init) ?? "nil")"
        )
        XCTAssertEqual(fc.findMatches.count, 3, "the coalesced re-search must have scanned the latest grid (three 'alpha's)")

        // Non-vacuity for the coalescing claim: exactly one seq transition
        // over the whole episode (seq0 → seq2), never a seq1 stop-over.
        XCTAssertFalse(observed.contains(seq1),
                       "a per-snapshot re-search would have stamped seq1 before seq2; coalescing must skip it")
        // Keep the strong reference alive through the last assertion.
        withExtendedLifetime(rig) {}
    }

    func test_closedBar_doesNotReSearchOnSnapshot() throws {
        let rig = try makeRig()
        let fc = rig.view.findController
        let seq0 = try publish(rig, line: "alpha")
        // Query set but no bar installed → no refresh scheduling.
        fc.findQuery = "alpha"
        fc.performSearch(query: "alpha")
        XCTAssertEqual(fc.findMatchesSeq, seq0)

        let seq1 = try publish(rig, line: "alpha again")
        pump(until: 0.250) { fc.findMatchesSeq == seq1 }
        XCTAssertEqual(fc.findMatchesSeq, seq0,
                       "with the find bar closed a new snapshot must not trigger a re-search")
        withExtendedLifetime(rig) {}
    }
}
