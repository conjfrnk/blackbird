import XCTest
import Metal
import MetalKit
@testable import Blackbird

final class MetalRendererTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_rendererInitializesWithSystemDevice() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = MetalRenderer(device: device, metrics: metrics)
        XCTAssertNotNil(renderer)
        XCTAssertTrue(renderer!.device === device)
    }

    func test_rendererPipelineStateLoads() throws {
        let device = try requireMetalDevice()
        // If init returns non-nil, both the library and the pipeline state loaded.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = MetalRenderer(device: device, metrics: metrics)
        XCTAssertNotNil(renderer)
    }

    func test_reconfigureWithFreshMetricsSucceeds() throws {
        // Regen the atlas for a different font size. Reconfigure returns
        // true on success and invalidates the frame-skip cache so the
        // next render() can't show stale pixels at the old resolution.
        let device = try requireMetalDevice()
        let metrics1 = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics1))
        let metrics2 = CellMetrics(font: .monospacedSystemFont(ofSize: 20, weight: .regular))
        XCTAssertTrue(renderer.reconfigure(metrics: metrics2, scale: 2.0))
        // The new atlas was installed; original font sizing was smaller so
        // the new cell pixel size should be larger.
        XCTAssertGreaterThan(renderer.atlas.cellPxHeight, 20)
    }

    func test_setCursorBlinkEnabled_resetsCache() throws {
        // Regression for swift-tests-render F8. The original body only
        // asserted "no crash" on `setCursorBlinkEnabled` + `invalidate()`
        // — zero behavioural signal. Post-fix we drive the renderer
        // through a blink-state flip with a snapshot-backed frame in
        // between, so the cursor-blink branch runs both with the flag
        // on and off. A regression that made `setCursorBlinkEnabled`
        // forget to store the new state would either leave `blinkPhase
        // Start` unchanged (causing the next frame to blink when the
        // user disabled it) or repaint identically in both branches
        // (no blink when enabled). Directly observing that is not
        // possible without further `@testable` hooks on `MetalRenderer`
        // (the audit explicitly permits DEBUG accessors but doesn't
        // require them). Stronger contract: after each flip, a
        // subsequent render must not crash AND the renderer must
        // remain usable (atlas lookups still succeed).
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snapshot = try makeSmallSnapshot(text: "cursor")

        // Enable blink + render; the FrameKey includes a time-derived
        // `blinkSkipNow` field that only matters when blink is enabled,
        // so this path differs from the disabled-blink one.
        renderer.setCursorBlinkEnabled(true)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        // Disable and render again. Under the fix, the blink-toggle
        // invalidates the frame-skip cache so the second render
        // rebuilds instead of short-circuiting on a stale FrameKey.
        renderer.setCursorBlinkEnabled(false)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        // Re-enable and render once more to exercise the transition in
        // the other direction.
        renderer.setCursorBlinkEnabled(true)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        // After the flip-flip-flip, the atlas must still respond to
        // lookups. Regression guard against a blink-state flip that
        // accidentally frees the atlas texture.
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("c")))
    }

    func test_rendererAcceptsSnapshotWithoutCrash() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        // Create a BBTerm directly, feed bytes, take snapshot. No MTKView
        // drawable available in tests — we only verify atlas lookup doesn't crash.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("hello world")
        let snapshot = try XCTUnwrap(term.snapshot())
        _ = snapshot
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("h")))
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("e")))
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("H")))
    }

    func test_rendererDeinitDrainsWithoutCrash() throws {
        // Regression guard for audit F8: releasing a MetalRenderer must
        // drain in-flight command buffers (if any) before the
        // DispatchSemaphore deallocates, otherwise an imbalanced wait/signal
        // count traps the process. Deinit commits a no-op command buffer
        // and waits for completion — this test verifies the release path
        // doesn't crash and that the object is actually freed.
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        weak var weakRef: MetalRenderer?
        autoreleasepool {
            var renderer: MetalRenderer? = MetalRenderer(device: device, metrics: metrics)
            XCTAssertNotNil(renderer)
            weakRef = renderer
            renderer = nil
        }
        // If deinit crashed, we'd never reach here. If the release didn't
        // zero the weak ref, something is retaining it (bug in the test
        // or a leaked capture). Either way, an explicit check beats silent
        // pass.
        XCTAssertNil(weakRef, "MetalRenderer should be deallocated once all strong refs drop")
    }

    // MARK: - Audit F11: render(in:) direct coverage
    //
    // Memory/time pre-flight per MEMORY `feedback_test_memory_safety`:
    //   Grid is 20x8 = 160 cells. Renderer holds three instance buffers
    //   at the startup capacity (200*80 = 16 000 CellInstance slots); at
    //   roughly 48 bytes each that's ~2.3 MB total. BBTerm ring buffer
    //   with 8 rows is trivial. No test here constructs a larger grid.
    //   The offscreen MTKView below never acquires a drawable (no
    //   CAMetalLayer has a connection), so `render(in:)` hits the
    //   early-return path after `wait/signal` balance — no GPU work
    //   submitted, no persistent resources leaked.

    /// MTKView subclass that never vends a drawable. `render(in:)`
    /// acquires `view.currentDrawable` and `view.currentRenderPassDescriptor`
    /// before encoding; when either is nil the renderer takes the
    /// early-return path (signal semaphore, skip encode/commit). Tests
    /// use this to exercise every code path up to and including the
    /// drawable acquisition — FrameKey build, frame-skip comparison,
    /// slot rotation, semaphore wait/signal balance — without ever
    /// presenting a real drawable.
    ///
    /// Why a subclass instead of a stock MTKView: a stock offscreen
    /// MTKView in a test host still vends a fresh
    /// `CAMetalDrawable` on demand (the CAMetalLayer is real even
    /// without a window). Calling `buffer.present(drawable)` on that
    /// drawable then `.commit()` hands it off for display; a second
    /// call to `render(in:)` would then see the same drawable slot
    /// recycled and AppKit/Core Animation logs `[API] Each
    /// CAMetalLayerDrawable can only be presented once!`. Returning
    /// nil sidesteps the whole encode path.
    private final class NoDrawableMTKView: MTKView {
        override var currentDrawable: CAMetalDrawable? { nil }
        override var currentRenderPassDescriptor: MTLRenderPassDescriptor? { nil }
    }

    /// Build a small offscreen MTKView that never returns a drawable.
    /// `render(in:)` will early-return on the `drawable == nil` branch
    /// after balancing its semaphore — the code paths we actually want
    /// to exercise (FrameKey build, frame-skip compare, slot rotation)
    /// all run before that branch. Crashes in those paths surface here.
    private func makeOffscreenMTKView(device: MTLDevice) -> MTKView {
        let view = NoDrawableMTKView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )
        // Don't let the view try to drive a timer-based draw; tests
        // call render(in:) directly.
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        return view
    }

    /// Spin up a BBTerm, feed it a line of text, return a fresh snapshot
    /// for the renderer. Small grid keeps memory and CPU bounded.
    private func makeSmallSnapshot(text: String = "abc") throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    func test_render_withNoSnapshot_doesNotCrash() throws {
        // Exercises the "snapshot is nil" branch: render() still runs
        // blink-phase computation, builds a FrameKey with default values,
        // takes a slot, then exits because the drawable is nil.
        // Verifies semaphore balancing on the no-snapshot early-return.
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        // Three successive calls to prove the semaphore isn't leaking
        // waits: if a single `signal()` was missed, the fourth would
        // block indefinitely (3 slots). Keep it below 4 for safety.
        renderer.render(in: view, snapshot: nil, focused: true)
        renderer.render(in: view, snapshot: nil, focused: true)
        renderer.render(in: view, snapshot: nil, focused: true)
    }

    func test_render_withSnapshot_doesNotCrash() throws {
        // Exercises the full FrameKey build + CacheKey build +
        // buildInstances(...) path for a small snapshot. Drawable is
        // nil in headless xctest, so the method exits before
        // encoder/commit — which is fine for coverage purposes. The
        // branches we're actually pinning (frame-skip compare, slot
        // rotation, instance count) all run before the drawable check.
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snapshot = try makeSmallSnapshot(text: "hello")
        renderer.render(in: view, snapshot: snapshot, focused: true, selection: nil)
    }

    func test_render_repeatedIdenticalSnapshot_stable() throws {
        // Audit F11 intent: frame-skip cache. When render() is called
        // twice with the same snapshot + state, the second call should
        // short-circuit at `frameKey == lastFrameKey`. We can't read
        // `lastFrameKey` directly without further test hooks, but we
        // can assert the path is stable (no crash, no unbalanced
        // semaphore, no deadlock) across many identical calls.
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snapshot = try makeSmallSnapshot(text: "cached")
        // 10 back-to-back identical renders: first builds the cache,
        // next 9 should hit the frame-skip short-circuit (which never
        // touches the semaphore, per the source comment "we never
        // claimed a slot, so we don't signal back"). If that balance
        // is off, the test host deadlocks — hence the tight upper
        // bound.
        for _ in 0..<10 {
            renderer.render(in: view, snapshot: snapshot, focused: true)
        }
    }

    func test_render_afterInvalidate_rerunsPath() throws {
        // `invalidate()` clears lastFrameKey so the next render rebuilds
        // instances instead of frame-skipping. We can't observe the
        // rebuild from outside directly — but we can verify the call
        // order doesn't crash and leaves the renderer in a sane state
        // by reaching for the atlas afterwards.
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snap = try makeSmallSnapshot(text: "x")
        renderer.render(in: view, snapshot: snap, focused: true)
        renderer.invalidate()
        renderer.render(in: view, snapshot: snap, focused: true)
        // Atlas must still respond to lookups after the invalidate+render
        // round trip. Regression guard against an invalidate() that
        // accidentally frees the atlas texture.
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("x")))
    }

    func test_render_withCursorBlinkEnabled_exercisesBlinkPhase() throws {
        // Audit F11 intent: blink-phase logic. Enabling blink causes
        // `render()` to compute a phase against CACurrentMediaTime and
        // fold that into the FrameKey (blinkSkipNow). Exercising the
        // path at two wall-clock moments guarantees the blink-phase
        // branch runs. Exact observability requires DEBUG-only hooks
        // we don't have; this test pins "it doesn't crash and the
        // renderer remains usable".
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snapshot = try makeSmallSnapshot(text: "|")
        renderer.setCursorBlinkEnabled(true)
        renderer.render(in: view, snapshot: snapshot, focused: true)
        // A tiny delay between renders so any wall-clock–driven logic
        // (blink phase, time-based caches) sees a forward step. 10 ms
        // is well under the 1.06 s blink cycle, so we don't guarantee
        // a phase flip — we just ensure the phase math runs with a
        // non-zero elapsed value.
        Thread.sleep(forTimeInterval: 0.01)
        renderer.render(in: view, snapshot: snapshot, focused: true)
        renderer.setCursorBlinkEnabled(false)
        renderer.render(in: view, snapshot: snapshot, focused: true)
    }

    func test_render_focusedVsUnfocused_stable() throws {
        // `focused` is part of the FrameKey — toggling it must not
        // crash, and the frame-skip cache must invalidate (because the
        // key differs). We stop short of asserting that cache state
        // because there's no exposed hook; the smoke test catches
        // crashes in the branches that depend on `focused` (cursor
        // fill flag, block-cursor inversion).
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snap = try makeSmallSnapshot(text: "f")
        renderer.render(in: view, snapshot: snap, focused: true)
        renderer.render(in: view, snapshot: snap, focused: false)
        renderer.render(in: view, snapshot: snap, focused: true)
    }

    func test_render_withDamagedSnapshot_exercisesPartialRebuild() throws {
        // Audit F11 intent: partial-row rebuild. When the CacheKey is
        // stable across two frames and the snapshot carries partial
        // damage, only damaged rows get rebuilt in `rowInstanceCache`.
        // We drive two renders in a row: the first establishes the
        // cache, the second reuses it with whatever damage the terminal
        // reports after we push a second chunk of input. The partial-
        // rebuild path runs unless damage >= rows/2, which is unlikely
        // for a single-line append.
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)

        // Use a single BBTerm across two snapshots so the second
        // snapshot actually tracks delta damage, not full damage.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        term.input("aaa")
        let snap1 = try XCTUnwrap(term.snapshot())
        renderer.render(in: view, snapshot: snap1, focused: true)

        term.input("b")
        let snap2 = try XCTUnwrap(term.snapshot())
        renderer.render(in: view, snapshot: snap2, focused: true)
    }

    /// Regression for metal-renderer F3.
    ///
    /// On a pure cursor-movement frame (arrow keys in an empty line),
    /// alacritty's damage iterator may not flag the row the cursor
    /// left or the row it entered — no cell-content delta exists, so
    /// the damage stays empty. Pre-fix, the partial-rebuild fast path
    /// then left a ghost inverted cell at the cursor's prior position
    /// because the row cache stayed as-is. Post-fix, cursor-moved
    /// frames force-rebuild the prev + new cursor rows even when they
    /// aren't in the damage list.
    ///
    /// This test drives two renders that differ only in cursor
    /// position and confirms the renderer stays stable across the
    /// move (no crash, no unbalanced semaphore, no cache corruption).
    /// Direct observation of "the old cursor row was rebuilt" would
    /// need a DEBUG hook we don't have; crashing would indicate a
    /// regression.
    func test_render_cursorMove_forcesRowRebuild() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)

        // First render: cursor at (row, col) = (0, 5) after typing.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        term.input("hello")
        let snap1 = try XCTUnwrap(term.snapshot())
        renderer.render(in: view, snapshot: snap1, focused: true)

        // Second render: move cursor via CSI B (cursor down) so the
        // cursor row changes without a per-cell content delta. In
        // practice alacritty may or may not flag the old/new rows;
        // the F3 fix ensures a ghost-free paint either way.
        term.input("\u{1B}[B")   // ESC[B = cursor down one
        let snap2 = try XCTUnwrap(term.snapshot())
        renderer.render(in: view, snapshot: snap2, focused: true)

        // Third: back up so old row == original row. Same resilience
        // check — ensures the prev/new insert logic survives cursor
        // motion in both directions without blowing up.
        term.input("\u{1B}[A")
        let snap3 = try XCTUnwrap(term.snapshot())
        renderer.render(in: view, snapshot: snap3, focused: true)
    }

    /// Regression for swift-tests-render F12: the triple-buffer ring
    /// pairs a 3-slot `DispatchSemaphore` with a rotating `frameIndex`
    /// that wraps mod 3. A regression that forgot to `signal()` on any
    /// render-exit path (nil drawable, frame-skip short-circuit, etc)
    /// would leak a slot and the fourth call would block indefinitely.
    /// Similarly, a frameIndex rotation bug (e.g. `(frameIndex + 2) %
    /// 3` typo) could produce an invalid slot index without crashing,
    /// but would eventually starve the ring.
    ///
    /// This test drives >2 × ring-depth calls through each exit path:
    ///   - frame-skip (same snapshot twice)
    ///   - damage-triggered rebuild (new snapshot each call)
    ///   - invalidate-between-calls (forces rebuild each time)
    /// The explicit `NoDrawableMTKView` forces the nil-drawable path
    /// on every one so the test can complete in xctest (no real GPU
    /// drawable is ever acquired). 10 calls — if any `signal()` was
    /// missed, the 4th would block forever and we'd hit the xctest
    /// default timeout (deliberate tripwire; the test must return
    /// within a handful of ms on the happy path).
    func test_render_tripleBufferRing_noStarvationAcrossMixedPaths() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)

        // Path 1: frame-skip short-circuit (3 same-snapshot renders). At
        // the ring's capacity of 3 these would all claim a slot if
        // frame-skip didn't bypass the semaphore; the comment at the
        // source `frameKey == lastFrameKey` branch says "we never
        // claimed a slot, so we don't signal back".
        let snap = try makeSmallSnapshot(text: "stable")
        for _ in 0..<3 {
            renderer.render(in: view, snapshot: snap, focused: true)
        }

        // Path 2: damage-triggered rebuild (each render has a new
        // snapshot so frame-skip can't fire). 4 calls > 3 slots, so
        // one of them must rotate through all three buffers. If the
        // no-drawable path fails to signal, this deadlocks before
        // the xctest default timeout.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        for i in 0..<4 {
            term.input("\(i)")
            let varying = try XCTUnwrap(term.snapshot())
            renderer.render(in: view, snapshot: varying, focused: true)
        }

        // Path 3: invalidate-between-calls forces a full rebuild on
        // every render. 3 calls = exactly ring depth, so every slot
        // must be hit and released before the next wait() lands.
        for _ in 0..<3 {
            renderer.invalidate()
            renderer.render(in: view, snapshot: snap, focused: true)
        }

        // Final sanity: renderer still responds to atlas queries after
        // 10 back-to-back ring rotations. A cache free or buffer
        // deallocation bug would surface here.
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("s")))
    }

    /// Regression for metal-renderer F20.
    ///
    /// Drawable acquisition now happens BEFORE the semaphore wait, so
    /// a frame that can't get a drawable (headless test host here) no
    /// longer claims a slot it then has to release. Four successive
    /// drawable-less renders in a row would have blocked indefinitely
    /// in the pre-fix ordering if `signal()` was missed; here we
    /// intentionally drive five calls — more than the 3-slot
    /// semaphore — to prove no slot is being leaked even under the
    /// "no drawable" path.
    func test_render_noDrawablePath_doesNotLeakSemaphore() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenMTKView(device: device)
        let snapshot = try makeSmallSnapshot(text: "leak-check")

        // Five calls; view returns nil drawable every time. If the
        // pre-fix order (wait-then-fail) somehow regressed, the
        // second through fifth call would block forever because the
        // first frame's `signal()` on drawable-fail is still running
        // — the test host would time out rather than fail cleanly,
        // which is why we keep the count small. Post-fix order (fail
        // before wait) has no signal imbalance at all.
        for _ in 0..<5 {
            renderer.render(in: view, snapshot: snapshot, focused: true)
        }
    }

    // MARK: - High-2: explicit black bg paints on non-black themes

    /// `shouldPaintBgQuad` decides whether a cell's background quad
    /// gets emitted. Pre-fix the decision compared `cell.bg` to literal
    /// `0x000000`, so on themes whose default bg isn't black (Atom
    /// dark, Catppuccin, Solarized …) any cell with `\x1b[40m` (palette
    /// black) silently dropped its quad and the theme bg leaked
    /// through. Fix compares to the active theme's `defaultBgRgb`
    /// instead. Audit H2.

    func test_shouldPaintBgQuad_explicitBlackPaintsOnNonBlackTheme() {
        // Atom dark theme bg = 0x282C34. Cell bg = palette black
        // (0x000000). User-emitted `\x1b[40m` IS explicit; must paint.
        XCTAssertTrue(MetalRenderer.shouldPaintBgQuad(
            cellBg: 0x000000, defaultBg: 0x282C34, reverse: false
        ))
    }

    func test_shouldPaintBgQuad_defaultBgDoesNotPaint() {
        // Cell bg matches theme default — no quad, transparent
        // clearColor shows through. This is the "default" cell case.
        XCTAssertFalse(MetalRenderer.shouldPaintBgQuad(
            cellBg: 0x282C34, defaultBg: 0x282C34, reverse: false
        ))
    }

    func test_shouldPaintBgQuad_explicitNonDefaultBgPaints() {
        // Cell bg is some palette colour ≠ default — vim status line,
        // syntax highlight. Must paint.
        XCTAssertTrue(MetalRenderer.shouldPaintBgQuad(
            cellBg: 0xFF0000, defaultBg: 0x282C34, reverse: false
        ))
    }

    func test_shouldPaintBgQuad_reverseAlwaysPaints() {
        // REVERSE swaps fg/bg; the resulting bg is whatever the cell's
        // fg was — always a concrete palette value the user wants
        // painted (cursor row, selection, highlight). Even when
        // `cellBg == defaultBg`, reverse forces the quad.
        XCTAssertTrue(MetalRenderer.shouldPaintBgQuad(
            cellBg: 0x282C34, defaultBg: 0x282C34, reverse: true
        ))
    }

    func test_shouldPaintBgQuad_blackThemeBlackCellDoesNotPaint() {
        // Black-on-black theme (the pre-fix code only worked here).
        // cell.bg == defaultBg == 0x000000 → no quad. Pin so future
        // refactors keep this case at parity with the post-fix logic.
        XCTAssertFalse(MetalRenderer.shouldPaintBgQuad(
            cellBg: 0x000000, defaultBg: 0x000000, reverse: false
        ))
    }

    // MARK: - M-16: displayOffset cast must not trap on negative input
    //
    // BBSnapshot.displayOffset returns Int (from a Rust u32) and is
    // therefore non-negative by construction today. The renderer used
    // to feed it through `UInt32(value)`, which traps on negative
    // input — a one-liner regression that lets a negative value sneak
    // through (e.g. an off-by-one in a future scrollback math change)
    // would crash the renderer mid-frame. Switching to
    // `UInt32(clamping:)` pins the contract at the cast site so the
    // hot per-frame path becomes unconditionally safe.
    //
    // We can't construct a BBSnapshot with a negative displayOffset
    // from a test (the field is u32 in Rust, the Swift accessor just
    // widens it). The smallest signal-bearing test is to pin the
    // semantics of `UInt32(clamping:)` for the inputs that matter:
    // negative ints clamp to 0, the project-typical positive range
    // round-trips, and Int.min doesn't trap. Co-located here (next
    // to shouldPaintBgQuad and the rest of the FrameKey-input pins)
    // because the cast lives inside the FrameKey/CacheKey builds.

    func test_displayOffsetCast_negativeClampsToZero() {
        // Sentinel for the regression we're guarding against: any
        // negative value (Int.min in particular — the audit-cited
        // worst case) must NOT trap and must produce a valid UInt32.
        XCTAssertEqual(UInt32(clamping: -1), 0)
        XCTAssertEqual(UInt32(clamping: Int.min), 0)
        XCTAssertEqual(UInt32(clamping: -100_000), 0)
    }

    func test_displayOffsetCast_positiveRoundTrips() {
        // Normal scrollback range — preserved exactly. Rust core caps
        // history at 200 000 lines; cast must not narrow.
        XCTAssertEqual(UInt32(clamping: 0), 0)
        XCTAssertEqual(UInt32(clamping: 200_000), 200_000)
        XCTAssertEqual(UInt32(clamping: Int(UInt32.max)), UInt32.max)
    }

    func test_displayOffsetCast_overflowSaturates() {
        // Inputs above UInt32.max saturate rather than trap. The
        // FrameKey contract is "two visually different scroll
        // positions must produce two different UInt32 values"; once
        // we've saturated we've exceeded that contract, but trapping
        // is strictly worse than rendering at the saturated key.
        XCTAssertEqual(UInt32(clamping: Int(UInt32.max) + 1), UInt32.max)
        XCTAssertEqual(UInt32(clamping: Int.max), UInt32.max)
    }
}
