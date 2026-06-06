import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for `TabStripView`'s NEW "drag a pill vertically to move the
/// window" capability, layered on top of the existing horizontal
/// drag-to-reorder gesture.
///
/// Why blind (per `feedback_blind_test_writing`): a wrong-but-plausible
/// implementation could trivially pass a one-sided test suite. Two concrete
/// failure modes this file is engineered to catch:
///
///   1. A direction classifier that only inspects |dx| (the shape of the
///      *current* reorder code) would treat a straight-down drag as
///      "below horizontal threshold → stay armed" and never move the
///      window. Driving a pure-vertical drag (dx=0, dy=10) and asserting
///      the window-move seam fired exactly once is what exposes that.
///   2. An implementation that calls the window-move seam AND also promotes
///      to the reorder `.dragging` state (or posts `orderDidChange`) on a
///      vertical drag would "work" visually but leave a committable reorder
///      armed. Asserting `dragStateForTesting == nil`, no pending index,
///      and zero `orderDidChange` observations on the vertical path closes
///      that hole. Symmetrically, the horizontal path must NOT fire the
///      window-move seam.
///
/// The state machine under test (per the contract):
///
///   classifyDrag(dx, dy, threshold):  let m = max(|dx|, |dy|)
///     m < threshold            -> .pending      (not committed yet)
///     |dx| > |dy|              -> .reorder      (horizontal-dominant)
///     else                     -> .windowMove   (vertical-dominant;
///                                                 exact 45° ties → windowMove)
///
///   ARMED (pendingDragPillIndex non-nil, dragState nil)
///    ── mouseDragged classified .pending     ──▶ ARMED (unchanged)
///    ── mouseDragged classified .reorder      ──▶ DRAGGING (existing path)
///    ── mouseDragged classified .windowMove   ──▶ IDLE + requestWindowDrag(event)
///                                                  (no reorder, no orderDidChange)
///
/// The `requestWindowDrag` seam is injected so the move can be spied on
/// without a live NSWindow / `performDrag(with:)`.
///
/// Memory + safety budget (per `feedback_test_memory_safety` /
/// `feedback_test_real_shell_controllers`):
///   - Per test: ≤ 3 stub tab `NSWindow` instances (~40 KB each), all with
///     `tabbingMode = .disallowed` so AppKit can't merge them into a live
///     group left behind by a sibling test and crash the xctest host.
///   - No `MainWindowController`, no PTYs, no real shells.
///   - The static classifier runs with zero AppKit setup.
///   - Wall time: < 50 ms per test.
final class TabStripWindowDragTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        // A buggy impl might still route through the reorder commit path
        // (TabOrderCoordinator.shared.move), mutating singleton state.
        // Reset so neither the next test here nor any later suite inherits
        // dirty coordinator state.
        TabOrderCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Setup helpers (mirror TabStripDragTests)

    private func makeStubWindows(_ count: Int, prefix: String = "w") -> [NSWindow] {
        (0..<count).map { i in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            w.title = "\(prefix)-\(i)"
            // See TabStripDragTests for the full rationale: bare NSWindows
            // can implicitly share a tabbing identity; `.disallowed` stops
            // AppKit merging our stubs into a live group from a prior test
            // and crashing the host on `.tabGroup` access.
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

    /// No-modifier mouse event — same signature/behavior as the existing
    /// `TabStripDragTests.mouseEvent`. `modifierFlags: []` is load-bearing:
    /// the window-move-on-vertical-drag gesture is the *unmodified* gesture
    /// (the contract is explicit: "in a non-horizontal direction, no
    /// modifier key").
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

    /// Centre of a pill body. The strip is `isFlipped` (y grows downward),
    /// 28pt tall, pills at y=4 height 24 → midY = 16. midX dodges the
    /// leading 14pt close hotspot. A vertical drag from here keeps x fixed
    /// and changes y; a horizontal drag keeps y fixed and changes x.
    private func pillCenter(_ frame: CGRect) -> NSPoint {
        NSPoint(x: frame.midX, y: frame.midY)
    }

    /// Async-tick helper: lets any (potentially async-posted)
    /// `orderDidChange` notification land before we assert it did NOT fire.
    private func drainMainQueue() {
        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)
    }

    // MARK: - A. classifyDrag pure table

    func test_classifyDrag_belowThreshold_x_isPending() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 3, dy: 0, threshold: 5),
            .pending,
            "|dx|=3 < threshold 5 → pending")
    }

    func test_classifyDrag_belowThreshold_y_isPending() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 0, dy: 3, threshold: 5),
            .pending,
            "|dy|=3 < threshold 5 → pending")
    }

    func test_classifyDrag_belowThreshold_diagonal_isPending() {
        // max(|3|,|4|) = 4 < 5 → still pending even though it's diagonal.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 3, dy: 4, threshold: 5),
            .pending,
            "max(|dx|,|dy|)=4 < threshold 5 → pending")
    }

    func test_classifyDrag_exactlyAtThreshold_horizontal_isReorder() {
        // m == threshold is NOT below threshold, and |dx| > |dy| → reorder.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 5, dy: 0, threshold: 5),
            .reorder,
            "(5,0) at threshold, horizontal-dominant → reorder")
    }

    func test_classifyDrag_exactlyAtThreshold_vertical_isWindowMove() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 0, dy: 5, threshold: 5),
            .windowMove,
            "(0,5) at threshold, vertical-dominant → windowMove")
    }

    func test_classifyDrag_horizontalDominant_pastThreshold_isReorder() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 6, dy: 1, threshold: 5),
            .reorder,
            "(6,1) |dx|>|dy| → reorder")
    }

    func test_classifyDrag_verticalDominant_pastThreshold_isWindowMove() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 1, dy: 6, threshold: 5),
            .windowMove,
            "(1,6) |dy|>|dx| → windowMove")
    }

    func test_classifyDrag_exact45DegreeTie_isWindowMove() {
        // |dx| == |dy|: the "else" branch wins → windowMove.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 5, dy: 5, threshold: 5),
            .windowMove,
            "(5,5) exact 45° tie → windowMove (ties go to windowMove)")
    }

    func test_classifyDrag_largePureHorizontal_isReorder() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 40, dy: 0, threshold: 5),
            .reorder,
            "(40,0) large pure-horizontal → reorder")
    }

    func test_classifyDrag_largePureVertical_isWindowMove() {
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 0, dy: 40, threshold: 5),
            .windowMove,
            "(0,40) large pure-vertical → windowMove")
    }

    func test_classifyDrag_negativeHorizontal_classifiesByMagnitude() {
        // Sign must not matter: (-6,0) is magnitude-6 horizontal → reorder.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: -6, dy: 0, threshold: 5),
            .reorder,
            "(-6,0) classified by |dx| → reorder")
    }

    func test_classifyDrag_negativeVertical_classifiesByMagnitude() {
        // (0,-6) is magnitude-6 vertical → windowMove.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 0, dy: -6, threshold: 5),
            .windowMove,
            "(0,-6) classified by |dy| → windowMove")
    }

    func test_classifyDrag_negativeDiagonal_belowThreshold_isPending() {
        // Both negative, max magnitude 4 < 5 → pending.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: -4, dy: -3, threshold: 5),
            .pending,
            "(-4,-3) max magnitude 4 < threshold 5 → pending")
    }

    func test_classifyDrag_honorsThresholdParameter() {
        // Prove the parameter is actually consulted, not the hard-coded 5.
        // (6,0) is past the default-5 threshold but below a threshold of 10
        // → pending; (12,0) crosses 10 → reorder; (0,12) → windowMove.
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 6, dy: 0, threshold: 10),
            .pending,
            "(6,0) with threshold 10: max magnitude 6 < 10 → pending")
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 12, dy: 0, threshold: 10),
            .reorder,
            "(12,0) with threshold 10: crosses 10, horizontal → reorder")
        XCTAssertEqual(
            TabStripView.classifyDrag(dx: 0, dy: 12, threshold: 10),
            .windowMove,
            "(0,12) with threshold 10: crosses 10, vertical → windowMove")
    }

    // MARK: - B. vertical pill drag past threshold moves the window

    func test_verticalPillDrag_pastThreshold_movesWindowOnce_andClearsState() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        XCTAssertGreaterThanOrEqual(frames.count, 2,
            "test precondition: at least 2 pill frames")

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        // Observe orderDidChange so we can prove the window-move path does
        // NOT also commit a reorder.
        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let down = pillCenter(frames[1])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Straight down: dx=0, dy=10 — vertical-dominant, well past the 5pt
        // threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x, y: down.y + 10)))

        XCTAssertEqual(fired, 1,
            "vertical drag past threshold must call requestWindowDrag exactly once")
        XCTAssertNil(strip.dragStateForTesting,
            "window-move drag must NOT enter the reorder .dragging state")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "window-move drag must reset the strip's drag state to idle")

        drainMainQueue()
        XCTAssertEqual(observed, 0,
            "window-move drag must NOT post orderDidChange")
    }

    // MARK: - C. horizontal pill drag past threshold still reorders

    func test_horizontalPillDrag_pastThreshold_stillReorders_noWindowMove() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Horizontal: dx=10, dy=0 — horizontal-dominant past threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x + 10, y: down.y)))

        XCTAssertEqual(fired, 0,
            "horizontal drag must NOT call requestWindowDrag")
        let state = strip.dragStateForTesting
        XCTAssertNotNil(state,
            "horizontal drag past threshold must promote to the reorder .dragging state")
        XCTAssertEqual(state?.originalIndex, grabbed,
            "reorder originalIndex must equal the grabbed pill index")
    }

    // MARK: - D. below-threshold drag stays armed, no window move

    func test_belowThreshold_verticalNudge_staysArmed_noWindowMove() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // dx=0, dy=4 — below the 5pt threshold in every direction.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x, y: down.y + 4)))

        XCTAssertEqual(fired, 0,
            "sub-threshold drag must NOT call requestWindowDrag")
        XCTAssertEqual(strip.pendingDragPillIndexForTesting, grabbed,
            "sub-threshold drag must stay armed at the grabbed index")
        XCTAssertNil(strip.dragStateForTesting,
            "sub-threshold drag must NOT promote to .dragging")
    }

    func test_belowThreshold_diagonalNudge_staysArmed_noWindowMove() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // dx=3, dy=3 — max magnitude 3 < 5, diagonal sub-threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x + 3, y: down.y + 3)))

        XCTAssertEqual(fired, 0,
            "sub-threshold diagonal drag must NOT call requestWindowDrag")
        XCTAssertEqual(strip.pendingDragPillIndexForTesting, grabbed,
            "sub-threshold diagonal drag must stay armed at the grabbed index")
        XCTAssertNil(strip.dragStateForTesting,
            "sub-threshold diagonal drag must NOT promote to .dragging")
    }

    // MARK: - E. window-move drag leaves no reorder-committable state

    func test_windowMoveDrag_thenMouseUp_noReorderCommit_stateIdle() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange,
            object: nil,
            queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let down = pillCenter(frames[1])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Vertical drag commits to window-move (state should clear to idle).
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x, y: down.y + 10)))
        // A trailing mouseUp must not resurrect a reorder commit from the
        // already-idle state.
        strip.mouseUp(with: mouseEvent(.leftMouseUp,
                                       at: NSPoint(x: down.x, y: down.y + 10)))

        XCTAssertEqual(fired, 1,
            "exactly one window-move request across the whole gesture")
        XCTAssertNil(strip.dragStateForTesting,
            "after window-move + mouseUp the strip must be idle (no dragState)")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "after window-move + mouseUp the strip must be idle (no pending)")

        drainMainQueue()
        XCTAssertEqual(observed, 0,
            "a window-move gesture must never post orderDidChange, even after mouseUp")
    }
}
