import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for "menu-2": the Edit / Find / View / Window menu
/// items that target `TerminalView` must be validated by AppKit against the
/// view's live state (selection, find matches, find options, prompt marks,
/// session), exactly like every other menu target in the app.
///
/// Contract under test (macOS menu conventions; Terminal.app / iTerm2):
///   - Edit > Copy is DISABLED when the view has no selection (so ⌘C falls
///     through instead of being swallowed by the menu), ENABLED with one.
///   - Find Next / Find Previous are DISABLED while the find controller has
///     no matches, ENABLED once it has some.
///   - Previous / Next Prompt are DISABLED until the session has recorded
///     OSC 133 prompt marks (otherwise ⌘⇧↑ / ⌘⇧↓ just beep), ENABLED after.
///   - "Find: Case Sensitive" and "Find: Regular Expression" show a
///     checkmark (`state == .on`) iff the corresponding find option is on,
///     and clear it (`.off`) when it is switched back off.
///   - Bigger / Smaller / Actual Size are DISABLED on a view that has no
///     session to act on, ENABLED once a session is attached.
///
/// **How validation is driven.** Through AppKit itself, not by calling any
/// `validateMenuItem` method directly: a real `NSMenu` (auto-enabling) holds
/// an `NSMenuItem` whose `target` is the view and whose `action` is the
/// production selector; `NSMenu.update()` is what the menu bar runs before
/// every display, and what decides `isEnabled` / `state`. If the view's
/// validation is not visible to AppKit (the reported bug) every item stays at
/// its seeded value (`isEnabled == true`, `state` unchanged), so the
/// disabled / checkmark assertions fail with the measured values printed.
/// The "enabled" halves pass both before and after the fix; they exist so a
/// trivially wrong fix (disable everything) cannot satisfy the suite.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 40 x 6 `BBTerm` (240 cells, `scrollback: 16`) per rig, one
///    640 x 240 headless `TerminalView` per rig; never added to a window,
///    never drawn; no `NSWindow`, no `MainWindowController`, no PTY, no
///    runloop pumping, no timers, no pasteboard access.
///  - Wall time dominated by `MTLCreateSystemDefaultDevice()`; each test
///    well under 1 s.
final class TerminalViewMenuValidationBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    /// Held together so nothing is deallocated mid-test.
    /// `TerminalView.session` is `weak`, so the strong `session` here is
    /// load-bearing.
    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let snapshot: BBSnapshot
    }

    private func makeView(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TerminalView {
        let device = try requireMetalDevice(file: file, line: line)
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            device: device
        )
    }

    /// A view with a live snapshot and an attached headless session, no
    /// selection, no find matches, no prompt marks.
    private func makeRig(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let view = try makeView(file: file, line: line)
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
            "BBTerm init failed", file: file, line: line
        )
        term.input("hello world\r\n")
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil", file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        return Rig(view: view, term: term, session: session, snapshot: snapshot)
    }

    // MARK: - AppKit-driven validation

    /// What AppKit decided for one menu item after a real `NSMenu.update()`.
    private struct Validated {
        let isEnabled: Bool
        let state: NSControl.StateValue
    }

    /// Runs the menu-bar's own validation pass for a single item targeting
    /// `view`. `seedState` is written to the item first so a view that never
    /// gets validated leaves a visibly stale value behind.
    private func validate(
        _ action: Selector,
        on view: TerminalView,
        seedState: NSControl.StateValue = .off
    ) -> Validated {
        let item = NSMenuItem(title: "probe", action: action, keyEquivalent: "")
        item.target = view
        item.state = seedState
        item.isEnabled = true
        let menu = NSMenu(title: "probe")
        menu.autoenablesItems = true
        menu.addItem(item)
        menu.update()
        return Validated(isEnabled: item.isEnabled, state: item.state)
    }

    private func describe(_ v: Validated) -> String {
        "isEnabled=\(v.isEnabled) state=\(v.state.rawValue)"
    }

    // MARK: - Tests

    /// Edit > Copy with no selection must be disabled, with a selection
    /// enabled. Today the menu swallows ⌘C with nothing to copy.
    func test_copy_isDisabledWithoutSelection_andEnabledWithOne() throws {
        let rig = try makeRig()
        XCTAssertNil(rig.view.selection, "precondition: fresh view has no selection")

        let noSel = validate(#selector(TerminalView.copy(_:)), on: rig.view)
        XCTAssertEqual(noSel.isEnabled, false,
                       "Copy must be disabled with no selection so Cmd-C falls through; AppKit left it at \(describe(noSel))")

        rig.view.selectAll(nil)
        XCTAssertEqual(rig.view.selection != nil, true,
                       "precondition: selectAll on a view with a snapshot must create a selection")

        let withSel = validate(#selector(TerminalView.copy(_:)), on: rig.view)
        XCTAssertEqual(withSel.isEnabled, true,
                       "Copy must be enabled once there is a selection; AppKit left it at \(describe(withSel))")
    }

    /// Find Next / Find Previous track whether the find controller has any
    /// matches.
    func test_findNextAndPrevious_disabledWithoutMatches_enabledWithMatches() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.view.findController.findMatches.count, 0,
                       "precondition: no find matches on a fresh view")

        let nextNone = validate(#selector(TerminalView.performFindNextAction(_:)), on: rig.view)
        let prevNone = validate(#selector(TerminalView.performFindPreviousAction(_:)), on: rig.view)
        XCTAssertEqual(nextNone.isEnabled, false,
                       "Find Next must be disabled with zero matches; AppKit left it at \(describe(nextNone))")
        XCTAssertEqual(prevNone.isEnabled, false,
                       "Find Previous must be disabled with zero matches; AppKit left it at \(describe(prevNone))")

        rig.view.findController.findMatches = [(line: 0, startCol: 0, endCol: 4)]
        XCTAssertEqual(rig.view.findController.findMatches.count, 1,
                       "precondition: injected find match must be retained")

        let nextSome = validate(#selector(TerminalView.performFindNextAction(_:)), on: rig.view)
        let prevSome = validate(#selector(TerminalView.performFindPreviousAction(_:)), on: rig.view)
        XCTAssertEqual(nextSome.isEnabled, true,
                       "Find Next must be enabled with one match; AppKit left it at \(describe(nextSome))")
        XCTAssertEqual(prevSome.isEnabled, true,
                       "Find Previous must be enabled with one match; AppKit left it at \(describe(prevSome))")
    }

    // MARK: - Find Next / Previous while a search is active

    private func pumpMain(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    /// Headless view + headless session (real BBTerm, no PTY, no window) whose
    /// 40 x 6 grid shows "alpha one / beta / alpha two". 240 cells, a few
    /// short lines, well under 1 s.
    private func makeFedRig() throws -> (view: TerminalView, session: TerminalSession) {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(), "Metal device required")
        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 40, rows: 6))
        view.session = session
        session.feedBytesForTests(Data("alpha one\r\nbeta\r\nalpha two\r\n".utf8))
        let landed = pumpMain(until: 3.0) {
            guard let snap = view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix("alpha two") }
        }
        XCTAssertTrue(landed, "fixture: the fed rows must reach the view's snapshot within 3 s")
        return (view, session)
    }

    /// A regex rescan empties the match cache synchronously and republishes
    /// from a background scan, and streamed output starts one every 100 ms.
    /// `advanceFind` exists to take a Cmd-G pressed in that gap (it defers it
    /// and resumes when the scan publishes), so the menu must NOT disable the
    /// item there: a disabled item stops the key before `advanceFind` runs and
    /// the keystroke is lost.
    func test_findNextAndPrevious_enabledWhileRegexRescanInFlight_andTheKeyIsDeferredNotLost() throws {
        let (view, session) = try makeFedRig()
        let fc = view.findController

        view.toggleFindRegex(nil)
        let bar = try XCTUnwrap(fc.findBar, "precondition: toggling regex installs the find bar")
        XCTAssertTrue(bar.options.regex, "precondition: regex mode is on")
        bar.setQuery("alpha")
        // The publish hops through DispatchQueue.main.async; nothing has pumped
        // the runloop since the scan started, so it is still in flight.
        XCTAssertTrue(fc.findMatches.isEmpty && fc.findMatchesSeq == nil,
                      "precondition: the regex scan is in flight, nothing published yet")

        let next = validate(#selector(TerminalView.performFindNextAction(_:)), on: view)
        let prev = validate(#selector(TerminalView.performFindPreviousAction(_:)), on: view)
        XCTAssertEqual(next.isEnabled, true,
                       "Find Next must stay enabled while a regex rescan is in flight; AppKit left it at \(describe(next))")
        XCTAssertEqual(prev.isEnabled, true,
                       "Find Previous must stay enabled while a regex rescan is in flight; AppKit left it at \(describe(prev))")

        // What the enabled item then does: the Cmd-G is deferred, not dropped.
        view.performFindNextAction(nil)
        XCTAssertEqual(fc.pendingRegexAdvance?.direction, .forward,
                       "a Cmd-G during an in-flight regex rescan must be remembered for the scan's publish")
        let published = pumpMain(until: 3.0) { fc.findMatchesSeq != nil }
        XCTAssertTrue(published, "the regex scan must publish within 3 s")
        XCTAssertEqual(fc.findMatches.map { $0.line }, [0, 2], "scan finds both 'alpha' rows")
        XCTAssertNil(fc.pendingRegexAdvance, "the publish must consume the deferred Cmd-G")
        _ = pumpMain(until: 0.4) { false }   // let the 250 ms scan-deadline timer drain
        withExtendedLifetime(session) {}
    }

    /// Substring mode: a live query whose cached matches are empty (output
    /// that contains it has just arrived, the 100 ms coalesced refresh has not
    /// run) is still an active search, and `advanceFind` re-scans
    /// synchronously. Closing the bar ends the search and disables the items
    /// again.
    func test_findNextAndPrevious_enabledForLiveQueryWithNoCachedMatches_disabledAfterBarCloses() throws {
        let (view, session) = try makeFedRig()
        let fc = view.findController

        fc.installFindBar()
        let bar = try XCTUnwrap(fc.findBar, "precondition: find bar installed")
        XCTAssertFalse(bar.options.regex, "precondition: substring mode")
        // Simulate the stale-empty cache: a live query, no cached matches.
        fc.findQuery = "alpha"
        fc.findMatches.removeAll()
        fc.findMatchesSeq = nil

        let next = validate(#selector(TerminalView.performFindNextAction(_:)), on: view)
        let prev = validate(#selector(TerminalView.performFindPreviousAction(_:)), on: view)
        XCTAssertEqual(next.isEnabled, true,
                       "Find Next must be enabled for a live query even with no cached matches; AppKit left it at \(describe(next))")
        XCTAssertEqual(prev.isEnabled, true,
                       "Find Previous must be enabled for a live query even with no cached matches; AppKit left it at \(describe(prev))")

        view.findBarDidClose(bar)
        XCTAssertNil(fc.findBar, "precondition: closing the bar drops it")
        let nextClosed = validate(#selector(TerminalView.performFindNextAction(_:)), on: view)
        let prevClosed = validate(#selector(TerminalView.performFindPreviousAction(_:)), on: view)
        XCTAssertEqual(nextClosed.isEnabled, false,
                       "Find Next must be disabled once the search is closed; AppKit left it at \(describe(nextClosed))")
        XCTAssertEqual(prevClosed.isEnabled, false,
                       "Find Previous must be disabled once the search is closed; AppKit left it at \(describe(prevClosed))")
        withExtendedLifetime(session) {}
    }

    /// Previous / Next Prompt are only meaningful once OSC 133 marks exist;
    /// before that the shortcuts just beep.
    func test_promptJumps_disabledWithoutMarks_enabledWithMarks() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.session.promptMarks.count, 0,
                       "precondition: headless session starts with no prompt marks")

        let prevNone = validate(#selector(TerminalView.jumpToPreviousPrompt(_:)), on: rig.view)
        let nextNone = validate(#selector(TerminalView.jumpToNextPrompt(_:)), on: rig.view)
        XCTAssertEqual(prevNone.isEnabled, false,
                       "Previous Prompt must be disabled with no OSC 133 marks; AppKit left it at \(describe(prevNone))")
        XCTAssertEqual(nextNone.isEnabled, false,
                       "Next Prompt must be disabled with no OSC 133 marks; AppKit left it at \(describe(nextNone))")

        rig.session._testAppendMark(.init(linesScrolled: 0, gridRow: 0))
        rig.session._testAppendMark(.init(linesScrolled: 5, gridRow: 2))
        XCTAssertEqual(rig.session.promptMarks.count, 2,
                       "precondition: two prompt marks recorded")

        let prevSome = validate(#selector(TerminalView.jumpToPreviousPrompt(_:)), on: rig.view)
        let nextSome = validate(#selector(TerminalView.jumpToNextPrompt(_:)), on: rig.view)
        XCTAssertEqual(prevSome.isEnabled, true,
                       "Previous Prompt must be enabled once marks exist; AppKit left it at \(describe(prevSome))")
        XCTAssertEqual(nextSome.isEnabled, true,
                       "Next Prompt must be enabled once marks exist; AppKit left it at \(describe(nextSome))")
    }

    /// Edit > Find > "Find: Case Sensitive" shows a checkmark iff the mode is
    /// on. The seed is the OPPOSITE of the expected state each time, so a
    /// validation pass that never runs is caught.
    func test_findCaseSensitive_showsCheckmarkWhenOn_andClearsWhenOff() throws {
        let rig = try makeRig()
        let action = #selector(TerminalView.toggleFindCaseSensitive(_:))

        rig.view.toggleFindCaseSensitive(nil)
        XCTAssertEqual(rig.view.findController.findBar?.options.caseSensitive, true,
                       "precondition: toggling Case Sensitive once must turn the find option on")
        let on = validate(action, on: rig.view, seedState: .off)
        XCTAssertEqual(on.state, .on,
                       "Case Sensitive is on, so its menu item must show a checkmark; AppKit left it at \(describe(on))")

        rig.view.toggleFindCaseSensitive(nil)
        XCTAssertEqual(rig.view.findController.findBar?.options.caseSensitive, false,
                       "precondition: toggling Case Sensitive again must turn the find option off")
        let off = validate(action, on: rig.view, seedState: .on)
        XCTAssertEqual(off.state, .off,
                       "Case Sensitive is off, so its menu item must drop the checkmark; AppKit left it at \(describe(off))")
    }

    /// Edit > Find > "Find: Regular Expression" shows a checkmark iff regex
    /// mode is on.
    func test_findRegex_showsCheckmarkWhenOn_andClearsWhenOff() throws {
        let rig = try makeRig()
        let action = #selector(TerminalView.toggleFindRegex(_:))

        rig.view.toggleFindRegex(nil)
        XCTAssertEqual(rig.view.findController.findBar?.options.regex, true,
                       "precondition: toggling Regular Expression once must turn the find option on")
        let on = validate(action, on: rig.view, seedState: .off)
        XCTAssertEqual(on.state, .on,
                       "Regular Expression is on, so its menu item must show a checkmark; AppKit left it at \(describe(on))")

        rig.view.toggleFindRegex(nil)
        XCTAssertEqual(rig.view.findController.findBar?.options.regex, false,
                       "precondition: toggling Regular Expression again must turn the find option off")
        let off = validate(action, on: rig.view, seedState: .on)
        XCTAssertEqual(off.state, .off,
                       "Regular Expression is off, so its menu item must drop the checkmark; AppKit left it at \(describe(off))")
    }

    /// Bigger / Smaller / Actual Size act on the view's session-backed
    /// terminal; with no session attached they are disabled.
    func test_fontSizeItems_disabledWithoutSession_enabledWithSession() throws {
        let bare = try makeView()
        XCTAssertNil(bare.session, "precondition: a bare view has no session")

        let actions: [(String, Selector)] = [
            ("Bigger", #selector(TerminalView.increaseFontSize(_:))),
            ("Smaller", #selector(TerminalView.decreaseFontSize(_:))),
            ("Actual Size", #selector(TerminalView.resetFontSize(_:))),
        ]
        for (name, action) in actions {
            let v = validate(action, on: bare)
            XCTAssertEqual(v.isEnabled, false,
                           "\(name) must be disabled on a view with no session; AppKit left it at \(describe(v))")
        }

        let rig = try makeRig()
        for (name, action) in actions {
            let v = validate(action, on: rig.view)
            XCTAssertEqual(v.isEnabled, true,
                           "\(name) must be enabled once a session is attached; AppKit left it at \(describe(v))")
        }
    }
}
