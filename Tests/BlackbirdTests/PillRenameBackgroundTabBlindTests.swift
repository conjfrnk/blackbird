import XCTest
import AppKit
@testable import Blackbird

/// Blind regression tests for LSM-2: choosing "Rename…" from the context menu
/// of a pill that belongs to a BACKGROUND tab must give the user a rename
/// editor they can see, and must never leave an editor open somewhere the user
/// cannot reach.
///
/// Written WITHOUT reading the bodies of `TabStripView.menu(for:)`,
/// `TitlebarTabBarViewController.beginInlineRename(for:)`,
/// `MainWindowController.renameActiveTab / beginRenameActiveTab /
/// applyInlineRename / refreshTabBar` or `TabStripView.update`
/// (CLAUDE.md "Author new behavior tests blind"). Only declarations, doc
/// comments and sibling test files (`TabPillFramePushBlindTests`,
/// `TabMoverTests`, `InlineRenameTests`) were consulted.
///
/// ## Observable contract
///
/// A native tab group shows exactly one window at a time: the group's
/// `selectedWindow`. Only that window's title-bar pill strip is on screen; the
/// strips of the other members are not. Tab pills are the only way to reach a
/// rename editor, so:
///
///   1. Right-click a non-selected pill, choose "Rename…": an inline rename
///      editor opens in a strip the user can see (the strip they right-clicked
///      in, or, if the implementation switches to that tab first, the newly
///      selected tab's strip). The menu item must not appear to do nothing.
///   2. No editor is ever left open in a strip that is not visible: nobody can
///      type into it, confirm it or cancel it, yet a later tab-list change
///      publishes whatever it holds.
///   3. The name the user types in that editor lands on the right-clicked tab.
///   4. If the user changes their mind (Escape), the tab keeps following its
///      shell's automatic title through the next tab-list change (open a tab):
///      its `titleOverride` stays unset. Nothing may be pinned that the user
///      neither typed nor confirmed.
///
/// Controls: the same path on the SELECTED tab's pill works today and must keep
/// working (proves the helpers can see a visible editor, so the failures above
/// are about the background-tab path and not about the rig).
///
/// ## Rig
///
/// ONE real `MainWindowController` (via `makeForTesting`, headless session: no
/// PTY, no shell) plus two plain stub windows merged into one tab group with
/// `addTabbedWindow`; more stubs are merged by the "open a tab" scenario. The
/// controller's window is the BACKGROUND tab; stub `host` is the selected tab.
/// The visible strip is a genuine `TitlebarTabBarViewController(window: host)`
/// (production wiring: its commit callback routes to the renamed window's
/// controller). Nothing is shown, closed or ordered out; every window and
/// controller is parked for process lifetime (the `TabMoverTests` template).
/// The menu is obtained from `TabStripView.menu(for:)` with a synthetic
/// right-click and the "Rename…" item is fired with `NSApp.sendAction`, the
/// way the menu machinery delivers it. No keystroke / CGEvent injection.
///
/// ## Cost pre-flight
///
/// Roughly 4-6 never-shown windows (~40 KB each) and one Metal-backed
/// terminal view (a few MB) for the whole class; strips are 600 x 28 pt. Each
/// scenario pumps the runloop for about 1-2 s in total.
@MainActor
final class PillRenameBackgroundTabBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Constants

    private static let baseFrame = NSRect(x: 120, y: 120, width: 600, height: 300)
    private static let stripWidth: CGFloat = 600
    private static let renameTitle = "Rename\u{2026}"
    private static let typedName = "Build Logs"

    // MARK: - Rig

    private struct Rig {
        let controller: MainWindowController
        /// The real controller's window. The BACKGROUND tab in most scenarios.
        let window: NSWindow
        /// Stub window that is the group's selected tab in the background
        /// scenarios.
        let host: NSWindow
        /// Production tab-bar controller for `host`: the strip the user is
        /// looking at when `host` is selected.
        let hostBar: TitlebarTabBarViewController
        let hostStrip: TabStripView
        /// The real controller's own strip.
        let controllerStrip: TabStripView
        let group: NSWindowTabGroup
    }

    private enum Selected {
        /// `host` is selected; the controller's window is a background tab.
        case host
        /// The controller's window is selected.
        case controllerWindow
    }

    private static var rigStorage: Rig?
    private static var rigAttempted = false
    private static var rigSkipReason = "rig was never built"
    private static var parkedControllers: [MainWindowController] = []
    private static var parkedStubs: [NSWindow] = []
    private static var parkedBars: [TitlebarTabBarViewController] = []
    private static var stubCounter = 0

    private func pump(_ seconds: TimeInterval = 0.1) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func makeStub(tabbingIdentifier: String) -> NSWindow {
        Self.stubCounter += 1
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        w.title = "rename-bg-stub-\(Self.stubCounter)"
        w.isReleasedWhenClosed = false
        w.tabbingMode = .preferred
        w.tabbingIdentifier = tabbingIdentifier
        Self.parkedStubs.append(w)
        return w
    }

    private func rig() throws -> Rig {
        if let r = Self.rigStorage { return r }
        if Self.rigAttempted { throw XCTSkip(Self.rigSkipReason) }
        Self.rigAttempted = true

        guard let controller = MainWindowController.makeForTesting(
            stubSession: .makeHeadlessForTests()
        ), let window = controller.window else {
            Self.rigSkipReason = "no Metal device (CI virtual display): makeForTesting returned nil"
            throw XCTSkip(Self.rigSkipReason)
        }
        Self.parkedControllers.append(controller)

        let host = makeStub(tabbingIdentifier: window.tabbingIdentifier)
        let sibling = makeStub(tabbingIdentifier: window.tabbingIdentifier)
        window.setFrame(Self.baseFrame, display: false)
        window.addTabbedWindow(host, ordered: .above)
        window.addTabbedWindow(sibling, ordered: .above)

        guard let group = window.tabGroup, group.windows.count == 3 else {
            Self.rigSkipReason = "xctest host refused the headless addTabbedWindow merge "
                + "(group windows: \(window.tabGroup?.windows.count ?? 0), expected 3)"
            throw XCTSkip(Self.rigSkipReason)
        }
        pump(0.3)

        // The strip the user is looking at when `host` is the selected tab.
        let hostBar = TitlebarTabBarViewController(window: host)
        Self.parkedBars.append(hostBar)
        guard let hostStrip = hostBar.view as? TabStripView else {
            Self.rigSkipReason = "TitlebarTabBarViewController.view is not a TabStripView"
            throw XCTSkip(Self.rigSkipReason)
        }
        hostStrip.frame = NSRect(x: 0, y: 0, width: Self.stripWidth, height: 28)

        group.selectedWindow = window
        pump(0.15)
        controller.refreshTabBar()
        pump(0.15)
        guard let controllerStrip = controller.titlebarTabBar?.view as? TabStripView else {
            Self.rigSkipReason = "controller has no TabStripView in titlebarTabBar"
            throw XCTSkip(Self.rigSkipReason)
        }

        let r = Rig(controller: controller, window: window, host: host, hostBar: hostBar,
                    hostStrip: hostStrip, controllerStrip: controllerStrip, group: group)
        Self.rigStorage = r
        return r
    }

    /// Puts the shared rig in a known state: nothing being edited anywhere, no
    /// override on the controller's tab, the requested tab selected, both
    /// strips laid out for the current tab list.
    private func prepare(_ selected: Selected,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let rig = try rig()

        // Earlier scenarios (and the bug itself) can leave an editor open.
        for strip in [rig.controllerStrip, rig.hostStrip] where strip.isEditingForTesting {
            strip.cancelEditForTesting()
        }
        rig.controller.session?.titleState.titleOverride = nil

        let want: NSWindow = (selected == .host) ? rig.host : rig.window
        rig.group.selectedWindow = want
        pump(0.15)
        rig.controller.refreshTabBar()
        rig.hostBar.refresh(availableWidth: Self.stripWidth)
        pump(0.15)

        let ordered = TabOrderCoordinator.shared.orderedTabs(for: rig.group)
        XCTAssertGreaterThanOrEqual(rig.group.windows.count, 3,
            "PRECONDITION: the group must have at least 3 tabs so Rename uses the inline editor, got \(rig.group.windows.count)",
            file: file, line: line)
        XCTAssertTrue(rig.group.selectedWindow === want,
            "PRECONDITION: selected tab should be '\(want.title)', got '\(rig.group.selectedWindow?.title ?? "nil")'",
            file: file, line: line)
        XCTAssertEqual(rig.controller.session?.titleState.titleOverride, nil,
            "PRECONDITION: the controller's tab must start with no title override",
            file: file, line: line)
        XCTAssertEqual(rig.controllerStrip.isEditingForTesting || rig.hostStrip.isEditingForTesting, false,
            "PRECONDITION: no editor may be open before the scenario starts",
            file: file, line: line)
        XCTAssertEqual(rig.hostStrip.pillCountForTesting, ordered.count,
            "PRECONDITION: the host strip must paint one pill per tab (\(ordered.count)), got \(rig.hostStrip.pillCountForTesting)",
            file: file, line: line)
        return rig
    }

    // MARK: - Scenario plumbing

    private func rightClickEvent(at p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: p,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }

    /// Right-clicks `target`'s pill in `strip` and delivers the resulting
    /// "Rename…" menu item the way the menu machinery does.
    private func chooseRename(in strip: TabStripView, onPillOf target: NSWindow, rig: Rig,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let ordered = TabOrderCoordinator.shared.orderedTabs(for: rig.group)
        let index = try XCTUnwrap(
            ordered.firstIndex(where: { (w: NSWindow) -> Bool in w === target }),
            "PRECONDITION: '\(target.title)' must be one of the group's ordered tabs",
            file: file, line: line)
        let frames = strip.pillFramesForTesting
        guard index < frames.count else {
            XCTFail("PRECONDITION: strip painted \(frames.count) pills, need index \(index)",
                    file: file, line: line)
            return
        }
        // `menu(for:)` converts the event's window location back into strip
        // space; a strip that lives inside a window (the controller's own)
        // needs the forward conversion, a window-less strip gets identity.
        let local = NSPoint(x: frames[index].midX, y: frames[index].midY)
        let point = strip.convert(local, to: nil)
        let menu = try XCTUnwrap(strip.menu(for: rightClickEvent(at: point)),
            "PRECONDITION: right-clicking a pill must produce a context menu",
            file: file, line: line)
        let item = try XCTUnwrap(
            menu.items.first(where: { (mi: NSMenuItem) -> Bool in mi.title == Self.renameTitle }),
            "PRECONDITION: the pill context menu must offer '\(Self.renameTitle)' (items: \(menu.items.map { $0.title }))",
            file: file, line: line)
        let action = try XCTUnwrap(item.action,
            "PRECONDITION: the '\(Self.renameTitle)' item must have an action",
            file: file, line: line)
        let delivered = NSApp.sendAction(action, to: item.target, from: item)
        XCTAssertTrue(delivered,
            "PRECONDITION: the '\(Self.renameTitle)' action must be delivered to its target",
            file: file, line: line)
        // Let any deferred work the action schedules (tab selection, editor
        // install) settle.
        pump(0.3)
    }

    /// The strip that is on screen: the one that belongs to the group's
    /// selected tab. Every other strip is hidden from the user.
    private func visibleAndHidden(_ rig: Rig) -> (visible: TabStripView?, hidden: [TabStripView]) {
        let selected = rig.group.selectedWindow
        if selected === rig.window { return (rig.controllerStrip, [rig.hostStrip]) }
        if selected === rig.host { return (rig.hostStrip, [rig.controllerStrip]) }
        return (nil, [rig.controllerStrip, rig.hostStrip])
    }

    private func describe(_ rig: Rig) -> String {
        let selected = rig.group.selectedWindow?.title ?? "nil"
        return "selected tab '\(selected)'; "
            + "controller-window strip editing=\(rig.controllerStrip.isEditingForTesting), "
            + "host strip editing=\(rig.hostStrip.isEditingForTesting) "
            + "(controller window is '\(rig.window.title)', host is '\(rig.host.title)')"
    }

    // MARK: - Controls (the path that works today)

    /// Control: Rename… on the SELECTED tab's pill opens an editor in the
    /// visible strip and the typed name is applied. Proves the helpers can see
    /// a visible editor and that the commit wiring reaches the controller.
    func test_control_renameOnSelectedPill_opensVisibleEditorAndAppliesTypedName() throws {
        let rig = try prepare(.controllerWindow)
        try XCTSkipUnless(rig.controllerStrip.pillCountForTesting >= 3,
            "controller strip is not laid out in this host (\(rig.controllerStrip.pillCountForTesting) pills)")

        try chooseRename(in: rig.controllerStrip, onPillOf: rig.window, rig: rig)

        let state = visibleAndHidden(rig)
        XCTAssertEqual(state.visible?.isEditingForTesting, true,
            "control: Rename… on the selected pill must open the editor in the visible strip; \(describe(rig))")

        guard let editor = state.visible, editor.isEditingForTesting else { return }
        editor.setEditTextForTesting(Self.typedName)
        editor.commitEditForTesting()
        pump(0.2)
        XCTAssertEqual(rig.controller.session?.titleState.titleOverride, Self.typedName,
            "control: the name typed into the visible editor must become the tab's override")
    }

    // MARK: - LSM-2: Rename… on a background pill

    /// The menu item must not appear to do nothing: an editor opens in the
    /// strip the user can see.
    func test_renameOnBackgroundPill_opensEditorInVisibleStrip() throws {
        let rig = try prepare(.host)
        try chooseRename(in: rig.hostStrip, onPillOf: rig.window, rig: rig)

        let state = visibleAndHidden(rig)
        XCTAssertEqual(state.visible?.isEditingForTesting, true,
            "Rename… on a background tab's pill opened no editor in the visible strip; \(describe(rig))")
    }

    /// An editor must never be left open in a strip nobody can see: it cannot
    /// be typed into, confirmed or cancelled, yet a later tab-list change
    /// publishes its contents.
    func test_renameOnBackgroundPill_leavesNoEditorInAHiddenStrip() throws {
        let rig = try prepare(.host)
        try chooseRename(in: rig.hostStrip, onPillOf: rig.window, rig: rig)

        let state = visibleAndHidden(rig)
        let hiddenEditing = state.hidden.filter { (s: TabStripView) -> Bool in s.isEditingForTesting }
        XCTAssertEqual(hiddenEditing.count, 0,
            "\(hiddenEditing.count) strip(s) are in rename mode while hidden from the user; \(describe(rig))")
    }

    /// End to end: the name typed into the editor lands on the tab that was
    /// right-clicked.
    func test_renameOnBackgroundPill_typedNameAppliesToRightClickedTab() throws {
        let rig = try prepare(.host)
        try chooseRename(in: rig.hostStrip, onPillOf: rig.window, rig: rig)

        let state = visibleAndHidden(rig)
        guard let editor = state.visible, editor.isEditingForTesting else {
            XCTFail("no visible rename editor to type into after choosing Rename… on a background pill; \(describe(rig))")
            return
        }
        editor.setEditTextForTesting(Self.typedName)
        editor.commitEditForTesting()
        pump(0.3)

        XCTAssertEqual(rig.controller.session?.titleState.titleOverride, Self.typedName,
            "the typed name must become the right-clicked tab's override")
    }

    /// The silent-corruption half of the report. The user opened the rename
    /// editor from the menu and backed out (Escape) of whatever they could
    /// see. Opening a new tab afterwards must not pin the tab's current title
    /// as a permanent override: nothing was typed or confirmed.
    func test_renameOnBackgroundPill_cancelled_thenNewTab_keepsAutomaticTitle() throws {
        let rig = try prepare(.host)
        try chooseRename(in: rig.hostStrip, onPillOf: rig.window, rig: rig)

        // The user presses Escape in the editor they can see (if there is one).
        let visible = visibleAndHidden(rig).visible
        if let editor = visible, editor.isEditingForTesting {
            editor.cancelEditForTesting()
        }
        pump(0.1)

        // Open a tab (Cmd-T / +): the group gains a member and every
        // controller's strip is refreshed, the same sweep AppDelegate runs.
        let newTab = makeStub(tabbingIdentifier: rig.window.tabbingIdentifier)
        rig.window.addTabbedWindow(newTab, ordered: .above)
        pump(0.3)
        XCTAssertGreaterThanOrEqual(rig.group.windows.count, 4,
            "PRECONDITION: the tab list must have grown, got \(rig.group.windows.count) tabs")
        rig.controller.refreshTabBar()
        rig.hostBar.refresh(availableWidth: Self.stripWidth)
        pump(0.3)

        XCTAssertEqual(rig.controller.session?.titleState.titleOverride, nil,
            "opening a tab after cancelling a rename pinned the tab's title as a permanent override; \(describe(rig))")
    }
}
