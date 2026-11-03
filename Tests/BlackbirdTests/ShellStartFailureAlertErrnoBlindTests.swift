import XCTest
import AppKit
import Darwin
@testable import Blackbird

/// Blind-authored regression test for **ERR-3: the "Couldn't start shell"
/// alert shows an opaque Cocoa string instead of the errno**.
///
/// Written from the bug report / contract WITHOUT reading the bodies of
/// `SessionLifecycle`, `PTY` or `TerminalSession` (CLAUDE.md "Author new
/// behavior tests blind"). Only declarations, doc comments, the
/// `makeForTesting(stubSession:)` / `makeHeadlessForTests()` seams and sibling
/// tests (harness templates: `CoreFailureKeepOpenBlindTests`,
/// `CustomShellDiesAtStartupBlindTests`) were consulted.
///
/// ## The bug being pinned
///
/// When the shell cannot be started (`PTY.spawn` throws, or
/// `TerminalSession.SessionError.coreInitFailed` is thrown), the window
/// presents a "Couldn't start shell" sheet whose body is
/// "Blackbird couldn't launch the shell:" followed by the thrown error's
/// description. For a bare Swift enum error that description is Foundation's
/// bridged placeholder
///
///     The operation couldn't be completed. (Blackbird.PTY.Error error 0.)
///
/// which names neither the failing call nor the errno. `forkpty` failing with
/// `EAGAIN` (process limit reached: a very common state on a busy developer
/// machine), out of ptys, and out of memory all render identically, so a user
/// cannot tell "out of processes" from "broken shell", and support cannot
/// triage a screenshot of the alert.
///
/// ## Contract (terminal / macOS conventions)
///
/// Every Unix terminal reports a failed fork/openpty by the errno's reason
/// (`strerror(3)`): "fork: Resource temporarily unavailable" is what a shell
/// prints at an exhausted process table, "Cannot allocate memory" at ENOMEM.
/// So the alert text a user reads must
///   1. contain the `strerror` reason of the errno that made the spawn fail,
///   2. differ for different errnos (the user can tell the causes apart), and
///   3. never be the bridged `(Blackbird.<Type> error N.)` Cocoa placeholder,
///      whichever error type reaches it (`SessionError.coreInitFailed`
///      carries no errno but is equally unreadable today).
/// Exact wording, punctuation, and whether the number is also shown are NOT
/// asserted: any sound fix (a `LocalizedError` conformance, an explicit
/// formatter in the alert, an `NSPOSIXError` bridge) satisfies the above.
///
/// ## How the production path is exercised
///
///   - Each test builds ONE real `MainWindowController` via
///     `makeForTesting(stubSession:)` with a headless (no-PTY) session, hands
///     the error to the real `SessionLifecycle.presentShellStartFailureAlert`
///     exactly as `startSession`'s `catch` does, then reads the text of the
///     sheet that AppKit actually attached to the window (`attachedSheet`).
///     Nothing about the alert's construction is mocked; the test reads what
///     the user would read.
///   - The end-to-end test squeezes `RLIMIT_NPROC` (soft) to 1 in this
///     process for the duration of a single `PTY.spawn` call, which makes the
///     kernel refuse the `fork` with `EAGAIN`, then feeds the REAL thrown
///     error to the alert. The limit is restored before any window work, and
///     the restoration is verified.
///
/// ## Non-vacuity
///
///   - The sheet really appeared and offers the documented "Retry" / "Close
///     Window" buttons before any text assertion is made.
///   - The end-to-end test asserts that an unsqueezed `PTY.spawn` succeeds
///     first (warming every once-per-process latch on the spawn path so a
///     failure is never cached for later tests; KittyTerminfo is resolved in
///     the class `setUp()`, see the comment there), that an
///     independent `posix_spawn` probe, under the squeeze, reports `EAGAIN`,
///     that `PTY.spawn` really threw, and that the soft limit was restored
///     (Darwin clamps the hard limit when the soft limit is lowered, so the
///     restore re-applies the soft value under the clamped hard limit).
///   - Every failure message prints the full measured alert text.
///
/// ## Safety / cost budget (CLAUDE.md test rules)
///
///   - At most ONE `MainWindowController` is alive at any time (static slot
///     ratchet); each is torn down before its helper returns. Controllers are
///     headless-stub-backed: no PTY, no shell, no fork.
///   - The squeeze lasts one `posix_spawn` probe + one `PTY.spawn`, both of
///     which fail inside `fork`, so no child is created; only this thread runs
///     in the window. Skipped when running as root (the kernel does not
///     enforce `RLIMIT_NPROC` for uid 0).
///   - Memory: one window + one Metal view (a few MB) per controller, <= 5
///     controllers in the file, sequentially. Time: < 1 s per controller.
final class ShellStartFailureAlertErrnoBlindTests: XCTestCase {

