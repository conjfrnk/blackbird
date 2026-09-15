import XCTest
import AppKit
import Metal
import QuartzCore
@testable import Blackbird
import BBCore

/// Blind behaviour tests for synchronous presentation during resize, the
/// selection-wakes-render-loop rule, and the un-occlude draw, written from
/// the spec without sight of the implementation.
///
/// Contracts under test:
///
///  1. A fresh view's `CAMetalLayer.presentsWithTransaction` is `false`
///     (the renderer reads that flag off the drawable at present time).
///  2. `TerminalView.viewWillStartLiveResize()` flips the backing
///     `CAMetalLayer.presentsWithTransaction` AND
///     `synchronousResizePresentation` to `true`;
///     `viewDidEndLiveResize()` puts both back to `false`. The public
///     `beginSynchronousResizePresentation()` /
///     `endSynchronousResizePresentation()` pair (custom right-drag resize)
///     has the same effect and is idempotent: begin twice + end once is
///     off, end without begin stays off.
///  3. While synchronous mode is on, each `setFrameSize` performs exactly
///     one synchronous draw, observable via the DEBUG-only
///     `synchronousDrawsForTesting` counter. Outside the mode the counter
///     never moves.
///  4. Assigning a *different* value to `selection` wakes an
///     idle-throttled render loop (`isIdleThrottled` becomes `false`).
///     `_enterIdleThrottleForTesting()` is the DEBUG seam into the
///     throttled state.
///  5. `windowOcclusionDidChange(visible:)` — `false` pauses the view and
///     draws nothing; the `false → true` transition draws exactly once and
///     unpauses; a repeated `true` is not a transition and draws nothing.
///
/// **Why the layer AND the renderer flag.** `presentsWithTransaction` is
/// what makes Core Animation wait for the drawable; the renderer flag is
/// what makes it *wait for the GPU* (`waitUntilScheduled` / present-after-
/// commit). Either alone leaves a resize frame that lags the window
/// chrome, so both are asserted on every transition.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 640 × 240 headless `TerminalView` per test; never added to a
///    window, never shown, never closed. No `NSWindow`, no
///    `MainWindowController`, no PTY. `TerminalSession.makeHeadlessForTests()`
///    has no pty, so `setFrameSize`'s resize propagation touches only the
///    in-process core.
///  - One 40 × 6 `BBTerm` (240 cells, `scrollback: 16`) per test so the
///    view has a snapshot to size against.
///  - Headless views have no drawable: the "synchronous draw" is a no-op
///    inside the renderer, so the tests observe only the counter. No
///    runloop pumping, no timers. Wall time is dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class SyncPresentationBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
    }

    private func makeRig(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            device: device
        )
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
            "BBTerm init failed", file: file, line: line
        )
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil", file: file, line: line)

        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        return Rig(view: view, term: term, session: session, recorder: recorder)
    }

    private func metalLayer(
        of view: TerminalView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CAMetalLayer {
        try XCTUnwrap(
            view.layer as? CAMetalLayer,
            "precondition: an MTKView's backing layer is a CAMetalLayer",
            file: file, line: line
        )
    }

    /// Asserts both halves of the synchronous-presentation switch agree.
    private func assertSynchronousMode(
        _ view: TerminalView,
        _ expected: Bool,
        _ why: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let layer = try metalLayer(of: view, file: file, line: line)
        XCTAssertEqual(layer.presentsWithTransaction, expected,
                       "\(why): CAMetalLayer.presentsWithTransaction", file: file, line: line)
    }

    private func makeSelection(line: Int32 = 0, from: Int = 0, to: Int = 5) -> Selection {
        Selection(
            anchor: BufferPoint(line: line, col: from),
            cursor: BufferPoint(line: line, col: to),
            mode: .character
        )
    }

    // MARK: - 1. Renderer flag

    func test_freshView_presentsAsynchronously() throws {
        // The layer flag is the single source of truth (the renderer reads
        // `drawable.layer.presentsWithTransaction` at present time).
        let rig = try makeRig()
        let layer = try metalLayer(of: rig.view)
        XCTAssertFalse(layer.presentsWithTransaction,
                       "a fresh view's CAMetalLayer must not be in transaction-presentation mode")
        XCTAssertFalse(rig.view.synchronousResizePresentation,
                       "a fresh view is not in synchronous-resize mode")
    }

    // MARK: - 2. Live-resize hooks

    func test_viewWillStartLiveResize_enablesSynchronousPresentation() throws {
        let rig = try makeRig()
        try assertSynchronousMode(rig.view, false, "precondition: fresh view")
        rig.view.viewWillStartLiveResize()
        try assertSynchronousMode(rig.view, true, "after viewWillStartLiveResize")
    }

    func test_viewDidEndLiveResize_restoresAsynchronousPresentation() throws {
        let rig = try makeRig()
        rig.view.viewWillStartLiveResize()
        try assertSynchronousMode(rig.view, true, "precondition: live resize began")
        rig.view.viewDidEndLiveResize()
        try assertSynchronousMode(rig.view, false, "after viewDidEndLiveResize")
    }

    func test_beginAndEndSynchronousResizePresentation_mirrorLiveResizeHooks() throws {
        let rig = try makeRig()
        try assertSynchronousMode(rig.view, false, "precondition: fresh view")
        rig.view.beginSynchronousResizePresentation()
        try assertSynchronousMode(rig.view, true, "after beginSynchronousResizePresentation")
        rig.view.endSynchronousResizePresentation()
        try assertSynchronousMode(rig.view, false, "after endSynchronousResizePresentation")
    }

    func test_beginTwiceThenEndOnce_turnsSynchronousPresentationOff() throws {
        // Not a refcount: the custom right-drag path and AppKit's live-resize
        // path may both fire for one gesture, and one `end` must be enough.
        let rig = try makeRig()
        rig.view.beginSynchronousResizePresentation()
        rig.view.beginSynchronousResizePresentation()
        try assertSynchronousMode(rig.view, true, "precondition: two begins")
        rig.view.endSynchronousResizePresentation()
        try assertSynchronousMode(rig.view, false, "begin×2 + end×1 must be OFF (idempotent, not counted)")
    }

    func test_endWithoutBegin_isANoOp() throws {
        let rig = try makeRig()
        try assertSynchronousMode(rig.view, false, "precondition: fresh view")
        rig.view.endSynchronousResizePresentation()
        rig.view.endSynchronousResizePresentation()
        try assertSynchronousMode(rig.view, false, "end without begin must stay off and not crash")
        // The mode must still be enterable afterwards — a stray `end` must
        // not have left a negative balance that swallows the next `begin`.
        rig.view.beginSynchronousResizePresentation()
        try assertSynchronousMode(rig.view, true, "begin after a stray end must still turn the mode on")
    }

    // MARK: - 3. Synchronous draw per setFrameSize

    #if DEBUG
    func test_setFrameSize_inSynchronousMode_drawsExactlyOncePerCall() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 0, "precondition: counter starts at 0")
        rig.view.beginSynchronousResizePresentation()
        rig.view.setFrameSize(NSSize(width: 650, height: 250))
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 1,
                       "one setFrameSize in synchronous mode → exactly one synchronous draw")
        rig.view.setFrameSize(NSSize(width: 660, height: 260))
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 2,
                       "a second setFrameSize → exactly one more synchronous draw")
        rig.view.endSynchronousResizePresentation()
    }

    func test_setFrameSize_outsideSynchronousMode_doesNotDrawSynchronously() throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 0, "precondition: counter starts at 0")
        rig.view.setFrameSize(NSSize(width: 650, height: 250))
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 0,
                       "default mode: setFrameSize must not force a synchronous draw")

        // And after a full begin/end cycle the mode is really off again.
        rig.view.beginSynchronousResizePresentation()
        rig.view.endSynchronousResizePresentation()
        rig.view.setFrameSize(NSSize(width: 640, height: 240))
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 0,
                       "after begin+end, setFrameSize must be back to the async path")
    }
    #endif

    // MARK: - 4. Selection wakes the render loop

    func test_selectionChange_wakesIdleThrottledRenderLoop() throws {
        let rig = try makeRig()
        XCTAssertNil(rig.view.selection, "precondition: no selection on a fresh view")
        rig.view._enterIdleThrottleForTesting()
        XCTAssertTrue(rig.view.isIdleThrottled, "precondition: the DEBUG seam enters the throttled state")

        rig.view.selection = makeSelection()

        XCTAssertFalse(rig.view.isIdleThrottled,
                       "a new selection must wake the render loop so the highlight paints at full rate")
    }

    func test_clearingSelection_wakesIdleThrottledRenderLoop() throws {
        let rig = try makeRig()
        rig.view.selection = makeSelection()
        rig.view._enterIdleThrottleForTesting()
        XCTAssertTrue(rig.view.isIdleThrottled, "precondition: throttled with a selection present")

        rig.view.selection = nil

        XCTAssertFalse(rig.view.isIdleThrottled,
                       "nil is a different value from a live selection: clearing must wake the loop too")
    }

    func test_replacingSelectionWithDifferentRange_wakesIdleThrottledRenderLoop() throws {
        let rig = try makeRig()
        rig.view.selection = makeSelection(line: 0, from: 0, to: 5)
        rig.view._enterIdleThrottleForTesting()
        XCTAssertTrue(rig.view.isIdleThrottled, "precondition: throttled")

        rig.view.selection = makeSelection(line: 1, from: 2, to: 9)

        XCTAssertFalse(rig.view.isIdleThrottled,
                       "an extended drag replaces the selection value and must wake the loop")
    }

    // MARK: - 5. Un-occlude draws once

    #if DEBUG
    func test_occlusionHidden_pausesWithoutDrawing() throws {
        let rig = try makeRig()
        XCTAssertFalse(rig.view.isPaused, "precondition: a fresh view is not paused")
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 0, "precondition: counter starts at 0")

        rig.view.windowOcclusionDidChange(visible: false)

        XCTAssertTrue(rig.view.isPaused, "an occluded window pauses the display link")
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, 0,
                       "going hidden must not draw — nobody can see it")
    }

    func test_occlusionVisibleAfterHidden_drawsOnceAndUnpauses() throws {
        let rig = try makeRig()
        rig.view.windowOcclusionDidChange(visible: false)
        XCTAssertTrue(rig.view.isPaused, "precondition: hidden pauses")
        let before = rig.view.synchronousDrawsForTesting

        rig.view.windowOcclusionDidChange(visible: true)

        XCTAssertFalse(rig.view.isPaused, "un-occlude must resume the display link")
        XCTAssertEqual(rig.view.synchronousDrawsForTesting, before + 1,
                       "the hidden → visible transition draws exactly once so the first visible frame is current, not stale")
    }

    func test_occlusionVisibleTwice_drawsOnlyOnTheTransition() throws {
        let rig = try makeRig()
        rig.view.windowOcclusionDidChange(visible: false)
        rig.view.windowOcclusionDidChange(visible: true)
        let afterFirst = rig.view.synchronousDrawsForTesting
        XCTAssertEqual(afterFirst, 1, "precondition: the first un-occlude drew once")

        rig.view.windowOcclusionDidChange(visible: true)

        XCTAssertEqual(rig.view.synchronousDrawsForTesting, afterFirst,
                       "a repeated visible=true is not a transition and must not draw again")
        XCTAssertFalse(rig.view.isPaused, "still unpaused after the repeated notification")
    }
    #endif
}
