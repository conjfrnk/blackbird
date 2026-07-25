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
/// The SELECTION gate on top of it (maintainer decision, 2026-07-25). Reaching
/// `clicks == 2` is necessary for rename but no longer sufficient: the pill
/// must ALSO have been the selected tab when the run STARTED
/// (`ClickSequenceMark.targetWasSelected`). "Click a background pill to switch
/// to it, click it again" and "deliberately double-click a background pill to
/// rename it" are the same event stream — nothing in the click bookkeeping can
/// separate them — so the tie is broken by asking whether the user was already
/// on that tab:
///
///  - double-click the SELECTED pill      → rename
///  - double-click a BACKGROUND pill      → switch to it, and stop
///  - rename a background tab             → click, pause past the interval,
///                                          then double-click
///
/// `targetWasSelected` is INHERITED through a continuing run, never re-read: by
/// click 2 the first click has already selected the tab, so a fresh read would
/// wave every background double-click straight through again. The renumbering
/// primitive itself is untouched — it still knows nothing about selection.
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
                      wasSelected: Bool = false,
                      at t: TimeInterval) -> TabStripView.ClickSequenceMark {
        TabStripView.ClickSequenceMark(target: target,
                                       systemClickCount: sys,
                                       effectiveClickCount: effective,
                                       targetWasSelected: wasSelected,
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
    /// A run may not cross tab GROUPS. The mark is shared across strips on
    /// purpose, but `ClickTarget.pill` compares a bare index — so without a
    /// group gate, a click on pill 1 of one window group would license a
    /// "double-click" on pill 1 of an entirely unrelated group, popping the
    /// rename field open on a tab the user only meant to switch to. Windows
    /// tabbed together share one `NSWindowTabGroup` instance (including a tab
    /// `addTabbedWindow` just created), so gating on its identity keeps every
    /// intra-group hand-off working.
    func test_differentTabGroup_breaksTheRun() {
        // Two distinct identities standing in for two NSWindowTabGroups.
        // The objects must be held in locals for the whole test: an
        // `ObjectIdentifier(NSObject())` built from a temporary is derived
        // from an address that is freed immediately, so the second allocation
        // can reuse it and the two identifiers compare EQUAL. That made this
        // test pass in isolation and fail in the full suite.
        let objectA = NSObject()
        let objectB = NSObject()
        let groupA = ObjectIdentifier(objectA)
        let groupB = ObjectIdentifier(objectB)
        XCTAssertNotEqual(groupA, groupB, "precondition: the two stand-in groups are distinct")
        let mark = TabStripView.ClickSequenceMark(
            target: .pill(1), groupID: groupA,
            systemClickCount: 1, effectiveClickCount: 1, timestamp: 0)

        XCTAssertEqual(
            TabStripView.effectiveClickCount(previous: mark, target: .pill(1), groupID: groupB,
                                             clickCount: 2, timestamp: quickGap,
                                             doubleClickInterval: NSEvent.doubleClickInterval),
            1,
            "a run must not continue into a different tab group, even on the same pill index")

        XCTAssertEqual(
            TabStripView.effectiveClickCount(previous: mark, target: .pill(1), groupID: groupA,
                                             clickCount: 2, timestamp: quickGap,
                                             doubleClickInterval: NSEvent.doubleClickInterval),
            2,
            "control: the same group continues the run — the cross-strip "
                + "hand-off inside one group must keep working")

        // A grouped mark must not be continued by an ungrouped strip either.
        XCTAssertEqual(
            TabStripView.effectiveClickCount(previous: mark, target: .pill(1), groupID: nil,
                                             clickCount: 2, timestamp: quickGap,
                                             doubleClickInterval: NSEvent.doubleClickInterval),
            1,
            "a strip with no tab group cannot continue a grouped run")
    }

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

    /// The renumbering primitive must stay ignorant of selection. The rename
    /// gate reads `targetWasSelected` off the MARK; the count is decided purely
    /// by target / contiguity / timing. An implementation that folded the new
    /// gate into the primitive would break `+` (which is never "selected") and
    /// the drag-arming path (which keys on `clicks == 1`), so pin the two
    /// concerns apart: flipping the flag on the previous mark may not move the
    /// count by even one.
    func test_primitiveIgnoresTargetWasSelected() {
        for target in [TabStripView.ClickTarget.pill(1), .addButton] {
            let unselected = mark(target, sys: 1, effective: 1, wasSelected: false, at: base)
            let selected = mark(target, sys: 1, effective: 1, wasSelected: true, at: base)
            XCTAssertEqual(
                renumber(previous: unselected, target, sys: 2, at: base + 0.125),
                2,
                "\(target): a run continues regardless of selectedness")
            XCTAssertEqual(
                renumber(previous: selected, target, sys: 2, at: base + 0.125),
                renumber(previous: unselected, target, sys: 2, at: base + 0.125),
                "\(target): the two marks differ only in targetWasSelected, so "
                    + "the renumbered count must be identical")
        }
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

    /// The mark is a value over exactly its fields, and it stores what it was
    /// handed — the two counts are deliberately distinct, so a struct that
    /// collapsed them would break the phantom-run arithmetic above, and
    /// `targetWasSelected` is a full member (a run that inherits it must
    /// inherit a value that actually round-trips).
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
        XCTAssertNotEqual(a, mark(.pill(1), sys: 2, effective: 1,
                                  wasSelected: true, at: base),
                          "a different targetWasSelected compares unequal")
        XCTAssertNotEqual(a, mark(.pill(1), sys: 2, effective: 1, at: base + 0.25),
                          "a different timestamp compares unequal")

        XCTAssertEqual(a.target, .pill(1))
        XCTAssertEqual(a.systemClickCount, 2)
        XCTAssertEqual(a.effectiveClickCount, 1)
        XCTAssertFalse(a.targetWasSelected,
                       "targetWasSelected defaults to false — a mark that says "
                           + "nothing about selection must not license a rename")
        XCTAssertEqual(a.timestamp, base, accuracy: 0)

        let selected = mark(.pill(1), sys: 2, effective: 1, wasSelected: true, at: base)
        XCTAssertTrue(selected.targetWasSelected,
                      "the mark stores the selectedness it was handed")
    }

    // MARK: - Integration rig

    /// A windowless `TabStripView` over `tabCount` never-shown stub windows,
    /// with the strip's callbacks recorded.
    ///
    /// `selected` is which pill the strip believes is the CURRENT tab — the
    /// rename gate reads it, so every rename test has to say which tab the user
    /// was on. The rig does not move it on its own: `onSelectWindow` is only
    /// recorded, exactly like production, where the switch travels through the
    /// window controller and comes back as a refresh. Tests that need that
    /// round trip call `selectTab(_:)`.
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
        private let width: CGFloat
        private(set) var selections: [NSWindow] = []
        private(set) var closes: [NSWindow] = []
        private(set) var renameCommits: [(window: NSWindow, title: String)] = []

        init(tabCount: Int, prefix: String, selected: Int = 0, width: CGFloat = 600) {
            precondition(selected < tabCount, "selected pill \(selected) out of range")
            let windows = StripRig.makeStubWindows(tabCount, prefix: prefix)
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
            // `makeStubWindows` already parked the windows.
            StripRig.parked.append(strip)
        }

        /// Pill index armed for a potential reorder drag, or `nil`.
        var pendingDragIndex: Int? { strip.pendingDragPillIndexForTesting }

        /// What the app does after a click switches tabs: the controller pushes
        /// the new selection back into every strip of the group. Same tab list,
        /// so it is NOT a list-shape change and the shared click mark survives
        /// — which is precisely the window in which the second half of a
        /// double-click lands, and precisely why the rename gate must inherit
        /// the run's ORIGINAL selectedness instead of re-reading it here.
        func selectTab(_ i: Int) {
            precondition(i < tabs.count, "pill \(i) out of range")
            strip.update(tabs: tabs, selected: tabs[i], width: width)
        }

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

        /// The installed inline-rename field, if any. `beginEditing` is the
        /// only `addSubview` call site in `TitlebarTabBar.swift`, so this is an
        /// oracle INDEPENDENT of `isEditingForTesting`: a "no rename" verdict
        /// that only consulted the flag would miss a field left on screen.
        var editFieldSubview: NSTextField? {
            strip.subviews.compactMap { $0 as? NSTextField }.first
        }

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

    /// Assert the strip is NOT renaming, via all three oracles: the edit-mode
    /// flag, no rename field installed as a subview, and `commitEditIfNeeded()`
    /// publishing nothing.
    private func assertNotRenaming(_ rig: StripRig,
                                   _ message: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertFalse(rig.isRenaming, message, file: file, line: line)
        XCTAssertNil(rig.editFieldSubview,
                     message + " (no rename field may be installed)",
                     file: file, line: line)
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

    /// Comfortably PAST the live interval, so a mousedown at this remove opens
    /// a brand-new run rather than continuing one. Expressed in event
    /// timestamps only — `mouseDown` renumbers off `NSEvent.timestamp`, so no
    /// test here has to burn real wall time to let a run lapse.
    private var lapsedGap: TimeInterval { NSEvent.doubleClickInterval * 2 + 0.1 }

    // MARK: - Integration: rename on a run one strip saw in full

    /// THE LOAD-BEARING POSITIVE. The gesture AppKit delivers for a
    /// double-click on the pill of the CURRENT tab: down(1), up(1), down(2).
    /// One strip saw the whole run and the user was already on that tab, so
    /// rename must open — if this breaks, the feature is gone.
    func test_integration_doubleClickOnSelectedPill_entersRename() {
        // The user is already on tab 1 — that is what the selection gate wants.
        let rig = StripRig(tabCount: 3, prefix: "genuine", selected: 1)
        XCTAssertFalse(rig.isRenaming, "precondition: not renaming yet")

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rig, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: quickGap)

        XCTAssertTrue(rig.isRenaming,
                      "a double-click delivered in full, on the tab the user is "
                          + "already on, must open the rename field")
        // The first click of the run still re-selects that pill (on mouseup);
        // in production that is the no-op self-select of the current tab.
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

    // MARK: - Integration: a background pill switches and stops

    /// THE REPORTED BUG (2026-07-24). The user clicks a background pill to
    /// switch to it, then clicks it again — and the rename field used to pop
    /// open. At the event level that stream is identical to deliberately
    /// double-clicking a background tab to rename it, so the maintainer's call
    /// is: a background double-click switches and stops.
    ///
    /// The app's selection round trip is modelled faithfully — click 1 selects
    /// tab 1, the controller pushes that back into the strip — because that is
    /// exactly the state a re-reading implementation would consult to wrongly
    /// license the rename.
    func test_integration_doubleClickOnBackgroundPill_selectsAndDoesNotRename() {
        let rig = StripRig(tabCount: 3, prefix: "background", selected: 0)

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rig, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rig.selections, [rig.tabs[1]],
                       "precondition: click 1 switched to the background tab")
        // The switch comes back as a same-shape refresh — pill 1 is the
        // current tab from here on, and the mark survives it.
        rig.selectTab(1)

        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: quickGap)
        pillMouseUp(rig, pill: 1, clickCount: 2, timestamp: quickGap)

        assertNotRenaming(
            rig,
            "a double-click that STARTED on a background pill must switch to "
                + "that tab and stop — rename is only for the tab you are on")
        // Click 2 is refused a rename, so it falls through to the ordinary
        // pill-click path and selects (a no-op switch in production, since
        // click 1 already moved there). Arming is suppressed at clicks > 1, so
        // this selection lands on mousedown rather than on release.
        XCTAssertEqual(rig.selections, [rig.tabs[1], rig.tabs[1]],
                       "both halves act on the pill the user aimed at, and "
                           + "neither of them renames it")
        XCTAssertEqual(rig.closes.count, 0,
                       "clicking a pill centre must never close it")
    }

    /// The documented way to rename a background tab: click it, let the run
    /// lapse past the double-click interval, then double-click the pill that is
    /// NOW selected. If this doesn't work, background tabs cannot be renamed at
    /// all and the policy is a regression rather than a tradeoff.
    func test_integration_backgroundPill_clickPauseDoubleClick_entersRename() {
        let rig = StripRig(tabCount: 3, prefix: "pause", selected: 0)

        // Click once to switch. AppKit's own count for this click is 1.
        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rig, pill: 1, clickCount: 1, timestamp: 0)
        rig.selectTab(1)
        assertNotRenaming(rig, "precondition: one click never renames")

        // …pause. A click this late reaches the strip as a fresh sequence
        // (clickCount back to 1), and its own mark is computed fresh — the pill
        // is selected NOW, so this run is rename-eligible.
        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: lapsedGap)
        pillMouseUp(rig, pill: 1, clickCount: 1, timestamp: lapsedGap)
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.targetWasSelected, true,
                       "the lapsed run starts on a pill that IS selected now")
        assertNotRenaming(rig, "the first click of the new run still doesn't rename")

        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: lapsedGap + quickGap)

        XCTAssertTrue(rig.isRenaming,
                      "click, pause, double-click is the documented way to "
                          + "rename a background tab and must work")
        rig.strip.commitEditIfNeeded()
        XCTAssertEqual(rig.renameCommits.count, 1,
                       "the edit is real")
        XCTAssertEqual(rig.renameCommits.first?.window, rig.tabs[1],
                       "rename targets the pill the user double-clicked")
        XCTAssertEqual(rig.renameCommits.first?.title, "pause-1",
                       "the field is pre-filled from that pill's title")
    }

    /// THE MECHANISM, pinned directly. `targetWasSelected` is INHERITED through
    /// a continuing run, never re-read — this is the single most likely place
    /// for a wrong-but-plausible implementation to slip through, because by
    /// click 2 the tab IS selected and a fresh read would answer `true`.
    ///
    /// The control at the end proves the fresh read really would say `true` at
    /// that moment, so the `false` above can only have come from inheritance.
    func test_integration_targetWasSelected_isInheritedNotRereadMidRun() {
        let rig = StripRig(tabCount: 3, prefix: "inherit", selected: 0)

        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.effectiveClickCount, 1,
                       "precondition: click 1 opened the run")
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.targetWasSelected, false,
                       "precondition: the run STARTED on a background pill")
        pillMouseUp(rig, pill: 1, clickCount: 1, timestamp: 0)

        // The tab really does become the selected one between the two halves.
        rig.selectTab(1)

        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: quickGap)
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.effectiveClickCount, 2,
                       "the run continued — the click count is not the reason "
                           + "this doesn't rename")
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.targetWasSelected, false,
                       "click 2 must carry the run's ORIGINAL selectedness, not "
                           + "a fresh read of a tab click 1 just selected")
        assertNotRenaming(rig, "an inherited false must refuse the rename")

        // Control: a run that STARTS now, on the same pill, reads true — so the
        // false above is inheritance and not a strip that simply never sees a
        // selected pill.
        pillMouseDown(rig, pill: 1, clickCount: 1, timestamp: lapsedGap)
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.targetWasSelected, true,
                       "a FRESH run on the now-selected pill reads true — the "
                           + "inherited false was a real inheritance")
    }

    // MARK: - Integration: the phantom activation click

    /// The strip's first event is a lone `clickCount == 2` with the shared
    /// mark cleared: the activating click was swallowed and NO strip saw it.
    /// It must NOT rename — it is an ordinary click and selects that tab.
    ///
    /// Aimed at the SELECTED pill on purpose: the selection gate would wave
    /// this one through, so the refusal can only come from the click-count
    /// renumbering. Pointed at a background pill the test would pass for two
    /// reasons at once and stop pinning the return-to-app case.
    func test_integration_loneDoubleClickOnSelectedPill_doesNotRename_andSelectsOnce() {
        let rig = StripRig(tabCount: 3, prefix: "phantom", selected: 1)
        XCTAssertNil(TabStripView.lastMouseDownForTesting,
                     "precondition: the shared mark starts cleared")

        pillMouseDown(rig, pill: 1, clickCount: 2, timestamp: 0)
        pillMouseUp(rig, pill: 1, clickCount: 2, timestamp: 0)

        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.targetWasSelected, true,
                       "precondition: the selection gate is satisfied here — "
                           + "only the renumbered count can refuse this rename")
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.effectiveClickCount, 1,
                       "…and it does: the lone clickCount==2 renumbers to 1")
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

    /// THE CROSS-STRIP RENAME, kept positive. Every tab is its own window with
    /// its own strip, and AppKit routinely splits the two halves of ONE gesture
    /// across two instances — a key-window change between the halves is enough.
    /// The shared mark is what carries the run (and now its selectedness)
    /// across that boundary: strip B sees that A handled click 1 on the same
    /// pill index within the interval, renumbers to 2, inherits
    /// `targetWasSelected` and renames.
    ///
    /// Both rigs stand for the SAME tab group with tab 1 current, which is the
    /// only shape that renames under the new policy.
    func test_integration_crossStrip_secondClickOnFreshStrip_entersRename() {
        // Both rigs are constructed FIRST: `update(tabs:)` clears the shared
        // mark on a list-shape change, so building B after A's click would
        // wipe the very mark under test.
        let rigA = StripRig(tabCount: 3, prefix: "winA", selected: 1)
        let rigB = StripRig(tabCount: 3, prefix: "winB", selected: 1)

        // Click 1 → window A's strip. It arms, and selects on release.
        pillMouseDown(rigA, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rigA, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rigA.selections, [rigA.tabs[1]],
                       "precondition: click 1 acted on the current tab")
        XCTAssertFalse(rigA.isRenaming,
                       "precondition: one click never renames")

        // Click 2 → the other window's strip, at the same pill index and
        // within the double-click interval.
        pillMouseDown(rigB, pill: 1, clickCount: 2, timestamp: quickGap)

        XCTAssertTrue(
            rigB.isRenaming,
            "the second half of a double-click delivered to another strip must "
                + "open rename — SOME strip saw click 1, on a selected pill")
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

    /// …and the cross-strip machinery must not smuggle the background case back
    /// in. This is the reported bug in its native shape: click 1 lands on the
    /// CURRENT window's strip (A) and switches to the background tab, which
    /// makes the destination window key — so click 2 is delivered to strip B,
    /// where that pill is ALREADY the selected one. A strip B that re-read
    /// selectedness instead of inheriting it would rename here, and the whole
    /// policy would be dead on the most common physical gesture.
    func test_integration_crossStrip_runStartedOnBackgroundPill_doesNotRename() {
        // Strip A: the window the user is on, showing tab 0. Strip B: the
        // destination window, where the clicked pill is the current tab —
        // exactly the state a fresh read would consult.
        let rigA = StripRig(tabCount: 3, prefix: "bgA", selected: 0)
        let rigB = StripRig(tabCount: 3, prefix: "bgB", selected: 1)

        pillMouseDown(rigA, pill: 1, clickCount: 1, timestamp: 0)
        pillMouseUp(rigA, pill: 1, clickCount: 1, timestamp: 0)
        XCTAssertEqual(rigA.selections, [rigA.tabs[1]],
                       "precondition: click 1 switched to the background tab")
        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.targetWasSelected, false,
                       "precondition: the run started on a pill that was NOT "
                           + "the selected tab")

        pillMouseDown(rigB, pill: 1, clickCount: 2, timestamp: quickGap)
        pillMouseUp(rigB, pill: 1, clickCount: 2, timestamp: quickGap)

        XCTAssertEqual(TabStripView.lastMouseDownForTesting?.effectiveClickCount, 2,
                       "the run DID continue across the strips — the refusal "
                           + "below is the selection gate, not the count")
        assertNotRenaming(
            rigB,
            "a run that began on a background pill must not rename, however "
                + "many strips its halves were split across")
        XCTAssertEqual(rigB.selections, [rigB.tabs[1]],
                       "strip B's click is an ordinary click on pill 1")
        assertNotRenaming(rigA, "strip A saw only one click and must not rename")
    }

    /// The cross-strip continuation is still bounded by the TARGET: click 1 on
    /// pill 0 in strip A, click 2 on pill 2 in strip B is not a double-click
    /// on any one tab. Strip B must select, not rename — and pill 2 is strip
    /// B's SELECTED tab here, so the selection gate would happily allow it: the
    /// target break is the only thing refusing.
    func test_integration_crossStrip_differentPillIndex_doesNotRename() {
        let rigA = StripRig(tabCount: 3, prefix: "xa", selected: 0)
        let rigB = StripRig(tabCount: 3, prefix: "xb", selected: 2)

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

    /// A rename-eligible double-click (run of 2, on the SELECTED pill) opens
    /// rename only on the pill BODY. The leading × hotspot belongs to the close
    /// affordance, so a double-click there must fall through to the ordinary
    /// pill-click path instead of opening the field under the user's cursor.
    /// The pill is deliberately the selected one: every other gate is satisfied
    /// here, so only the hotspot can be what refuses.
    func test_integration_doubleClickOnCloseHotspot_doesNotRename() {
        let rig = StripRig(tabCount: 3, prefix: "hotspot", selected: 1)
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
    /// `clickCount == 2` cannot continue a run through it. Aimed at the
    /// SELECTED pill so the cleared mark is the only thing standing between
    /// this gesture and a rename.
    func test_integration_bareStripMouseDown_clearsSharedMark() {
        let rig = StripRig(tabCount: 3, prefix: "bare", selected: 1)

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
    /// order) must NOT clear the mark. Selecting a tab triggers a tab-bar
    /// refresh on the destination window, and if that refresh wiped the mark
    /// the cross-strip rename above would be broken again.
    func test_integration_widthOnlyUpdate_preservesSharedMark() {
        let rig = StripRig(tabCount: 3, prefix: "widthonly", selected: 1)

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
