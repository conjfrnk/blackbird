import XCTest
import AppKit
@testable import Blackbird

/// Integration tests for the `+` (new tab) button's click gate, driving the
/// real `TabStripView.mouseDown(with:)` with synthesized `NSEvent`s.
///
/// The gate is one line — `if clicks == 1 { onAddTab?() }` — but `clicks` is
/// the RENUMBERED count from the shared click-sequence primitive
/// (`TabStripView.effectiveClickCount`, unit-tested in
/// `TabRenameClickSequenceTests`), not `NSEvent.clickCount`. Everything below
/// pins the behaviour that renumbering buys, through the only surface that
/// matters to the user: how many tabs one gesture opens.
///
/// Two failure modes the gate sits between:
///
///  - FIRE TWICE (RCA P2). A fast double-click on `+` must open ONE tab. The
///    raw-count gate got this right on a single strip and wrong across
///    strips: click 1 fires `onAddTab`, the new window becomes key, and
///    click 2 is delivered to the NEW window's strip — a different instance,
///    whose per-view mark was empty, so it fired again and opened a second
///    tab. The shared mark is what closes that hole.
///  - FIRE NEVER. When Blackbird isn't frontmost the activating click is
///    swallowed (`acceptsFirstMouse` is false), so the first mousedown any
///    strip receives already carries `clickCount == 2`. A literal
///    `event.clickCount == 1` gate drops it on the floor and `+` is inert
///    until the user clicks a third time.
///
/// Oracle: the count of `onAddTab` invocations. It is the strip's only
/// new-tab escape hatch (`TitlebarTabBar` wires it to the controller's
/// add-tab action), so the count is exact — and it is summed ACROSS strips
/// wherever a gesture spans two windows.
///
/// Memory + safety budget (`feedback_test_memory_safety`):
///  - ≤ 2 strips and ≤ 5 stub `NSWindow`s (200×100, contentless) per test;
///    never shown, so no backing store is ever allocated. < 300 KB per test.
///  - Stub windows and strips are PARKED for the process lifetime — never
///    shown, never `close()`d, never `orderOut`n
///    (`feedback_tabgroup_test_host_segv`). `tabbingMode = .disallowed` keeps
///    them out of any stray `NSWindowTabGroup` a sibling suite created.
///  - No `MainWindowController`, no PTYs, no real shells.
///  - Wall time < 10 ms per test, except the one test that deliberately waits
///    out a double-click interval.
final class AddTabButtonClickSequenceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // `TabStripView.lastMouseDown` is PROCESS-WIDE static state — shared
    // across every strip on purpose. Every test that drives `mouseDown` must
    // start from a known-empty mark, or a leftover from the previous test
    // decides this one's verdict and the suite passes or fails depending on
    // run order. Clearing on both ends keeps sibling suites clean too.
    override func setUp() {
        super.setUp()
        TabStripView.resetClickSequenceForTesting()
    }

    override func tearDown() {
        TabStripView.resetClickSequenceForTesting()
        super.tearDown()
    }

    // MARK: - Rig

    /// A windowless `TabStripView` over never-shown stub windows, with
    /// `onAddTab` counted.
    ///
    /// NOTE: constructing a rig calls `update(tabs:selected:width:)`, whose
    /// list-shape-change branch CLEARS the shared mark. Every test must
    /// therefore build ALL of its rigs before delivering any mousedown.
    private final class AddRig {
        /// Parked for the process lifetime: never shown, never `close()`d,
        /// never `orderOut`n (`feedback_tabgroup_test_host_segv`).
        private static var parked: [AnyObject] = []

        let strip: TabStripView
        let tabs: [NSWindow]
        private(set) var addCount = 0
        private(set) var selections: [NSWindow] = []

        init(tabCount: Int = 2, prefix: String, width: CGFloat = 600) {
            let windows: [NSWindow] = (0..<tabCount).map { i in
                let w = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                    styleMask: [.titled],
                    backing: .buffered,
                    defer: true
                )
                w.title = "\(prefix)-\(i)"
                // Bare NSWindows created in one test process share a derived
                // tabbing identifier; `.disallowed` stops AppKit folding these
                // stubs into a group a sibling suite left behind (see
                // TabStripDragTests for the full writeup).
                w.tabbingMode = .disallowed
                return w
            }
            self.tabs = windows
            self.strip = TabStripView(
                frame: NSRect(x: 0, y: 0, width: width, height: TabStripView.height)
            )
            strip.update(tabs: windows, selected: windows[0], width: width)
            strip.onAddTab = { [weak self] in self?.addCount += 1 }
            strip.onSelectWindow = { [weak self] w in self?.selections.append(w) }
            AddRig.parked.append(contentsOf: windows as [AnyObject])
            AddRig.parked.append(strip)
        }

        /// Centre of the trailing `+` button in strip-local coordinates.
        var addButtonCenter: NSPoint {
            let f = strip.addButtonFrameForTesting
            return NSPoint(x: f.midX, y: f.midY)
        }

        /// Centre of pill `i` in strip-local coordinates.
        func pillCenter(_ i: Int) -> NSPoint {
            let frames = strip.pillFramesForTesting
            precondition(i < frames.count, "pill \(i) out of range")
            return NSPoint(x: frames[i].midX, y: frames[i].midY)
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            clickCount: Int,
                            timestamp: TimeInterval) -> NSEvent {
        // `p` is a VIEW coordinate (as reported by `addButtonFrameForTesting`),
        // but `NSEvent.location` is a WINDOW coordinate and
        // `TabStripView.mouseDown` converts it through an `isFlipped == true`
        // view — which mirrors y about the strip's height. Pre-mirror so the
        // point a test names is the point the strip actually hit-tests.
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

    /// Deliver one `+` mousedown to `rig`'s strip.
    private func addButtonMouseDown(_ rig: AddRig,
                                    clickCount: Int,
                                    timestamp: TimeInterval) {
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                             at: rig.addButtonCenter,
                                             clickCount: clickCount,
                                             timestamp: timestamp))
    }

    /// Deliver one pill mousedown + mouseup to `rig`'s strip. Used only to
    /// interpose a different click TARGET between two `+` clicks.
    private func pillClick(_ rig: AddRig,
                           pill i: Int,
                           clickCount: Int,
                           timestamp: TimeInterval) {
        let p = rig.pillCenter(i)
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p,
                                             clickCount: clickCount,
                                             timestamp: timestamp))
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p,
                                           clickCount: clickCount,
                                           timestamp: timestamp))
    }

    private func assertAddButtonIsHittable(_ rig: AddRig,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let f = rig.strip.addButtonFrameForTesting
        XCTAssertGreaterThan(f.width, 0,
                             "precondition: the `+` button must have a real frame",
                             file: file, line: line)
        XCTAssertGreaterThan(f.height, 0,
                             "precondition: the `+` button must have a real frame",
                             file: file, line: line)
        // The hit point must belong to the `+` and to no pill, or these tests
        // would be measuring pill clicks.
        let p = rig.addButtonCenter
        XCTAssertFalse(
            rig.strip.pillFramesForTesting.contains { NSPointInRect(p, $0) },
            "precondition: the `+` hit point must not fall inside any pill",
            file: file, line: line)
    }

    /// A gap guaranteed to be INSIDE the live system double-click interval.
    /// Read from `NSEvent.doubleClickInterval` because `mouseDown` reads it
    /// too — a hardcoded 0.1 would be wrong on a machine set to "fast".
    private var quickGap: TimeInterval { NSEvent.doubleClickInterval / 4 }

    // MARK: - The ordinary click

    /// Baseline: one click on `+` opens one tab, and does not select a pill.
    func test_singleClickOnAddButton_opensExactlyOneTab() {
        let rig = AddRig(prefix: "single")
        assertAddButtonIsHittable(rig)
        XCTAssertEqual(rig.addCount, 0, "precondition: no tab opened yet")

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)

        XCTAssertEqual(rig.addCount, 1, "one click on `+` opens one tab")
        XCTAssertEqual(rig.selections.count, 0,
                       "a `+` click must never fall through to pill selection")
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.target, .addButton,
                       "the click is recorded against the `+` target so the "
                           + "next event can be recognised as its continuation")
    }

    // MARK: - RCA P2: one gesture, one tab

    /// A fast double-click on `+` delivered entirely to ONE strip opens
    /// exactly one tab. `clicks` renumbers to [1, 2] and only 1 fires.
    func test_fastDoubleClickOnOneStrip_opensExactlyOneTab() {
        let rig = AddRig(prefix: "fastdouble")
        assertAddButtonIsHittable(rig)

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        addButtonMouseDown(rig, clickCount: 2, timestamp: quickGap)

        XCTAssertEqual(rig.addCount, 1,
                       "a fast double-click on `+` must open one tab, not two")
    }

    /// A triple-click is still one gesture.
    func test_fastTripleClickOnOneStrip_opensExactlyOneTab() {
        let rig = AddRig(prefix: "fasttriple")
        assertAddButtonIsHittable(rig)

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        addButtonMouseDown(rig, clickCount: 2, timestamp: quickGap)
        addButtonMouseDown(rig, clickCount: 3, timestamp: quickGap * 2)

        XCTAssertEqual(rig.addCount, 1,
                       "a triple-click on `+` must still open exactly one tab")
    }

    /// THE DOUBLE-FIRE CASE — the regression the shared mark exists to fix.
    ///
    /// Click 1 lands on the CURRENT window's strip (A) and opens a tab. That
    /// new window becomes key, so click 2 of the same physical double-click
    /// is delivered to the NEW window's strip (B) — a different instance, at
    /// the same screen point, that has never seen a mousedown of its own.
    /// With a per-view mark B saw an empty mark and fired again: one gesture,
    /// two tabs. With the shared mark B sees that a strip already handled
    /// click 1 on `+` within the interval, renumbers to 2, and stays quiet.
    func test_crossStrip_fastDoubleClick_opensExactlyOneTabInTotal() {
        // Both rigs are constructed FIRST: `update(tabs:)` clears the shared
        // mark on a list-shape change, so building B after A's click would
        // wipe the very mark under test.
        let rigA = AddRig(tabCount: 2, prefix: "winA")
        // The destination window's strip already shows the tab that click 1
        // opened, so its `+` sits at a different x — a per-view design cannot
        // use geometry to tell these apart, only the shared run can.
        let rigB = AddRig(tabCount: 3, prefix: "winB")
        assertAddButtonIsHittable(rigA)
        assertAddButtonIsHittable(rigB)

        addButtonMouseDown(rigA, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rigA.addCount, 1,
                       "precondition: click 1 opened a tab on strip A")

        addButtonMouseDown(rigB, clickCount: 2, timestamp: quickGap)

        XCTAssertEqual(rigB.addCount, 0,
                       "strip B must NOT fire: click 2 continues the `+` run a "
                           + "sibling strip already handled")
        XCTAssertEqual(rigA.addCount + rigB.addCount, 1,
                       "one physical double-click on `+` opens exactly one tab, "
                           + "however many strips the events were split across")
    }

    // MARK: - The phantom activation click: `+` must stay live

    /// The strip's first event is a lone `clickCount == 2` with the shared
    /// mark cleared: the activating click was swallowed and NO strip saw it.
    /// It renumbers to 1 and must open a tab — a literal `clickCount == 1`
    /// gate left `+` inert on the click right after coming back to the app.
    func test_loneDoubleClickMouseDown_opensExactlyOneTab() {
        let rig = AddRig(prefix: "phantom")
        assertAddButtonIsHittable(rig)
        XCTAssertNil(TabStripView.lastMouseDownForTesting,
                     "precondition: the shared mark starts cleared")

        addButtonMouseDown(rig, clickCount: 2, timestamp: 0)

        XCTAssertEqual(rig.addCount, 1,
                       "a clickCount==2 whose first half no strip received is "
                           + "the run's first click — it must open one tab")
    }

    /// Both halves of the fix compose: the activation click fires (system
    /// count 2, no mark), and the genuine second click of the user's
    /// double-click (system count 3, a direct continuation of the mark the
    /// activation click left behind) is suppressed. Delivered run [2, 3]
    /// renumbers to [1, 2] → one gesture, one tab.
    func test_activationClickThenItsDoubleClickTail_opensExactlyOneTab() {
        let rig = AddRig(prefix: "phantomdouble")
        assertAddButtonIsHittable(rig)

        addButtonMouseDown(rig, clickCount: 2, timestamp: 0)
        XCTAssertEqual(rig.addCount, 1,
                       "precondition: the post-activation click opened a tab")

        addButtonMouseDown(rig, clickCount: 3, timestamp: quickGap)

        XCTAssertEqual(rig.addCount, 1,
                       "the clickCount==3 tail continues the click this strip "
                           + "just handled → one gesture, one tab")
    }

    /// The same phantom-then-tail stream split across two strips: click 1 is
    /// swallowed by activation, click 2 opens a tab on strip A, click 3 is
    /// delivered to the new window's strip B. Still one tab.
    func test_crossStrip_activationClickThenTail_opensExactlyOneTabInTotal() {
        let rigA = AddRig(tabCount: 2, prefix: "xphantomA")
        let rigB = AddRig(tabCount: 3, prefix: "xphantomB")
        assertAddButtonIsHittable(rigA)
        assertAddButtonIsHittable(rigB)

        addButtonMouseDown(rigA, clickCount: 2, timestamp: 0)
        XCTAssertEqual(rigA.addCount, 1,
                       "precondition: the post-activation click opened a tab")

        addButtonMouseDown(rigB, clickCount: 3, timestamp: quickGap)

        XCTAssertEqual(rigA.addCount + rigB.addCount, 1,
                       "the tail lands on the new window's strip and must not "
                           + "open a second tab")
    }

    // MARK: - Separate gestures still open separate tabs

    /// Two deliberate, unrelated clicks open two tabs. Guards the opposite
    /// failure: a gate that suppressed too eagerly ("never fire twice in a
    /// row") would make `+` feel broken for ordinary use. AppKit reports
    /// `clickCount == 1` for a click too slow to continue the previous one,
    /// and 1 is never renumbered.
    func test_twoDeliberateClicks_openTwoTabs() {
        let rig = AddRig(prefix: "twoclicks")
        assertAddButtonIsHittable(rig)

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rig.addCount, 1, "precondition: the first click fired")
        addButtonMouseDown(rig, clickCount: 1, timestamp: 1.0)

        XCTAssertEqual(rig.addCount, 2,
                       "two clicks that each start their own run open two tabs")
    }

    /// The interval itself is load-bearing, not just the system count: a
    /// second click that arrives with a RISING system count but more than one
    /// double-click interval later is a separate gesture and opens a second
    /// tab.
    ///
    /// The gap is made real in BOTH clocks — the events carry timestamps past
    /// the interval AND the test waits it out on the runloop — so the test
    /// holds whether the strip reads `NSEvent.timestamp` or a wall clock.
    func test_secondClickBeyondInterval_opensASecondTab() throws {
        let interval = NSEvent.doubleClickInterval
        try XCTSkipIf(interval > 1.5,
                      "double-click interval configured absurdly long "
                          + "(\(interval)s); the wait would dominate the suite")

        let rig = AddRig(prefix: "slowpair")
        assertAddButtonIsHittable(rig)

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rig.addCount, 1, "precondition: the first click fired")

        let gap = interval + 0.1
        RunLoop.current.run(until: Date().addingTimeInterval(gap))
        addButtonMouseDown(rig, clickCount: 2, timestamp: gap)

        XCTAssertEqual(rig.addCount, 2,
                       "a click more than one double-click interval later is a "
                           + "new gesture and opens a second tab, even though "
                           + "the system's count kept rising")
    }

    /// A different click TARGET breaks the `+` run: click `+`, click a pill,
    /// then click `+` again quickly. The third click cannot be a continuation
    /// of the first (the pill click is in between), so it opens a tab. A gate
    /// that keyed only on counts and timing — ignoring the target — would
    /// swallow it and make `+` inert right after a tab switch.
    func test_pillClickBetweenAddClicks_breaksTheRun_secondAddFires() {
        let rig = AddRig(tabCount: 2, prefix: "targetbreak")
        assertAddButtonIsHittable(rig)

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rig.addCount, 1, "precondition: the first `+` click fired")

        pillClick(rig, pill: 0, clickCount: 2, timestamp: quickGap)
        XCTAssertEqual(rig.selections, [rig.tabs[0]],
                       "precondition: the interposed pill click selected pill 0")

        addButtonMouseDown(rig, clickCount: 3, timestamp: quickGap * 2)

        XCTAssertEqual(rig.addCount, 2,
                       "the `+` click after a pill click starts a new run and "
                           + "must open a tab")
    }
}
