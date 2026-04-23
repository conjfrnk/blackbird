import XCTest
import Combine
@testable import Blackbird

/// K3 shutdown-order barrier. Each of these invariants was established
/// by a separate fix during the audit sweep; this test pins them
/// together so a future refactor that breaks one is caught by a single,
/// fast test rather than surfacing as a TSan trap or a renderer
/// crash.
///
/// The invariant: once `TerminalSession.terminate()` returns, NO
/// further `@Published` snapshot assignments may occur. Downstream
/// consumers (TerminalView, FindBar caches, hyperlink scanners) may be
/// tearing down; an out-of-order snapshot after `terminate()` wakes
/// stale subscribers and causes the "snapshot seq jumped backwards"
/// diagnostics that preceded commits `3e92396` and `37ea428`.
final class SessionShutdownBarrierTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// After `terminate()`, feeding bytes must NOT cause a `@Published
    /// snapshot` update. The feed path sees `isTerminated == true` in
    /// its main-dispatch closure and bails before writing `self.snapshot`.
    func test_noSnapshotPublishedAfterTerminate() {
        let session = TerminalSession.makeHeadlessForTests()

        // Prime: feed a byte and confirm a pre-terminate snapshot is
        // observable. Without this baseline, a "no post-terminate
        // snapshot" assertion is satisfied vacuously by a session
        // that never publishes at all.
        let pre = expectation(description: "pre-terminate snapshot")
        var pretoken: AnyCancellable?
        pretoken = session.$snapshot.compactMap { $0 }.sink { _ in
            pretoken?.cancel()
            pre.fulfill()
        }
        session.feedBytesForTests(Data("pre".utf8))
        wait(for: [pre], timeout: 1.0)

        // Barrier: terminate, then feed again. If the post-terminate
        // feed leaks through to @Published, this subscriber fires.
        session.terminate()

        var postFired = false
        let postToken = session.$snapshot
            .dropFirst()   // ignore the Combine initial replay
            .sink { _ in postFired = true }
        defer { postToken.cancel() }

        session.feedBytesForTests(Data("post".utf8))
        // feedBytesForTests dispatches through coreQueue → main. Pump main
        // long enough for the straggler to either fire or bail.
        let deadline = Date(timeIntervalSinceNow: 0.25)
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertFalse(
            postFired,
            "feed after terminate must not publish a snapshot"
        )
    }

    /// Sanity: repeated `terminate()` is idempotent. A defensive caller
    /// (e.g. window-close path firing alongside application-terminate)
    /// must not crash on double-terminate.
    func test_terminateIsIdempotent() {
        let session = TerminalSession.makeHeadlessForTests()
        session.terminate()
        session.terminate()       // no crash == pass
        session.terminate()
    }
}
