import XCTest
import AppKit
@testable import Blackbird

/// Blind regression tests for wt2-rename-unchanged-commit: opening the inline
/// rename editor and leaving it without editing must NOT turn the tab's
/// current automatic title into a permanent user override. The tab has to
/// keep following its shell (OSC 0/2 titles, cwd titles, program titles).
///
/// Written WITHOUT reading the bodies of `TabStripView` / `TabRenameController`
/// (commit + begin paths), `TitlebarTabBarViewController`,
/// `MainWindowController.beginRenameActiveTab / applyInlineRename /
/// refreshTabBar` or `SessionTitleState` (CLAUDE.md "Author new behavior tests
/// blind"). Only declarations, doc comments and sibling test files
/// (`PillRenameBackgroundTabBlindTests`, `TabTitleRevertToShellNameBlindTests`,
/// `TabRenameClickSequenceTests`, `InlineRenameTests`) were consulted.
///
/// ## Observable contract
///
/// Rename Tab says "Leave empty to keep the current auto title" and the Tab
/// menu offers "Reset to Auto": the tab title is automatic until the user
/// deliberately TYPES a name. Safari / Chrome / iTerm2 / Terminal.app all work
/// this way: double-clicking a tab title (or choosing Rename) and pressing
/// Return, or clicking away, without changing the text is a no-op. The
/// editor opens pre-filled with the tab's current title, so "committed
/// unchanged" is indistinguishable from "committed the current title" unless
/// the implementation remembers that nothing was edited.
///
/// So, for every way into the editor (double-click on the selected pill,
/// Ctrl-Cmd-R, the pill menu's "Rename...") and every way out that is not
/// Escape (Return, a tab opening, a sibling tab leaving, focus moving to the
/// terminal):
///
///   1. the tab's `titleOverride` stays unset, and
///   2. the tab keeps following the shell: a later OSC 2 title from the shell
///      shows up in `window.title` (what the pill, the title bar and the
///      Window menu display).
///
/// Both seeds matter: the tab showing an OSC title the shell set, and the
/// tab showing the default shell name ("zsh") because the shell never set one.
///
/// Controls (pass today, must keep passing): a name the user actually TYPES
/// still becomes the override and still beats the shell; Escape leaves the tab
/// automatic. They prove the fix is not "never apply a rename".
///
/// ## Rig
///
/// A real `MainWindowController` (via `makeForTesting`, headless session: no
/// PTY, no shell) whose window is merged with 1-2 plain stub windows through
/// `addTabbedWindow`, so the group has 2-3 tabs and Rename uses the inline
/// pill editor. The controller's window is the SELECTED tab and its own
/// production `TabStripView` is the strip under test; its commit callback is
/// the production wiring to `applyInlineRename`. Bytes reach the session
/// through `feedBytesForTests` (the parser path a real program takes).
/// Nothing is shown, closed or ordered out; everything is parked for the
/// process lifetime (the `TabMoverTests` template). The strip is driven
/// through its DEBUG hooks and synthesized `NSEvent`s handed straight to
/// `mouseDown(with:)`; no keystroke or CGEvent injection.
///
/// ## Cost pre-flight
///
/// One rig per test: one Metal-backed terminal view (a few MB), 2-3 never
/// shown windows (~40 KB each), a 600 x 28 pt strip; at most 9 rigs in this
/// file, all parked (well under 100 MB total). Each wait is capped at 2 s and
/// returns as soon as its condition holds.
@MainActor
final class RenameUneditedCommitKeepsAutoTitleBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        // The click mark is process-wide state; start from a clean one.
        TabStripView.resetClickSequenceForTesting()
    }

    override func tearDown() {
        TabStripView.resetClickSequenceForTesting()
        super.tearDown()
    }

    // MARK: - Constants

    private static let baseFrame = NSRect(x: 140, y: 140, width: 600, height: 300)
    private static let renameTitle = "Rename\u{2026}"
    /// What the shell titles the tab before the user opens the editor.
    private static let shellTitle = "connor@host: ~/proj"
    /// What the shell titles the tab AFTER the editor was dismissed.
    private static let followUpTitle = "connor@host: ~/other-dir"
    private static let typedName = "Build Logs"

    // MARK: - Rig

    private struct Rig {
        let controller: MainWindowController
        let window: NSWindow
        let session: TerminalSession
        let strip: TabStripView
        let group: NSWindowTabGroup
        let stubs: [NSWindow]
        /// `window.title` right after the controller was built: the default
        /// shell name seed ("zsh").
        let shellName: String
    }

    private static var parkedControllers: [MainWindowController] = []
    private static var parkedStubs: [NSWindow] = []
    private static var stubCounter = 0

    private func makeStub(tabbingIdentifier: String) -> NSWindow {
        Self.stubCounter += 1
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.title = "unedited-rename-stub-\(Self.stubCounter)"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        w.tabbingIdentifier = tabbingIdentifier
        Self.parkedStubs.append(w)
        return w
    }

    /// Spins the main runloop in 10 ms slices until `condition` holds or
    /// `seconds` elapse (title events and Combine sinks settle on main).
    private func pump(for seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    private func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private let waitSeconds: TimeInterval = 2.0

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

    private func osc2(_ title: String) -> String { "\u{1B}]2;\(title)\u{07}" }

    /// Builds a rig whose group has `1 + stubCount` tabs with the
    /// controller's window selected. Skips (does not fail) only when the host
    /// cannot build a Metal-backed controller or refuses the headless merge.
    private func makeRig(stubCount: Int = 2,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ), let window = controller.window, let session = controller.session else {
            throw XCTSkip("no Metal device (CI virtual display): makeForTesting returned nil")
        }
        Self.parkedControllers.append(controller)
        let shellName = window.title

        var stubs: [NSWindow] = []
        window.setFrame(Self.baseFrame, display: false)
        for _ in 0..<stubCount {
            let stub = makeStub(tabbingIdentifier: window.tabbingIdentifier)
            window.addTabbedWindow(stub, ordered: .above)
            stubs.append(stub)
        }
        guard let group = window.tabGroup, group.windows.count == stubCount + 1 else {
            throw XCTSkip("xctest host refused the headless addTabbedWindow merge "
                + "(group windows: \(window.tabGroup?.windows.count ?? 0), expected \(stubCount + 1))")
        }
        pump(0.3)
        group.selectedWindow = window
        pump(0.15)
        controller.refreshTabBar()
        pump(0.15)

        guard let strip = controller.titlebarTabBar?.view as? TabStripView else {
            throw XCTSkip("controller has no TabStripView in titlebarTabBar")
        }
        let ordered = TabOrderCoordinator.shared.orderedTabs(for: group)
        // Rig preconditions (asserted, not assumed).
        XCTAssertEqual(ordered.count, stubCount + 1,
            "PRECONDITION: the ordered tab list must have \(stubCount + 1) tabs, got \(ordered.count)",
            file: file, line: line)
        XCTAssertTrue(group.selectedWindow === window,
            "PRECONDITION: the controller's tab must be the selected one, selected is '\(group.selectedWindow?.title ?? "nil")'",
            file: file, line: line)
        XCTAssertEqual(strip.pillCountForTesting, ordered.count,
            "PRECONDITION: the controller's strip must paint one pill per tab (\(ordered.count)), got \(strip.pillCountForTesting)",
            file: file, line: line)
        XCTAssertEqual(strip.isEditingForTesting, false,
            "PRECONDITION: no rename editor may be open before the scenario starts",
            file: file, line: line)
        XCTAssertEqual(session.titleState.titleOverride, nil,
            "PRECONDITION: a fresh tab has no title override, got \(String(describing: session.titleState.titleOverride))",
            file: file, line: line)
        XCTAssertEqual(shellName.isEmpty, false,
            "PRECONDITION: a fresh tab carries the shell name as its title, got an empty window.title",
            file: file, line: line)
        let applied: [String] = [Self.shellTitle, Self.followUpTitle, Self.typedName]
        XCTAssertEqual(applied.contains(shellName), false,
            "PRECONDITION: the default title '\(shellName)' collides with a title this test applies",
            file: file, line: line)
        return Rig(controller: controller, window: window, session: session, strip: strip,
                   group: group, stubs: stubs, shellName: shellName)
    }

    /// Has the shell set `shellTitle` and waits until the tab shows it.
    private func seedShellTitle(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        feed(osc2(Self.shellTitle), to: rig)
        let shown = waitForTitle(Self.shellTitle, in: rig)
        XCTAssertEqual(shown, Self.shellTitle,
            "PRECONDITION: the shell's OSC 2 title must reach window.title (seed was '\(rig.shellName)')",
            file: file, line: line)
        XCTAssertEqual(rig.session.titleState.titleOverride, nil,
            "PRECONDITION: an OSC title is not an override",
            file: file, line: line)
    }

    /// The tab still shows the default shell name: the shell never set a title.
    private func assertDefaultShellNameShowing(_ rig: Rig,
                                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rig.window.title, rig.shellName,
            "PRECONDITION: the tab must still show the default shell name '\(rig.shellName)', but window.title is '\(rig.window.title)'",
            file: file, line: line)
        XCTAssertEqual(rig.session.titleState.displayTitle, nil,
            "PRECONDITION: the stub shell never set a title and no rename is active, got displayTitle \(String(describing: rig.session.titleState.displayTitle))",
            file: file, line: line)
    }

    // MARK: - Entering the editor

    private enum Opener: String {
        case ctrlCmdR = "Ctrl-Cmd-R (beginRenameActiveTab)"
        case contextMenu = "the pill context menu's Rename..."
        case doubleClick = "double-clicking the selected pill"
    }

    private func selectedPillIndex(_ rig: Rig) -> Int? {
        TabOrderCoordinator.shared.orderedTabs(for: rig.group)
            .firstIndex(where: { (w: NSWindow) -> Bool in w === rig.window })
    }

    private func rightClickEvent(at p: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0))
    }

    private func leftMouseEvent(_ type: NSEvent.EventType, at p: NSPoint,
                                clickCount: Int, timestamp: TimeInterval) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: [], timestamp: timestamp,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1.0))
    }

    /// Opens the inline editor on the selected tab's pill the given way and
    /// asserts that it really is open (the precondition of every scenario).
    private func openEditor(_ opener: Opener, rig: Rig,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        // Ctrl-Cmd-R falls back to a MODAL alert in a single-tab window; never
        // risk that in a test.
        XCTAssertGreaterThanOrEqual(rig.group.windows.count, 2,
            "PRECONDITION: the group needs at least 2 tabs, got \(rig.group.windows.count)",
            file: file, line: line)
        let index = try XCTUnwrap(selectedPillIndex(rig),
            "PRECONDITION: the controller's window must be in the ordered tab list",
            file: file, line: line)
        let frames = rig.strip.pillFramesForTesting
        guard index < frames.count else {
            XCTFail("PRECONDITION: strip painted \(frames.count) pills, need index \(index)",
                    file: file, line: line)
            return
        }
        let local = NSPoint(x: frames[index].midX, y: frames[index].midY)
        let point = rig.strip.convert(local, to: nil)

        switch opener {
        case .ctrlCmdR:
            rig.controller.beginRenameActiveTab()
        case .contextMenu:
            let menu = try XCTUnwrap(rig.strip.menu(for: try rightClickEvent(at: point)),
                "PRECONDITION: right-clicking a pill must produce a context menu",
                file: file, line: line)
            let item = try XCTUnwrap(
                menu.items.first(where: { (mi: NSMenuItem) -> Bool in mi.title == Self.renameTitle }),
                "PRECONDITION: the pill menu must offer '\(Self.renameTitle)' (items: \(menu.items.map { $0.title }))",
                file: file, line: line)
            let action = try XCTUnwrap(item.action,
                "PRECONDITION: '\(Self.renameTitle)' must have an action", file: file, line: line)
            let delivered = NSApp.sendAction(action, to: item.target, from: item)
            XCTAssertTrue(delivered,
                "PRECONDITION: the '\(Self.renameTitle)' action must be delivered", file: file, line: line)
        case .doubleClick:
            // The gesture AppKit delivers for a double-click: down(1), up(1),
            // down(2) inside the system double-click interval.
            let gap = NSEvent.doubleClickInterval / 4
            rig.strip.mouseDown(with: try leftMouseEvent(.leftMouseDown, at: point, clickCount: 1, timestamp: 0))
            rig.strip.mouseUp(with: try leftMouseEvent(.leftMouseUp, at: point, clickCount: 1, timestamp: 0))
            rig.strip.mouseDown(with: try leftMouseEvent(.leftMouseDown, at: point, clickCount: 2, timestamp: gap))
        }
        pump(0.3)

        XCTAssertEqual(rig.strip.isEditingForTesting, true,
            "PRECONDITION: \(opener.rawValue) must open the inline rename editor on the selected tab "
                + "(window.title '\(rig.window.title)', \(rig.group.windows.count) tabs)",
            file: file, line: line)
    }

    // MARK: - The contract

    /// Asserts the tab is still automatic and still follows the shell
    /// afterwards. A still-open editor is cancelled first (a fix may
    /// legitimately keep the editor across a tab-list change; what is under
    /// test is the pinned title, not the editor's lifetime).
    private func assertTabStillFollowsShell(_ rig: Rig, afterAction action: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let titleRightAfter = rig.window.title
        let overrideRightAfter = rig.session.titleState.titleOverride
        if rig.strip.isEditingForTesting {
            rig.strip.cancelEditForTesting()
            pump(0.1)
        }
        XCTAssertEqual(overrideRightAfter, nil,
            "\(action) without typing pinned the tab's title as a permanent override "
                + "'\(overrideRightAfter ?? "nil")' (window.title was '\(titleRightAfter)')",
            file: file, line: line)

        // The tab must still follow the shell: a new OSC title shows up.
        feed(osc2(Self.followUpTitle), to: rig)
        let shown = waitForTitle(Self.followUpTitle, in: rig)
        XCTAssertEqual(shown, Self.followUpTitle,
            "after \(action) without typing, the shell's next OSC 2 title '\(Self.followUpTitle)' must show on the tab, "
                + "but window.title is '\(shown)' (override '\(rig.session.titleState.titleOverride ?? "nil")')",
            file: file, line: line)
    }

    // MARK: - Opened, then Return without typing (OSC title showing)

    func test_ctrlCmdR_thenReturnWithoutTyping_oscTitle_keepsFollowingShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.ctrlCmdR, rig: rig)
        rig.strip.commitEditForTesting()
        pump(0.2)

        assertTabStillFollowsShell(rig, afterAction: "Ctrl-Cmd-R then Return")
    }

    func test_contextMenuRename_thenReturnWithoutTyping_oscTitle_keepsFollowingShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.contextMenu, rig: rig)
        rig.strip.commitEditForTesting()
        pump(0.2)

        assertTabStillFollowsShell(rig, afterAction: "pill menu Rename... then Return")
    }

    func test_doubleClickSelectedPill_thenReturnWithoutTyping_oscTitle_keepsFollowingShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.doubleClick, rig: rig)
        rig.strip.commitEditForTesting()
        pump(0.2)

        assertTabStillFollowsShell(rig, afterAction: "double-clicking the selected pill then Return")
    }

    // MARK: - Opened, then Return without typing (default shell name showing)

    func test_ctrlCmdR_thenReturnWithoutTyping_defaultShellName_keepsFollowingShell() throws {
        let rig = try makeRig()
        assertDefaultShellNameShowing(rig)

        try openEditor(.ctrlCmdR, rig: rig)
        rig.strip.commitEditForTesting()
        pump(0.2)

        assertTabStillFollowsShell(rig, afterAction: "Ctrl-Cmd-R then Return on the default '\(rig.shellName)' title")
    }

    /// The smallest group the editor appears in: exactly two tabs.
    func test_doubleClick_inTwoTabGroup_thenReturnWithoutTyping_defaultShellName_keepsFollowingShell() throws {
        let rig = try makeRig(stubCount: 1)
        assertDefaultShellNameShowing(rig)

        try openEditor(.doubleClick, rig: rig)
        rig.strip.commitEditForTesting()
        pump(0.2)

        assertTabStillFollowsShell(rig, afterAction: "double-clicking the selected pill of a 2-tab group then Return")
    }

    // MARK: - Editor left open while the group changes (no user action at all)

    /// A tab opens (Cmd-T) while the editor is open: the strip commits the
    /// open editor on the list-shape change.
    func test_editorOpen_thenTabOpens_keepsFollowingShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.ctrlCmdR, rig: rig)

        let newTab = makeStub(tabbingIdentifier: rig.window.tabbingIdentifier)
        rig.window.addTabbedWindow(newTab, ordered: .above)
        pump(0.3)
        XCTAssertEqual(rig.group.windows.count, 4,
            "PRECONDITION: the tab list must have grown to 4 tabs, got \(rig.group.windows.count)")
        rig.group.selectedWindow = rig.window
        pump(0.15)
        rig.controller.refreshTabBar()
        pump(0.3)

        assertTabStillFollowsShell(rig, afterAction: "a tab opening while the rename editor is open")
    }

    /// A sibling shell exits while the editor is open: the strip is handed a
    /// SHORTER tab list. Windows are not closed or ordered out (CLAUDE.md
    /// tab-group rule), so the shorter list is handed to the strip directly,
    /// the same `update(tabs:selected:width:)` call `refreshTabBar` makes.
    func test_editorOpen_thenSiblingLeavesTabList_keepsFollowingShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.ctrlCmdR, rig: rig)

        let before = TabOrderCoordinator.shared.orderedTabs(for: rig.group)
        let shorter: [NSWindow] = before.filter { (w: NSWindow) -> Bool in
            return w !== rig.stubs[0]
        }
        XCTAssertEqual(shorter.count, before.count - 1,
            "PRECONDITION: exactly one sibling must leave the list (before \(before.count), after \(shorter.count))")
        let width = rig.strip.frame.width > 0 ? rig.strip.frame.width : 600
        rig.strip.update(tabs: shorter, selected: rig.window, width: width)
        pump(0.2)

        assertTabStillFollowsShell(rig, afterAction: "a sibling tab leaving while the rename editor is open")
    }

    // MARK: - Opened, then the user clicks away (focus moves to the terminal)

    func test_editorOpen_thenFocusMovesToTerminal_keepsFollowingShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.ctrlCmdR, rig: rig)
        let terminal = try XCTUnwrap(rig.controller.terminalView,
            "PRECONDITION: the controller must own a terminal view to click")
        _ = rig.window.makeFirstResponder(terminal)
        pump(0.3)

        assertTabStillFollowsShell(rig, afterAction: "clicking the terminal while the rename editor is open")
    }

    // MARK: - Controls (pass today, must keep passing)

    /// A name the user actually types still becomes the override, still beats
    /// the shell, and the editor is closed by the commit.
    func test_control_typedNameStillBecomesOverrideAndBeatsShell() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.ctrlCmdR, rig: rig)
        rig.strip.setEditTextForTesting(Self.typedName)
        rig.strip.commitEditForTesting()
        pump(0.2)

        XCTAssertEqual(rig.session.titleState.titleOverride, Self.typedName,
            "control: a typed name must become the tab's override")
        XCTAssertEqual(waitForTitle(Self.typedName, in: rig), Self.typedName,
            "control: the typed name must reach window.title (was '\(rig.window.title)')")

        feed(osc2(Self.followUpTitle), to: rig)
        pump(0.3)
        XCTAssertEqual(rig.window.title, Self.typedName,
            "control: a user-typed name must keep beating the shell's OSC title, but window.title is '\(rig.window.title)'")
    }

    /// Escape (the one exit that worked) leaves the tab automatic.
    func test_control_escapeLeavesTabAutomatic() throws {
        let rig = try makeRig()
        seedShellTitle(rig)

        try openEditor(.ctrlCmdR, rig: rig)
        rig.strip.cancelEditForTesting()
        pump(0.2)
        XCTAssertEqual(rig.strip.isEditingForTesting, false,
            "control: cancelling must close the editor")

        assertTabStillFollowsShell(rig, afterAction: "Ctrl-Cmd-R then Escape")
    }
}
