import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for the `+` (new tab) button's click-sequence gate:
/// `TabStripView.shouldFireAddButton(previous:clickCount:timestamp:
/// doubleClickInterval:)` and its integration through the real
/// `TabStripView.mouseDown(with:)`.
///
/// The bug being pinned (BUG-2): `NSEvent.clickCount` describes the
/// SYSTEM's click sequence, not this view's. When Blackbird isn't
/// frontmost — or a different Blackbird window is key — the activating
/// click is swallowed (`acceptsFirstMouse` is false), so the strip never
/// sees it. The user, seeing nothing happen, clicks `+` again and THAT
/// mousedown arrives carrying `clickCount == 2`. A gate that only fires
/// on `clickCount == 1` therefore drops the click on the floor: the `+`
/// button is inert until the user clicks a third time slowly. The strip
/// must fire on the first click of a sequence AS THIS VIEW SEES IT.
///
/// What must NOT regress: RCA P2 — a fast double-click on `+` opens
/// exactly ONE tab, not two. So a click is suppressed only when it
/// *directly continues* a `+` sequence this view already handled: the
/// previous mark is on `+`, its `clickCount` is exactly one less than
/// this one, and the two are within the double-click interval. Any other
/// shape (no mark, a gap in the counts, a stale mark, an out-of-order
/// mark) is a click this view has not accounted for, and it fires.
///
/// Truth table the predicate must implement (`p` = previous mark,
/// `n` = incoming clickCount, `Δ` = timestamp − p.timestamp,
/// `I` = doubleClickInterval):
///
///     p == nil                            → fire
///     p.clickCount != n − 1               → fire
///     Δ < 0                               → fire   (stale / reordered)
///     Δ > I                               → fire   (separate gesture)
///     p.clickCount == n − 1 && 0 ≤ Δ ≤ I  → SUPPRESS
///
/// Oracles:
///  - pure level ⇢ the predicate's `Bool` return.
///  - integration ⇢ the count of `onAddTab` invocations over a
///    synthesized mousedown stream. `onAddTab` is the strip's only
///    new-tab escape hatch (`TitlebarTabBar` wires it to the
///    controller's add-tab action), so the count is exact.
///
/// Memory + safety budget (`feedback_test_memory_safety`):
///  - The predicate tests allocate nothing beyond a handful of 2-field
///    value-type marks (< 1 KB total).
///  - Integration tests build ≤ 1 strip + 2 stub `NSWindow`s (200×100,
///    contentless, never shown → no backing store) each: < 100 KB per
///    test, < 500 KB for the suite.
///  - Stub windows and strips are PARKED for the process lifetime —
///    never shown, never `close()`d, never `orderOut`n
///    (`feedback_tabgroup_test_host_segv`). `tabbingMode = .disallowed`
///    keeps them out of any stray `NSWindowTabGroup` a sibling suite
///    created.
///  - No `MainWindowController`, no PTYs, no real shells.
///  - Wall time < 10 ms per test; nothing waits on the runloop.
final class AddTabButtonClickSequenceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// A representative system double-click interval. Passed explicitly
    /// so the predicate tests never depend on the developer's or CI
    /// runner's "Double-click speed" setting.
    private let interval: TimeInterval = 0.5

    /// Origin of every predicate scenario's click sequence.
    private let t0: TimeInterval = 100.0

    private func mark(clickCount: Int,
                      at t: TimeInterval) -> TabStripView.AddButtonClickMark {
        TabStripView.AddButtonClickMark(clickCount: clickCount, timestamp: t)
    }

    /// Explicitly typed `nil` — `shouldFireAddButton(previous: nil, …)`
    /// would otherwise be ambiguous at the call site.
    private let noMark: TabStripView.AddButtonClickMark? = nil

    private func shouldFire(previous: TabStripView.AddButtonClickMark?,
                            clickCount: Int,
                            timestamp: TimeInterval,
                            doubleClickInterval: TimeInterval? = nil) -> Bool {
        TabStripView.shouldFireAddButton(
            previous: previous,
            clickCount: clickCount,
            timestamp: timestamp,
            doubleClickInterval: doubleClickInterval ?? interval
        )
    }

    // MARK: - No prior mark → always fires

    /// The ordinary case: app is already frontmost, user clicks `+` once.
    func test_noPreviousMark_clickCountOne_fires() {
        XCTAssertTrue(
            shouldFire(previous: noMark, clickCount: 1, timestamp: t0),
            "the first click of a sequence with no prior `+` mark must open a tab"
        )
    }

    /// THE BUG. The strip's very first event is a `clickCount == 2`
    /// mousedown because AppKit consumed the `clickCount == 1` half
    /// activating the app/window. This view never saw that click, so this
    /// one is the first it has handled — the tab must still open.
    func test_noPreviousMark_clickCountTwo_fires_activationClickBug() {
        XCTAssertTrue(
            shouldFire(previous: noMark, clickCount: 2, timestamp: t0),
            "a clickCount==2 with no prior `+` mark is a click whose first "
                + "half was swallowed by activation — it must still open a tab, "
                + "not leave the `+` button inert"
        )
    }

    /// Same reasoning taken to its limit: any count this view has not
    /// already accounted for fires. A user hammering `+` on an unfocused
    /// window can hand the strip an arbitrarily deep count as its first
    /// event.
    func test_noPreviousMark_clickCountFive_fires() {
        XCTAssertTrue(
            shouldFire(previous: noMark, clickCount: 5, timestamp: t0),
            "any clickCount is a first click when this view holds no `+` mark"
        )
    }

    // MARK: - Direct continuation → suppressed (RCA P2 preserved)

    /// The behaviour the count gate existed for: a fast double-click on
    /// `+` opens exactly ONE tab. The strip handled the `clickCount == 1`
    /// half itself, so the `clickCount == 2` tail is the same gesture.
    func test_directContinuation_secondClickWithinInterval_suppressed() {
        XCTAssertFalse(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 2,
                       timestamp: t0 + 0.1),
            "a fast double-click on `+` must open exactly one tab (RCA P2): "
                + "the clickCount==2 tail of a sequence this view already "
                + "handled is suppressed"
        )
    }

    /// Triple-click is the same gesture continued once more; still one tab.
    func test_directContinuation_thirdClickWithinInterval_suppressed() {
        XCTAssertFalse(
            shouldFire(previous: mark(clickCount: 2, at: t0),
                       clickCount: 3,
                       timestamp: t0 + 0.1),
            "a triple-click on `+` must still open exactly one tab"
        )
    }

    /// Zero elapsed is the tightest possible continuation — the interval
    /// test is `0 ≤ Δ`, not `0 < Δ`.
    func test_directContinuation_zeroElapsed_suppressed() {
        XCTAssertFalse(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 2,
                       timestamp: t0),
            "two events sharing a timestamp are one gesture → suppressed"
        )
    }

    // MARK: - Boundary

    /// Inclusive upper bound, matching `isOwnDoubleClick`'s boundary: a
    /// second click landing exactly one interval later is still one
    /// gesture. Pinned so the two gates can't drift apart on the edge.
    func test_directContinuation_elapsedExactlyAtInterval_suppressed() {
        XCTAssertFalse(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 2,
                       timestamp: t0 + interval),
            "elapsed exactly == doubleClickInterval is still one gesture "
                + "(inclusive boundary, matching isOwnDoubleClick)"
        )
    }

    // MARK: - Not a direct continuation → fires

    /// Too slow to be one gesture. The user genuinely clicked twice and
    /// wants two tabs — which is also what happens today, where a slow
    /// second click arrives with `clickCount == 1` and fires.
    func test_secondClickBeyondInterval_fires() {
        XCTAssertTrue(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 2,
                       timestamp: t0 + 0.9),
            "0.9s after the first click with a 0.5s interval is a second "
                + "deliberate click → a second tab"
        )
    }

    /// A gap in the counts THIS view saw: it handled click 1, then the
    /// next event it receives is click 3 (click 2 went somewhere else —
    /// another window's strip, or was swallowed). Click 2 was never
    /// accounted for here, so click 3 is not a direct continuation.
    func test_countGapInSequence_fires() {
        XCTAssertTrue(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 3,
                       timestamp: t0 + 0.1),
            "clickCount jumped 1 → 3: the intervening click was never handled "
                + "by this view, so this is not a continuation it may swallow"
        )
    }

    /// A stale / out-of-order mark (synthesized or reordered events) must
    /// never suppress a real click: suppression requires a COHERENT
    /// continuation, and a mark that post-dates the incoming event isn't
    /// part of this gesture.
    func test_negativeElapsed_fires() {
        XCTAssertTrue(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 2,
                       timestamp: t0 - 0.1),
            "a mark that post-dates the incoming click is stale — it must not "
                + "suppress a click the user really made"
        )
    }

    /// A fresh `clickCount == 1` always fires: no mark can be one less
    /// than 1, so the "direct continuation" test can never match it.
    /// This is repeated slow clicking on `+` → one tab per click.
    func test_freshClickCountOne_afterEarlierMark_fires() {
        XCTAssertTrue(
            shouldFire(previous: mark(clickCount: 1, at: t0),
                       clickCount: 1,
                       timestamp: t0 + 0.1),
            "a clickCount==1 starts a new sequence and always opens a tab"
        )
    }

    // MARK: - The interval parameter is actually consulted

    /// Guards against an implementation that ignores the injected
    /// interval and reads `NSEvent.doubleClickInterval` (or a hardcoded
    /// constant) internally: identical marks and counts, only the
    /// interval differs, and the verdict must flip.
    func test_intervalParameterDecidesVerdict() {
        let previous = mark(clickCount: 1, at: t0)
        let clickAt = t0 + 0.5

        XCTAssertFalse(
            shouldFire(previous: previous, clickCount: 2,
                       timestamp: clickAt, doubleClickInterval: 1.0),
            "0.5s elapsed is inside a 1.0s interval → one gesture → suppressed"
        )
        XCTAssertTrue(
            shouldFire(previous: previous, clickCount: 2,
                       timestamp: clickAt, doubleClickInterval: 0.125),
            "the same 0.5s elapsed is outside a 0.125s interval → two gestures "
                + "→ fires"
        )
    }

    /// A zero interval means only simultaneous events form one gesture.
    func test_zeroInterval_suppressesOnlyZeroElapsed() {
        XCTAssertFalse(
            shouldFire(previous: mark(clickCount: 1, at: t0), clickCount: 2,
                       timestamp: t0, doubleClickInterval: 0),
            "zero elapsed is within a zero interval (inclusive) → suppressed"
        )
        XCTAssertTrue(
            shouldFire(previous: mark(clickCount: 1, at: t0), clickCount: 2,
                       timestamp: t0 + 0.001, doubleClickInterval: 0),
            "any positive elapsed exceeds a zero interval → fires"
        )
    }

    // MARK: - AddButtonClickMark value semantics

    /// The mark is a pure `Equatable` value over exactly its two fields —
    /// the strip stores and replaces it, never mutates it.
    func test_addButtonClickMark_equality() {
        let a = mark(clickCount: 2, at: t0)
        XCTAssertEqual(a, mark(clickCount: 2, at: t0),
                       "same clickCount + timestamp → equal")
        XCTAssertNotEqual(a, mark(clickCount: 1, at: t0),
                          "differing clickCount → not equal")
        XCTAssertNotEqual(a, mark(clickCount: 2, at: t0 + 0.001),
                          "differing timestamp → not equal")
        XCTAssertEqual(a.clickCount, 2, "clickCount is stored verbatim")
        XCTAssertEqual(a.timestamp, t0, "timestamp is stored verbatim")
    }

    // MARK: - Integration rig

    /// A windowless `TabStripView` over never-shown stub windows, with
    /// `onAddTab` counted.
    private final class AddRig {
        /// Parked for the process lifetime: never shown, never closed,
        /// never ordered out (`feedback_tabgroup_test_host_segv`).
        private static var parked: [AnyObject] = []

        let strip: TabStripView
        let tabs: [NSWindow]
        private(set) var addCount = 0

        init(tabCount: Int = 2, prefix: String, width: CGFloat = 600) {
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
            strip.onAddTab = { [weak self] in self?.addCount += 1 }
            AddRig.parked.append(contentsOf: windows as [AnyObject])
            AddRig.parked.append(strip)
        }

        /// Centre of the trailing `+` button in strip-local coordinates.
        var addButtonCenter: NSPoint {
            let f = strip.addButtonFrameForTesting
            return NSPoint(x: f.midX, y: f.midY)
        }
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            clickCount: Int,
                            timestamp: TimeInterval) -> NSEvent {
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

    /// Deliver one `+` mousedown to the strip.
    private func addButtonMouseDown(_ rig: AddRig,
                                    clickCount: Int,
                                    timestamp: TimeInterval) {
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                             at: rig.addButtonCenter,
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
        // The hit point must belong to the `+` and to no pill, or the
        // integration tests would be measuring pill clicks.
        let p = rig.addButtonCenter
        XCTAssertFalse(
            rig.strip.pillFramesForTesting.contains { NSPointInRect(p, $0) },
            "precondition: the `+` hit point must not fall inside any pill",
            file: file, line: line)
    }

    // MARK: - Integration: real mouseDown → onAddTab count

    /// RCA P2, end to end: the full fast-double-click event stream on
    /// `+` — down(1) then down(2), 0.1 s apart — opens exactly ONE tab.
    func test_integration_fastDoubleClickOnAddButton_opensExactlyOneTab() {
        let rig = AddRig(prefix: "fastdouble")
        assertAddButtonIsHittable(rig)
        XCTAssertEqual(rig.addCount, 0, "precondition: no tab opened yet")

        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        addButtonMouseDown(rig, clickCount: 2, timestamp: 0.1)

        XCTAssertEqual(
            rig.addCount, 1,
            "a fast double-click on `+` this strip saw in full must open one "
                + "tab, not two"
        )
    }

    /// THE REGRESSION TEST. The strip's FIRST event is a lone
    /// `clickCount == 2` mousedown: AppKit swallowed the first click
    /// activating the app/window, so this view never saw it. Pre-fix the
    /// gate (`clickCount == 1`) dropped this on the floor and the `+`
    /// button did nothing — the user had to click a third time.
    func test_integration_loneDoubleClickMouseDown_opensExactlyOneTab() {
        let rig = AddRig(prefix: "phantom")
        assertAddButtonIsHittable(rig)
        XCTAssertEqual(rig.addCount, 0, "precondition: no tab opened yet")

        addButtonMouseDown(rig, clickCount: 2, timestamp: 0)

        XCTAssertEqual(
            rig.addCount, 1,
            "a clickCount==2 mousedown that is this strip's first event is a "
                + "post-activation click — it must open exactly one tab "
                + "(pre-fix it opened zero)"
        )
    }

    /// The two halves of the fix must compose: an activation click fires
    /// (count 2, no mark), and the genuine second click of the user's
    /// double-click (count 3, a direct continuation of the mark the
    /// activation click left behind) is suppressed. One gesture, one tab.
    func test_integration_activationClickThenItsDoubleClickTail_opensOneTab() {
        let rig = AddRig(prefix: "phantomdouble")
        assertAddButtonIsHittable(rig)

        // The click that reached the strip after activation swallowed the
        // first one.
        addButtonMouseDown(rig, clickCount: 2, timestamp: 0)
        XCTAssertEqual(rig.addCount, 1,
                       "precondition: the post-activation click opened a tab")

        // The user was actually double-clicking; the tail arrives here too.
        addButtonMouseDown(rig, clickCount: 3, timestamp: 0.1)

        XCTAssertEqual(
            rig.addCount, 1,
            "the clickCount==3 tail directly continues the clickCount==2 click "
                + "this strip just handled → one gesture, one tab"
        )
    }

    /// Two deliberate, separated clicks on `+` open two tabs. Guards the
    /// opposite failure: a fix that suppressed too eagerly (e.g. "never
    /// fire twice in a row") would make `+` feel broken for normal use.
    func test_integration_twoSeparatedClicks_openTwoTabs() {
        let rig = AddRig(prefix: "twoclicks")
        assertAddButtonIsHittable(rig)

        // Two starts-of-sequence: AppKit reports `clickCount == 1` for a
        // click that is too slow to continue the previous one. Neither can
        // ever be a direct continuation (no mark's count is one less than
        // 1), so both fire — under either an event-timestamp or a
        // wall-clock reading of the mark.
        addButtonMouseDown(rig, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rig.addCount, 1, "precondition: the first click opened a tab")
        addButtonMouseDown(rig, clickCount: 1, timestamp: 1.0)

        XCTAssertEqual(
            rig.addCount, 2,
            "two deliberate clicks separated by more than one double-click "
                + "interval must open two tabs"
        )
    }
}
