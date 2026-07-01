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

    /// Audit cwd-hyperlink F4. The headless test session has no live PTY
    /// (exitCode path short-circuits differently), so this test pins the
    /// "no source" contract: resolver returns nil, not a stale cwd from
    /// a dead session. A fuller test for the fg-child-priority path would
    /// require a live PTY — deferred to integration.
    func testForNewTab_nilSource_returnsNil() {
        XCTAssertNil(CwdResolver.forNewTab(source: nil))
    }

    /// ⌘N: new window is a fresh start (spec §3). The resolver returns
    /// nil, and `PTY.spawn(initialWorkingDirectory: nil)` then falls
    /// through to `$HOME` via its built-in `getpwuid` path. Pinning
    /// `forNewWindow` at nil here keeps that contract explicit so a
    /// future refactor that made ⌘N inherit again would fail loudly.
    func testNewWindowAlwaysHome() {
        XCTAssertNil(CwdResolver.forNewWindow())
    }

    /// Percent-encoded path components decode correctly through OSC 7.
    /// A shell that escaped the CWD via e.g. `$(pwd | sed 's/ /%20/g')`
    /// should land on the decoded filesystem path — `/Users/foo/my proj`,
    /// not the literal `%20` string.
    func testOscCwdPercentDecodesSpaces() {
        let s = TerminalSession.makeHeadlessForTests()
        let exp = expectation(description: "cwd lands")
        let cancellable = s.$lastKnownCwd.dropFirst().sink { value in
            if value != nil { exp.fulfill() }
        }
        s.feedBytesForTests(Data("\u{1b}]7;file:///Users/foo/my%20proj\u{1b}\\".utf8))
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()
        XCTAssertEqual(s.lastKnownCwd, "/Users/foo/my proj")
    }

    /// Non-local authority rejected.
    func testOscCwdRejectsNonLocalAuthority() {
        let s = TerminalSession.makeHeadlessForTests()
        s.feedBytesForTests(Data("\u{1b}]7;file://remote.host/Users/foo\u{1b}\\".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(s.lastKnownCwd, "remote authority must not update cwd")
    }

    /// Malformed UTF-8 in percent-decoded path rejected.
    func testOscCwdRejectsInvalidUtf8() {
        let s = TerminalSession.makeHeadlessForTests()
        // %FF is valid percent-encoding but 0xFF is not a valid UTF-8 byte.
        // The Rust gate must drop this.
        s.feedBytesForTests(Data("\u{1b}]7;file:///bad/%FF/path\u{1b}\\".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(s.lastKnownCwd, "non-UTF-8 path must not surface")
    }

    /// `localhost` authority accepted as a local alias.
    func testOscCwdAcceptsLocalhostAuthority() {
        let s = TerminalSession.makeHeadlessForTests()
        let exp = expectation(description: "cwd lands")
        let cancellable = s.$lastKnownCwd.dropFirst().sink { value in
            if value != nil { exp.fulfill() }
        }
        s.feedBytesForTests(Data("\u{1b}]7;file://localhost/Users/foo/proj\u{1b}\\".utf8))
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()
        XCTAssertEqual(s.lastKnownCwd, "/Users/foo/proj")
    }

    // MARK: - SSH-trust gate (audit synthesis #4 / KNOWN_ISSUES "OSC 7 trust over SSH")

    /// Gate fires when foreground namespace is `.remote(...)` → OSC 7
    /// payload is dropped, `lastKnownCwd` keeps its previous value.
    /// Simulates `ssh remote` being live: the shell on the other side
    /// emits `OSC 7;file:///root/.ssh`, which on the local fs is
    /// `/Users/<me>/.ssh` — the attack documented in KNOWN_ISSUES.md.
    func testOscCwdDroppedWhenForegroundIsRemote() {
        let s = TerminalSession.makeHeadlessForTests()
        // Seed a known-good local cwd, simulating "user was at this
        // path before they ran `ssh`".
        s._testForegroundNamespaceOverride = .local
        let trustedLocal = "/Users/foo/local-project"
        let exp = expectation(description: "trusted cwd lands")
        let cancellable = s.$lastKnownCwd.dropFirst().sink { value in
            if value != nil { exp.fulfill() }
        }
        s.feedBytesForTests(Data("\u{1b}]7;file://\(trustedLocal)\u{1b}\\".utf8))
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()
        XCTAssertEqual(s.lastKnownCwd, trustedLocal)

        // Now simulate ssh being live and a remote OSC 7 arriving.
        s._testForegroundNamespaceOverride = .remote(basename: "ssh", pid: 99999)
        s.feedBytesForTests(Data("\u{1b}]7;file:///root/.ssh\u{1b}\\".utf8))
        // Pump the runloop briefly — a missed gate would visibly flip
        // lastKnownCwd from the trusted value to /root/.ssh.
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(
            s.lastKnownCwd, trustedLocal,
            "OSC 7 from a remote shell must not overwrite the local cwd"
        )
        s._testForegroundNamespaceOverride = nil
    }

    /// Fail-closed: `.unknown` (couldn't classify the tree) is treated
    /// like `.remote`, NOT like `.local`. A syscall failure or BFS cap
    /// hit must not silently let a remote OSC 7 through.
    func testOscCwdDroppedWhenForegroundIsUnknown() {
        let s = TerminalSession.makeHeadlessForTests()
        s._testForegroundNamespaceOverride = .unknown(reason: "test")
        s.feedBytesForTests(Data("\u{1b}]7;file:///some/path\u{1b}\\".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(
            s.lastKnownCwd,
            ".unknown classification must fail-closed (drop OSC 7), not pass through"
        )
        s._testForegroundNamespaceOverride = nil
    }

    /// Gate clears (user ran `exit` from ssh) → subsequent OSC 7 lands
    /// normally. The gate is consulted per-event, not latched.
    func testOscCwdResumesAfterRemoteExits() {
        let s = TerminalSession.makeHeadlessForTests()
        s._testForegroundNamespaceOverride = .remote(basename: "ssh", pid: 99999)
        s.feedBytesForTests(Data("\u{1b}]7;file:///remote/hidden\u{1b}\\".utf8))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(s.lastKnownCwd, "remote OSC 7 must not seed lastKnownCwd")

        // ssh exits — namespace returns to .local.
        s._testForegroundNamespaceOverride = .local
        let exp = expectation(description: "local cwd lands after ssh exit")
        let cancellable = s.$lastKnownCwd.dropFirst().sink { value in
            if value != nil { exp.fulfill() }
        }
        s.feedBytesForTests(Data("\u{1b}]7;file:///Users/foo/back-home\u{1b}\\".utf8))
        wait(for: [exp], timeout: 1.0)
        cancellable.cancel()
        XCTAssertEqual(s.lastKnownCwd, "/Users/foo/back-home")
        s._testForegroundNamespaceOverride = nil
    }

    /// Headless session has no PTY → classification defaults to
    /// `.local` so existing OSC 7 tests (which don't set an override)
    /// keep working. The fail-closed posture for production is enforced
    /// inside `PTY.classifyForegroundNamespace()`, which returns
    /// `.unknown` on tcgetpgrp/proc_listpids failure — production
    /// sessions always have `pty != nil` so they go through that path.
    func testHeadlessSessionDefaultsToLocal() {
        let s = TerminalSession.makeHeadlessForTests()
        if case .local = s.classifyForegroundNamespace() {
            // ok — headless ergonomic default
        } else {
            XCTFail(
                "Headless session should default to .local for test ergonomics; got \(s.classifyForegroundNamespace())"
            )
        }
    }

    /// Negative control: walking from this xctest process — which has
    /// no `ssh` / `mosh-client` / `docker` etc in its tree — returns
    /// `.local`. Pinned with the BFS-on-self check.
    func testClassifyProcessTreeOnSelfReturnsLocal() {
        let me = getpid()
        let result = ForegroundProcessProbe.classify(rootPID: me)
        switch result {
        case .local:
            break  // expected
        case .remote(let basename, _):
            XCTFail("xctest tree must not contain remote binary; matched \(basename)")
        case .unknown(let reason):
            XCTFail("xctest tree should classify cleanly as .local; got .unknown(\(reason))")
        }
    }

    /// Audit fix-#01 (2026-05-11): when proc_pidpath / proc_listpids fail
    /// on the rootPID (e.g. the foreground process exited between
    /// tcgetpgrp and the classification walk; sandbox-restricted target;
    /// EPERM), the classifier must fail-CLOSED to `.unknown` rather than
    /// falling through to `.local`. The OSC 7 trust gate accepts only
    /// `.local`; a fail-open `.local` on a remote shell whose proc
    /// metadata is briefly inaccessible would cause cwdChanged events to
    /// be trusted as local, mis-pointing `lastKnownCwd` for ⌘T cwd
    /// inheritance.
    ///
    /// Setup: pick a pid sentinel that's guaranteed unallocated on this
    /// system (Darwin pid_max is configurable via sysctl but is well
    /// under INT32_MAX in practice). proc_pidpath against an unallocated
    /// pid returns -1 with errno=ESRCH — the real-syscall-failure shape
    /// the fix-#01 strict probes detect. Pre-fix-#01 this returned
    /// `.local` because the BFS fell through `executableBasename==nil`
    /// and `childPIDs==[]` (silently treating syscall failure as "no
    /// match"/"no children"). Post-fix it returns `.unknown(reason:
    /// "proc_pidpath failed on rootPID ...")`.
    ///
    /// Using a spawned-then-reaped pid would race: macOS pid recycling
    /// can hand the slot to a stranger process before our classifier
    /// runs, and proc_pidpath would succeed against the stranger
    /// (returning .local for the stranger's tree). The sentinel approach
    /// is deterministic.
    func testClassifyProcessTreeOnDefunctPIDReturnsUnknown() {
        // Pid INT32_MAX is unambiguously above any kernel allocation —
        // Darwin's PID_MAX is on the order of 100K on stock kernels.
        // Verify proc_pidpath fails before driving the classifier, so a
        // future kernel change that allocates very large pids surfaces
        // here rather than producing a false-pass.
        let sentinelPID: pid_t = pid_t.max
        var buf = [CChar](repeating: 0, count: 4096)
        let probe = proc_pidpath(sentinelPID, &buf, UInt32(buf.count))
        // Darwin's proc_pidpath returns 0 OR -1 for unallocated pids
        // (kernel may reject early with n=0, or fail with n=-1+errno).
        // Either signal counts as the syscall-failure shape the strict
        // probe must detect. A successful (n > 0) probe would mean the
        // sentinel is actually a live pid on this host — pick a larger
        // sentinel in that case.
        XCTAssertLessThanOrEqual(
            probe, 0,
            "test setup: proc_pidpath against pid_t.max must signal failure (n <= 0); if your kernel allocates pid_t.max, pick a larger sentinel"
        )
        let result = ForegroundProcessProbe.classify(rootPID: sentinelPID)
        switch result {
        case .local:
            XCTFail("ForegroundProcessProbe.classify on a syscall-failing pid must fail-CLOSED to .unknown, got .local — regression of audit fix-#01")
        case .remote(let basename, _):
            XCTFail("ForegroundProcessProbe.classify on a syscall-failing pid must not match remote; got .remote(\(basename))")
        case .unknown:
            break  // expected
        }
    }

    /// Basename-set membership: the remote-binary set contains the
    /// canonical wrappers we said it would. Without this, a refactor
    /// that accidentally narrowed the set (e.g., dropped `mosh-client`
    /// on the assumption it's "covered by ssh") would silently regress
    /// the gate to mishandle non-ssh remote sessions, and the BFS-on-
    /// self test would still pass. Pairs with the BFS-walks-correctly
    /// negative control above to give us positive + negative coverage
    /// without spawning subprocesses (`proc_pidpath` returns the
    /// interpreter path for shebang scripts, which would defeat a
    /// naive script-based positive control). Audit synthesis #4.
    func testRemoteShellBasenameSetCoversCanonicalWrappers() {
        // The expected entries — these are the ones the gate's threat
        // model relies on. A regression that drops any of these is a
        // security-relevant change and should be loud.
        let expected = ["ssh", "slogin", "mosh-client", "telnet",
                        "docker", "podman", "nerdctl", "kubectl", "lima"]
        for binary in expected {
            XCTAssertTrue(
                ForegroundProcessProbe.remoteShellBinaryBasenamesForTests.contains(binary),
                "remote-binary set must contain '\(binary)' — required for SSH-trust gate"
            )
        }
        // Negative: the set is conservative, not catch-all. Local
        // tools that look similar but don't run a remote shell
        // (`scp`, `rsync`, `git`) must NOT be in the set, otherwise the
        // gate would over-fire and pin lastKnownCwd unnecessarily
        // during routine local file ops.
        for binary in ["zsh", "bash", "scp", "rsync", "git"] {
            XCTAssertFalse(
                ForegroundProcessProbe.remoteShellBinaryBasenamesForTests.contains(binary),
                "'\(binary)' must NOT be in the remote-binary set — would over-fire the gate"
            )
        }
    }
}
