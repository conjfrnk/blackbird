import XCTest
import AppKit
@testable import Blackbird

/// Ensures the test host (`Blackbird.app`) terminates cleanly after the test
/// bundle finishes. Without this, `xcodebuild test` leaves zombie app
/// processes: SwiftUI @main apps with a WindowGroup don't auto-exit when
/// XCTest completes.
///
/// Each XCTestCase registers this observer in `class func setUp()`; the
/// singleton guard prevents duplicate registration.
final class TestHostTermination: NSObject, XCTestObservation {
    static let shared = TestHostTermination()
    private var registered = false
    private let lock = NSLock()
    private var issueCount: Int = 0

    func register() {
        lock.lock()
        defer { lock.unlock() }
        guard !registered else { return }
        XCTestObservationCenter.shared.addTestObserver(self)
        registered = true
    }

    /// Audit S2-004: heartbeat for the host's idle-based safety net
    /// (TestHostActivityMonitor). Posting on every test start/finish
    /// means a healthy run — however long — never trips the host's
    /// exit fuse; only a genuinely hung/abandoned host goes idle.
    func testCaseWillStart(_ testCase: XCTestCase) {
        NotificationCenter.default.post(
            name: TestHostActivityMonitor.activityNotification, object: nil
        )
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        NotificationCenter.default.post(
            name: TestHostActivityMonitor.activityNotification, object: nil
        )
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        lock.lock()
        issueCount += 1
        lock.unlock()
    }

    func testSuite(_ testSuite: XCTestSuite, didRecord issue: XCTIssue) {
        lock.lock()
        issueCount += 1
        lock.unlock()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        // Small delay so any pending main-thread work (cancellables, etc.)
        // completes before we exit. Use exit() directly rather than
        // NSApp.terminate because XCTest can intercept the latter and keep
        // the process alive (empirical — we were getting zombie host apps).
        //
        // Propagate test status to the exit code: any recorded XCTIssue
        // (assertion failure, thrown error, crash) exits non-zero so CI
        // catches red runs. Without this, a failing test bundle still
        // exited 0 and passed CI silently.
        lock.lock()
        let failed = issueCount > 0
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            exit(failed ? 1 : 0)
        }
    }
}

// MARK: - Audit S2-004: idle-heartbeat notification contract

/// The test host's safety net (`TestHostActivityMonitor`, app side) only
/// exits after 300 s WITHOUT a heartbeat; `TestHostTermination` (this
/// file, test side) posts that heartbeat on every test start/finish.
/// The two sides rendezvous solely on the notification NAME — a silent
/// rename on either side would re-introduce the killed-mid-run host
/// (or never-exiting zombie) failure mode with no compile error. Pin
/// the literal both sides rely on.
///
/// The 300 s timeout itself is untestable here (a test cannot sit idle
/// for 5 minutes without itself posting start/finish heartbeats), so
/// this is deliberately limited to the name contract + a post smoke.
///
/// Memory: zero allocations beyond a Notification. Wall < 1 ms.
final class TestHostActivityHeartbeatTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_heartbeatNotificationName_isStableContract_andPostingDoesNotCrash() {
        XCTAssertEqual(
            TestHostActivityMonitor.activityNotification.rawValue,
            "dev.conjfrnk.blackbird.testHostActivity",
            "renaming the heartbeat notification silently decouples the "
            + "test-side poster from the app-side idle monitor (audit S2-004)"
        )
        // Post smoke: the app-side observer (live in this very host
        // process) must tolerate a heartbeat with no object/userInfo.
        // Reaching the end of the test without a crash is the assertion.
        NotificationCenter.default.post(
            name: TestHostActivityMonitor.activityNotification, object: nil
        )
    }
}
