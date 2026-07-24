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
///     `clickCount == 2`.
///
/// Contract under test at this level: rename opens only for a
/// double-click THIS strip saw in full (it received the `clickCount == 1`
/// mousedown on the same pill, within the system double-click interval).
/// Anything else is an ordinary click — it selects the tab.
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

    // MARK: - Rig

    /// A windowless `TabStripView` over `tabCount` never-shown stub
    /// windows, with the strip's three callbacks recorded.
    private final class StripRig {
        /// Parked for the process lifetime. These are never shown and
        /// never closed; they die at process exit.
        private static var parked: [AnyObject] = []

        let strip: TabStripView
        let tabs: [NSWindow]
        private(set) var selections: [NSWindow] = []
        private(set) var closes: [NSWindow] = []
        private(set) var renameCommits: [(window: NSWindow, title: String)] = []

        init(tabCount: Int, prefix: String, width: CGFloat = 600) {
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
            self.strip = TabStripView(
                frame: NSRect(x: 0, y: 0, width: width, height: TabStripView.height)
            )
            strip.update(tabs: windows, selected: windows[0], width: width)
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
        NSEvent.mouseEvent(
            with: type,
            location: p,
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

    // MARK: - Genuine double-click still renames

    /// The gesture AppKit actually delivers for a double-click on a pill:
    /// down(1), up(1), down(2). The strip saw the whole sequence, so
    /// rename MUST open — the fix must not cost the feature.
    func test_genuineDoubleClick_fullEventSequence_entersRename() {
        let rig = StripRig(tabCount: 3, prefix: "genuine")
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
        let rig = StripRig(tabCount: 3, prefix: "nomouseup")
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
    func test_loneDoubleClickMouseDown_doesNotRename_andSelectsTab() {
        let rig = StripRig(tabCount: 3, prefix: "phantom")
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

        let rig = StripRig(tabCount: 3, prefix: "stale")
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
    /// twice, so nothing may enter rename.
    func test_firstClickOnDifferentPill_doesNotRename() {
        let rig = StripRig(tabCount: 3, prefix: "otherpill")

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

    /// Two windows, two strips. The user clicks a pill in strip A (which
    /// switches windows), then clicks strip B right away. AppKit hands
    /// strip B a `clickCount == 2` mousedown as the very first event that
    /// view instance has ever seen. Strip B must not rename.
    func test_freshStrip_receivingDoubleClickAsItsFirstEvent_doesNotRename() {
        let rigA = StripRig(tabCount: 3, prefix: "winA")
        let rigB = StripRig(tabCount: 3, prefix: "winB")

        // Full click in window A's strip — the system's click sequence
        // now stands at 1.
        click(rigA, pill: 1, clickCount: 1)
        XCTAssertEqual(rigA.selections.count, 1,
                       "precondition: strip A handled an ordinary click")

        // The follow-up click lands in window B's strip, carrying the
        // system's continued count.
        click(rigB, pill: 1, clickCount: 2)

        assertNotRenaming(
            rigB,
            "a strip that never received the first mousedown of the sequence "
                + "must not treat clickCount==2 as its own double-click"
        )
        assertNotRenaming(
            rigA,
            "strip A saw only a single click and must not be renaming either"
        )
        XCTAssertEqual(rigB.selections.count, 1,
                       "strip B's click must act as one ordinary click")
        XCTAssertEqual(rigB.selections.first, rigB.tabs[1],
                       "…selecting the pill the user clicked in window B")
    }

    /// A phantom activation click must not poison the strip's bookkeeping:
    /// the very next genuine double-click still renames. This is what
    /// separates "ignore clicks whose first half we missed" from
    /// "double-click rename is broken after any stray clickCount==2".
    func test_phantomDoubleClick_thenGenuineDoubleClick_stillRenames() {
        let rig = StripRig(tabCount: 3, prefix: "recover")
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
