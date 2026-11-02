import XCTest
import AppKit
import Combine
@testable import Blackbird
@testable import BBCore

/// Blind-authored regression test for **CL-4: the core-failure sheet's
/// "Keep Open" button closes the window anyway**.
///
/// Written from the bug report / contract WITHOUT reading the bodies of
/// `SessionLifecycle`, `MainWindowController` or `TerminalSession` (CLAUDE.md
/// "Author new behavior tests blind"). Only declarations, doc comments, the
/// `makeForTesting(stubSession:)` seam and sibling tests (harness templates:
/// `MainWindowControllerLifetimeTests`, `UnseenAttentionBlindTests`) were
/// consulted.
///
/// ## The bug being pinned
///
/// When the Rust core panics (a caught panic surfaces as a `.fatal` core
/// event) the session tears itself down and the window presents a sheet,
/// "The terminal engine stopped", with two choices: "Close Tab" and
/// "Keep Open". "Keep Open" is the user saying "leave this tab on screen, I
/// want to read the scrollback / error context". Because the session's child
/// is always ended on a fatal, the shell-exit auto-close machinery fires as
/// soon as the sheet goes away, so the tab closes within ~50 ms of the click
/// and "Keep Open" is a dead choice.
///
/// ## Contract (terminal / macOS convention)
///
/// A button labelled "Keep Open" on a sheet must leave the window open. After
/// the user picks it, the window must NOT begin closing and must stay visible
/// (no Dock zombie, no vanished tab) for as long as the user leaves it alone.
/// Only the sheet's other choice ("Close Tab") or an explicit user close may
/// close it.
///
/// ## How the production sequence is reproduced
///
///   1. ONE real `MainWindowController` is built via
///      `makeForTesting(stubSession:)`, but with a REAL PTY-backed session
///      (`TerminalSession.start` running `/bin/cat`, a tiny 20x5 grid), not
///      the headless double: the headless double has no PTY, so it never
///      publishes `exitCode` and cannot show the bug. `/bin/cat` rather than
///      zsh keeps the host stable (CLAUDE.md: live zsh sessions destabilise
///      the xctest host).
///   2. The window is shown (the auto-close poll only acts on a visible or
///      miniaturized window).
///   3. A `.fatal` core event is delivered through the session's REAL
///      installed core-event handler (the same closure the FFI trampoline
///      calls), on the session's core queue, exactly as a caught Rust panic
///      would. The test-only Rust panic symbol is not linked into the Swift
///      build, and `BBTerm.dispatch` is private, so the handler is recovered
///      by reflection on `BBTerm`'s stored property named `handler`
///      (declared `private var handler: EventHandler?` in BBTerm.swift). The
///      test asserts the lookup succeeded and that the session reacted
///      (`coreFailureMessage` published), so a rename cannot make the test
///      pass vacuously.
///   4. The sheet is located on the window (`attachedSheet`), its "Keep Open"
///      button is found by title and clicked with `performClick` (a direct
///      programmatic click: no CGEvent / keystroke injection).
///   5. The runloop is pumped for a generous window (1.5 s, 30x the reported
///      ~50 ms close delay); the window must not close.
///
/// ## Non-vacuity
///
///   - the session really has a PTY and has not exited before the fatal,
///   - the fatal reached the session (`coreFailureMessage` equals the
///     injected message),
///   - the sheet really appeared with a "Keep Open" button,
///   - the window did NOT close while the sheet was still up (so a close
///     after the click is attributable to the dismissal),
///   - the sheet really went away after the click (the click landed),
///   - the observed `exitCode` is recorded in every failure message.
///
/// ## Gating
///
/// Like every other real-window lifecycle test (`MainWindowControllerLifetimeTests`,
/// `CloseConfirmBypassTests`, `JoinedTabCloseReleaseBlindTests`) this shows a
/// real window and, on the buggy build, watches it close, which is the
/// pattern that can destabilise a cumulative xctest host. It is therefore
/// opt-in and meant to run in isolation:
///
///     TEST_RUNNER_BB_RUN_WINDOW_LIFECYCLE_TESTS=1 scripts/test.sh \
///         -only-testing:BlackbirdTests/CoreFailureKeepOpenBlindTests
///
/// The gate is the FIRST statement of the test, so a default run builds no
/// window, no session, and closes nothing.
///
/// ## Safety / cost budget (CLAUDE.md test rules)
///
///   - Exactly ONE real `MainWindowController` and ONE real PTY child
///     (`/bin/cat`, idle). Window is standalone (never tab-merged).
///   - Grid 20x5 = 100 cells; scrollback is the Preferences default, lazily
///     allocated by the core. Well under a few MB.
///   - Time: <= ~5 s worst case (1.5 s observation window plus bounded
///     waits that exit early), typically ~2 s.
///   - Runloop pumping uses short slices; nothing blocks on a window-server
///     call that could hang.
final class CoreFailureKeepOpenBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
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

    /// The core-event handler `TerminalSession` installed on its `BBTerm`
    /// (the closure the FFI trampoline invokes), recovered by reflection.
    private func installedCoreEventHandler(of term: BBTerm) -> BBTerm.EventHandler? {
        for child in Mirror(reflecting: term).children where child.label == "handler" {
            return child.value as? BBTerm.EventHandler
        }
        return nil
    }

    // MARK: - Test

    func test_keepOpenOnCoreFailureSheet_leavesTheWindowOpen() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_WINDOW_LIFECYCLE_TESTS"] != "1",
            "set BB_RUN_WINDOW_LIFECYCLE_TESTS=1 to run real-window lifecycle tests in isolation"
        )

        // A REAL PTY-backed session (idle `cat`), so a fatal-triggered
        // terminate() has a live child to end and exitCode can publish.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 20, rows: 5)
        )
        XCTAssertTrue(session.pty != nil,
                      "precondition: the session must be backed by a real PTY")
        XCTAssertNil(session.exitCode,
                     "precondition: the child must be alive before the core fails")

        guard let controller = MainWindowController.makeForTesting(stubSession: session) else {
            session.terminate()
            throw XCTSkip("no Metal device (CI virtual display) — makeForTesting returned nil; skipping")
        }
        guard let window = controller.window else {
            session.terminate()
            throw XCTSkip("makeForTesting produced a controller without a window")
        }
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            controller.terminateSessions()
            if !controller.isClosing { window.close() }
        }
        XCTAssertTrue(controller.session === session,
                      "precondition: the controller must be running the real-PTY session")

        // Record the exit code the instant it publishes (the auto-close
        // trigger), purely so failure messages can print it.
        var observedExitCode: Int32?
        let exitSink = session.$exitCode.compactMap { $0 }.sink { observedExitCode = $0 }
        defer { exitSink.cancel() }

        controller.showWindow(nil)
        XCTAssertTrue(window.isVisible,
                      "precondition: the window must be on screen (auto-close only acts on a visible window)")

        // 1. Deliver a `.fatal` through the session's real core-event handler.
        let panicMessage = "CL-4 blind test: injected core panic"
        let handler = try XCTUnwrap(
            installedCoreEventHandler(of: session.bbterm),
            "TerminalSession did not install a core event handler on its BBTerm "
                + "(reflection lookup of BBTerm.handler failed), so a .fatal cannot be injected"
        )
        session.coreQueue.sync { handler(.fatal(panicMessage)) }

        // 2. The session must react (proves the injection reached the real
        //    fatal path) and the window must present the failure sheet.
        let sheetAppeared = pump(timeout: 3.0) { window.attachedSheet != nil }
        XCTAssertEqual(
            session.coreFailureMessage, panicMessage,
            "the injected .fatal must reach TerminalSession's fatal path and publish the message"
        )
        XCTAssertTrue(
            sheetAppeared,
            "a core failure must present a sheet on the window (attachedSheet stayed nil for 3 s)"
        )
        guard let sheet = window.attachedSheet else {
            return  // XCTAssertTrue above already recorded the failure
        }

        let buttons = allButtons(in: sheet.contentView ?? NSView())
        let titles = buttons.map(\.title)
        let keepOpen = try XCTUnwrap(
            buttons.first { $0.title == "Keep Open" },
            "the core-failure sheet must offer a \"Keep Open\" button; buttons found: \(titles)"
        )

        // 3. While the sheet is still up the window must stay open; this
        //    control makes any later close attributable to the dismissal.
        pump(timeout: 0.4) { controller.isClosing || !window.isVisible }
        XCTAssertEqual(
            controller.isClosing, false,
            "control: the window must not start closing while the core-failure sheet is still showing "
                + "(exitCode=\(String(describing: observedExitCode)))"
        )
        XCTAssertEqual(
            window.isVisible, true,
            "control: the window must stay visible while the core-failure sheet is still showing"
        )
        XCTAssertTrue(
            window.attachedSheet === sheet,
            "control: the sheet must still be attached before the click"
        )

        // 4. The user picks "Keep Open".
        let clickedAt = Date()
        keepOpen.performClick(nil)
        let sheetDismissed = pump(timeout: 2.0) { window.attachedSheet == nil }
        XCTAssertTrue(
            sheetDismissed,
            "clicking \"Keep Open\" must dismiss the sheet (it was still attached 2 s later; "
                + "the click did not land, so the assertions below would be vacuous)"
        )

        // 5. Observe for 1.5 s (~30x the reported ~50 ms auto-close delay).
        //    Exit early the moment the window starts to go away.
        var closedAfter: TimeInterval?
        pump(timeout: 1.5) {
            if controller.isClosing || !window.isVisible {
                closedAfter = Date().timeIntervalSince(clickedAt)
                return true
            }
            return false
        }

        let closedDescription = closedAfter.map { String(format: "%.0f ms", $0 * 1000) } ?? "never"
        XCTAssertEqual(
            controller.isClosing, false,
            "\"Keep Open\" must leave the window open, but it began closing "
                + "(closed after \(closedDescription) from the click; "
                + "exitCode=\(String(describing: observedExitCode)), "
                + "window.isVisible=\(window.isVisible))"
        )
        XCTAssertEqual(
            window.isVisible, true,
            "\"Keep Open\" must leave the window on screen, but it is no longer visible "
                + "(closed after \(closedDescription) from the click; "
                + "exitCode=\(String(describing: observedExitCode)))"
        )
    }
}
