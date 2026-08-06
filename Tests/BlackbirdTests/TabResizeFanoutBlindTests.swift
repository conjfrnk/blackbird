import XCTest
import AppKit
import Metal
import MetalKit
@testable import Blackbird

/// Blind-authored behaviour tests for **window resize must reach every tab,
/// and the resize path must not stall main** (issue #29).
///
/// Written purely from the design contract, WITHOUT reading
/// `TabFrameSync.swift`, `ResizeController.swift`, `MetalRenderer.swift`,
/// `MainWindowController.swift`, or the `propagateResize` implementation —
/// project policy (CLAUDE.md "Author new behavior tests blind") so a
/// wrong-but-plausible implementation can't pass for the wrong reason.
///
/// ## Background
///
/// Blackbird uses macOS native tabs: every tab is its own `NSWindow` inside an
/// `NSWindowTabGroup`. AppKit applies a group resize to a BACKGROUND tab
/// lazily — only when that tab is next selected — so until then the background
/// tab's PTY winsize is stale and its shell/TUI renders at the old geometry.
/// The fix pushes the front window's settled frame onto its sibling tab
/// windows. Separately, a COLUMN change reflows the whole scrollback
/// (~10 ms at 20k lines, ~37 ms at 100k) and used to run synchronously on
/// main for every cell-boundary crossing of a live drag; a ROW-only change is
/// measured free (~0.000 ms).
///
/// ## What each section pins
///
///   - **A** `TabFrameSync.targets(front:frame:groupWindows:)` — the pure
///     fan-out decision: who actually needs a `setFrame`.
///   - **B** The fan-out must push a FRAME, never a `(cols, rows)`: the same
///     pixel frame maps through each tab's OWN metrics, so tabs at different
///     text sizes land on different grids.
///   - **C** `TerminalView.propagateResize` delivery policy:
///     `.sync` for the first resize + row-only changes, `.coalesced` for
///     column changes (the expensive reflow never runs synchronously on
///     main), `.async` for the font-change path, and nothing at all when the
///     resize doesn't cross a cell boundary.
///   - **D** `TerminalSession.resizeCoalesced(to:)` semantics: latest-wins,
///     the same clamp as the other resize paths, and a clean no-op after
///     `terminate()`.
///   - **E** `MetalRenderer`'s frame-skip cache must key on the VIEWPORT —
///     the same snapshot drawn into a differently-sized view is a different
///     image and must be re-encoded.
///
/// ## Headless-xctest safety discipline (this project has crashed hosts)
///
///   - Every `NSWindow` here is constructed `defer: true`, never shown, never
///     merged into a tab group, never `close()`d or `orderOut()`n, and parked
///     untouched in a static array for process lifetime (a closed/ordered-out
///     member of a headlessly-merged tab group poisons a deferred
///     CoreAnimation transaction that SEGVs the host later — see
///     `TabMoverTests`). Section A is deliberately written so the fan-out
///     decision is testable with NO live tab group at all.
///   - No `MainWindowController`, no real shells: every session comes from
///     `TerminalSession.makeHeadlessForTests()` (no PTY).
///   - Grids stay small (largest live grid outside the clamp test is
///     ~120×30); the one 1000×1000 clamp test is gated by
///     `requireTestFitsInBudget`.
///   - `Preferences.shared.fontSize` is saved/restored around every test so
///     per-view font state can't leak into sibling suites.
@MainActor
final class TabResizeFanoutBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Headless sessions created by a test. Held strongly because
    /// `TerminalView.session` is `weak`; terminated in `tearDown`.
    private var liveSessions: [TerminalSession] = []

    private var originalFontSize: Double = 13

    override func setUp() {
        super.setUp()
        originalFontSize = Preferences.shared.fontSize
        Preferences.shared.fontSize = 13
        pumpMainQueue()
    }

    override func tearDown() {
        for session in liveSessions { session.terminate() }
        liveSessions.removeAll()
        Preferences.shared.fontSize = originalFontSize
        pumpMainQueue()
        super.tearDown()
    }

    /// A few main-queue turns so the `Preferences.objectWillChange` →
    /// `receive(on: .main)` hop lands. Same helper as `PerViewTextSizeTests`.
    private func pumpMainQueue(times: Int = 2) {
        for i in 0..<times {
            let exp = expectation(description: "main queue turn \(i)")
            DispatchQueue.main.async { exp.fulfill() }
            wait(for: [exp], timeout: 2.0)
        }
    }

    // MARK: - Shared helpers

    /// Windows are parked UNTOUCHED for process lifetime — never shown, never
    /// closed, never ordered out. They were never on screen, so parking costs
    /// nothing visible and avoids the deferred-CA-transaction SEGV class.
    private static var parkedWindows: [NSWindow] = []

    /// A bare, NEVER-SHOWN window placed at `frame`. `tabbingMode` is
    /// `.disallowed` so AppKit can never auto-merge these into a live tab
    /// group behind our back.
    private func makeParkedWindow(
        frame: NSRect,
        miniaturized: Bool = false
    ) -> NSWindow {
        let style: NSWindow.StyleMask = [.titled, .closable, .resizable, .miniaturizable]
        let w: NSWindow
        if miniaturized {
            w = FakeMiniaturizedWindow(
                contentRect: frame, styleMask: style, backing: .buffered, defer: true)
        } else {
            w = NSWindow(
                contentRect: frame, styleMask: style, backing: .buffered, defer: true)
        }
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.setFrame(frame, display: false)
        Self.parkedWindows.append(w)
        return w
    }

    /// A never-shown window that REPORTS itself miniaturized without ever
    /// touching the window server.
    ///
    /// `miniaturize(_:)` on a real window is off limits here: it is a live
    /// window-server operation with an animation and a deferred CoreAnimation
    /// transaction, exactly the class of call that has SEGV'd this host after
    /// the fact. `isMiniaturized` is an `open` ObjC property, so a subclass
    /// override is honoured by every caller (same technique
    /// `MetalRendererTests.NoDrawableMTKView` uses for `currentDrawable`)
    /// while staying entirely inside our process.
    @MainActor
    private final class FakeMiniaturizedWindow: NSWindow {
        override var isMiniaturized: Bool { true }
    }

    /// A headless `TerminalView` with a headless (PTY-less) session attached
    /// and one frame change already propagated, so any FURTHER resize is a
    /// "subsequent" one under contract C.
    private func makePrimedView(
        width: CGFloat = 600,
        height: CGFloat = 400
    ) throws -> TerminalView {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        liveSessions.append(session)
        view.session = session
        view.setFrameSize(NSSize(width: width, height: height))
        let primed = try XCTUnwrap(
            view.lastPropagatedSizeForTesting(),
            "priming setFrameSize(\(width)×\(height)) must have propagated a grid — "
            + "without a first propagation the 'subsequent resize' half of the "
            + "delivery contract cannot be exercised at all"
        )
        XCTAssertGreaterThan(Int(primed.cols), 1,
                             "primed grid must have real columns, not the 1-cell floor")
        return view
    }

    /// Column count `propagateResize` must derive from a frame width, using
    /// the formula already pinned by `TerminalViewResizeMathTests`
    /// (`Int(usableWidth / cellWidth)`, leftover absorbed by the inset).
    /// Used for PREMISE checks so the tests don't have to guess when
    /// `lastPropagatedSize` is stamped on the coalesced path.
    private func expectedCols(forWidth width: CGFloat, view: TerminalView) -> Int {
        let usable = width - 2 * TerminalView.horizontalContentInsetPoints
        return Int(usable / view.metrics.cellWidth)
    }

    // MARK: - A. TabFrameSync.targets — the pure fan-out decision

    /// Rule 1: `front` is NEVER a target, even when its own frame differs from
    /// the frame being fanned out.
    ///
    /// Why it matters: the fan-out runs when the FRONT window settles at a new
    /// size. Feeding the front window back its own frame is at best a wasted
    /// `setFrame` and at worst a resize feedback loop (front settles → fan-out
    /// → front resizes → settles → fan-out …) during a live drag.
    func test_targets_neverIncludesFrontWindow_evenWhenFrontFrameDiffers() {
        // The sibling is STALE (its own frame differs from the fan-out frame),
        // so rule 2 (already-at-frame) can't be what excludes anything here.
        let target = NSRect(x: 120, y: 140, width: 520, height: 340)
        let sibling = makeParkedWindow(frame: NSRect(x: 10, y: 20, width: 400, height: 300))
        XCTAssertNotEqual(sibling.frame, target,
                          "premise: the sibling must be stale so rule 1 is what is under test")
        // Front deliberately sits somewhere else, so only rule 1 can exclude it.
        let front = makeParkedWindow(frame: NSRect(x: 60, y: 80, width: 300, height: 220))
        XCTAssertNotEqual(front.frame, target,
                          "premise: front must NOT already be at the fan-out frame, "
                          + "otherwise rule 2 (already-at-frame) would exclude it and "
                          + "rule 1 would be untested")

        let result = TabFrameSync.targets(
            front: front,
            frame: target,
            groupWindows: [front, sibling]
        )

        XCTAssertFalse(
            result.contains(where: { $0 === front }),
            "the front window must never be a fan-out target: it is the window "
            + "that just settled at this frame, and pushing the frame back onto "
            + "it re-enters the resize path (feedback loop during a live drag)"
        )
        XCTAssertEqual(
            result.map(ObjectIdentifier.init),
            [sibling].map(ObjectIdentifier.init),
            "the stale sibling — and only it — must be targeted"
        )
    }

    /// Rule 2: a window already EXACTLY at the fan-out frame is excluded, so a
    /// re-run does no work (idempotence).
    ///
    /// Why it matters: the fan-out can fire repeatedly (every settle, every
    /// tab selection change). A `setFrame` on a window that is already at that
    /// frame still churns AppKit layout for every tab in the group; worse, a
    /// window that is mid-drag can be knocked around by a redundant set.
    func test_targets_excludesWindowsAlreadyAtTheFrame_soReRunIsIdempotent() {
        let alreadyThere = makeParkedWindow(frame: NSRect(x: 120, y: 140, width: 520, height: 340))
        let target = alreadyThere.frame   // read back: exactly what AppKit stored
        let stale = makeParkedWindow(frame: NSRect(x: 200, y: 90, width: 380, height: 260))
        let front = makeParkedWindow(frame: NSRect(x: 60, y: 80, width: 300, height: 220))
        XCTAssertNotEqual(stale.frame, target,
                          "premise: the stale sibling must start at a DIFFERENT frame, "
                          + "otherwise this test can't tell rule 2 from 'targets nothing'")

        let first = TabFrameSync.targets(
            front: front, frame: target, groupWindows: [front, alreadyThere, stale]
        )
        XCTAssertEqual(
            first.map(ObjectIdentifier.init),
            [stale].map(ObjectIdentifier.init),
            "only the window whose frame differs needs a setFrame; the sibling "
            + "already at the target frame must be filtered out"
        )

        // Simulate the fan-out having been applied, then re-run: with every
        // sibling now at the frame, a second pass must be a complete no-op.
        stale.setFrame(target, display: false)
        XCTAssertEqual(stale.frame, target,
                       "premise: applying the fan-out must actually land the sibling on "
                       + "the target frame (AppKit did not constrain this never-shown window)")
        let second = TabFrameSync.targets(
            front: front, frame: target, groupWindows: [front, alreadyThere, stale]
        )
        XCTAssertTrue(
            second.isEmpty,
            "re-running the fan-out after it has been applied must select NOTHING — "
            + "a fan-out that keeps re-issuing setFrame on already-correct windows "
            + "burns a full AppKit layout pass per tab on every settle"
        )
    }

    /// Rule 3: a miniaturized window is excluded.
    ///
    /// Why it matters: resizing a miniaturized window fights the Dock's
    /// minimise state (and on Tahoe can force it back out of the Dock). A
    /// miniaturized tab will be re-laid-out by AppKit when it is restored, so
    /// there is nothing to gain by touching it now.
    ///
    /// The miniaturized window here reports `isMiniaturized == true` via a
    /// subclass override — see `FakeMiniaturizedWindow` — because calling
    /// `miniaturize(_:)` on a real window is a live window-server operation
    /// this host cannot survive. Its frame differs from the fan-out frame, so
    /// rule 2 cannot exclude it: only rule 3 can.
    func test_targets_excludesMiniaturizedWindows() {
        let target = NSRect(x: 120, y: 140, width: 520, height: 340)
        let front = makeParkedWindow(frame: NSRect(x: 60, y: 80, width: 300, height: 220))
        let mini = makeParkedWindow(frame: NSRect(x: 30, y: 40, width: 280, height: 200),
                                    miniaturized: true)
        let awake = makeParkedWindow(frame: NSRect(x: 200, y: 90, width: 380, height: 260))
        XCTAssertTrue(mini.isMiniaturized,
                      "premise: the fake must actually report itself miniaturized")
        XCTAssertNotEqual(mini.frame, target,
                          "premise: the miniaturized window must be at a DIFFERENT frame, "
                          + "otherwise rule 2 would exclude it and rule 3 would be untested")

        let result = TabFrameSync.targets(
            front: front, frame: target, groupWindows: [front, mini, awake]
        )

        XCTAssertFalse(
            result.contains(where: { $0 === mini }),
            "a miniaturized tab window must not be resized by the fan-out — AppKit "
            + "re-lays it out on restore, and setFrame on a miniaturized window "
            + "fights its Dock state"
        )
        XCTAssertEqual(
            result.map(ObjectIdentifier.init),
            [awake].map(ObjectIdentifier.init),
            "the awake stale sibling is still targeted; only the miniaturized one drops out"
        )
    }

    /// Rule 4: the order of `groupWindows` is preserved in the result.
    ///
    /// Why it matters: the group order is the user's visible tab order. Fanning
    /// out in that order keeps the resize sequence deterministic (and makes any
    /// AppKit-side flush ordering reproducible when debugging); a set-based or
    /// dictionary-based implementation would silently randomise it.
    func test_targets_preservesGroupWindowOrder() {
        let target = NSRect(x: 120, y: 140, width: 520, height: 340)
        let front = makeParkedWindow(frame: NSRect(x: 60, y: 80, width: 300, height: 220))
        let a = makeParkedWindow(frame: NSRect(x: 61, y: 81, width: 301, height: 221))
        let b = makeParkedWindow(frame: NSRect(x: 62, y: 82, width: 302, height: 222))
        let c = makeParkedWindow(frame: NSRect(x: 63, y: 83, width: 303, height: 223))

        let result = TabFrameSync.targets(
            front: front, frame: target, groupWindows: [front, a, b, c]
        )
        XCTAssertEqual(
            result.map(ObjectIdentifier.init),
            [a, b, c].map(ObjectIdentifier.init),
            "targets must come back in group order (a, b, c) — a Set/Dictionary-backed "
            + "implementation would scramble the user's tab order into a "
            + "nondeterministic resize sequence"
        )

        // Same windows, reversed group order → reversed result. Pins that the
        // order comes from the INPUT, not from creation order or hash order.
        let reversed = TabFrameSync.targets(
            front: front, frame: target, groupWindows: [c, b, a, front]
        )
        XCTAssertEqual(
            reversed.map(ObjectIdentifier.init),
            [c, b, a].map(ObjectIdentifier.init),
            "the result order must track the supplied group order, not object identity "
            + "or creation order"
        )
    }

    /// Rule 5: an empty group, or a group whose only member is `front`, yields
    /// an empty array — a single-tab window fans out to nobody.
    func test_targets_emptyGroupAndFrontOnlyGroup_yieldNoTargets() {
        let target = NSRect(x: 120, y: 140, width: 520, height: 340)
        let front = makeParkedWindow(frame: NSRect(x: 60, y: 80, width: 300, height: 220))

        XCTAssertTrue(
            TabFrameSync.targets(front: front, frame: target, groupWindows: []).isEmpty,
            "an empty group (no NSWindowTabGroup at all) must produce no targets — "
            + "the fan-out must be safe to call unconditionally on every settle"
        )
        XCTAssertTrue(
            TabFrameSync.targets(front: front, frame: target, groupWindows: [front]).isEmpty,
            "a single-tab window fans out to nobody: the group contains only front, "
            + "and front is never a target"
        )
    }

    // MARK: - B. Per-tab metrics: one frame, different grids

    /// The fan-out must push a **frame**, never a `(cols, rows)`.
    ///
    /// Tabs can be at different text sizes (per-tab ⌘+/⌘−, issue #28). Two
    /// views handed the SAME pixel frame must therefore land on DIFFERENT
    /// grids, because each maps the frame through its own `CellMetrics`. If a
    /// future refactor "optimises" the fan-out by computing the front tab's
    /// grid once and pushing `(cols, rows)` to the siblings, a 20 pt tab would
    /// be told it has the 13 pt tab's column count — its shell would wrap at
    /// the wrong width with no visible cause. This test is the regression
    /// guard for exactly that shortcut.
    func test_sameFrame_yieldsDifferentGrids_forTabsAtDifferentTextSizes() throws {
        let small = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let big = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        for view in [small, big] {
            let session = TerminalSession.makeHeadlessForTests()
            liveSessions.append(session)
            view.session = session
        }

        // `big` gets a per-view override (the per-tab text-size feature);
        // `small` keeps following the 13 pt global default pinned in setUp.
        for _ in 0..<7 { big.increaseFontSize(nil) }
        XCTAssertEqual(big.metrics.font.pointSize, 20,
                       "premise: seven ⌘+ steps from the 13 pt default land on 20 pt")
        XCTAssertEqual(small.metrics.font.pointSize, 13,
                       "premise: the other tab still follows the global default")
        XCTAssertGreaterThan(big.metrics.cellWidth, small.metrics.cellWidth,
                             "premise: a bigger font must have a wider cell")

        // The identical pixel frame a fan-out would push onto both tabs.
        let frame = NSSize(width: 800, height: 480)
        small.setFrameSize(frame)
        big.setFrameSize(frame)

        let smallGrid = try XCTUnwrap(
            small.lastPropagatedSizeForTesting(),
            "the 13 pt tab must have propagated a grid for the pushed frame"
        )
        let bigGrid = try XCTUnwrap(
            big.lastPropagatedSizeForTesting(),
            "the 20 pt tab must have propagated a grid for the pushed frame"
        )

        XCTAssertGreaterThan(
            Int(smallGrid.cols), Int(bigGrid.cols),
            "the same 800 pt width must yield MORE columns at 13 pt than at 20 pt "
            + "(\(smallGrid.cols) vs \(bigGrid.cols)). Equal column counts mean the "
            + "resize path is carrying a (cols, rows) pair instead of a frame — a "
            + "tab at a different text size would then be sized with a sibling's grid."
        )
        XCTAssertGreaterThan(
            Int(smallGrid.rows), Int(bigGrid.rows),
            "the same 480 pt height must yield more rows at 13 pt than at 20 pt "
            + "(\(smallGrid.rows) vs \(bigGrid.rows)) — the row count is metrics-derived too"
        )
        // Exact per-view mapping: each view's column count must come from its
        // OWN cell width, using the formula TerminalViewResizeMathTests pins.
        XCTAssertEqual(
            Int(smallGrid.cols), expectedCols(forWidth: 800, view: small),
            "the 13 pt tab's columns must be derived from ITS cell width"
        )
        XCTAssertEqual(
            Int(bigGrid.cols), expectedCols(forWidth: 800, view: big),
            "the 20 pt tab's columns must be derived from ITS cell width"
        )
    }

    // MARK: - C. propagateResize delivery policy

    /// C1: the FIRST resize a view ever propagates is `.sync`.
    ///
    /// Startup ordering depends on it: the shell is spawned against the grid
    /// the first propagation establishes. Deferring that first resize onto a
    /// later runloop turn would let the shell start at the placeholder grid and
    /// then get a SIGWINCH mid-prompt (visible as a redraw glitch on every new
    /// tab), so the "never reflow on main" optimisation must NOT swallow the
    /// first delivery.
    func test_firstPropagatedResize_isSync() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        liveSessions.append(session)
        view.session = session

        // Construction may already have propagated once (the DEBUG factory
        // builds the view at 100×100). If so THAT is the first resize; if not,
        // the first frame change below is. Either way the first recorded
        // delivery is the one the contract talks about.
        let atBirth = view.lastResizeDeliveryForTesting
        view.setFrameSize(NSSize(width: 800, height: 480))
        let first = atBirth ?? view.lastResizeDeliveryForTesting

        let grid = try XCTUnwrap(
            view.lastPropagatedSizeForTesting(),
            "premise: 100×100 → 800×480 must cross cell boundaries, so a resize "
            + "must have been propagated"
        )
        XCTAssertGreaterThan(Int(grid.cols), 1, "premise: a real grid was propagated")
        XCTAssertEqual(
            first, .sync,
            "the first resize a view propagates must be delivered SYNCHRONOUSLY. "
            + "It is the resize the shell is spawned against; deferring it means the "
            + "shell starts at the placeholder grid and takes a SIGWINCH mid-prompt. "
            + "(nil here means the view propagated a resize without recording how it "
            + "delivered it — the observable itself is part of the contract.)"
        )
    }

    /// C2: a subsequent resize that changes the COLUMN count is `.coalesced`.
    ///
    /// A column change reflows the entire scrollback — measured ~10 ms at 20k
    /// lines and ~37 ms at 100k. Running that synchronously on main for every
    /// cell-boundary crossing of a live drag is what made the window resize
    /// stutter. It must be handed to the coalescing path so a drag that crosses
    /// twenty column boundaries costs ONE reflow, off the main thread.
    func test_subsequentColumnChange_isCoalesced_neverSyncOnMain() throws {
        let view = try makePrimedView(width: 600, height: 400)
        let colsBefore = expectedCols(forWidth: 600, view: view)
        let colsAfter = expectedCols(forWidth: 900, view: view)
        XCTAssertNotEqual(colsBefore, colsAfter,
                          "premise: 600 → 900 pt must cross column boundaries "
                          + "(\(colsBefore) → \(colsAfter))")

        // Width-only change: columns change, rows cannot (height is untouched).
        view.setFrameSize(NSSize(width: 900, height: 400))

        XCTAssertEqual(
            view.lastResizeDeliveryForTesting, .coalesced,
            "a column change must be COALESCED, never run inline on main: it reflows "
            + "the whole scrollback (~10 ms at 20k lines, ~37 ms at 100k). A `.sync` "
            + "here is the resize-stutter regression — every cell-boundary crossing of "
            + "a live drag would block the main thread for a full reflow."
        )
    }

    /// C3: a subsequent resize that changes ONLY the row count stays `.sync`.
    ///
    /// A row-only change costs ~0.000 ms (no reflow — the columns, and
    /// therefore every wrapped line, are unchanged). Coalescing it would buy
    /// nothing and would cost the no-lag guarantee: a vertical-only drag would
    /// visibly trail the window edge by a frame or more.
    func test_subsequentRowOnlyChange_staysSync() throws {
        let view = try makePrimedView(width: 600, height: 400)

        // Establish a fresh baseline with a row-only change first, so `before`
        // is a grid the view definitely propagated (the priming change above
        // may have been a column change, whose bookkeeping timing this test
        // deliberately does not assume).
        view.setFrameSize(NSSize(width: 600, height: 500))
        let before = try XCTUnwrap(view.lastPropagatedSizeForTesting(),
                                   "premise: the baseline row change propagated a grid")

        // Height-only change. Cell height at 13 pt is ~15–16 pt, so dropping
        // 200 pt moves the row count by ~12 for ANY plausible titlebar inset;
        // the column count cannot move because the width is untouched.
        view.setFrameSize(NSSize(width: 600, height: 300))
        let after = try XCTUnwrap(view.lastPropagatedSizeForTesting(),
                                  "premise: the row-only change propagated a grid")

        XCTAssertEqual(Int(after.cols), Int(before.cols),
                       "premise: an unchanged width must leave the column count alone "
                       + "(\(before.cols) → \(after.cols))")
        XCTAssertNotEqual(Int(after.rows), Int(before.rows),
                          "premise: 500 → 300 pt must cross row boundaries "
                          + "(\(before.rows) → \(after.rows))")
        XCTAssertEqual(
            view.lastResizeDeliveryForTesting, .sync,
            "a row-only resize must stay SYNCHRONOUS. It costs ~0.000 ms (no reflow: "
            + "the column count, and therefore every wrapped line, is unchanged), and "
            + "deferring it makes a vertical drag visibly trail the window edge."
        )
    }

    /// C4: the font-change path is `.async`.
    ///
    /// A text-size change (⌘+/⌘−, the Settings slider) rebuilds the glyph atlas
    /// and then re-derives the grid from the new metrics. That resize is
    /// delivered asynchronously so the atlas swap and the PTY winsize update
    /// don't interleave inside the same main-thread turn as the keystroke.
    func test_fontSizeChange_propagatesAsync() throws {
        let view = try makePrimedView(width: 600, height: 400)
        let primed = try XCTUnwrap(view.lastPropagatedSizeForTesting())
        let colsBefore = primed.cols
        let rowsBefore = primed.rows

        view.increaseFontSize(nil)
        XCTAssertEqual(view.metrics.font.pointSize, 14,
                       "premise: ⌘+ stepped the acting view 13 → 14 pt")

        XCTAssertEqual(
            view.lastResizeDeliveryForTesting, .async,
            "the font-change resize must be delivered on the ASYNC path — it is "
            + "`propagateResize(async: true)`, distinct from both the startup `.sync` "
            + "delivery and the drag-time `.coalesced` one. Seeing `.sync` here means "
            + "the atlas rebuild and the winsize update now share one main-thread turn; "
            + "seeing `.coalesced` means a keystroke-driven resize can be dropped/merged "
            + "with a drag."
        )
        // Prove a resize really was recomputed from the NEW metrics. Columns
        // are the wrong probe for a single 13 → 14 pt step: cell width lands on
        // the same integer for both sizes in the default font, so the column
        // count legitimately doesn't move. Cell HEIGHT does, so rows do.
        let after = try XCTUnwrap(view.lastPropagatedSizeForTesting())
        XCTAssertLessThanOrEqual(
            Int(after.cols), Int(colsBefore),
            "a bigger font can never yield MORE columns in the same frame "
            + "(\(colsBefore) → \(after.cols))"
        )
        XCTAssertLessThan(
            Int(after.rows), Int(rowsBefore),
            "premise: a bigger font in the same frame must yield fewer rows "
            + "(\(rowsBefore) → \(after.rows)) — otherwise no resize was propagated at all"
        )
    }

    /// C5: a resize that does not cross a cell boundary records nothing new —
    /// the `lastPropagatedSize` dedupe still holds.
    ///
    /// A live drag delivers a `setFrameSize` per mouse move (60–120 Hz), and
    /// the overwhelming majority land inside the current cell. Those must be
    /// dropped before any delivery decision is made; a coalescer that still
    /// schedules work for every sub-pixel move re-introduces the stutter it
    /// was meant to remove.
    ///
    /// Discriminator: we first make the last recorded delivery `.coalesced`
    /// (via a column change), then nudge the width by HALF the remaining
    /// sub-cell slack. If the dedupe were dropped, the view would deliver a
    /// resize whose column count is unchanged — which contract C3 classifies
    /// as `.sync` — so a lost dedupe flips the recorded value.
    func test_subCellResize_isDeduped_recordsNoNewDelivery() throws {
        let view = try makePrimedView(width: 600, height: 400)
        let cw = view.metrics.cellWidth

        // Put the view in a known state whose last delivery is `.coalesced`.
        let width: CGFloat = 900
        view.setFrameSize(NSSize(width: width, height: 400))
        XCTAssertEqual(view.lastResizeDeliveryForTesting, .coalesced,
                       "setup precondition (contract C2, pinned by its own test): a "
                       + "column change records a coalesced delivery")

        // Nudge strictly inside the current column: half the slack left over
        // after the last whole cell.
        let usable = width - 2 * TerminalView.horizontalContentInsetPoints
        let cols = (usable / cw).rounded(.down)
        let slack = usable - cols * cw
        let nudge = (cw - slack) * 0.5
        XCTAssertGreaterThan(nudge, 0.0,
                             "premise: there must be room to grow inside the current column")
        XCTAssertEqual(
            expectedCols(forWidth: width + nudge, view: view),
            expectedCols(forWidth: width, view: view),
            "premise: the nudge must stay INSIDE the current column — if the column "
            + "count moved, this is no longer a sub-cell resize and the test is invalid"
        )

        view.setFrameSize(NSSize(width: width + nudge, height: 400))

        XCTAssertEqual(
            view.lastResizeDeliveryForTesting, .coalesced,
            "a sub-cell resize must record NO new delivery — the `lastPropagatedSize` "
            + "dedupe drops it before any delivery decision. If the dedupe is gone the "
            + "view re-delivers a grid whose columns did not change, which the policy "
            + "classifies as `.sync`, and every 60–120 Hz mouse move of a live drag "
            + "starts doing resize work again."
        )
    }

    // MARK: - D. TerminalSession.resizeCoalesced semantics

    /// D1: latest-wins. N coalesced resizes back-to-back leave the terminal at
    /// the LAST requested size, never at an intermediate one.
    ///
    /// This is the whole point of coalescing a drag: the intermediate sizes are
    /// disposable, but the final one is not. A coalescer that keeps the FIRST
    /// request (or drops the request that arrives while one is in flight)
    /// strands the shell at a stale geometry when the drag stops — the exact
    /// failure the feature exists to prevent.
    func test_resizeCoalesced_latestWins_acrossABurst() throws {
        // Memory pre-flight: the largest grid here is 120×30. With BBTerm's
        // scrollback the estimator charges 120 × (30 + 10 000) × 16 B ≈ 19 MB —
        // far inside the 256 MB per-test budget.
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 120, rows: 30, scrollback: 10_000)
        )
        let session = TerminalSession.makeHeadlessForTests()
        liveSessions.append(session)

        let burst: [(cols: UInt16, rows: UInt16)] = [
            (40, 10), (60, 14), (80, 18), (100, 24), (120, 30)
        ]
        for size in burst {
            session.resizeCoalesced(to: .init(cols: size.cols, rows: size.rows))
        }

        let last = burst[burst.count - 1]
        waitForSessionGrid(session, cols: Int(last.cols), rows: Int(last.rows))
        let settled = try XCTUnwrap(session.takeSnapshotForTests(),
                                    "the session core queue must still answer after the burst")
        XCTAssertEqual(
            [Int(settled.cols), Int(settled.rows)], [Int(last.cols), Int(last.rows)],
            "after a burst of coalesced resizes the terminal must be at the LAST "
            + "requested size (\(last.cols)×\(last.rows)), not an intermediate one. "
            + "Landing on an earlier size means the coalescer keeps the first request "
            + "or drops requests that arrive while one is in flight — the shell would "
            + "stay at a stale geometry once the drag stops."
        )

        // And it must STAY there: no late intermediate may overwrite the final
        // size after the fact.
        settle(milliseconds: 250)
        let afterSettle = try XCTUnwrap(session.takeSnapshotForTests(),
                                        "the session must still answer after settling")
        XCTAssertEqual(
            [Int(afterSettle.cols), Int(afterSettle.rows)], [Int(last.cols), Int(last.rows)],
            "a late-arriving intermediate resize must not overwrite the final size — "
            + "latest-wins has to survive the queue draining, not just the first landing"
        )
    }

    /// D2: `resizeCoalesced` clamps exactly like the existing resize paths.
    ///
    /// `TerminalSession.clampResize` pins cols/rows into [2, 1000] and the Rust
    /// core enforces the same ceiling; a new entry point that bypasses the
    /// clamp hands the core an out-of-range grid (and, on the low end, a 0×0
    /// winsize the shell reads as "unknown size"). Parity contract with
    /// `TerminalSessionTests.test_resize_clampsOversizedDimensions`.
    func test_resizeCoalesced_clampsOversizedAndUndersizedDimensions() throws {
        // Memory pre-flight: the clamp ceiling is 1000×1000. BBTerm's
        // scrollback is ~10k lines, so 1000 × (1000 + 10 000) × 16 B ≈ 176 MB
        // worst case — inside the 256 MB budget, and the helper skips rather
        // than OOMs on a smaller host (post-2026-04-20 rule).
        try requireTestFitsInBudget(
            estimatedBytes: estimatedGridBytes(cols: 1000, rows: 1000, scrollback: 10_000)
        )
        let session = TerminalSession.makeHeadlessForTests()
        liveSessions.append(session)

        session.resizeCoalesced(to: .init(cols: UInt16.max, rows: UInt16.max))
        waitForSessionGrid(session, cols: 1000, rows: 1000, timeout: 12.0)
        let clamped = try XCTUnwrap(session.takeSnapshotForTests(),
                                    "the session must answer after the oversized resize")
        XCTAssertEqual(
            [Int(clamped.cols), Int(clamped.rows)], [1000, 1000],
            "an oversized coalesced resize must clamp to exactly 1000×1000, the same "
            + "ceiling `resize(to:)` and the Rust core enforce — a new entry point that "
            + "skips the clamp hands the core an out-of-range grid"
        )

        // Low end: below the floor must clamp UP to 2, not through to 0.
        session.resizeCoalesced(to: .init(cols: 0, rows: 0))
        waitForSessionGrid(session, cols: 2, rows: 2)
        let floored = try XCTUnwrap(session.takeSnapshotForTests(),
                                    "the session must answer after the undersized resize")
        XCTAssertEqual(
            [Int(floored.cols), Int(floored.rows)], [2, 2],
            "an undersized coalesced resize must clamp UP to the 2×2 floor — a 0×0 "
            + "winsize reaches the shell as 'size unknown' and TUIs render at their "
            + "own defaults"
        )
    }

    /// D3: after `terminate()`, a coalesced resize is a clean no-op.
    ///
    /// The window can settle (and the tab fan-out can fire) after a session has
    /// already been torn down — closing a tab while dragging the window edge is
    /// enough. The dead session must absorb the resize without trapping and
    /// without touching its grid; and, critically, its core queue must remain
    /// responsive, because a coalesced path that parks work behind a barrier
    /// the terminated session will never run would deadlock every later
    /// `coreQueue.sync` (the hang here is the tripwire).
    func test_resizeCoalesced_afterTerminate_isACleanNoOp() throws {
        let session = TerminalSession.makeHeadlessForTests()
        liveSessions.append(session)

        session.resizeCoalesced(to: .init(cols: 40, rows: 12))
        waitForSessionGrid(session, cols: 40, rows: 12)
        let before = try XCTUnwrap(session.takeSnapshotForTests(),
                                   "premise: the live session took the first resize")
        XCTAssertEqual([Int(before.cols), Int(before.rows)], [40, 12],
                       "premise: the live session is at 40×12 before termination")

        session.terminate()

        // Three post-mortem resizes: a settle, a fan-out, and a stray drag tick.
        session.resizeCoalesced(to: .init(cols: 33, rows: 11))
        session.resizeCoalesced(to: .init(cols: 34, rows: 12))
        session.resizeCoalesced(to: .init(cols: 35, rows: 13))
        settle(milliseconds: 250)

        // Reaching this line at all is the primary assertion: `settle` pumped
        // the runloop and `takeSnapshotForTests` does a `coreQueue.sync`, so a
        // coalesced item parked behind something the dead session never runs
        // would hang here rather than return.
        let after = session.takeSnapshotForTests()
        // A terminated session releases its core handle, so it legitimately
        // stops vending snapshots — that IS the clean no-op. What must not
        // happen is the dead session's grid following the post-mortem requests.
        if let after {
            XCTAssertEqual(
                [Int(after.cols), Int(after.rows)], [Int(before.cols), Int(before.rows)],
                "a resize after terminate() must be a clean no-op: if the dead session "
                + "still answers at all, its grid must stay exactly where it was "
                + "(\(before.cols)×\(before.rows)), not follow the post-mortem requests"
            )
        }
    }

    // MARK: - E. Renderer frame-skip must key on the viewport

    /// The frame-skip cache short-circuits `render(in:)` when nothing that
    /// affects the image changed. The VIEWPORT affects the image: the same
    /// snapshot drawn into a 320×192 view and a 640×384 view produces two
    /// different pictures.
    ///
    /// This is the resize path's renderer half. During a drag the snapshot can
    /// legitimately be unchanged for many frames (idle shell) while the view
    /// grows every frame. A frame-skip key that ignores the viewport makes the
    /// renderer skip exactly those frames — the terminal content freezes at the
    /// old size and only snaps to the new geometry when the next byte arrives.
    ///
    /// Observable: `didFrameSkipLastRender` (false ⇒ the frame was encoded and
    /// presented). Hosts whose offscreen `CAMetalLayer` cannot vend a drawable
    /// can't distinguish encoded from skipped, so they `XCTSkip` after the
    /// probe render — same limitation the existing S2-006/S2-007 tests carry.
    func test_render_sameSnapshotIntoDifferentViewportSizes_mustNotFrameSkip() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        // Keep wall-clock out of the frame key so "identical frame" really is
        // identical (the blink phase is time-derived when blink is enabled).
        renderer.setCursorBlinkEnabled(false)

        let small = makeProbeView(device: device, size: CGSize(width: 320, height: 192))
        let big = makeProbeView(device: device, size: CGSize(width: 640, height: 384))
        XCTAssertNotEqual(
            small.drawableSize, big.drawableSize,
            "premise: the two probe views must have different drawable sizes, otherwise "
            + "there is no viewport change to detect"
        )

        // Memory pre-flight: one 20×8 BBTerm (~3 KB), one renderer (~4 MB of
        // instance buffers + atlas), two small MTKViews with ≤3 drawables each
        // (≈3 MB). Well under 10 MB.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        term.input("viewport-key")
        let snapshot = try XCTUnwrap(term.snapshot())

        // 1. Baseline: encode once into the small viewport.
        renderer.render(in: small, snapshot: snapshot, focused: true)
        if renderer.didFrameSkipLastRender {
            throw XCTSkip(
                "xctest host cannot acquire an offscreen CAMetalLayer drawable (the probe "
                + "render reported a skipped frame), so encoded-vs-skipped is "
                + "indistinguishable here — the viewport-key contract is unobservable "
                + "on this host (same limitation as MetalRendererTests' S2-006/S2-007)."
            )
        }
        small.releaseDrawables()

        // 2. Control: identical snapshot AND identical viewport must skip.
        //    Without this the test could pass on a renderer that simply never
        //    frame-skips at all.
        renderer.render(in: small, snapshot: snapshot, focused: true)
        XCTAssertTrue(
            renderer.didFrameSkipLastRender,
            "control: re-rendering the SAME snapshot into the SAME viewport must "
            + "short-circuit on the frame-skip cache. If this is false the renderer "
            + "isn't frame-skipping at all and the viewport assertion below would "
            + "pass vacuously."
        )

        // 3. The contract: same snapshot, DIFFERENT viewport ⇒ must encode.
        renderer.render(in: big, snapshot: snapshot, focused: true)
        XCTAssertFalse(
            renderer.didFrameSkipLastRender,
            "the same snapshot rendered into a LARGER viewport must be encoded, not "
            + "skipped: the viewport is part of the image. A frame key that ignores it "
            + "freezes the terminal's pixels at the old size for the whole drag — the "
            + "content only catches up when the next byte arrives from the shell."
        )
        big.releaseDrawables()

        // 4. And symmetrically on the way back down: shrinking is a change too,
        //    so an implementation that only notices growth still fails here.
        renderer.render(in: small, snapshot: snapshot, focused: true)
        XCTAssertFalse(
            renderer.didFrameSkipLastRender,
            "returning to the SMALLER viewport with the same snapshot must also encode — "
            + "the last encoded frame was at the larger viewport, so this frame differs. "
            + "A key that tracks only the largest viewport seen would wrongly skip here."
        )
    }

    /// Offscreen probe view for the renderer. Stock drawable behaviour (the
    /// xctest host's CAMetalLayer does vend drawables offscreen on real
    /// hardware); `releaseDrawables()` is called between successful encodes so
    /// we never re-present the same `CAMetalDrawable` (which logs
    /// "Each CAMetalLayerDrawable can only be presented once!").
    private func makeProbeView(device: MTLDevice, size: CGSize) -> MTKView {
        let view = MTKView(
            frame: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            device: device
        )
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        // Must match the renderer pipeline's colorAttachments[0] format.
        view.colorPixelFormat = .bgra8Unorm
        return view
    }

    // MARK: - Async waiting helpers

    /// Wait until the session's terminal grid reaches `cols`×`rows`.
    ///
    /// Reads through `takeSnapshotForTests()` (a `coreQueue.sync`) so the
    /// observation is race-free with the core queue that owns `bbterm`, and
    /// drives the wait with an `XCTestExpectation` + main-queue re-arm rather
    /// than a `Thread.sleep` spin. On timeout it fulfils anyway so the caller's
    /// own `XCTAssertEqual` reports the ACTUAL grid instead of a bare
    /// "expectation not fulfilled".
    ///
    /// `nonisolated` so the re-arm closure doesn't have to hop actors.
    nonisolated private func waitForSessionGrid(
        _ session: TerminalSession,
        cols: Int,
        rows: Int,
        timeout: TimeInterval = 8.0
    ) {
        let exp = expectation(description: "session grid reaches \(cols)×\(rows)")
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if let snap = session.takeSnapshotForTests(),
               Int(snap.cols) == cols, Int(snap.rows) == rows {
                exp.fulfill()
                return
            }
            if Date() >= deadline {
                exp.fulfill()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
        }
        poll()
        wait(for: [exp], timeout: timeout + 2.0)
    }

    /// Let queued work drain for a bounded interval without blocking the main
    /// thread (an `XCTestExpectation` + `asyncAfter`, not a sleep).
    nonisolated private func settle(milliseconds: Int) {
        let exp = expectation(description: "settle \(milliseconds) ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
            exp.fulfill()
        }
        wait(for: [exp], timeout: Double(milliseconds) / 1000.0 + 5.0)
    }
}

// UNPINNED: the end-to-end fan-out — "front window settles → every sibling tab
// window actually receives setFrame → every sibling TerminalView repropagates
// its grid" — is not covered here. Observing it requires a live
// NSWindowTabGroup built by `addTabbedWindow`, and this suite would then have
// to keep those merged windows parked forever (they can never be closed or
// ordered out; see the CoreAnimation SEGV note at the top). That is exactly the
// integration this file's section A was designed to make unnecessary: the
// decision is pure, so the remaining glue is a single `for w in targets {
// w.setFrame(frame, display: true) }`. If that glue is ever non-trivial, pin it
// in TabMoverTests, which already owns the parked-tab-group rig.
//
// UNPINNED: `.coalesced` deliveries are pinned as a POLICY decision (which path
// the view chose), not as a wall-clock measurement. Asserting "the reflow did
// not block main for N ms" needs a deterministic 20k-line scrollback and a
// timing threshold, which belongs in the latency gate (scripts/bench-latency.sh)
// rather than in a unit test that has to pass on a loaded CI runner.
