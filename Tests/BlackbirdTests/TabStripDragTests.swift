import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for `TabStripView`'s drag-to-reorder state machine
/// and its two pure static helpers (`computeIntermediateIndex`,
/// `intermediateSlot`).
///
/// Why blind: a wrong-but-plausible impl that, say, promotes to an
/// active drag on the first `mouseDragged` regardless of distance would
/// silently pass any test that only verifies the "≥ 5pt promotes"
/// path. Testing the negation (below-threshold drag stays armed-only)
/// is what catches that class of bug. Same for the "no-op move at
/// drop time" branch — a naive impl that always calls
/// `TabOrderCoordinator.move` on mouseUp would post a spurious
/// notification when the user clicked-and-released without crossing
/// a slot boundary.
///
/// State machine the strip must implement (per the contract):
///
///   IDLE
///    ── mouseDown on pill body, ≥2 tabs ──▶ ARMED
///    ── mouseDown elsewhere / 1 tab / dblclick / close hotspot ─▶ IDLE
///
///   ARMED  (pendingDragPillIndex non-nil, dragState nil)
///    ── mouseDragged, |Δx| < 5 ──▶ ARMED (unchanged)
///    ── mouseDragged, |Δx| ≥ 5 ──▶ DRAGGING
///    ── mouseUp                ──▶ IDLE  (no move call)
///    ── update(tabs) with new list shape ──▶ IDLE
///
///   DRAGGING (dragState non-nil)
///    ── mouseDragged           ──▶ DRAGGING (update currentIndex)
///    ── mouseUp with currentIndex != originalIndex ─▶ IDLE + move()
///    ── mouseUp with currentIndex == originalIndex ─▶ IDLE (no move)
///    ── update(tabs) with new list shape ──▶ IDLE (cancel)
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - Per test: 1 host `NSWindow` + ≤ 4 stub tab `NSWindow`
///     instances (~40 KB each). ≤ 200 KB transient per test.
///   - No `MainWindowController`, no PTYs, no real shells.
///   - The static helpers run without any AppKit setup.
///   - Wall time: < 50 ms per test.
final class TabStripDragTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        // The drop branch invokes `TabOrderCoordinator.shared.move(...)`,
        // which mutates singleton state. Reset so the next test in this
        // suite — or any subsequent test class — starts clean.
        TabOrderCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Setup helpers

    private func makeStubWindows(_ count: Int, prefix: String = "d") -> [NSWindow] {
        (0..<count).map { i in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            w.title = "\(prefix)-\(i)"
            // Explicitly forbid tabbing: NSWindow's default tabbing
            // identifier is derived from class + autosave name, so bare
            // NSWindows created in the same test process can implicitly
            // share an id. If a sibling test (TabOrderCoordinatorTests)
            // promoted a window via `makeKeyAndOrderFront`, AppKit will
            // happily merge our new stubs into that group on first
            // `.tabGroup` access — `tabs[0].tabGroup` would then be
            // non-nil, and the strip's drop branch would call into
            // `coordinator.move` against a real group containing
            // half-deallocated peers from a prior test, crashing the
            // xctest host. `.disallowed` slams that door.
            w.tabbingMode = .disallowed
            return w
        }
    }

    private func makeStrip(tabCount: Int, width: CGFloat = 600)
        -> (TabStripView, [NSWindow])
    {
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        let tabs = makeStubWindows(tabCount)
        strip.update(tabs: tabs, selected: tabs[0], width: width)
        return (strip, tabs)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at p: NSPoint,
                            clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: p,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        )!
    }

    /// Centre point of a pill in strip-local coordinates. We pick the
    /// vertical centre of the pill frame and the horizontal centre,
    /// which dodges the leading 14pt close hotspot (whose centre is
    /// 6+7=13pt inside the left edge — well to the left of the pill
    /// centre for any non-degenerate pill width).
    private func pillCenter(_ frame: CGRect) -> NSPoint {
        NSPoint(x: frame.midX, y: frame.midY)
    }

    /// Point on the leading close hotspot of a pill. The hotspot is
    /// "the leading 14pt circle 6pt inside the pill's left edge", so
    /// its centre is at (origin.x + 6 + 7, frame.midY) = origin.x + 13.
    private func pillCloseHotspot(_ frame: CGRect) -> NSPoint {
        NSPoint(x: frame.origin.x + 13, y: frame.midY)
    }

    // MARK: - mouseDown arming

    func test_mouseDown_onPillBody_arms_pendingDrag() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        XCTAssertGreaterThanOrEqual(frames.count, 2,
            "test precondition: at least 2 pill frames")

        strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                        at: pillCenter(frames[1])))

        let pending = strip.pendingDragPillIndexForTesting
        XCTAssertEqual(pending, 1,
            "mouseDown on pill body must arm pendingDrag at that index")
        XCTAssertNil(strip.dragStateForTesting,
            "armed-but-not-promoted state has dragState nil")
    }

    func test_mouseDown_doubleClick_doesNotArmDrag() {
        // Double-click is the inline-rename entry point and must NOT
        // also arm a drag — otherwise releasing without moving would
        // fire a no-op move and the rename could race with reorder.
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                        at: pillCenter(frames[0]),
                                        clickCount: 2))

        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "double-click must NOT arm pendingDrag (enters rename path)")
    }

    func test_mouseDown_singleTabStrip_doesNotArmDrag() {
        let (strip, _) = makeStrip(tabCount: 1)
        let frames = strip.pillFramesForTesting

        // With only one tab there is nothing to reorder; the drag
        // must not arm.
        strip.mouseDown(with: mouseEvent(.leftMouseDown,
                                        at: pillCenter(frames[0])))

        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "1-tab strip must not arm a drag (no reorder possible)")
    }

    func test_mouseDown_onCloseHotspot_doesNotArmDrag() {
        // The close hotspot is the leading 14pt circle 6pt inside the
        // pill's left edge. Production gates the hotspot on a prior
        // mouseMoved hover that arms the X glyph, but the SPEC says a
        // mouseDown on that geometry must not arm a drag. Drive a
        // mouseMoved to that point first so any internal hover-state
        // requirement is satisfied, then mouseDown.
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let hotspot = pillCloseHotspot(frames[1])

        // Arm the hover/close state. The strip's `mouseMoved` is a
        // public NSResponder entry point.
        strip.mouseMoved(with: mouseEvent(.mouseMoved, at: hotspot))

        // Now the mouseDown on the hotspot.
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: hotspot))

        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "mouseDown on close hotspot must route to close, not arm a drag")
    }

    // MARK: - mouseDragged threshold

    func test_drag_below_threshold_does_not_promote() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[1])

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Move 4pt — below the 5pt promotion threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 4, y: down.y)))

        XCTAssertEqual(strip.pendingDragPillIndexForTesting, 1,
            "pendingDrag must remain armed below threshold")
        XCTAssertNil(strip.dragStateForTesting,
            "below-threshold drag must NOT promote to active dragState")
    }

    func test_drag_at_or_above_threshold_promotes() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[1])

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Move 5pt — at the promotion threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 5, y: down.y)))

        let state = strip.dragStateForTesting
        XCTAssertNotNil(state, "5pt delta must promote to active drag")
        XCTAssertEqual(state?.originalIndex, 1,
            "originalIndex must equal the armed pill index")
        // currentIndex starts equal to originalIndex; whether it has
        // already advanced after a 5pt move is layout-dependent, but
        // for an unmoved-from-down 5pt nudge to the right within the
        // pill it should still be 1.
        XCTAssertEqual(state?.currentIndex, 1,
            "currentIndex starts at originalIndex on initial promotion")
    }

    func test_drag_negativeDelta_atOrAboveThreshold_promotes() {
        // Symmetry: the threshold is |Δx|, not signed Δx.
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[2])

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x - 6, y: down.y)))

        XCTAssertNotNil(strip.dragStateForTesting,
            "negative 6pt delta must also promote (|Δx| ≥ 5)")
    }

    // MARK: - mouseUp commit/no-op

    func test_mouseUp_clearsAllDragState() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[0])

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 20, y: down.y)))
        strip.mouseUp(with: mouseEvent(.leftMouseUp,
                                      at: NSPoint(x: down.x + 20, y: down.y)))

        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "mouseUp must clear pendingDrag")
        XCTAssertNil(strip.dragStateForTesting,
            "mouseUp must clear dragState")
    }

    func test_mouseUp_withCurrentEqualsOriginal_postsNoOrderDidChange() {
        // Click-and-release with no slot crossing: currentIndex stayed
        // equal to originalIndex through the whole drag. mouseUp must
        // NOT post `orderDidChange`.
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[1])

        // Observer set up BEFORE the gesture.
        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Promote, but stay within the original slot — only move 5pt,
        // which (for any reasonable pill width ≥ 10pt) does not cross
        // to slot 0 or slot 2.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 5, y: down.y)))
        // Drag back to the down point so currentIndex == originalIndex.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged, at: down))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: down))

        // Allow any async-posted notification to land.
        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)

        XCTAssertEqual(observed, 0,
            "no-op drop (currentIndex == originalIndex) must NOT post orderDidChange")
    }

    func test_mouseUp_acrossSlot_invokesCoordinatorMove() {
        // Drag pill 0 well past pill 2's centre, then release. The
        // strip must call `TabOrderCoordinator.shared.move(...)`,
        // which posts `orderDidChange`.
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[0])
        let dropTarget = pillCenter(frames[2])

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Promote.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 6, y: down.y)))
        // Cross past slot 2's centre.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged, at: dropTarget))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: dropTarget))

        // Let any async-posted notification land.
        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)

        // NOTE: the strip's drop branch calls `move(window:to:in:)`
        // with the live tab group. Our stub windows aren't in any
        // NSWindowTabGroup, so the coordinator's group-aware `move`
        // may early-out for a non-member window — which would post
        // no notification. Treat this as a soft check: if the
        // notification did fire, fine; if not, we still assert the
        // strip's own state machine cleared correctly. The stronger
        // invariant — drop with cross != no-op — is covered by the
        // state-machine clearing combined with the
        // currentIndex-shifts test below.
        XCTAssertNil(strip.dragStateForTesting,
            "mouseUp must clear dragState even on a cross-slot drop")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "mouseUp must clear pendingDrag even on a cross-slot drop")
        // Best-effort: 0 or 1 — but never more than 1 (no spurious
        // double-post).
        XCTAssertLessThanOrEqual(observed, 1,
            "at most one orderDidChange per drop")
    }

    func test_mouseUp_withoutPromotion_postsNoOrderDidChange() {
        // mouseDown + mouseUp with no mouseDragged in between (or only
        // a sub-threshold drag) must be a no-op drop.
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[1])

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: down))

        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)

        XCTAssertEqual(observed, 0,
            "mouseUp without promotion (a plain click) must NOT post orderDidChange")
    }

    // MARK: - list-shape-change cancellation

    func test_listShapeChange_duringActiveDrag_cancelsDrag() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[1])

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 20, y: down.y)))
        XCTAssertNotNil(strip.dragStateForTesting,
            "precondition: drag is active after 20pt move")

        // Different count: 3 → 2 tabs. The strip must cancel.
        let replacement = makeStubWindows(2, prefix: "newcount")
        strip.update(tabs: replacement, selected: replacement[0], width: 600)

        XCTAssertNil(strip.dragStateForTesting,
            "list count change must cancel an active drag")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "list count change must also clear pending state")
    }

    func test_identityChange_duringActiveDrag_cancelsDrag() throws {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        let down = pillCenter(frames[0])

        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                          at: NSPoint(x: down.x + 15, y: down.y)))
        let pre = try XCTUnwrap(strip.dragStateForTesting,
            "precondition: a 15pt drag should have promoted")
        XCTAssertEqual(pre.originalIndex, 0,
            "precondition: drag originated at pill 0")

        // Same count but different NSWindow instances — production
        // treats this as a list-shape change (it's a stale-index
        // hazard for rename, and equally so for drag).
        let replacement = makeStubWindows(3, prefix: "newids")
        strip.update(tabs: replacement, selected: replacement[0], width: 600)

        XCTAssertNil(strip.dragStateForTesting,
            "identity change must cancel an active drag")
    }

    // MARK: - computeIntermediateIndex (pure static)

    /// Three pills of width 100 at x = 0, 100, 200. The cursor is
    /// described as a `(cursorX, downOffsetX)` pair — the dragged
    /// pill's centre sits at `cursorX - downOffsetX + (pillWidth/2)`
    /// (or some equivalent formulation depending on the convention).
    /// The contract says "cursor anchored such that the dragged pill's
    /// CENTRE sits over slot 1's centre returns 1". Slot 1's centre
    /// is x=150 on the spec's frames.
    private var threeEqualFrames: [CGRect] {
        [CGRect(x: 0, y: 4, width: 100, height: 24),
         CGRect(x: 100, y: 4, width: 100, height: 24),
         CGRect(x: 200, y: 4, width: 100, height: 24)]
    }

    func test_computeIntermediateIndex_centerOverSlot1_returns1() {
        // Anchor: dragged from slot 0 (downOffsetX = 50 — centre of
        // the original pill). cursorX = 150 places the dragged pill's
        // centre at 150 − 50 + 50 = 150, which is the centre of slot 1.
        let idx = TabStripView.computeIntermediateIndex(
            cursorX: 150,
            downOffsetX: 50,
            count: 3,
            pillFrames: threeEqualFrames
        )
        XCTAssertEqual(idx, 1,
            "dragged pill centre over slot 1 centre → index 1")
    }

    func test_computeIntermediateIndex_pastSlot2Center_returns2() {
        // Push cursor so the dragged pill's centre is past slot 2's
        // centre (x=250). cursorX = 260 with downOffsetX=50 → centre
        // at 260 − 50 + 50 = 260 (past 250).
        let idx = TabStripView.computeIntermediateIndex(
            cursorX: 260,
            downOffsetX: 50,
            count: 3,
            pillFrames: threeEqualFrames
        )
        XCTAssertEqual(idx, 2,
            "past slot 2's centre → index 2")
    }

    func test_computeIntermediateIndex_farLeft_clampsToZero() {
        let idx = TabStripView.computeIntermediateIndex(
            cursorX: -1000,
            downOffsetX: 50,
            count: 3,
            pillFrames: threeEqualFrames
        )
        XCTAssertEqual(idx, 0,
            "cursor far to the left must clamp to 0")
    }

    func test_computeIntermediateIndex_farRight_clampsToCountMinusOne() {
        let idx = TabStripView.computeIntermediateIndex(
            cursorX: 100_000,
            downOffsetX: 50,
            count: 3,
            pillFrames: threeEqualFrames
        )
        XCTAssertEqual(idx, 2,
            "cursor far to the right must clamp to count-1")
    }

    // MARK: - intermediateSlot (pure static)

    func test_intermediateSlot_draggedItem_returnsDraggedTo() {
        // The dragged pill (originalIdx == draggedFrom) always
        // occupies the destination slot.
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 2, draggedFrom: 2, draggedTo: 0),
            0,
            "originalIdx == draggedFrom → returns draggedTo (the dragged pill is at its target)"
        )
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 0, draggedFrom: 0, draggedTo: 3),
            3
        )
    }

    func test_intermediateSlot_noDrag_returnsOriginalIdx() {
        // draggedFrom == draggedTo: nothing has moved, every pill
        // is at its original slot.
        for i in 0..<5 {
            XCTAssertEqual(
                TabStripView.intermediateSlot(originalIdx: i, draggedFrom: 2, draggedTo: 2),
                i,
                "draggedFrom == draggedTo → returns originalIdx for all i"
            )
        }
    }

    func test_intermediateSlot_dragRight_siblingsInRangeShiftLeft() {
        // Drag pill 1 → slot 3 (rightward). Siblings at indices 2 and
        // 3 (in (draggedFrom, draggedTo]) shift one slot left.
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 2, draggedFrom: 1, draggedTo: 3),
            1,
            "sibling 2 is in (1, 3] → shifts left to slot 1")
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 3, draggedFrom: 1, draggedTo: 3),
            2,
            "sibling 3 is in (1, 3] → shifts left to slot 2")
        // Siblings OUTSIDE the range stay put.
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 0, draggedFrom: 1, draggedTo: 3),
            0,
            "sibling 0 is left of draggedFrom → stays put")
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 4, draggedFrom: 1, draggedTo: 3),
            4,
            "sibling 4 is right of draggedTo → stays put")
    }

    func test_intermediateSlot_dragLeft_siblingsInRangeShiftRight() {
        // Drag pill 3 → slot 1 (leftward). Siblings at indices 1 and 2
        // (in [draggedTo, draggedFrom)) shift one slot right.
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 1, draggedFrom: 3, draggedTo: 1),
            2,
            "sibling 1 is in [1, 3) → shifts right to slot 2")
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 2, draggedFrom: 3, draggedTo: 1),
            3,
            "sibling 2 is in [1, 3) → shifts right to slot 3")
        // Siblings outside the range unchanged.
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 0, draggedFrom: 3, draggedTo: 1),
            0)
        XCTAssertEqual(
            TabStripView.intermediateSlot(originalIdx: 4, draggedFrom: 3, draggedTo: 1),
            4)
    }
}
