import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for `TabStripView`'s NEW pill-gesture contract.
///
/// Why blind (per `feedback_blind_test_writing`): a test author who has seen
/// the implementation tends to write tests that mirror the code's shape and so
/// pass for the wrong reason. These tests are written purely from the behavior
/// contract, and are deliberately engineered around the two changes that this
/// revision makes to the previous behavior:
///
///   1. DIRECTION HEURISTIC REMOVED. The old design moved the window when a
///      pill was dragged *vertically* with no modifier (a `classifyDrag` with a
///      baked-in 1.5 vertical-dominance bias). That direction classifier is
///      GONE. The new pure classifier is `classifyPillDrag(...)` and direction
///      no longer matters: any no-modifier drag past threshold REORDERS, and a
///      window move requires the configured modifier (in ANY axis). The
///      headline regression here is `test_plain_straightDown_reorders_*`: a
///      straight-DOWN no-modifier drag now reorders and must NOT move the
///      window — the exact inverse of the old behavior.
///
///   2. SELECTION DEFERRED TO mouseUp-as-click (a user-reported bug). Selection
///      (`onSelectWindow`) used to fire on mouseDown, which meant merely
///      pressing a pill — or starting a drag from it — switched the active tab.
///      It must now fire ONLY on a mouseUp that released without the gesture
///      ever crossing the drag threshold (a true click). It must NOT fire on
///      mouseDown, and must NEVER fire on any drag (reorder OR window-move).
///      The `test_selection_*` group pins this; those are the bug-regression
///      tests.
///
/// The pure classifier under test (per the refined contract), rules in order:
///
///   classifyPillDrag(dx, dy, threshold, hasMoveModifier):
///     dx or dy non-finite       -> .pending     (degenerate sample ignored,
///                                                 REGARDLESS of hasMoveModifier)
///     max(|dx|, |dy|) < threshold
///                               -> .pending     (not moved enough yet,
///                                                 REGARDLESS of hasMoveModifier)
///     hasMoveModifier == true    -> .windowMove  (ANY axis)
///     else                       -> .reorder     (ANY axis; direction is dead)
///
/// The strip's gesture state machine on top of that classifier:
///
///   ARMED (pendingDragPillIndex non-nil, dragState nil)
///    -- mouseDragged classified .pending     --> ARMED (unchanged)
///    -- mouseDragged classified .reorder      --> DRAGGING (reorder path)
///    -- mouseDragged classified .windowMove   --> IDLE + requestWindowDrag(event)
///                                                  (no reorder, no orderDidChange)
///    -- mouseUp with no drag ever started     --> IDLE + onSelectWindow(pill)
///
/// The `requestWindowDrag` seam is injected so a window move can be spied on
/// without a live NSWindow / `performDrag(with:)`.
///
/// Memory + safety budget (per `feedback_test_memory_safety` /
/// `feedback_test_real_shell_controllers`):
///   - Per test: <= 5 stub tab `NSWindow` instances (~40 KB each), all with
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
        // (TabOrderCoordinator.shared.move), mutating singleton state. Reset so
        // neither the next test here nor any later suite inherits dirty state.
        TabOrderCoordinator.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - Setup helpers

    private func makeStubWindows(_ count: Int, prefix: String = "w") -> [NSWindow] {
        (0..<count).map { i in
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            w.title = "\(prefix)-\(i)"
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
        mouseEvent(type, at: p, modifierFlags: [], clickCount: clickCount)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at p: NSPoint,
                            modifierFlags: NSEvent.ModifierFlags,
                            clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: p, modifierFlags: modifierFlags,
            timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: clickCount, pressure: 1.0
        )!
    }

    private func pillCenter(_ frame: CGRect) -> NSPoint {
        NSPoint(x: frame.midX, y: frame.midY)
    }

    private func drainMainQueue() {
        let tick = expectation(description: "tick")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { tick.fulfill() }
        wait(for: [tick], timeout: 1.0)
    }

    // MARK: - A. classifyPillDrag pure table — no modifier
    //
    // With no modifier, any sample past threshold reorders REGARDLESS of axis.
    // This is the core of the direction-heuristic removal: the old code split
    // on |dy| vs |dx|; the new code does not look at direction at all.

    func test_classifyPillDrag_belowThreshold_x_isPending() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 3, dy: 0, threshold: 5,
                                          hasMoveModifier: false),
            .pending,
            "|dx|=3 < threshold 5 -> pending")
    }

    func test_classifyPillDrag_belowThreshold_y_isPending() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 0, dy: 3, threshold: 5,
                                          hasMoveModifier: false),
            .pending,
            "|dy|=3 < threshold 5 -> pending")
    }

    func test_classifyPillDrag_belowThreshold_diagonal_isPending() {
        // max(|3|,|4|) = 4 < 5 -> still pending even though it's diagonal.
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 3, dy: 4, threshold: 5,
                                          hasMoveModifier: false),
            .pending,
            "max(|dx|,|dy|)=4 < threshold 5 -> pending")
    }

    func test_classifyPillDrag_noModifier_pastThreshold_horizontal_isReorder() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 40, dy: 0, threshold: 5,
                                          hasMoveModifier: false),
            .reorder,
            "(40,0) no modifier past threshold -> reorder")
    }

    /// HEADLINE INVERSION (contract 1, vertical-now-reorders): a pure VERTICAL
    /// no-modifier drag used to be a window move; it must now be a reorder.
    func test_classifyPillDrag_noModifier_pastThreshold_vertical_isReorder_INVERSION() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 0, dy: 40, threshold: 5,
                                          hasMoveModifier: false),
            .reorder,
            "(0,40) no modifier: direction heuristic REMOVED -> reorder (was windowMove)")
    }

    func test_classifyPillDrag_noModifier_pastThreshold_diagonal_isReorder() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 20, dy: 30, threshold: 5,
                                          hasMoveModifier: false),
            .reorder,
            "(20,30) no modifier diagonal -> reorder (direction does not matter)")
    }

    func test_classifyPillDrag_noModifier_exactlyAtThreshold_isReorder() {
        // m == threshold is NOT below threshold; no modifier -> reorder.
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 5, dy: 0, threshold: 5,
                                          hasMoveModifier: false),
            .reorder,
            "(5,0) exactly at threshold, no modifier -> reorder")
    }

    func test_classifyPillDrag_noModifier_negative_classifiesByMagnitude() {
        // Sign must not matter: (-40,0) magnitude-40 -> reorder.
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: -40, dy: 0, threshold: 5,
                                          hasMoveModifier: false),
            .reorder,
            "(-40,0) classified by magnitude, no modifier -> reorder")
    }

    // MARK: - A2. classifyPillDrag pure table — with modifier
    //
    // With the move modifier held, any sample past threshold is a windowMove
    // REGARDLESS of axis (horizontal window move is now possible).

    func test_classifyPillDrag_modifier_pastThreshold_horizontal_isWindowMove_INVERSION() {
        // Old behavior: horizontal-with-modifier was not a window move. New: it is.
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 40, dy: 0, threshold: 5,
                                          hasMoveModifier: true),
            .windowMove,
            "(40,0) modifier held -> windowMove (horizontal window move now possible)")
    }

    func test_classifyPillDrag_modifier_pastThreshold_vertical_isWindowMove() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 0, dy: 40, threshold: 5,
                                          hasMoveModifier: true),
            .windowMove,
            "(0,40) modifier held -> windowMove")
    }

    func test_classifyPillDrag_modifier_pastThreshold_diagonal_isWindowMove() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 25, dy: 25, threshold: 5,
                                          hasMoveModifier: true),
            .windowMove,
            "(25,25) modifier held diagonal -> windowMove (any axis)")
    }

    func test_classifyPillDrag_modifier_exactlyAtThreshold_isWindowMove() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 5, dy: 0, threshold: 5,
                                          hasMoveModifier: true),
            .windowMove,
            "(5,0) exactly at threshold, modifier held -> windowMove")
    }

    // MARK: - A3. classifyPillDrag — threshold gate dominates the modifier
    //
    // Below threshold is .pending REGARDLESS of the modifier. The modifier
    // never lets a sub-threshold sample commit to a window move.

    func test_classifyPillDrag_modifier_belowThreshold_isPending() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 3, dy: 0, threshold: 5,
                                          hasMoveModifier: true),
            .pending,
            "(3,0) below threshold stays pending even with modifier held")
    }

    func test_classifyPillDrag_modifier_belowThreshold_diagonal_isPending() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 3, dy: 4, threshold: 5,
                                          hasMoveModifier: true),
            .pending,
            "(3,4) max magnitude 4 < threshold 5: pending even with modifier")
    }

    // MARK: - A4. classifyPillDrag — the threshold PARAMETER is consulted
    //
    // Prove `threshold` is actually used (not a hard-coded constant). With
    // threshold 10, a delta of 6 stays pending where it would commit at 5.

    func test_classifyPillDrag_honorsThresholdParameter_noModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 6, dy: 0, threshold: 10,
                                          hasMoveModifier: false),
            .pending,
            "(6,0) threshold 10: 6 < 10 -> pending")
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 12, dy: 0, threshold: 10,
                                          hasMoveModifier: false),
            .reorder,
            "(12,0) threshold 10: 12 >= 10, no modifier -> reorder")
    }

    func test_classifyPillDrag_honorsThresholdParameter_withModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 6, dy: 0, threshold: 10,
                                          hasMoveModifier: true),
            .pending,
            "(6,0) threshold 10 with modifier: 6 < 10 -> pending (gate first)")
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 12, dy: 0, threshold: 10,
                                          hasMoveModifier: true),
            .windowMove,
            "(12,0) threshold 10 with modifier: 12 >= 10 -> windowMove")
    }

    // MARK: - A5. classifyPillDrag — non-finite guard (degenerate samples)
    //
    // A NaN / +/-infinity component is a degenerate sample and must be ignored:
    // classifyPillDrag returns .pending rather than committing on garbage —
    // REGARDLESS of the modifier (the non-finite guard precedes the modifier).

    func test_classifyPillDrag_nanDx_isPending_noModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: CGFloat.nan, dy: 0, threshold: 5,
                                          hasMoveModifier: false),
            .pending,
            "dx = NaN -> degenerate sample -> pending")
    }

    func test_classifyPillDrag_nanDx_isPending_withModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: CGFloat.nan, dy: 0, threshold: 5,
                                          hasMoveModifier: true),
            .pending,
            "dx = NaN -> degenerate sample -> pending even with modifier")
    }

    func test_classifyPillDrag_nanDy_isPending_withModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 0, dy: CGFloat.nan, threshold: 5,
                                          hasMoveModifier: true),
            .pending,
            "dy = NaN -> degenerate sample -> pending even with modifier")
    }

    func test_classifyPillDrag_infiniteDx_isPending_withModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: CGFloat.infinity, dy: 0, threshold: 5,
                                          hasMoveModifier: true),
            .pending,
            "dx = +infinity -> degenerate sample -> pending even with modifier")
    }

    func test_classifyPillDrag_negativeInfiniteDy_isPending_noModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: 0, dy: -CGFloat.infinity, threshold: 5,
                                          hasMoveModifier: false),
            .pending,
            "dy = -infinity -> degenerate sample -> pending")
    }

    func test_classifyPillDrag_bothInfinite_isPending_withModifier() {
        XCTAssertEqual(
            TabStripView.classifyPillDrag(dx: CGFloat.infinity, dy: CGFloat.infinity,
                                          threshold: 5, hasMoveModifier: true),
            .pending,
            "dx = dy = +infinity -> degenerate sample -> pending even with modifier")
    }

    // MARK: - B. plain (no-modifier) pill drag past threshold REORDERS, any axis
    //
    // Contract 2. The headline behavior change vs the old code: a straight-DOWN
    // no-modifier drag must reorder and must NOT move the window.

    /// VERTICAL-NOW-REORDERS regression (contract 2 headline): a straight-down
    /// no-modifier drag past threshold must promote to the reorder .dragging
    /// state and must NOT fire the window-move seam. The OLD code moved the
    /// window here.
    func test_plain_straightDown_reorders_noWindowMove_INVERSION() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        XCTAssertGreaterThanOrEqual(frames.count, 2,
            "test precondition: at least 2 pill frames")

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Straight down: dx=0, dy=10 — no modifier, well past the 5pt threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x, y: down.y + 10)))

        XCTAssertEqual(fired, 0,
            "straight-down no-modifier drag must NOT move the window (direction heuristic removed)")
        let state = strip.dragStateForTesting
        XCTAssertNotNil(state,
            "straight-down no-modifier drag past threshold must promote to the reorder .dragging state")
        XCTAssertEqual(state?.originalIndex, grabbed,
            "reorder originalIndex must equal the grabbed pill index")
    }

    func test_plain_horizontal_reorders_noWindowMove() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Horizontal: dx=10, dy=0 — no modifier past threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x + 10, y: down.y)))

        XCTAssertEqual(fired, 0,
            "horizontal no-modifier drag must NOT move the window")
        let state = strip.dragStateForTesting
        XCTAssertNotNil(state,
            "horizontal no-modifier drag past threshold must promote to the reorder .dragging state")
        XCTAssertEqual(state?.originalIndex, grabbed,
            "reorder originalIndex must equal the grabbed pill index")
    }

    // MARK: - C. modifier-bearing pill drag MOVES the window, any axis
    //
    // Contract 3. Default modifier is Command; with it held, ANY delta past
    // threshold (horizontal OR vertical) fires the window-move seam exactly
    // once, does NOT enter the reorder .dragging state, resets to idle, and
    // posts NO orderDidChange.

    func test_commandDrag_horizontal_movesWindowOnce_clearsState() {
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }

        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        XCTAssertGreaterThanOrEqual(frames.count, 2,
            "test precondition: at least 2 pill frames")

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange, object: nil, queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let down = pillCenter(frames[1])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Command held + HORIZONTAL delta past threshold (dx=10, dy=0). Without
        // the modifier this is a reorder; the modifier must move the window.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x + 10, y: down.y),
                                            modifierFlags: [.command]))

        XCTAssertEqual(fired, 1,
            "Command horizontal drag past threshold must call requestWindowDrag exactly once")
        XCTAssertNil(strip.dragStateForTesting,
            "Command drag must NOT enter the reorder .dragging state")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "Command drag must reset the strip's drag state to idle")

        drainMainQueue()
        XCTAssertEqual(observed, 0,
            "Command drag must NOT post orderDidChange (no reorder commit)")
    }

    func test_commandDrag_vertical_movesWindowOnce_clearsState() {
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }

        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange, object: nil, queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let down = pillCenter(frames[1])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Command held + VERTICAL delta past threshold (dx=0, dy=10).
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x, y: down.y + 10),
                                            modifierFlags: [.command]))

        XCTAssertEqual(fired, 1,
            "Command vertical drag past threshold must call requestWindowDrag exactly once")
        XCTAssertNil(strip.dragStateForTesting,
            "Command drag must NOT enter the reorder .dragging state")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "Command drag must reset the strip's drag state to idle")

        drainMainQueue()
        XCTAssertEqual(observed, 0,
            "Command drag must NOT post orderDidChange (no reorder commit)")
    }

    // MARK: - C2. the configured window-drag modifier is actually READ
    //
    // Prove the pill path reads Preferences.shared.windowDragModifier rather
    // than hardcoding Command: with the pref set to "Option-Command", a
    // Command-only drag must NOT move the window (it reorders), and an
    // Option-Command drag MUST move it.

    /// Case A — WRONG modifier does NOT move the window. With the configured
    /// modifier set to Option-Command, a Command-only drag past threshold must
    /// behave like a normal reorder: no window move, reorder armed. This is the
    /// assertion that fails a hardcoded-Command impl.
    func test_optionCommandPref_commandOnlyDrag_reorders_doesNotMove() {
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Option-Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }

        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting
        XCTAssertGreaterThanOrEqual(frames.count, 2,
            "test precondition: at least 2 pill frames")

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Command ONLY (not the configured Option-Command) past threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x + 10, y: down.y),
                                            modifierFlags: [.command]))

        XCTAssertEqual(fired, 0,
            "with the configured modifier Option-Command, a Command-only drag must NOT move the window — proves Command is not hardcoded")
        XCTAssertNotNil(strip.dragStateForTesting,
            "a Command-only drag (wrong modifier) is a normal reorder, so it must arm the .dragging state")
    }

    /// Case B — RIGHT modifier DOES move the window. With the configured
    /// modifier set to Option-Command, an Option-Command drag past threshold
    /// must fire the window-move seam once and leave no reorder-committable
    /// state.
    func test_optionCommandPref_optionCommandDrag_movesWindowOnce() {
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Option-Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }

        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        var observed = 0
        let token = NotificationCenter.default.addObserver(
            forName: TabOrderCoordinator.orderDidChange, object: nil, queue: nil
        ) { _ in observed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        let down = pillCenter(frames[1])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Option-Command (the configured modifier) past threshold.
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged,
                                            at: NSPoint(x: down.x + 10, y: down.y),
                                            modifierFlags: [.option, .command]))

        XCTAssertEqual(fired, 1,
            "Option-Command drag (the configured modifier) past threshold must call requestWindowDrag exactly once")
        XCTAssertNil(strip.dragStateForTesting,
            "Option-Command drag must NOT enter the reorder .dragging state")
        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "Option-Command drag must reset the strip's drag state to idle")

        drainMainQueue()
        XCTAssertEqual(observed, 0,
            "Option-Command drag must NOT post orderDidChange (no reorder commit)")
    }

    // MARK: - D. DEFERRED selection (contract 4) — the user-reported bug
    //
    // Selection (onSelectWindow) must NOT fire on mouseDown and must NEVER fire
    // on any drag. It fires ONLY on a mouseUp that released without the gesture
    // ever crossing the drag threshold (a true click). Each test grabs a
    // NON-active pill (index 1; the strip was created selected: tabs[0]) so a
    // fired selection is observable.

    /// 4a — mouseDown alone does NOT select (selection is deferred to mouseUp).
    func test_selection_mouseDownAlone_doesNotSelect() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var selections = 0
        strip.onSelectWindow = { _ in selections += 1 }

        let grabbed = 1
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: pillCenter(frames[grabbed])))

        XCTAssertEqual(selections, 0,
            "selection must be DEFERRED: mouseDown alone must not fire onSelectWindow")
    }

    /// 4b — a true click (down + up at the same point, no drag) selects exactly
    /// once, with the grabbed pill's window by identity.
    func test_selection_clickWithoutDrag_selectsGrabbedWindowOnce() {
        let (strip, tabs) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var selected: [NSWindow] = []
        strip.onSelectWindow = { selected.append($0) }

        let grabbed = 1
        let p = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: p))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: p))

        XCTAssertEqual(selected.count, 1,
            "a click (down+up, no drag) on a non-active pill must fire onSelectWindow exactly once")
        XCTAssertTrue(selected.first === tabs[grabbed],
            "the selected window must be === the grabbed pill's window (identity)")
    }

    /// 4c — a no-modifier reorder drag then mouseUp must NEVER select (a drag
    /// must not switch tabs).
    func test_selection_reorderDragThenUp_doesNotSelect() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var selections = 0
        strip.onSelectWindow = { _ in selections += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // No-modifier reorder drag past threshold.
        let moved = NSPoint(x: down.x + 10, y: down.y)
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged, at: moved))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: moved))

        XCTAssertEqual(selections, 0,
            "a reorder drag must NEVER fire onSelectWindow (a drag must not switch tabs)")
    }

    /// 4d — a modifier window-move drag then mouseUp must NEVER select.
    func test_selection_windowMoveDragThenUp_doesNotSelect() {
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }

        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var selections = 0
        strip.onSelectWindow = { _ in selections += 1 }
        strip.requestWindowDrag = { _ in /* swallow */ }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Command window-move drag past threshold.
        let moved = NSPoint(x: down.x + 10, y: down.y)
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged, at: moved,
                                            modifierFlags: [.command]))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: moved,
                                       modifierFlags: [.command]))

        XCTAssertEqual(selections, 0,
            "a window-move drag must NEVER fire onSelectWindow")
    }

    /// 4e — the user's EXACT words: a straight-down no-modifier drag then
    /// mouseUp must NOT select AND must NOT move the window (it reorders).
    func test_selection_straightDownDragThenUp_doesNotSelect_doesNotMove() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var selections = 0
        strip.onSelectWindow = { _ in selections += 1 }
        var moves = 0
        strip.requestWindowDrag = { _ in moves += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // Straight down: dx=0, dy=10 — no modifier.
        let moved = NSPoint(x: down.x, y: down.y + 10)
        strip.mouseDragged(with: mouseEvent(.leftMouseDragged, at: moved))
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: moved))

        XCTAssertEqual(selections, 0,
            "straight-down drag must NOT switch tabs (no selection)")
        XCTAssertEqual(moves, 0,
            "straight-down no-modifier drag must NOT move the window (it reorders)")
    }

    // MARK: - E. below-threshold gesture stays armed, does nothing
    //
    // Contract 5. A sub-threshold nudge fires no window move, keeps the pending
    // index armed at the grabbed pill, and never promotes to .dragging.

    func test_belowThreshold_verticalNudge_staysArmed_noWindowMove() {
        let (strip, _) = makeStrip(tabCount: 3)
        let frames = strip.pillFramesForTesting

        var fired = 0
        strip.requestWindowDrag = { _ in fired += 1 }

        let grabbed = 1
        let down = pillCenter(frames[grabbed])
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: down))
        // dx=0, dy=4 — below the 5pt threshold.
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

    // MARK: - F. reserved trailing window-drag gutter
    //
    // Contract 6. After update(), the empty span at the trailing edge — past
    // the rightmost of {last pill, + button} — must be at least
    // TabStripView.minDragGutter wide, so the window stays draggable by empty
    // titlebar even when tabs fill the bar. No pill may extend into the gutter.

    private func assertGutter(_ strip: TabStripView, width: CGFloat,
                              tabs: Int, file: StaticString = #filePath,
                              line: UInt = #line) {
        let pillFrames = strip.pillFramesForTesting
        XCTAssertFalse(pillFrames.isEmpty,
            "precondition: at least one pill frame for \(tabs) tabs @ \(width)",
            file: file, line: line)
        let rightmostPillMaxX = pillFrames.map { $0.maxX }.max()!
        let addMaxX = strip.addButtonFrameForTesting.maxX
        let occupied = max(rightmostPillMaxX, addMaxX)
        let gutter = width - occupied
        XCTAssertGreaterThanOrEqual(
            gutter, TabStripView.minDragGutter,
            "trailing gutter (\(gutter)) must be >= minDragGutter for \(tabs) tabs @ width \(width)",
            file: file, line: line)
        XCTAssertLessThanOrEqual(
            rightmostPillMaxX, width - TabStripView.minDragGutter,
            "no pill may extend into the reserved gutter (\(tabs) tabs @ width \(width))",
            file: file, line: line)
    }

    func test_gutter_2tabs_width600() {
        let (strip, _) = makeStrip(tabCount: 2, width: 600)
        assertGutter(strip, width: 600, tabs: 2)
    }

    func test_gutter_3tabs_width600() {
        let (strip, _) = makeStrip(tabCount: 3, width: 600)
        assertGutter(strip, width: 600, tabs: 3)
    }

    func test_gutter_5tabs_width600() {
        let (strip, _) = makeStrip(tabCount: 5, width: 600)
        assertGutter(strip, width: 600, tabs: 5)
    }

    func test_gutter_3tabs_narrowWidth420() {
        let (strip, _) = makeStrip(tabCount: 3, width: 420)
        assertGutter(strip, width: 420, tabs: 3)
    }

    // MARK: - G. armed gesture is cancelled when the tab list changes shape mid-press
    //
    // Reviewer-found edge in the deferred-selection design: if a sibling tab
    // closes AFTER a pill press has armed a drag but BEFORE the press is
    // released, the armed gesture must be CANCELLED — otherwise the now-stale
    // grab could fire a wrong selection on the trailing mouseUp. This mirrors
    // how an in-flight reorder (.dragging) is already cancelled on a list-shape
    // change.

    func test_armedDrag_listShapeChangesBeforeMouseUp_cancelsArmed_noSelection() {
        let (strip, tabs) = makeStrip(tabCount: 3)

        var selections = 0
        strip.onSelectWindow = { _ in selections += 1 }

        // Arm a drag on a NON-active background pill (index 2; strip is
        // selected: tabs[0]).
        let frames = strip.pillFramesForTesting
        strip.mouseDown(with: mouseEvent(.leftMouseDown, at: pillCenter(frames[2])))
        XCTAssertEqual(strip.pendingDragPillIndexForTesting, 2,
            "precondition: the press must arm a drag at the grabbed index")

        // Simulate a sibling tab closing while the press is held: count 3 -> 2.
        strip.update(tabs: Array(tabs.prefix(2)), selected: tabs[0], width: 600)

        XCTAssertNil(strip.pendingDragPillIndexForTesting,
            "a list-shape change while armed must cancel the armed gesture (stale grab must not survive)")

        // Release: must not fire a wrong selection from the cancelled grab.
        strip.mouseUp(with: mouseEvent(.leftMouseUp, at: pillCenter(strip.pillFramesForTesting[0])))
        XCTAssertEqual(selections, 0,
            "a cancelled armed gesture must not fire onSelectWindow on the trailing mouseUp")
    }
}
