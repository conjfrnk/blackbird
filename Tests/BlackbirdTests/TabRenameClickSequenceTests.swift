import XCTest
import AppKit
@testable import Blackbird

/// Tests for the tab strip's click-renumbering primitive
/// (`TabStripView.effectiveClickCount(previous:target:clickCount:timestamp:
/// doubleClickInterval:)`) and for the rename gate that reads it, driving the
/// real `TabStripView.mouseDown(with:)` with synthesized `NSEvent`s.
///
/// Why the primitive exists. `NSEvent.clickCount` counts the SYSTEM's click
/// sequence, not any one view's. AppKit keeps counting across window- and
/// app-activation boundaries, and it counts clicks that were never delivered
/// to a strip at all: when Blackbird isn't frontmost the activating click is
/// swallowed (`acceptsFirstMouse` is false), so the user's NEXT click already
/// arrives carrying `clickCount == 2`. Trusting the raw count pops the rename
/// field open when the user only meant to come back to the app and pick a tab.
///
/// Why the mark is SHARED across strips rather than per-view. Every tab is its
/// own `NSWindow` with its own `TabStripView` instance, and both selecting a
/// pill and opening a tab make a DIFFERENT window key. So the two halves of
/// ONE user gesture are routinely delivered to TWO different strip instances,
/// at the same screen point. A per-view mark cannot see the first half, which
/// broke two gestures at once — a fast double-click on `+` opened two tabs,
/// and double-clicking a BACKGROUND pill to rename it was refused. Sharing is
/// exactly what distinguishes the two look-alike event streams: for a genuine
/// background-pill double-click SOME strip saw click 1, whereas for the
/// phantom activation click NO strip did.
///
/// The renumbering contract (`p` = previous mark, `n` = raw `clickCount`,
/// `Δ` = `timestamp − p.timestamp`, `I` = `doubleClickInterval`):
///
///     n <= 1                                      → n           (unchanged)
///     p != nil && p.target == target
///        && p.systemClickCount == n − 1
///        && 0 <= Δ <= I                           → p.effectiveClickCount + 1
///     otherwise                                   → 1
///
/// Oracles:
///  - pure level ⇢ the `Int` the primitive returns, folded over a run of
///    mousedowns exactly the way `mouseDown` folds it (renumber, then record
///    a mark carrying BOTH counts).
///  - integration ⇢ `isEditingForTesting` for "rename began",
///    `commitEditIfNeeded()` → `onCommitRename` for "the edit is real and
///    targets that window", `onSelectWindow` for "ordinary click", and
///    `pendingDragPillIndexForTesting` for "a reorder drag was armed".
///
/// Memory + safety budget (`feedback_test_memory_safety`):
///  - ≤ 2 strips and ≤ 7 stub `NSWindow`s (200×100, contentless) per test;
///    never shown, so no backing store is ever allocated. < 400 KB per test.
///  - Stub windows and strips are PARKED for the process lifetime — never
///    shown, never `close()`d, never `orderOut`n
///    (`feedback_tabgroup_test_host_segv`). `tabbingMode = .disallowed` keeps
///    them out of any stray `NSWindowTabGroup` a sibling suite created.
///  - No `MainWindowController`, no PTYs, no real shells.
///  - Wall time < 20 ms per test; nothing here waits on the runloop.
final class TabRenameClickSequenceTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // `TabStripView.lastMouseDown` is PROCESS-WIDE static state — that is the
    // whole point of the redesign. Every test that drives `mouseDown` (or
    // inspects the shared mark) must therefore start from a known-empty mark,
    // or a leftover from the previous test decides this one's verdict and the
    // suite passes or fails depending on run order. Clearing on both ends
    // keeps sibling suites clean too.
    override func setUp() {
        super.setUp()
        TabStripView.resetClickSequenceForTesting()
    }

    override func tearDown() {
        TabStripView.resetClickSequenceForTesting()
        super.tearDown()
    }

    // MARK: - Pure fixtures

    /// The double-click interval used by the pure tests. 0.5 is exactly
    /// representable in binary floating point, as are all the offsets below
    /// (0.125, 0.25, 0.5), so the boundary cases compare exact values — no
    /// epsilon slop can accidentally decide an outcome.
    private let interval: TimeInterval = 0.5

    /// An arbitrary non-zero base timestamp: non-zero so a "click earlier
    /// than the mark" case can be expressed without going negative, and so an
    /// implementation that confuses `timestamp` with "elapsed since previous"
    /// is caught.
    private let base: TimeInterval = 100.0

    private func mark(_ target: TabStripView.ClickTarget,
                      sys: Int,
                      effective: Int,
                      at t: TimeInterval) -> TabStripView.ClickSequenceMark {
        TabStripView.ClickSequenceMark(target: target,
                                       systemClickCount: sys,
                                       effectiveClickCount: effective,
                                       timestamp: t)
    }

    private func renumber(previous: TabStripView.ClickSequenceMark?,
                          _ target: TabStripView.ClickTarget,
                          sys: Int,
                          at t: TimeInterval,
                          doubleClickInterval: TimeInterval? = nil) -> Int {
        TabStripView.effectiveClickCount(
            previous: previous,
            target: target,
            clickCount: sys,
            timestamp: t,
            doubleClickInterval: doubleClickInterval ?? interval)
    }

    /// Fold a run of mousedowns THE STRIPS RECEIVED through the primitive
    /// exactly as `mouseDown` does — renumber, then record a mark carrying
    /// both the raw and the assigned count — and return the effective count
    /// assigned to each event in order.
    ///
    /// This is the honest oracle for "delivered run sys [a, b] → effective
    /// [x, y]": the recorded mark's `effectiveClickCount` is what the NEXT
    /// event builds on, so a chain can only be verified by chaining.
    private func effectiveRun(
        _ events: [(target: TabStripView.ClickTarget, sys: Int, at: TimeInterval)],
        doubleClickInterval: TimeInterval? = nil
    ) -> [Int] {
        var previous: TabStripView.ClickSequenceMark?
        var effective: [Int] = []
        for e in events {
            let n = TabStripView.effectiveClickCount(
                previous: previous,
                target: e.target,
                clickCount: e.sys,
                timestamp: e.at,
                doubleClickInterval: doubleClickInterval ?? interval)
            effective.append(n)
            previous = TabStripView.ClickSequenceMark(target: e.target,
                                                      systemClickCount: e.sys,
                                                      effectiveClickCount: n,
                                                      timestamp: e.at)
        }
        return effective
    }

    // MARK: - Pure: a run the strips saw in full keeps its ordinals

    /// The ordinary double-click: both halves were delivered, so the raw
    /// counts and the renumbered counts agree.
    func test_deliveredRun_oneThenTwo_renumbersToOneTwo() {
        XCTAssertEqual(
            effectiveRun([(target: .pill(1), sys: 1, at: base),
                          (target: .pill(1), sys: 2, at: base + 0.125)]),
            [1, 2],
            "a run the strips received in full keeps the system's ordinals")
    }

    /// Triple-click: the run keeps counting as long as each event directly
    /// continues the last one.
    func test_deliveredRun_oneTwoThree_renumbersToOneTwoThree() {
        XCTAssertEqual(
            effectiveRun([(target: .pill(1), sys: 1, at: base),
                          (target: .pill(1), sys: 2, at: base + 0.125),
                          (target: .pill(1), sys: 3, at: base + 0.25)]),
            [1, 2, 3],
            "a fully-delivered triple-click renumbers to 1, 2, 3")
    }

    /// Same run on the `+` button. The target is what makes a run a run; the
    /// arithmetic is identical for `.addButton`.
    func test_deliveredRun_onAddButton_renumbersToOneTwo() {
        XCTAssertEqual(
            effectiveRun([(target: .addButton, sys: 1, at: base),
                          (target: .addButton, sys: 2, at: base + 0.1)]),
            [1, 2],
            "`+` runs renumber by the same rule as pill runs")
    }

    // MARK: - Pure: the phantom activation click

    /// THE ACTIVATION CLICK. No strip in the process has seen a mousedown, so
    /// the mark is nil — yet the window server hands the first delivered event
    /// `clickCount == 2`. It must be renumbered to 1: as far as the strips are
    /// concerned this is the opening click of a gesture.
    func test_phantomActivationClick_nilPrevious_renumbersToOne() {
        XCTAssertEqual(
            renumber(previous: nil, .pill(0), sys: 2, at: base), 1,
            "a clickCount==2 no strip has a mark for is the run's FIRST click")
    }

    /// The nil-mark restart cannot depend on the target, the timestamp, or how
    /// deep the system's count already is — a process whose strips have seen
    /// nothing has no run to continue anywhere.
    func test_phantomActivationClick_restartsForEveryTargetCountAndTime() {
        let targets: [TabStripView.ClickTarget] = [.pill(0), .pill(3), .addButton]
        for target in targets {
            for sys in [2, 3, 5, 9] {
                for t in [0.0, base, base + 10 * interval] {
                    XCTAssertEqual(
                        renumber(previous: nil, target, sys: sys, at: t), 1,
                        "nil mark, target \(target), sys \(sys), t=\(t) → 1")
                }
            }
        }
    }

    /// THE IMPORTANT ONE. The activation click was swallowed, so the first
    /// event any strip receives carries `clickCount == 2`; the user was really
    /// double-clicking, so the tail arrives as `clickCount == 3`. Delivered run
    /// [2, 3] must renumber to [1, 2] — the gesture the user actually made,
    /// with rename opening on the second delivered click and not the first.
    ///
    /// This is what a naive `clickCount == 2` gate gets exactly backwards: it
    /// renames on the phantom and ignores the real second click.
    func test_phantomThenGenuineDoubleClick_sysTwoThree_renumbersToOneTwo() {
        XCTAssertEqual(
            effectiveRun([(target: .pill(2), sys: 2, at: base),
                          (target: .pill(2), sys: 3, at: base + 0.125)]),
            [1, 2],
            "delivered run [2, 3] is the user's first-and-second click → [1, 2]")
    }

    // MARK: - Pure: the target is part of the run

    /// Two clicks on two different pills are two gestures, however fast. The
    /// second must restart at 1 (it selects pill 1; it does not rename it).
    func test_differentPillTarget_breaksTheRun() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(0), sys: 1, effective: 1, at: base),
                     .pill(1), sys: 2, at: base + 0.125),
            1,
            "a mark on pill 0 cannot continue into a click on pill 1")
    }

    /// A pill click followed by a `+` click is likewise two gestures — the
    /// `+` press must be treated as the first click of its own run, or the
    /// button goes inert right after a tab switch.
    func test_pillThenAddButton_breaksTheRun() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(0), sys: 1, effective: 1, at: base),
                     .addButton, sys: 2, at: base + 0.125),
            1,
            "a pill mark cannot continue into a `+` click")
    }

    /// …and symmetrically.
    func test_addButtonThenPill_breaksTheRun() {
        XCTAssertEqual(
            renumber(previous: mark(.addButton, sys: 1, effective: 1, at: base),
                     .pill(0), sys: 2, at: base + 0.125),
            1,
            "a `+` mark cannot continue into a pill click")
    }

    /// The same pill INDEX is the same target even though the mark was left by
    /// a different strip instance: `.pill(2)` on window A's strip and
    /// `.pill(2)` on window B's strip are the same tab position, which is what
    /// the user sees and clicks twice.
    func test_samePillIndex_isTheSameTarget_runContinues() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(2), sys: 1, effective: 1, at: base),
                     .pill(2), sys: 2, at: base + 0.125),
            2,
            "same pill index → same target → the run continues to 2")
    }

    /// Full target matrix: the run continues on the diagonal and restarts
    /// everywhere else. Catches an implementation that dropped the target
    /// comparison (all-2) as well as one that compares the wrong pair.
    func test_targetMatrix_continuesOnlyOnMatchingTarget() {
        let targets: [TabStripView.ClickTarget] =
            [.pill(0), .pill(1), .pill(2), .addButton]
        for marked in targets {
            for clicked in targets {
                let n = renumber(
                    previous: mark(marked, sys: 1, effective: 1, at: base),
                    clicked, sys: 2, at: base + 0.125)
                XCTAssertEqual(
                    n, marked == clicked ? 2 : 1,
                    "mark on \(marked), click on \(clicked)")
            }
        }
    }

    // MARK: - Pure: the system sequence must be contiguous

    /// The strips handled click 1, and the next event they receive is click 3
    /// — click 2 went somewhere else entirely. The run they saw is not
    /// contiguous, so this event opens a fresh one.
    func test_gapInSystemSequence_restartsAtOne() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(1), sys: 1, effective: 1, at: base),
                     .pill(1), sys: 3, at: base + 0.125),
            1,
            "system counts 1 → 3 skip a click no strip handled → restart")
    }

    /// Any non-contiguous step restarts, in either direction.
    func test_nonContiguousSystemCounts_allRestart() {
        for sys in [2, 3, 5, 7] {
            XCTAssertEqual(
                renumber(previous: mark(.pill(1), sys: 3, effective: 2, at: base),
                         .pill(1), sys: sys, at: base + 0.125),
                1,
                "a mark at system count 3 continues only into 4, not \(sys)")
        }
        // Control: the contiguous step really does continue, so the loop above
        // is rejecting on contiguity and not on some other input.
        XCTAssertEqual(
            renumber(previous: mark(.pill(1), sys: 3, effective: 2, at: base),
                     .pill(1), sys: 4, at: base + 0.125),
            3,
            "control: system 3 → 4 continues, and builds on the EFFECTIVE 2")
    }

    /// The continuation builds on the mark's `effectiveClickCount`, not on the
    /// raw system count — that is the whole point of carrying two numbers. A
    /// phantom-restarted run at system count 5 whose effective count is 1
    /// continues to 2, not to 6.
    func test_continuationBuildsOnEffectiveCountNotSystemCount() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(1), sys: 5, effective: 1, at: base),
                     .pill(1), sys: 6, at: base + 0.125),
            2,
            "the next ordinal is effectiveClickCount + 1, not systemClickCount + 1")
    }

    // MARK: - Pure: elapsed vs the interval

    /// Two clicks too far apart are two gestures.
    func test_elapsedBeyondInterval_restartsAtOne() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(1), sys: 1, effective: 1, at: base),
                     .pill(1), sys: 2, at: base + interval + 0.001),
            1,
            "elapsed just past the interval starts a new run")
    }

    /// The upper bound is INCLUSIVE. `base` (100.0) and `interval` (0.5) are
    /// both exactly representable, so `(base + interval) − base == interval`
    /// holds bit-exactly and this really is the boundary, not a near-miss.
    func test_elapsedExactlyAtInterval_continuesRun() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(1), sys: 1, effective: 1, at: base),
                     .pill(1), sys: 2, at: base + interval),
            2,
            "elapsed exactly == the interval still continues (inclusive bound)")
    }

    /// Zero elapsed is the tightest continuation — the lower bound is
    /// `0 <= Δ`, not `0 < Δ`. Synthesized events routinely share a timestamp.
    func test_zeroElapsed_continuesRun() {
        XCTAssertEqual(
            renumber(previous: mark(.pill(1), sys: 1, effective: 1, at: base),
                     .pill(1), sys: 2, at: base),
            2,
            "two events sharing a timestamp are 0 elapsed → one run")
    }

    /// A mousedown timestamped BEFORE the mark cannot be that mark's follow-up.
    /// An `abs(Δ) <= interval` implementation would wrongly accept it.
    func test_negativeElapsed_restartsAtOne() {
        for backwards in [0.001, 0.125, interval, interval + 0.001, 60.0] {
            XCTAssertEqual(
                renumber(previous: mark(.pill(1), sys: 1, effective: 1, at: base),
                         .pill(1), sys: 2, at: base - backwards),
                1,
                "a click \(backwards)s BEFORE the mark cannot continue it")
        }
    }

    /// The `doubleClickInterval` PARAMETER must actually be consulted: one
    /// fixed elapsed time flips the verdict as the interval moves around it.
    /// Catches an implementation that ignores the argument and reads
    /// `NSEvent.doubleClickInterval` (or a constant) internally — which would
    /// make the primitive untestable and silently ignore the user's system
    /// setting.
    func test_intervalParameterIsConsulted() {
        let previous = mark(.pill(1), sys: 1, effective: 1, at: base)
        let elapsed: TimeInterval = 0.25
        XCTAssertEqual(
            renumber(previous: previous, .pill(1), sys: 2,
                     at: base + elapsed, doubleClickInterval: 1.0),
            2,
            "0.25s elapsed is inside a 1.0s interval → the run continues")
        XCTAssertEqual(
            renumber(previous: previous, .pill(1), sys: 2,
                     at: base + elapsed, doubleClickInterval: 0.125),
            1,
            "the same 0.25s elapsed is outside a 0.125s interval → restart")
    }

    /// A zero interval admits only simultaneous events. Degenerate, but it
    /// pins the direction of the inclusive bound at the extreme.
    func test_zeroInterval_continuesOnlyOnZeroElapsed() {
        let previous = mark(.pill(3), sys: 1, effective: 1, at: base)
        XCTAssertEqual(
            renumber(previous: previous, .pill(3), sys: 2, at: base,
                     doubleClickInterval: 0),
            2,
            "0 elapsed within a 0 interval is still inclusive → continues")
        XCTAssertEqual(
            renumber(previous: previous, .pill(3), sys: 2, at: base + 0.001,
                     doubleClickInterval: 0),
            1,
            "any positive elapsed exceeds a 0 interval → restart")
    }

    // MARK: - Pure: counts at or below 1 pass through untouched

    /// 1 already starts a gesture; it is returned unchanged rather than
    /// "restarted", and no prior mark can promote it.
    func test_clickCountOne_passesThroughUnchanged() {
        XCTAssertEqual(
            renumber(previous: nil, .pill(0), sys: 1, at: base), 1,
            "clickCount 1 with no mark is 1")
        XCTAssertEqual(
            renumber(previous: mark(.pill(0), sys: 1, effective: 1, at: base),
                     .pill(0), sys: 1, at: base + 0.01),
            1,
            "clickCount 1 stays 1 even directly after a mark on the same target")
        XCTAssertEqual(
            renumber(previous: mark(.pill(0), sys: 0, effective: 0, at: base),
                     .pill(0), sys: 1, at: base + 0.01),
            1,
            "a mark whose count is 0 cannot promote a 1 into a 2")
    }

    /// 0 and negatives are synthesized values no caller should see rewritten:
    /// they pass through verbatim, NOT normalized to 1. A gate reading
    /// `clicks == 1` must not fire for them.
    func test_clickCountZeroAndNegative_passThroughUnchanged() {
        for sys in [0, -1, -7] {
            XCTAssertEqual(
                renumber(previous: nil, .pill(0), sys: sys, at: base), sys,
                "clickCount \(sys) passes through untouched with no mark")
            XCTAssertEqual(
                renumber(previous: mark(.pill(0), sys: sys - 1, effective: 1, at: base),
                         .pill(0), sys: sys, at: base + 0.01),
                sys,
                "clickCount \(sys) passes through untouched even with a "
                    + "contiguous mark — the guard is on the count, not the mark")
        }
    }

    // MARK: - Pure: purity

    /// The primitive is static and pure: same inputs, same answer, no hidden
    /// state accumulating across calls (a first-call-only latch would be a
    /// real hazard, since `mouseDown` evaluates this on every event).
    func test_primitiveIsPure_repeatedCallsAgree() {
        let previous = mark(.pill(1), sys: 1, effective: 1, at: base)
        var continuations: [Int] = []
        var restarts: [Int] = []
        for _ in 0..<8 {
            continuations.append(
                renumber(previous: previous, .pill(1), sys: 2, at: base + 0.125))
            restarts.append(
                renumber(previous: nil, .pill(1), sys: 2, at: base + 0.125))
        }
        XCTAssertEqual(continuations, Array(repeating: 2, count: 8),
                       "the continuation tuple answers 2 on every call")
        XCTAssertEqual(restarts, Array(repeating: 1, count: 8),
                       "the nil-mark tuple answers 1 on every call")
    }

    // MARK: - Pure: value semantics

    /// `ClickTarget` equality is part of the contract — it is what decides
    /// whether a run continues.
    func test_clickTarget_equality() {
        XCTAssertEqual(TabStripView.ClickTarget.pill(2),
                       TabStripView.ClickTarget.pill(2),
                       "same pill index → equal targets")
        XCTAssertNotEqual(TabStripView.ClickTarget.pill(2),
                          TabStripView.ClickTarget.pill(3),
                          "different pill index → different targets")
        XCTAssertNotEqual(TabStripView.ClickTarget.pill(0),
                          TabStripView.ClickTarget.addButton,
                          "a pill is never the `+` button")
        XCTAssertEqual(TabStripView.ClickTarget.addButton,
                       TabStripView.ClickTarget.addButton,
                       "`+` equals `+`")
    }

    /// The mark is a value over exactly its four fields, and it stores what it
    /// was handed — the two counts are deliberately distinct, so a struct that
    /// collapsed them would break the phantom-run arithmetic above.
    func test_clickSequenceMark_equalsFieldWise() {
        let a = mark(.pill(1), sys: 2, effective: 1, at: base)
        XCTAssertEqual(a, mark(.pill(1), sys: 2, effective: 1, at: base),
                       "identical field values compare equal")
        XCTAssertNotEqual(a, mark(.pill(2), sys: 2, effective: 1, at: base),
                          "a different target compares unequal")
        XCTAssertNotEqual(a, mark(.pill(1), sys: 3, effective: 1, at: base),
                          "a different systemClickCount compares unequal")
        XCTAssertNotEqual(a, mark(.pill(1), sys: 2, effective: 2, at: base),
                          "a different effectiveClickCount compares unequal")
        XCTAssertNotEqual(a, mark(.pill(1), sys: 2, effective: 1, at: base + 0.25),
                          "a different timestamp compares unequal")

        XCTAssertEqual(a.target, .pill(1))
        XCTAssertEqual(a.systemClickCount, 2)
        XCTAssertEqual(a.effectiveClickCount, 1)
        XCTAssertEqual(a.timestamp, base, accuracy: 0)
    }

    // MARK: - Integration rig

    /// A windowless `TabStripView` over `tabCount` never-shown stub windows,
    /// with the strip's callbacks recorded.
    ///
    /// NOTE: constructing a rig calls `update(tabs:selected:width:)`, whose
    /// list-shape-change branch CLEARS the shared mark. Every test must
    /// therefore build ALL of its rigs before delivering any mousedown.
    private final class StripRig {
        /// Parked for the process lifetime: never shown, never `close()`d,
        /// never `orderOut`n (`feedback_tabgroup_test_host_segv`).
        private static var parked: [AnyObject] = []

        let strip: TabStripView
        let tabs: [NSWindow]
        private(set) var selections: [NSWindow] = []
        private(set) var closes: [NSWindow] = []
        private(set) var renameCommits: [(window: NSWindow, title: String)] = []

        init(tabCount: Int, prefix: String, width: CGFloat = 600) {
            let windows = StripRig.makeStubWindows(tabCount, prefix: prefix)
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
            // `makeStubWindows` already parked the windows.
            StripRig.parked.append(strip)
        }

        /// Pill index armed for a potential reorder drag, or `nil`.
        var pendingDragIndex: Int? { strip.pendingDragPillIndexForTesting }

        /// Extra stub windows for list-shape-change tests. Also parked.
        static func makeStubWindows(_ count: Int, prefix: String) -> [NSWindow] {
            let windows: [NSWindow] = (0..<count).map { i in
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
            parked.append(contentsOf: windows as [AnyObject])
            return windows
        }

        /// `true` while a pill is in inline-rename mode.
        var isRenaming: Bool { strip.isEditingForTesting }

        /// Centre of pill `i` in strip-local coordinates. Horizontally centred,
        /// so it is nowhere near the leading close hotspot (whose centre sits
        /// 13pt inside the pill's left edge).
        func pillCenter(_ i: Int) -> NSPoint {
            let frames = strip.pillFramesForTesting
            precondition(i < frames.count, "pill \(i) out of range")
            return NSPoint(x: frames[i].midX, y: frames[i].midY)
        }

        /// Leading close hotspot of pill `i`: the 14pt circle 6pt inside the
        /// pill's left edge, so its centre is at `minX + 13`.
        func pillCloseHotspot(_ i: Int) -> NSPoint {
            let frames = strip.pillFramesForTesting
            precondition(i < frames.count, "pill \(i) out of range")
            return NSPoint(x: frames[i].minX + 13, y: frames[i].midY)
        }
    }

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

    /// One mousedown on pill `i` of `rig`'s strip.
    private func pillMouseDown(_ rig: StripRig,
                               pill i: Int,
                               clickCount: Int,
                               timestamp: TimeInterval = 0) {
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                             at: rig.pillCenter(i),
                                             clickCount: clickCount,
                                             timestamp: timestamp))
    }

    /// The trailing mouseup of a click on pill `i`. Selection for a
    /// single-click press is DEFERRED to mouseup (the armed-drag path), so a
    /// test that asserts on `onSelectWindow` has to deliver it.
    private func pillMouseUp(_ rig: StripRig,
                             pill i: Int,
                             clickCount: Int,
                             timestamp: TimeInterval = 0) {
        rig.strip.mouseUp(with: mouseEvent(.leftMouseUp,
                                           at: rig.pillCenter(i),
                                           clickCount: clickCount,
                                           timestamp: timestamp))
    }

    /// Assert the strip is NOT renaming, via both oracles: the edit-mode flag
    /// and `commitEditIfNeeded()` publishing nothing.
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

    /// A gap guaranteed to be INSIDE the live system double-click interval.
    /// Read from `NSEvent.doubleClickInterval` because `mouseDown` reads it
    /// too — a hardcoded 0.1 would be wrong on a machine set to "fast".
    private var quickGap: TimeInterval { NSEvent.doubleClickInterval / 4 }

    // MARK: - Integration: rename on a run one strip saw in full

    /// The gesture AppKit delivers for a double-click on a pill of the key
    /// window: down(1), up(1), down(2). One strip saw the whole run, so rename
    /// must open — the redesign must not cost the feature.
    func test_integration_genuineDoubleClickOnOneStrip_entersRename() {
        let rig = StripRig(tabCount: 3, prefix: "genuine")
        XCTAssertFalse(rig.isRenaming, "precondition: not renaming yet")

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rig, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: quickGap)

        XCTAssertTrue(rig.isRenaming,
                      "a double-click delivered in full must open the rename field")
        // The first click of the run still switches tabs (on mouseup).
        XCTAssertEqual(rig.selections, [rig.tabs[1]],
                       "the opening click of the run selects that pill, once")

        // Second oracle: the in-flight edit is real and targets pill 1.
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.count, 1,
                       "commitEditIfNeeded must publish the in-flight rename")
        XCTAssertEqual(rig.renameCommits.first?.window, rig.tabs[1],
                       "rename must target the double-clicked pill's window")
        XCTAssertEqual(rig.renameCommits.first?.title, "genuine-1",
                       "the field is pre-filled with that pill's title")
    }

    // MARK: - Integration: the phantom activation click

    /// The strip's first event is a lone `clickCount == 2` with the shared
    /// mark cleared: the activating click was swallowed and NO strip saw it.
    /// It must NOT rename — it is an ordinary click and selects that tab.
    func test_integration_loneDoubleClick_doesNotRename_andSelectsOnce() {
        let rig = StripRig(tabCount: 3, prefix: "phantom")
        XCTAssertNil(TabStripView.lastMouseDownForTesting,
                     "precondition: the shared mark starts cleared")

        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: 0)
        pillMouseUp(rig, pill: 1, clickCount: 2, timestamp: 0)

        assertNotRenaming(
            rig,
            "a clickCount==2 whose first half no strip received is an "
                + "activation click, not a rename gesture")
        XCTAssertEqual(rig.selections, [rig.tabs[1]],
                       "the phantom double-click acts as ONE ordinary click on "
                           + "the pill the user aimed at")
        XCTAssertEqual(rig.closes.count, 0,
                       "clicking a pill centre must never close it")
    }

    /// THE REGRESSION THE PANEL FOUND. Because the phantom `clickCount == 2`
    /// renumbers to 1, it must take the ordinary single-click path — which
    /// ARMS a reorder drag and defers selection to mouseup. The pre-rewrite
    /// code selected eagerly and armed nothing, so the press could not be
    /// dragged: grabbing a background pill after coming back to the app
    /// reordered nothing.
    func test_integration_loneDoubleClick_armsReorderDrag() {
        let rig = StripRig(tabCount: 3, prefix: "armed")

        pillMouseDown(rig, pill: 2, clickCount: 2, timestamp: 0)

        XCTAssertEqual(rig.pendingDragIndex, 2,
                       "a renumbered-to-1 press must arm a reorder drag on the "
                           + "pill it landed on")
        XCTAssertEqual(rig.selections.count, 0,
                       "…and must NOT select eagerly on mousedown — selection "
                           + "is deferred so a drag never switches tabs")
        XCTAssertFalse(rig.isRenaming, "…and must not rename")

        // Released without crossing the drag threshold → it was a click after
        // all, and the deferred selection fires.
        pillMouseUp(rig, pill: 2, clickCount: 2, timestamp: 0)
        XCTAssertEqual(rig.selections, [rig.tabs[2]],
                       "releasing without a drag commits the deferred selection")
    }

    // MARK: - Integration: the cross-strip gesture (the reason for the rewrite)

    /// THE CROSS-STRIP RENAME. Every tab is its own window with its own strip.
    /// The user double-clicks a BACKGROUND pill: click 1 lands on the CURRENT
    /// window's strip (A) and selects that tab, which makes the destination
    /// window key — so click 2 is delivered to the DESTINATION window's strip
    /// (B), a different instance that has never seen a mousedown.
    ///
    /// With a per-view mark, B refused to rename and background-pill rename
    /// was simply broken. With the shared mark, B sees that A handled click 1
    /// on the same pill index within the interval and renumbers to 2 → rename.
    func test_integration_crossStrip_secondClickOnFreshStrip_entersRename() {
        // Both rigs are constructed FIRST: `update(tabs:)` clears the shared
        // mark on a list-shape change, so building B after A's click would
        // wipe the very mark under test.
        let rigA = StripRig(tabCount: 3, prefix: "winA")
        let rigB = StripRig(tabCount: 3, prefix: "winB")

        // Click 1 → window A's strip. It arms, and selects on release.
        pillMouseDown(rigA, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rigA, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rigA.selections, [rigA.tabs[1]],
                       "precondition: click 1 selected the background tab")
        XCTAssertFalse(rigA.isRenaming,
                       "precondition: one click never renames")

        // Click 2 → the destination window's strip, at the same pill index and
        // within the double-click interval.
        pillMouseDown(rigB, pill: 1, clickCount: 2, timestamp: quickGap)

        XCTAssertTrue(
            rigB.isRenaming,
            "the second half of a double-click delivered to the destination "
                + "window's strip must open rename — SOME strip saw click 1")
        rigB.strip.commitEditIfNeeded()
        XCTAssertEqual(rigB.renameCommits.count, 1,
                       "the edit on strip B is real")
        XCTAssertEqual(rigB.renameCommits.first?.window, rigB.tabs[1],
                       "rename targets the pill the user double-clicked")
        XCTAssertEqual(rigB.renameCommits.first?.title, "winB-1",
                       "the field is pre-filled from that pill's title")
        XCTAssertEqual(rigB.selections.count, 0,
                       "the renaming click must not ALSO select")
        XCTAssertFalse(rigA.isRenaming,
                       "strip A saw only one click and must not be renaming")
    }

    /// The cross-strip continuation is still bounded by the TARGET: click 1 on
    /// pill 0 in strip A, click 2 on pill 2 in strip B is not a double-click
    /// on any one tab. Strip B must select, not rename.
    func test_integration_crossStrip_differentPillIndex_doesNotRename() {
        let rigA = StripRig(tabCount: 3, prefix: "xa")
        let rigB = StripRig(tabCount: 3, prefix: "xb")

        pillMouseDown(rigA, pill: 0, clickCount: 1, timestamp: 0)
        pillMouseUp(rigA, pill: 0, clickCount: 1, timestamp: 0)

        pillMouseDown(rigB, pill: 2, clickCount: 2, timestamp: quickGap)
        pillMouseUp(rigB, pill: 2, clickCount: 2, timestamp: quickGap)

        assertNotRenaming(
            rigB,
            "click 1 landed on a different pill — this is not a double-click "
                + "on the pill strip B was asked to rename")
        XCTAssertEqual(rigB.selections, [rigB.tabs[2]],
                       "strip B's click is an ordinary click on pill 2")
    }

    // MARK: - Integration: the close hotspot is not a rename target

    /// `clicks == 2` opens rename only on the pill BODY. The leading × hotspot
    /// belongs to the close affordance, so a double-click there must fall
    /// through to the ordinary pill-click path instead of opening the field
    /// under the user's cursor.
    func test_integration_doubleClickOnCloseHotspot_doesNotRename() {
        let rig = StripRig(tabCount: 3, prefix: "hotspot")
        let hotspot = rig.pillCloseHotspot(1)

        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: hotspot,
                                             clickCount: 1, timestamp: 0))
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: hotspot,
                                             clickCount: 2, timestamp: quickGap))

        assertNotRenaming(
            rig,
            "a double-click on the close hotspot must not open inline rename")
        XCTAssertEqual(rig.selections, [rig.tabs[1]],
                       "it falls through to the ordinary pill-click path and "
                           + "selects that tab")
        XCTAssertEqual(rig.closes.count, 0,
                       "…and does not close it either: the × only closes when "
                           + "the user is actually hovered on it")
    }

    // MARK: - Integration: what clears the shared mark

    /// A mousedown on bare strip (between pills, below the pill row) is not a
    /// click target at all: it CLEARS the shared mark, so the next
    /// `clickCount == 2` cannot continue a run through it.
    func test_integration_bareStripMouseDown_clearsSharedMark() {
        let rig = StripRig(tabCount: 3, prefix: "bare")

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.target, .pill(1),
                       "precondition: the pill click recorded a mark")

        // y = 1 is below every pill and below the `+` (both are laid out at
        // y = 4, height 24), so this point belongs to no target.
        let bare = NSPoint(x: 2, y: 1)
        XCTAssertFalse(rig.strip.pillFramesForTesting.contains { NSPointInRect(bare, $0) },
                       "precondition: the bare point is inside no pill")
        XCTAssertFalse(NSPointInRect(bare, rig.strip.addButtonFrameForTesting),
                       "precondition: the bare point is not on the `+`")
        rig.strip.mouseDown(with: mouseEvent(.leftMouseDown, at: bare,
                                             clickCount: 2, timestamp: quickGap))

        XCTAssertNil(TabStripView.lastMouseDownForTesting,
                     "a mousedown on no target clears the shared mark")

        // …and the run really is broken: the following clickCount==2 on pill 1
        // renumbers to 1 and selects instead of renaming.
        pillMouseDown(rig, pill: 1, clickCount: 3, timestamp: quickGap * 2)
        pillMouseUp(rig, pill: 1, clickCount: 3, timestamp: quickGap * 2)
        assertNotRenaming(rig, "the cleared mark cannot license a rename")
        XCTAssertEqual(rig.selections, [rig.tabs[1]],
                       "it is an ordinary click instead")
    }

    /// A list-shape change clears the mark: the recorded target refers to the
    /// OLD pill list, and a reshuffle underneath a half-finished double-click
    /// would otherwise rename whatever tab inherited that slot.
    func test_integration_listShapeChange_clearsSharedMark() {
        let rig = StripRig(tabCount: 3, prefix: "reshape")

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.effectiveClickCount, 1,
                       "precondition: the pill click recorded a first-click mark")

        let replacement = StripRig.makeStubWindows(2, prefix: "reshaped")
        rig.strip.update(tabs: replacement, selected: replacement[0], width: 600)

        XCTAssertNil(TabStripView.lastMouseDownForTesting,
                     "a list-shape change drops the mark rather than remapping it")
    }

    /// The converse, and it matters: a width-only refresh (same windows, same
    /// order) must NOT clear the mark. Selecting a background tab triggers a
    /// tab-bar refresh on the destination window, and if that refresh wiped
    /// the mark the cross-strip rename above would be broken again.
    func test_integration_widthOnlyUpdate_preservesSharedMark() {
        let rig = StripRig(tabCount: 3, prefix: "widthonly")

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        let before = TabStripView.lastMouseDownForTesting
        XCTAssertEqual(before?.target, .pill(1),
                       "precondition: the pill click recorded a mark")

        rig.strip.update(tabs: rig.tabs, selected: rig.tabs[1], width: 520)

        XCTAssertEqual(TabStripView.lastMouseDownForTesting, before,
                       "a width-only refresh must leave the run intact")

        // And the run really does continue across the refresh.
        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: quickGap)
        XCTAssertTrue(rig.isRenaming,
                      "the second click still renames after a width-only refresh")
    }
}
