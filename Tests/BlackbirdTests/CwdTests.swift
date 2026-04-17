import XCTest
@testable import Blackbird

/// Cwd plumbing: OSC 7 updates `TerminalSession.lastKnownCwd`, and the
/// tab / window actions correctly honour (tab) or ignore (window) that
/// value. Matches spec §4.1 (OSC 7 event) and §4.4 (new-tab-in-cwd).
final class CwdTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Happy path: OSC 7 ; file:///Users/foo/proj ST → Rust core emits
    /// CwdChanged(payload="/Users/foo/proj"); Swift stores it on the
    /// session.
    func testOscCwdUpdatesLastKnownCwd() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("\u{1b}]7;file:///Users/foo/proj\u{1b}\\".utf8))
        // The underlying `bbterm.onEvent` callback lands on `coreQueue`
        // (non-main), then hops to `main` to mutate `lastKnownCwd`. The
        // feedBytesForTests helper below serialises through the same
        // queue and blocks on main-sync so by the time we assert, the
        // property is settled. No expectation plumbing needed.
        XCTAssertEqual(s.lastKnownCwd, "/Users/foo/proj")
    }

    /// Non-file scheme is dropped by the Rust core before it fires
    /// CwdChanged — nothing should land on the session.
    func testMalformedOscCwdIgnored() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("\u{1b}]7;https://example/x\u{1b}\\".utf8))
        XCTAssertNil(s.lastKnownCwd)
    }

    /// ⌘T: new tab inherits the active session's `lastKnownCwd`.
    func testNewTabForksInActiveCwd() {
        let controller = MainWindowController.makeHeadlessForTests()
        let active = controller.session!
        active.lastKnownCwd = "/tmp/somewhere"
        let next = controller.newTabForTests()
        XCTAssertEqual(next.spawnedCwd, "/tmp/somewhere")
    }

    /// ⌘N: new window is a fresh start (spec §3). Never inherits cwd,
    /// always starts at `$HOME`.
    func testNewWindowAlwaysHome() {
        let controller = MainWindowController.makeHeadlessForTests()
        controller.session?.lastKnownCwd = "/tmp/somewhere"
        let newWin = controller.app.newWindowForTests()
        XCTAssertEqual(
            newWin.session?.spawnedCwd,
            ProcessInfo.processInfo.environment["HOME"]
        )
    }
}
