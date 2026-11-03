import XCTest
import AppKit
@testable import Blackbird

/// Blind regression test for LSM-1: clearing a tab-title override, or a
/// program restoring the title (XTWINOPS pop), must put the shell's own name
/// back on the tab, not leave the previous title behind.
///
/// Observable contract (terminal / macOS conventions + the in-tree docs):
///
///   - A new tab is titled with its shell's name ("zsh", "bash", ...). That
///     is the title a user sees on the tab pill, in the window title bar and
///     in the Window menu until something else claims it. (The window
///     controller seeds `window.title` with the shell basename at session
///     start; the pill and the Window menu mirror `window.title`.)
///   - Rename Tab says "Leave empty to keep the current auto title" and the
///     Tab menu offers "Reset to Auto". Both promise that the user's rename
///     goes away and the tab returns to its automatic title. For a shell
///     that never sets a title (stock zsh/bash, no precmd titler), the
///     automatic title is the shell name.
///   - A full-screen program such as vim/nvim saves the title with
///     `CSI 22 ; 0 t`, sets its own with OSC 2, and on exit restores the
///     saved title with `CSI 23 ; 0 t`. xterm restores what was there before
///     the program ran. When the shell never set a title, what was there
///     before was the shell name, so after the program quits the tab must
///     read the shell name again and not "<file> - NVIM".
///
/// What is observed: `MainWindowController.window?.title`, the value the tab
/// pill, the title bar and the Window menu all show. Nothing here looks at
/// `SessionTitleState` internals, so any sound fix (a fallback in the view,
/// the session, or the controller) satisfies it.
///
/// Rig: a real `MainWindowController` built through `makeForTesting` around a
/// headless (no PTY, no shell) session. The window is never shown, closed or
/// ordered out, and the controller is parked for the process lifetime (the
/// CLAUDE.md tab-group rule). Bytes reach the session through
/// `feedBytesForTests`, exactly the parser path a real program's output
/// takes, and the title events hop to main as in production.
///
/// Cost pre-flight: one window + one Metal view per test (a few MB each,
/// retained, at most 6 in this file), a 2x2 core grid, a few hundred bytes of
/// fed escape sequences. Time: each wait is capped at 2 s and exits as soon
/// as its condition holds; the passing path is well under 100 ms per wait.
final class TabTitleRevertToShellNameBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    private struct Rig {
        let controller: MainWindowController
        let window: NSWindow
        let session: TerminalSession
        /// `window.title` right after the controller was built, before any
        /// rename or program touched the title: the shell-name seed.
        let shellName: String
    }

    /// Every controller built here lives for the whole process.
    private static var parkedControllers: [MainWindowController] = []

    /// Titles used by the tests; the shell-name seed must differ from all.
    private static let renameText = "My Renamed Tab"
    private static let nvimTitle = "notes.txt (~/proj) - NVIM"
    private static let shellSetTitle = "connor@host: ~/proj"

    private func makeRig() throws -> Rig {
        let stub = TerminalSession.makeHeadlessForTests()
        guard let controller = MainWindowController.makeForTesting(stubSession: stub),
              let window = controller.window,
              let session = controller.session
        else {
            throw XCTSkip("no Metal device (CI virtual display): makeForTesting returned nil")
        }
        Self.parkedControllers.append(controller)
        // Rig precondition: the controller is wired to the stub we hand-feed.
        XCTAssertTrue(session === stub,
                      "rig precondition: the controller must run the injected headless session")
        let shellName = window.title
        return Rig(controller: controller, window: window, session: session, shellName: shellName)
    }

    /// Spins the main runloop in 10 ms slices until `condition` holds or
    /// `seconds` elapse (title events and Combine sinks settle on main).
    private func pump(for seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        // One more slice so anything queued behind the condition has landed.
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private let waitSeconds: TimeInterval = 2.0

    /// Waits for `window.title == expected` and returns the title observed
    /// when the wait ended (equal to `expected` on success).
    @discardableResult
    private func waitForTitle(_ expected: String, in rig: Rig) -> String {
        pump(for: waitSeconds) { () -> Bool in
            return rig.window.title == expected
        }
        return rig.window.title
    }

    private func feed(_ text: String, to rig: Rig) {
        rig.session.feedBytesForTests(Data(text.utf8))
    }

    private let push = "\u{1B}[22;0t"
    private let pop = "\u{1B}[23;0t"
    private func osc2(_ title: String) -> String { "\u{1B}]2;\(title)\u{07}" }

    /// Common precondition block: the seed is a real shell name and cannot be
    /// mistaken for any title this file applies.
    private func assertSeed(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.shellName.isEmpty, false,
                       "rig precondition: a fresh tab must already carry a title (the shell name); got an empty window.title",
                       file: file, line: line)
        let applied: [String] = [Self.renameText, Self.nvimTitle, Self.shellSetTitle]
        XCTAssertEqual(applied.contains(rig.shellName), false,
                       "rig precondition: the seed title '\(rig.shellName)' collides with a title this test applies",
                       file: file, line: line)
        XCTAssertEqual(rig.session.titleState.displayTitle, nil,
                       "rig precondition: the stub shell never set a title and no rename is active, got displayTitle \(String(describing: rig.session.titleState.displayTitle))",
                       file: file, line: line)
    }

    // MARK: - Rename cleared -> shell name

    /// Inline pill rename (and the single-tab alert) commit an empty string
    /// to mean "clear the override, back to the auto title".
    func test_emptyRename_afterRename_revertsTabToShellName() throws {
        let rig = try makeRig()
        assertSeed(rig)

        rig.controller.applyInlineRename(Self.renameText)
        XCTAssertEqual(waitForTitle(Self.renameText, in: rig), Self.renameText,
                       "precondition: a rename must reach window.title (seed was '\(rig.shellName)')")

        rig.controller.applyInlineRename("")
        let after = waitForTitle(rig.shellName, in: rig)
        XCTAssertEqual(after, rig.shellName,
                       "an empty rename must return the tab to the shell name '\(rig.shellName)', but window.title is '\(after)'")
    }

    /// The Tab menu's "Reset to Auto".
    func test_resetToAuto_afterRename_revertsTabToShellName() throws {
        let rig = try makeRig()
        assertSeed(rig)

        rig.controller.applyInlineRename(Self.renameText)
        XCTAssertEqual(waitForTitle(Self.renameText, in: rig), Self.renameText,
                       "precondition: a rename must reach window.title (seed was '\(rig.shellName)')")

        rig.controller.resetActiveTabTitle(nil)
        let after = waitForTitle(rig.shellName, in: rig)
        XCTAssertEqual(after, rig.shellName,
                       "Reset to Auto must return the tab to the shell name '\(rig.shellName)', but window.title is '\(after)'")
    }

    /// The reset has to win even with a program title underneath: rename
    /// while a program title is showing, clear it, program title is back
    /// (this orders override-clear against a live OSC title). Guards against
    /// a "fix" that only handles the no-title case by forgetting titles.
    func test_resetToAuto_withProgramTitleUnderneath_showsProgramTitle() throws {
        let rig = try makeRig()
        assertSeed(rig)

        feed(osc2(Self.shellSetTitle), to: rig)
        XCTAssertEqual(waitForTitle(Self.shellSetTitle, in: rig), Self.shellSetTitle,
                       "precondition: an OSC 2 title must reach window.title (seed was '\(rig.shellName)')")

        rig.controller.applyInlineRename(Self.renameText)
        XCTAssertEqual(waitForTitle(Self.renameText, in: rig), Self.renameText,
                       "precondition: a rename must beat the OSC title")

        rig.controller.resetActiveTabTitle(nil)
        let after = waitForTitle(Self.shellSetTitle, in: rig)
        XCTAssertEqual(after, Self.shellSetTitle,
                       "clearing the rename must show the shell's own title '\(Self.shellSetTitle)', but window.title is '\(after)'")
    }

    // MARK: - Program restores the title (XTWINOPS pop) -> shell name

    /// vim/nvim shape, with the program running between the sequences: push,
    /// set its title, (it runs), pop on exit.
    func test_xtwinopsPop_afterProgramTitle_revertsTabToShellName() throws {
        let rig = try makeRig()
        assertSeed(rig)

        feed(push + osc2(Self.nvimTitle), to: rig)
        XCTAssertEqual(waitForTitle(Self.nvimTitle, in: rig), Self.nvimTitle,
                       "precondition: the program's OSC 2 title must reach window.title (seed was '\(rig.shellName)')")

        feed(pop, to: rig)
        let after = waitForTitle(rig.shellName, in: rig)
        XCTAssertEqual(after, rig.shellName,
                       "after the program pops the saved title the tab must read the shell name '\(rig.shellName)', but window.title is '\(after)'")
    }

    /// The exact headless sequence from the bug report, in one chunk:
    /// `ESC[22;0t ESC]2;X BEL ESC[23;0t`. Afterwards the title pipeline must
    /// still be alive (a later OSC 2 shows up), so a revert cannot be faked
    /// by a pipeline that dropped title events altogether.
    func test_xtwinopsPushOscPop_inOneChunk_revertsTabToShellName() throws {
        let rig = try makeRig()
        assertSeed(rig)

        feed(push + osc2("X") + pop, to: rig)
        // Give the three events time to land; the last one decides.
        pump(for: 0.3) { () -> Bool in return false }
        let after = waitForTitle(rig.shellName, in: rig)
        XCTAssertEqual(after, rig.shellName,
                       "push, OSC 2 'X', pop must leave the shell name '\(rig.shellName)' on the tab, but window.title is '\(after)'")

        feed(osc2(Self.nvimTitle), to: rig)
        XCTAssertEqual(waitForTitle(Self.nvimTitle, in: rig), Self.nvimTitle,
                       "control: a later OSC 2 must still retitle the tab after the pop (title pipeline alive)")
    }

    /// Control for the pop path: when the shell DID set a title before the
    /// program ran, the pop restores that one. Pins what "restore" means.
    func test_xtwinopsPop_restoresTitleTheShellSetBeforeTheProgram() throws {
        let rig = try makeRig()
        assertSeed(rig)

        feed(osc2(Self.shellSetTitle), to: rig)
        XCTAssertEqual(waitForTitle(Self.shellSetTitle, in: rig), Self.shellSetTitle,
                       "precondition: the shell's OSC 2 title must reach window.title")

        feed(push + osc2(Self.nvimTitle), to: rig)
        XCTAssertEqual(waitForTitle(Self.nvimTitle, in: rig), Self.nvimTitle,
                       "precondition: the program's OSC 2 title must replace the shell's")

        feed(pop, to: rig)
        let after = waitForTitle(Self.shellSetTitle, in: rig)
        XCTAssertEqual(after, Self.shellSetTitle,
                       "the pop must restore the shell's own title '\(Self.shellSetTitle)', but window.title is '\(after)'")
    }
}