    // MARK: - One-live-controller ratchet

    private static var liveControllerCount = 0
    private static let liveControllerLock = NSLock()

    private static func acquireControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        precondition(
            liveControllerCount == 0,
            "ShellStartFailureAlertErrnoBlindTests: a previous test left a real "
                + "MainWindowController alive; at most ONE may exist."
        )
        liveControllerCount = 1
    }

    private static func releaseControllerSlot() {
        liveControllerLock.lock()
        defer { liveControllerLock.unlock() }
        liveControllerCount = max(0, liveControllerCount - 1)
    }

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
        // Resolve KittyTerminfo's once-per-process latch HERE, before any
        // window exists, and not lazily inside the end-to-end test. Its first
        // evaluation shells out to `tic`/`infocmp` and waits (spinning the
        // main runloop); doing that after earlier tests in this class have
        // dismissed their sheets and closed their windows killed the xctest
        // host outright (observed: silent host exit, "Restarting after
        // unexpected exit"), the deferred-CATransaction hazard CLAUDE.md
        // documents. It must also resolve while fork still works, so the
        // squeezed spawn below cannot cache a failure for later tests.
        _ = KittyTerminfo.available
    }

    // MARK: - Helpers

    /// Pump the main runloop in 20 ms slices until `condition` holds or
    /// `timeout` elapses. Returns whether the condition was met.
    @discardableResult
    private func pump(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for sub in view.subviews { found += allButtons(in: sub) }
        return found
    }

    private func allLabelTexts(in view: NSView) -> [String] {
        var found: [String] = []
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            found.append(field.stringValue)
        }
        for sub in view.subviews { found += allLabelTexts(in: sub) }
        return found
    }

    /// Build a headless-stub-backed controller, push `error` through the real
    /// failure-alert presenter, and return everything the sheet says.
    private func presentedAlertText(
        for error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        Self.acquireControllerSlot()
        defer { Self.releaseControllerSlot() }

        let stub = TerminalSession.makeHeadlessForTests()
        guard let controller = MainWindowController.makeForTesting(stubSession: stub) else {
            throw XCTSkip("no Metal device (CI virtual display): makeForTesting returned nil")
        }
        let window = try XCTUnwrap(controller.window, "controller must own a window", file: file, line: line)
        let view = try XCTUnwrap(controller.terminalView, "controller must own a TerminalView", file: file, line: line)

        defer {
            // Dismiss through the sheet's own close button (never "Retry",
            // which would start a real shell), let the handler run, then
            // make sure the window is gone.
            if let sheet = window.attachedSheet {
                let buttons = allButtons(in: sheet.contentView ?? NSView())
                if let close = buttons.first(where: { $0.title.hasPrefix("Close") }) {
                    close.performClick(nil)
                } else {
                    window.endSheet(sheet)
                }
                pump(timeout: 2.0) { window.attachedSheet == nil }
            }
            controller.terminateSessions()
            if !controller.isClosing { window.close() }
        }

        controller.sessionLifecycle.presentShellStartFailureAlert(error: error, inView: view)

        let sheetAppeared = pump(timeout: 3.0) { window.attachedSheet != nil }
        XCTAssertEqual(
            sheetAppeared, true,
            "presentShellStartFailureAlert must attach a sheet to the window (attachedSheet stayed nil for 3 s)",
            file: file, line: line
        )
        let sheet = try XCTUnwrap(window.attachedSheet, "no failure sheet to read", file: file, line: line)

        let content = sheet.contentView ?? NSView()
        let buttonTitles = allButtons(in: content).map(\.title)
        XCTAssertEqual(
            buttonTitles.contains("Retry") && buttonTitles.contains(where: { $0.hasPrefix("Close") }), true,
            "fixture: the failure sheet must offer \"Retry\" and a \"Close...\" button; buttons found: \(buttonTitles)",
            file: file, line: line
        )

        return allLabelTexts(in: content).joined(separator: " | ")
    }

    /// strerror(3) text for an errno.
    private func reason(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    /// Fragments of Foundation's bridged placeholder for a Swift enum error:
    /// "The operation couldn't be completed. (Blackbird.PTY.Error error 0.)".
    private func opaqueCocoaFragments(in text: String) -> [String] {
        var hits: [String] = []
        for marker in ["be completed", "Blackbird.PTY", "Blackbird.TerminalSession", "SessionError"]
        where text.contains(marker) {
            hits.append(marker)
        }
        if text.range(of: #"\(Blackbird\.[A-Za-z_.]+ error \d+\.?\)"#, options: .regularExpression) != nil {
            hits.append("(Blackbird.<Type> error N.)")
        }
        return hits
    }

    // MARK: - Tests

    /// The Trigger's errno: fork refused with EAGAIN (process limit). The
    /// alert must say why, in the words every Unix tool uses.
    func testForkFailureAlertNamesTheErrnoReason() throws {
        let code: Int32 = EAGAIN
        let text = try presentedAlertText(for: PTY.Error.forkFailed(errno: code))
        let expected = reason(code)

        XCTAssertEqual(
            text.lowercased().contains(expected.lowercased()), true,
            "the \"Couldn't start shell\" alert for forkFailed(errno: \(code)) must state the errno reason "
                + "\"\(expected)\" so the user can tell a process limit from a broken shell; "
                + "the alert text was: «\(text)»"
        )
        let none: [String] = []
        XCTAssertEqual(
            opaqueCocoaFragments(in: text), none,
            "the alert must not show Foundation's opaque bridged-enum placeholder; the alert text was: «\(text)»"
        )
    }

    /// Different errnos (process limit vs out of memory) must read
    /// differently, each naming its own reason: today they render
    /// identically, which is the "cannot tell the causes apart" half of the
    /// impact.
    func testDifferentForkErrnosProduceDifferentAlertsEachNamingItsOwnReason() throws {
        let again: Int32 = EAGAIN
        let nomem: Int32 = ENOMEM
        let againText = try presentedAlertText(for: PTY.Error.forkFailed(errno: again))
        let nomemText = try presentedAlertText(for: PTY.Error.forkFailed(errno: nomem))

        XCTAssertEqual(
            againText.lowercased().contains(reason(again).lowercased()), true,
            "forkFailed(errno: EAGAIN=\(again)) alert must contain \"\(reason(again))\"; alert text was: «\(againText)»"
        )
        XCTAssertEqual(
            nomemText.lowercased().contains(reason(nomem).lowercased()), true,
            "forkFailed(errno: ENOMEM=\(nomem)) alert must contain \"\(reason(nomem))\"; alert text was: «\(nomemText)»"
        )
        XCTAssertNotEqual(
            againText, nomemText,
            "EAGAIN (process limit) and ENOMEM (out of memory) must not produce the same alert; both read: «\(againText)»"
        )
    }

    /// `SessionError.coreInitFailed` (the other error `startSession` can
    /// catch) carries no errno, but it must not surface as the bridged
    /// `(Blackbird.TerminalSession.SessionError error 0.)` placeholder either.
    func testCoreInitFailedAlertIsNotTheOpaqueCocoaPlaceholder() throws {
        let text = try presentedAlertText(for: TerminalSession.SessionError.coreInitFailed)
        let none: [String] = []
        XCTAssertEqual(
            opaqueCocoaFragments(in: text), none,
            "the \"Couldn't start shell\" alert for SessionError.coreInitFailed must be human-readable, "
                + "not Foundation's bridged-enum placeholder; the alert text was: «\(text)»"
        )
    }

    /// End to end with a REAL fork failure: squeeze the soft process limit,
    /// let `PTY.spawn` fail inside `forkpty`, and show the thrown error.
    func testRealProcessLimitForkFailureAlertNamesTheErrnoReason() throws {
        try XCTSkipIf(
            geteuid() == 0,
            "RLIMIT_NPROC is not enforced for uid 0; the fork cannot be made to fail"
        )

        // Warm-up: one UNsqueezed spawn, so every other once-per-process
        // latch on the spawn path (shell integration root, passwd lookups;
        // KittyTerminfo is already resolved in `setUp()`) resolves now, with
        // fork working, instead of caching a failure for the rest of the
        // xctest process while the limit is squeezed. Also proves the spawn
        // arguments are valid, so the squeezed throw is the fork's.
        do {
            let warm = try PTY.spawn(
                executable: "/usr/bin/true",
                arguments: [],
                envOverrides: [:],
                size: PTY.Size(cols: 20, rows: 5)
            )
            warm.terminate()
        } catch {
            XCTFail("rig precondition: an unsqueezed PTY.spawn(\"/usr/bin/true\") must succeed; it threw \(error)")
            return
        }

        // ---- Squeeze: nothing but a probe and one spawn runs in here. ----
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NPROC, &original), 0,
                       "rig precondition: getrlimit(RLIMIT_NPROC) must succeed (errno \(errno))")
        var squeezed = original
        squeezed.rlim_cur = 1
        let squeezeRC = setrlimit(RLIMIT_NPROC, &squeezed)
        let squeezeErrno = errno
        guard squeezeRC == 0 else {
            throw XCTSkip("cannot lower RLIMIT_NPROC in this environment (errno \(squeezeErrno))")
        }

        var probePID: pid_t = 0
        var probeRC: Int32 = -1
        var spawnError: Error?
        var unexpectedPTY: PTY?
        do {
            defer {
                // Darwin clamps the hard limit to maxprocperuid when the soft
                // limit is lowered (observed: 16000 -> 10666), and a
                // non-root process cannot raise the hard limit back, so
                // restore the soft limit under the CURRENT hard limit.
                var current = rlimit()
                _ = getrlimit(RLIMIT_NPROC, &current)
                var restore = original
                if restore.rlim_max > current.rlim_max { restore.rlim_max = current.rlim_max }
                _ = setrlimit(RLIMIT_NPROC, &restore)
            }
            let path = "/usr/bin/true"
            probeRC = path.withCString { (cpath: UnsafePointer<CChar>) -> Int32 in
                let argv: [UnsafeMutablePointer<CChar>?] = [UnsafeMutablePointer<CChar>(mutating: cpath), nil]
                let envp: [UnsafeMutablePointer<CChar>?] = [nil]
                return posix_spawn(&probePID, cpath, nil, nil, argv, envp)
            }
            do {
                unexpectedPTY = try PTY.spawn(
                    executable: path,
                    arguments: [],
                    envOverrides: [:],
                    size: PTY.Size(cols: 20, rows: 5)
                )
            } catch {
                spawnError = error
            }
        }
        // ---- Squeeze over. Clean up anything that wrongly succeeded. ----
        if probeRC == 0 {
            var status: Int32 = 0
            _ = waitpid(probePID, &status, 0)
        }
        unexpectedPTY?.terminate()

        var after = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NPROC, &after), 0, "getrlimit after restore must succeed")
        XCTAssertEqual(
            after.rlim_cur, original.rlim_cur,
            "rig: the soft RLIMIT_NPROC must be restored (was \(original.rlim_cur), now \(after.rlim_cur))"
        )

        // Rig preconditions: the squeeze really makes fork fail with EAGAIN.
        XCTAssertEqual(
            probeRC, EAGAIN,
            "rig precondition: with RLIMIT_NPROC soft=1 an independent posix_spawn must fail with EAGAIN "
                + "(\(EAGAIN)); got \(probeRC)"
        )
        let thrown = try XCTUnwrap(
            spawnError,
            "rig precondition: PTY.spawn must throw when the kernel refuses the fork (RLIMIT_NPROC soft=1)"
        )

        // ---- The behavior under test: what does the user read? ----
        let text = try presentedAlertText(for: thrown)
        let expected = reason(EAGAIN)
        XCTAssertEqual(
            text.lowercased().contains(expected.lowercased()), true,
            "PTY.spawn really failed with EAGAIN under a process limit; the \"Couldn't start shell\" alert "
                + "must state \"\(expected)\". Thrown error: \(String(describing: thrown)); "
                + "the alert text was: «\(text)»"
        )
        let none: [String] = []
        XCTAssertEqual(
            opaqueCocoaFragments(in: text), none,
            "the alert for a real fork failure must not show Foundation's opaque placeholder; "
                + "the alert text was: «\(text)»"
        )
    }
}
