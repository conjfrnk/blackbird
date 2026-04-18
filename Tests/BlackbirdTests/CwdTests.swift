import XCTest
import Combine
@testable import Blackbird

/// Cwd plumbing: OSC 7 updates `TerminalSession.lastKnownCwd`; the shared
/// `CwdResolver` (used by both ⌘T and ⌘N in production) maps the active
/// session to the directory a new shell should start in. Matches spec
/// §4.1 (OSC 7 event) and §4.4 / §3 (⌘T inherits, ⌘N is fresh).
final class CwdTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Happy path: OSC 7 ; file:///Users/foo/proj ST → Rust core emits
    /// CwdChanged(payload="/Users/foo/proj"); Swift stores it on the
    /// session. Uses Combine to wait on the publisher so there's no
    /// runloop-pump flake window — the expectation fulfills as soon as
    /// the main-queue hop inside `wire()` lands.
    func testOscCwdUpdatesLastKnownCwd() {
        let s = TerminalSession.makeHeadlessForTests()
        let exp = expectation(description: "cwd lands")
        let cancellable = s.$lastKnownCwd
            .dropFirst()                 // skip the initial nil
            .sink { value in
                if value != nil { exp.fulfill() }
            }
        s.feedBytesForTests(Data("\u{1b}]7;file:///Users/foo/proj\u{1b}\\".utf8))
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()
        XCTAssertEqual(s.lastKnownCwd, "/Users/foo/proj")
    }

    /// Non-file scheme is dropped by the Rust core before it ever fires
    /// `CwdChanged` — so no event lands on the session, and
    /// `lastKnownCwd` stays nil. This is a *negative* assertion: we
    /// can't await an event that never fires, so feed the bytes, pump
    /// the main runloop briefly to drain any pending main-queue hops
    /// (there should be none), and verify the value is still nil.
    func testMalformedOscCwdIgnored() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("\u{1b}]7;https://example/x\u{1b}\\".utf8))
        // Intentional short pump: a legitimate `.cwdChanged` dispatch
        // would schedule a `DispatchQueue.main.async` inside `wire()`.
        // Giving any such hop a chance to land means that a missed gate
        // in the Rust core would visibly flip this value to non-nil
        // rather than silently racing past our assertion.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(s.lastKnownCwd)
    }

    /// ⌘T: new tab inherits the active session's `lastKnownCwd`. Calls
    /// the real production resolver — same function `AppDelegate
    /// .newWindowForTab(_:)` calls — so if the priority ever changes
    /// this test moves with it.
    func testNewTabForksInActiveCwd() {
        let s = TerminalSession.makeHeadlessForTests()
        s.lastKnownCwd = "/tmp/somewhere"
        XCTAssertEqual(CwdResolver.forNewTab(source: s), "/tmp/somewhere")
    }

    /// ⌘N: new window is a fresh start (spec §3). The resolver returns
    /// nil, and `PTY.spawn(initialWorkingDirectory: nil)` then falls
    /// through to `$HOME` via its built-in `getpwuid` path. Pinning
    /// `forNewWindow` at nil here keeps that contract explicit so a
    /// future refactor that made ⌘N inherit again would fail loudly.
    func testNewWindowAlwaysHome() {
        XCTAssertNil(CwdResolver.forNewWindow())
    }
}
