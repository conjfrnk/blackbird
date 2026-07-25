import XCTest
import AppKit
@testable import Blackbird

/// Integration tests for the "activation click must not rename a tab"
/// contract, driving the REAL `TabStripView.mouseDown(with:)` with
/// synthesized `NSEvent`s.
///
/// The bug being pinned: `NSEvent.clickCount` describes the SYSTEM's
/// click sequence, not this view's. AppKit keeps counting across window
/// and application activation boundaries, and it counts clicks that were
/// never delivered to the strip at all. Two user-visible consequences:
///
///  1. Blackbird isn't frontmost (or a different Blackbird window is
///     key). The user clicks a pill; because `acceptsFirstMouse` is false
///     that click only activates and `TabStripView` never sees it.
///     Nothing appears to happen, so the user clicks again — and THAT
///     mousedown arrives with `clickCount == 2`. Pre-fix the strip opened
///     the rename field instead of switching tabs.
///  2. The user clicks pill B in window A's strip (window B becomes key),
///     then clicks again quickly. Window B's strip is a DIFFERENT view
///     instance that never saw a first click, yet the event still carries
///     `clickCount == 2`. That one IS a genuine double-click on pill B —
///     one gesture whose two halves AppKit split across two views — so it
///     must rename. Telling it apart from case 1 is exactly why the click
///     mark is SHARED across every strip in the process instead of being
///     per-view: for case 2 some strip saw click 1, for case 1 none did.
///
/// Contract under test at this level: rename opens only for a double-click
/// SOME strip saw in full — the run of mousedowns the strips received
/// (renumbered by `TabStripView.effectiveClickCount`) reached 2 on this pill
/// index, within the system double-click interval — AND only when that pill was
/// ALREADY the selected tab when the run STARTED. Anything else is an ordinary
/// click: it arms a reorder drag and selects on release.
///
/// The selection half of that gate is a maintainer decision taken 2026-07-25,
/// and it is what closes case 2's twin: "click a background pill to switch to
/// it, then click it again" produces the SAME event stream as "deliberately
/// double-click a background pill to rename it", so no amount of click
/// bookkeeping can separate them. The tie is broken by asking whether the user
/// was already on that tab:
///
///  - double-click the SELECTED pill  → rename
///  - double-click a BACKGROUND pill  → switch to it, and stop
///  - rename a background tab         → click, pause past the interval, then
///                                      double-click
///
/// The run's selectedness is INHERITED through every click of the run, never
/// re-read: by click 2 the first click has already selected the tab, so a fresh
/// read would wave every background double-click straight back through.
///
/// Oracles (existing surfaces only, no new production hooks):
///  - "is renaming" ⇢ the inline-rename `NSTextField` is installed as a
///    subview of the strip. `beginEditing` is the ONLY `addSubview` call
///    site in `TitlebarTabBar.swift`, so this is exact.
///  - corroborating ⇢ `commitEditIfNeeded()` publishes through
///    `onCommitRename` when (and only when) an edit is in flight — the
///    same no-op-vs-publish split `InlineRenameTests` pins.
///  - "ordinary click" ⇢ `onSelectWindow` fires exactly once for the
///    clicked window over the mousedown+mouseup pair. This is deliberately
///    agnostic about WHERE the selection happens: the strip may select
///    eagerly in `mouseDown` or defer to `mouseUp`-as-click (the armed
///    drag path). Both are one selection for one click.
///
/// Memory + safety budget (`feedback_test_memory_safety`):
///  - ≤ 2 strips and ≤ 6 stub `NSWindow`s (200×100, contentless) per
///    test; never shown, so no backing store is ever allocated.
///    < 300 KB per test, < 2 MB for the suite.
///  - Stub windows and strips are PARKED for the process lifetime — never
///    shown, never `close()`d, never `orderOut`n (`feedback_tabgroup_
///    test_host_segv`). `tabbingMode = .disallowed` also keeps them out of
///    any stray `NSWindowTabGroup` a sibling suite may have created.
///  - No `MainWindowController`, no PTYs, no real shells.
///  - Wall time < 20 ms per test, except the stale-interval test which
///    deliberately waits out one system double-click interval.
final class TabRenameActivationClickTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // The click mark (`TabStripView.lastMouseDown`) is PROCESS-WIDE static
    // state — shared across every strip on purpose. Every test that drives
    // `mouseDown` must therefore start from a known-empty mark, or a leftover
    // from the previous test (or a sibling suite) decides this one's verdict
    // and the results depend on run order.
    override func setUp() {
        super.setUp()
        TabStripView.resetClickSequenceForTesting()
    }

    override func tearDown() {
        TabStripView.resetClickSequenceForTesting()
        super.tearDown()
    }

    // MARK: - Rig

    /// A windowless `TabStripView` over `tabCount` never-shown stub
    /// windows, with the strip's three callbacks recorded.
    ///
    /// `selected` is which pill the strip believes is the CURRENT tab. The
    /// rename gate reads it, so every test here has to say which tab the user
    /// was on. The rig never moves it on its own — `onSelectWindow` is only
    /// recorded, exactly like production, where the switch travels through the
    /// window controller and comes back as a refresh. Tests that need that
    /// round trip call `selectTab(_:)`.
    private final class StripRig {
        /// Parked for the process lifetime. These are never shown and
        /// never closed; they die at process exit.
        private static var parked: [AnyObject] = []

        let strip: TabStripView
        let tabs: [NSWindow]
        private let width: CGFloat
        private(set) var selections: [NSWindow] = []
        private(set) var closes: [NSWindow] = []
        private(set) var renameCommits: [(window: NSWindow, title: String)] = []

        init(tabCount: Int, prefix: String, selected: Int = 0, width: CGFloat = 600) {
            precondition(selected < tabCount, "selected pill \(selected) out of range")
            let windows: [NSWindow] = (0..<tabCount).map { i in
                let w = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                w.title = "\(prefix)-\(i)"
                // Bare NSWindows created in one test process share a
                // derived tabbing identifier; `.disallowed` stops AppKit
                // folding these stubs into a group a sibling suite left
                // behind (see TabStripDragTests for the full writeup).
                w.tabbingMode = .disallowed
                return w
            }
            self.tabs = windows
            self.width = width
            self.strip = TabStripView(
                frame: NSRect(x: 0, y: 0, width: width, height: TabStripView.height)
            )
            strip.update(tabs: windows, selected: windows[selected], width: width)
            strip.onSelectWindow = { [weak self] w in self?.selections.append(w) }
            strip.onCloseWindow = { [weak self] w in self?.closes.append(w) }
            strip.onCommitRename = { [weak self] w, t in
                self?.renameCommits.append((window: w, title: t))
            }
            StripRig.parked.append(contentsOf: windows as [AnyObject])
            StripRig.parked.append(strip)
        }

        /// `true` while the inline-rename field is installed. `beginEditing`
        /// is the only `addSubview` call site in the strip.
        var isRenaming: Bool {
            strip.subviews.contains { $0 is NSTextField }
        }

        /// What the app does after a click switches tabs: the controller pushes
        /// the new selection back into every strip of the group. Same tab list,
        /// so it is NOT a list-shape change and the shared click mark survives
        /// it — which is precisely the window in which the second half of a
        /// double-click lands, and precisely why the rename gate must inherit
        /// the run's ORIGINAL selectedness rather than re-read it here.
        func selectTab(_ i: Int) {
            precondition(i < tabs.count, "pill \(i) out of range")
            strip.update(tabs: tabs, selected: tabs[i], width: width)
        }

        /// Centre of pill `i` in strip-local coordinates. Horizontally
        /// centred, so it is nowhere near the leading close hotspot
        /// (whose centre sits 13pt inside the pill's left edge).
        func pillCenter(_ i: Int) -> NSPoint {
            let frames = strip.pillFramesForTesting
            precondition(i < frames.count, "pill \(i) out of range")
            return NSPoint(x: frames[i].midX, y: frames[i].midY)
        }
    }

    /// Synthesize a mouse event. `timestamp` matters for the stale-click
    /// test: the strip must reject a `clickCount == 2` whose sequence
    /// started longer ago than the system double-click interval.
    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            clickCount: Int,
                            timestamp: TimeInterval = 0) -> NSEvent {
        // `p` is given in VIEW coordinates (that is what `pillFramesForTesting`
        // and `addButtonFrameForTesting` report), but `NSEvent.location` is a
        // WINDOW coordinate and `TabStripView.mouseDown` runs it through
        // `convert(_:from: nil)`. The strip is `isFlipped == true`, so that
        // conversion mirrors y about the strip's height. Pre-mirror here so a
        // test that says "y = 1" really does click view-y 1. Without this every
        // point silently lands at `height - y`, which happens to stay inside
        // the pill band for pill-centre clicks — so the mistake hides until a
        // test depends on y, e.g. one aiming at the bare strip below the pills.
        let windowPoint = NSPoint(x: p.x, y: TabStripView.height - p.y)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        )!
    }

    /// One complete click delivered to the strip: mousedown then mouseup
    /// at the same point, as AppKit always delivers them.
    private func click(_ rig: StripRig,
                       pill: Int,
                       clickCount: Int,
                       timestamp: TimeInterval = 0) {
        let p = rig.pillCenter(pill)
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p,
                                             clickCount: clickCount,
                                             timestamp: timestamp))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p,
                                           clickCount: clickCount,
                                           timestamp: timestamp))
    }

    /// Assert the strip is NOT in rename mode, using both oracles: no
    /// field installed, and `commitEditIfNeeded` publishes nothing.
    private func assertNotRenaming(_ rig: StripRig,
                                   _ message: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertFalse(rig.isRenaming, message, file: file, line: line)
        let before = rig.renameCommits.count
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.count, before,
                       message + " (commitEditIfNeeded must be a no-op)",
                       file: file, line: line)
    }

    // MARK: - Genuine double-click on the current tab still renames

    /// THE LOAD-BEARING POSITIVE. The gesture AppKit actually delivers for a
    /// double-click on the pill of the CURRENT tab: down(1), up(1), down(2).
    /// The strip saw the whole sequence and the user was already on that tab,
    /// so rename MUST open — neither fix may cost the feature.
    func test_genuineDoubleClickOnSelectedPill_fullEventSequence_entersRename() {
        let rig = StripRig(tabCount: 3, prefix: "genuine", selected: 1)
        XCTAssertFalse(rig.isRenaming, "precondition: not renaming yet")

        let p = rig.pillCenter(1)
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 1))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p, clickCount: 1))
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 2))

        XCTAssertTrue(
            rig.isRenaming,
            "a double-click this strip saw in full must open the rename field"
        )
        // The first click of the sequence still switches tabs, exactly as
        // it did before the fix.
        XCTAssertEqual(rig.selections.first, rig.tabs[1],
                       "the clickCount==1 half of the gesture selects the pill")

        // Second oracle: the in-flight edit is real and targets pill 1.
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.count, 1,
                       "commitEditIfNeeded must publish the in-flight rename")
        XCTAssertEqual(rig.renameCommits.first?.window, rig.tabs[1],
                       "rename must target the double-clicked pill's window")
        XCTAssertEqual(rig.renameCommits.first?.title, "genuine-1",
                       "the field is pre-filled with that pill's title")
    }

    /// Same sequence minus the intervening mouseup. The mark the strip
    /// keeps is of the last mousedown it RECEIVED, so the presence or
    /// absence of the mouseup must not decide whether rename opens.
    func test_genuineDoubleClick_withoutInterveningMouseUp_entersRename() {
        let rig = StripRig(tabCount: 3, prefix: "nomouseup", selected: 2)
        let p = rig.pillCenter(2)

        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 1))
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 2))

        XCTAssertTrue(
            rig.isRenaming,
            "the strip received the clickCount==1 mousedown on this pill, so "
                + "the clickCount==2 mousedown is its own double-click"
        )
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.first?.window, rig.tabs[2])
    }

    // MARK: - Consequence 1: phantom activation click

    /// The activation-click bug. The strip never received the first
    /// mousedown (AppKit consumed it activating the app), so its first
    /// event of the sequence is a `clickCount == 2` mousedown. That must
    /// NOT rename — it must behave like an ordinary click and switch to
    /// the clicked tab.
    ///
    /// Aimed at the pill of the CURRENT tab on purpose: the selection gate
    /// would let this one through, so the refusal can only be the renumbered
    /// click count. On a background pill the test would pass for two reasons at
    /// once and stop pinning the return-to-app case at all.
    func test_loneDoubleClickMouseDownOnSelectedPill_doesNotRename_andSelectsTab() {
        let rig = StripRig(tabCount: 3, prefix: "phantom", selected: 1)
        XCTAssertFalse(rig.isRenaming, "precondition: not renaming yet")

        click(rig, pill: 1, clickCount: 2)

        assertNotRenaming(
            rig,
            "a clickCount==2 mousedown with no first click delivered to THIS "
                + "strip is an activation click, not a rename gesture"
        )
        XCTAssertEqual(rig.selections.count, 1,
                       "the phantom double-click must act as one ordinary click")
        XCTAssertEqual(rig.selections.first, rig.tabs[1],
                       "…and it must select the pill the user clicked")
        XCTAssertEqual(rig.closes.count, 0,
                       "clicking a pill centre must never close it")
    }

    // MARK: - The reported bug: a background pill switches and stops

    /// THE 2026-07-24 REPORT. The user clicks a background pill to switch to
    /// it, then clicks it again — and the rename field used to pop open. The
    /// maintainer's call: a double-click that STARTED on a background pill
    /// switches to that tab and stops there.
    ///
    /// The app's selection round trip is modelled faithfully (click 1 switches,
    /// the controller pushes the new selection back into the strip) because
    /// that is exactly the state an implementation that RE-READ selectedness
    /// would consult to wrongly license the rename.
    func test_doubleClickOnBackgroundPill_switchesWithoutRenaming() {
        let rig = StripRig(tabCount: 3, prefix: "background", selected: 0)
        let p = rig.pillCenter(1)

        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 1))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p, clickCount: 1))
        XCTAssertEqual(rig.selections, [rig.tabs[1]],
                       "precondition: click 1 switched to the background tab")
        // …and the switch comes back as a same-shape refresh: pill 1 is the
        // current tab from here on, while the click mark survives.
        rig.selectTab(1)

        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 2))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p, clickCount: 2))

        assertNotRenaming(
            rig,
            "a double-click whose run began on a background pill must switch "
                + "to that tab and stop — rename is for the tab you are on"
        )
        XCTAssertEqual(rig.selections, [rig.tabs[1], rig.tabs[1]],
                       "both halves act on the pill the user aimed at (click 2 "
                           + "falls through to the ordinary pill-click path), "
                           + "and neither renames it")
        XCTAssertEqual(rig.closes.count, 0,
                       "clicking a pill centre must never close it")
    }

    /// The documented way to rename a background tab: click it, let the run
    /// lapse past the double-click interval, then double-click the pill that is
    /// NOW current. Without this the policy would be a regression rather than a
    /// tradeoff — background tabs could not be renamed at all.
    ///
    /// The lapse is expressed in event timestamps (`mouseDown` renumbers off
    /// `NSEvent.timestamp`), so this test costs no wall time.
    func test_backgroundPill_clickThenPauseThenDoubleClick_entersRename() {
        let rig = StripRig(tabCount: 3, prefix: "pause", selected: 0)
        let p = rig.pillCenter(1)
        let lapsed = NSEvent.doubleClickInterval * 2 + 0.1

        // Click once to switch tabs; the app propagates the new selection.
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p,
                                             clickCount: 1, timestamp: 0))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p,
                                           clickCount: 1, timestamp: 0))
        rig.selectTab(1)
        assertNotRenaming(rig, "precondition: one click never renames")

        // …pause. AppKit restarts its count, and the strip computes this run's
        // selectedness fresh — the pill IS the current tab now.
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p,
                                             clickCount: 1, timestamp: lapsed))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p,
                                           clickCount: 1, timestamp: lapsed))
        assertNotRenaming(rig, "the opening click of the new run doesn't rename")

        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 2,
                                             timestamp: lapsed + NSEvent.doubleClickInterval / 4))

        XCTAssertTrue(
            rig.isRenaming,
            "click, pause, double-click is the documented way to rename a "
                + "background tab and must work"
        )
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.count, 1,
                       "the in-flight edit is real")
        XCTAssertEqual(rig.renameCommits.first?.window, rig.tabs[1],
                       "rename targets the pill the user double-clicked")
        XCTAssertEqual(rig.renameCommits.first?.title, "pause-1",
                       "the field is pre-filled with that pill's title")
    }

    /// Same shape, but the strip HAS seen a first click — just too long
    /// ago. A stale mark must not license a rename either: the user's
    /// earlier click and this one are two separate gestures.
    ///
    /// The gap is made real in BOTH clocks — the events carry timestamps
    /// past the interval AND the test waits out the interval on the
    /// runloop — so the test holds whether the strip marks the sequence
    /// with `NSEvent.timestamp` or with a wall clock.
    func test_firstClickOlderThanDoubleClickInterval_doesNotRename() throws {
        let interval = NSEvent.doubleClickInterval
        try XCTSkipIf(interval > 1.5,
                      "double-click interval configured absurdly long "
                          + "(\(interval)s); the wait would dominate the suite")

        // Pill 1 is the CURRENT tab, so the selection gate is satisfied and the
        // staleness of the run is the only thing that can refuse the rename.
        let rig = StripRig(tabCount: 3, prefix: "stale", selected: 1)
        let p = rig.pillCenter(1)

        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p,
                                             clickCount: 1, timestamp: 0))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p,
                                           clickCount: 1, timestamp: 0))
        XCTAssertEqual(rig.selections.count, 1,
                       "precondition: the first click selected the pill")

        // Let real time pass beyond the interval, then deliver a mousedown
        // whose own timestamp is also past it.
        let gap = interval + 0.1
        RunLoop.current.run(until: Date().addingTimeInterval(gap))
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p,
                                             clickCount: 2, timestamp: gap))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p,
                                           clickCount: 2, timestamp: gap))

        assertNotRenaming(
            rig,
            "a clickCount==2 arriving more than one double-click interval "
                + "after the strip's last mousedown is a fresh click"
        )
        XCTAssertEqual(rig.selections.count, 2,
                       "the stale-sequence click still selects, once")
        XCTAssertEqual(rig.selections.last, rig.tabs[1])
    }

    /// The first click landed on a DIFFERENT pill. Even though the system
    /// counts the pair as a double-click, no single pill was clicked
    /// twice, so nothing may enter rename. Pill 2 — the one the second click
    /// lands on — is the CURRENT tab here, so the selection gate would allow
    /// it: the broken run is the only thing refusing.
    func test_firstClickOnDifferentPill_doesNotRename() {
        let rig = StripRig(tabCount: 3, prefix: "otherpill", selected: 2)

        let first = rig.pillCenter(0)
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: first, clickCount: 1))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: first, clickCount: 1))

        let second = rig.pillCenter(2)
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: second, clickCount: 2))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: second, clickCount: 2))

        assertNotRenaming(
            rig,
            "the clickCount==1 half landed on a different pill — this is not "
                + "a double-click on the pill being renamed"
        )
        XCTAssertEqual(rig.selections.count, 2,
                       "two ordinary clicks → two selections")
        XCTAssertEqual(rig.selections.first, rig.tabs[0])
        XCTAssertEqual(rig.selections.last, rig.tabs[2],
                       "the second click selects the pill it landed on")
    }

    // MARK: - Consequence 2: cross-window sequence

    /// Two windows, two strips, ONE gesture. AppKit routinely splits the halves
    /// of a double-click across two view instances — a key-window change
    /// between them is enough — so the run (and now the run's selectedness)
    /// has to survive the hand-off. Both strips here stand for the same tab
    /// group with tab 1 CURRENT, which is the shape that renames.
    ///
    /// The strips DID see this gesture in full, just across two views, so
    /// rename must open on strip B. (Under the old per-view mark strip B
    /// refused outright and cross-window double-click rename silently stopped
    /// working. The shared mark restores it, and is also what keeps the phantom
    /// activation click above rejected — there, NO strip saw click 1.)
    func test_crossStripDoubleClickOnSelectedPill_secondHalfOnFreshStrip_entersRename() {
        // Both rigs are constructed FIRST: `update(tabs:)` clears the shared
        // mark on a list-shape change, so building B after A's click would
        // wipe the very mark under test.
        let rigA = StripRig(tabCount: 3, prefix: "winA", selected: 1)
        let rigB = StripRig(tabCount: 3, prefix: "winB", selected: 1)

        // Full click in window A's strip — the system's click sequence now
        // stands at 1, and so does the strips' own run.
        click(rigA, pill: 1, clickCount: 1)
        XCTAssertEqual(rigA.selections, [rigA.tabs[1]],
                       "precondition: strip A's click acted on the current tab")

        // The follow-up click lands in window B's strip, at the same pill
        // index, carrying the system's continued count.
        rigB.strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                              at: rigB.pillCenter(1),
                                              clickCount: 2))

        XCTAssertTrue(
            rigB.isRenaming,
            "the second half of a double-click, delivered to another window's "
                + "fresh strip, must open rename — some strip saw click 1 on "
                + "this (already selected) pill within the interval"
        )
        rigB.strip.commitEditIfNeeded()
        XCTAssertEqual(rigB.renameCommits.count, 1,
                       "the in-flight edit on strip B is real")
        XCTAssertEqual(rigB.renameCommits.first?.window, rigB.tabs[1],
                       "rename targets the pill the user double-clicked")
        XCTAssertEqual(rigB.renameCommits.first?.title, "winB-1",
                       "the field is pre-filled with that pill's title")
        XCTAssertEqual(rigB.selections.count, 0,
                       "the renaming click must not ALSO select a tab")
        assertNotRenaming(
            rigA,
            "strip A saw only a single click and must not be renaming"
        )
    }

    /// …and the same machinery must not smuggle the background case back in.
    /// This is the reported bug in its native two-window shape: click 1 lands
    /// in window A's strip and switches to the background tab, which makes
    /// window B key — so click 2 is delivered to window B's strip, where that
    /// pill is ALREADY the current tab. An implementation that re-read
    /// selectedness on strip B instead of inheriting the run's would rename
    /// here, and the policy would be dead on the most common physical gesture.
    func test_crossStripDoubleClick_runStartedOnBackgroundPill_doesNotRename() {
        // Strip A: the window the user is on, showing tab 0. Strip B: the
        // destination window, where the clicked pill is the current tab —
        // exactly the state a fresh read would consult.
        let rigA = StripRig(tabCount: 3, prefix: "bgA", selected: 0)
        let rigB = StripRig(tabCount: 3, prefix: "bgB", selected: 1)

        click(rigA, pill: 1, clickCount: 1)
        XCTAssertEqual(rigA.selections, [rigA.tabs[1]],
                       "precondition: click 1 switched to the background tab")

        rigB.strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                              at: rigB.pillCenter(1),
                                              clickCount: 2))
        rigB.strip.mouseUp(with: mouseEvent(.leftMouseUp,
                                            at: rigB.pillCenter(1),
                                            clickCount: 2))

        assertNotRenaming(
            rigB,
            "a run that began on a background pill must not rename, however "
                + "many strips its halves were split across"
        )
        XCTAssertEqual(rigB.selections, [rigB.tabs[1]],
                       "strip B's click is an ordinary click on that pill")
        assertNotRenaming(
            rigA,
            "strip A saw only a single click and must not be renaming"
        )
    }

    /// A phantom activation click must not poison the strip's bookkeeping:
    /// the very next genuine double-click still renames. This is what
    /// separates "ignore clicks whose first half we missed" from
    /// "double-click rename is broken after any stray clickCount==2".
    func test_phantomDoubleClick_thenGenuineDoubleClick_stillRenames() {
        // Pill 1 is the current tab throughout, so the recovery being measured
        // is the click bookkeeping's and not the selection gate's.
        let rig = StripRig(tabCount: 3, prefix: "recover", selected: 1)
        let p = rig.pillCenter(1)

        // Phantom activation click first.
        click(rig, pill: 1, clickCount: 2)
        assertNotRenaming(rig, "precondition: the phantom click did not rename")

        // Now a real, complete double-click on the same pill.
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 1))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p, clickCount: 1))
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p, clickCount: 2))

        XCTAssertTrue(
            rig.isRenaming,
            "a genuine double-click after a phantom activation click must "
                + "still open rename"
        )
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.count, 1)
        XCTAssertEqual(rig.renameCommits.first?.window, rig.tabs[1])
        XCTAssertEqual(rig.renameCommits.first?.title, "recover-1")
    }
}
