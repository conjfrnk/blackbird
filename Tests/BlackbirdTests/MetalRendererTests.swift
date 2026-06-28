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
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        XCTAssertTrue(renderer.device === device,
                      "renderer must surface the device it was constructed with")
        XCTAssertGreaterThan(renderer.atlas.capacityGlyphs, 0,
                             "atlas must be sized to at least one glyph slot")
    }

    func test_rendererPipelineStateLoads() throws {
        let device = try requireMetalDevice()
        // If init returns non-nil, both the library and the pipeline state loaded.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        XCTAssertEqual(renderer.atlas.metrics.cellWidth, metrics.cellWidth,
                       "pipeline must preserve the metrics it was constructed with")
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
        let cEntry = try XCTUnwrap(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("c")))
        XCTAssertFalse(cEntry.isColor, "ASCII 'c' must rasterize to the mono atlas, not the color path")
        XCTAssertFalse(cEntry.isWide, "ASCII 'c' must occupy a single atlas slot, not a wide pair")
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
        for c in ["h", "e", "H"] {
            let entry = try XCTUnwrap(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar(c)!))
            XCTAssertFalse(entry.isColor, "ASCII '\(c)' must rasterize to mono atlas")
            XCTAssertFalse(entry.isWide, "ASCII '\(c)' must be single-slot, not wide")
        }
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
            XCTAssertTrue(renderer?.device === device,
                          "renderer must surface its constructor device before being released")
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
        let xEntry = renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("x"))
        XCTAssertFalse(xEntry?.isColor ?? true, "atlas must accept 'x' as a mono ASCII glyph after invalidate+render")
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
        let sEntry1 = renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("s"))
        XCTAssertFalse(sEntry1?.isColor ?? true, "atlas must accept 's' after 10 back-to-back ring rotations")
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

    // MARK: - M-20: metricsGeneration bumps on every metrics mutation

    /// Pins the audit-M-20 invariant: every metrics mutation bumps
    /// `metricsGeneration`, which is folded into both `FrameKey` and
    /// `CacheKey`. Without this counter the font-size invariant was
    /// held only by the explicit `lastFrameKey = nil` inside
    /// `reconfigure(metrics:scale:)` — any other path that mutated
    /// `metrics` directly (today: none, but `metrics` is `public var`)
    /// would silently bypass the invalidation and the next render
    /// could short-circuit on a stale FrameKey while the cell sizes
    /// had changed underneath.
    ///
    /// Mirrors the GlyphAtlas `generation` test in GlyphAtlasTests.
    func test_metricsGeneration_startsAtOneAndBumpsOnReconfigure() throws {
        let device = try requireMetalDevice()
        let metrics1 = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics1))
        // Initial generation is 1 (set in init). The exact value isn't
        // load-bearing — what matters is that a fresh renderer has a
        // non-zero generation and that subsequent reconfigures
        // monotonically bump it.
        let gen0 = renderer.metricsGeneration
        XCTAssertGreaterThanOrEqual(gen0, 1,
            "fresh renderer must seed metricsGeneration so FrameKey is well-defined on the first render")

        let metrics2 = CellMetrics(font: .monospacedSystemFont(ofSize: 20, weight: .regular))
        XCTAssertTrue(renderer.reconfigure(metrics: metrics2, scale: 2.0))
        let gen1 = renderer.metricsGeneration
        XCTAssertEqual(gen1, gen0 &+ 1,
            "successful reconfigure must bump metricsGeneration by 1")

        let metrics3 = CellMetrics(font: .monospacedSystemFont(ofSize: 16, weight: .regular))
        XCTAssertTrue(renderer.reconfigure(metrics: metrics3, scale: 2.0))
        XCTAssertEqual(renderer.metricsGeneration, gen1 &+ 1,
            "second reconfigure must bump metricsGeneration again")
    }

    // MARK: - H7: drawable-failure must not advance the skip-cache
    //
    // `lastFrameKey` is the renderer's frame-skip cache key; when the
    // current FrameKey matches `lastFrameKey` `render(in:)` short-
    // circuits without re-encoding. Pre-fix, `lastFrameKey` was
    // written BEFORE drawable acquisition — so a frame that bailed
    // on `view.currentDrawable == nil` (window minimised, drawable
    // pool exhausted) recorded its FrameKey, causing the next call
    // with an identical FrameKey to silently skip and never recover.
    // The fix moves the `lastFrameKey` write to AFTER successful
    // drawable + descriptor + command-buffer + encoder acquisition,
    // so an early return leaves `lastFrameKey` pinned to the
    // previous *encoded* frame.

    /// Counting subclass: returns nil for `currentDrawable` (forces
    /// the failure path) and tallies how many times the property
    /// was queried. The skip-cache short-circuit returns BEFORE
    /// touching `currentDrawable`, so a poisoned cache shows up as
    /// "queried fewer times than render() was called". A healthy
    /// cache (post-fix) queries `currentDrawable` on every call.
    private final class CountingNoDrawableMTKView: MTKView {
        var currentDrawableQueries: Int = 0
        override var currentDrawable: CAMetalDrawable? {
            currentDrawableQueries += 1
            return nil
        }
        override var currentRenderPassDescriptor: MTLRenderPassDescriptor? { nil }
    }

    /// Regression for audit H7. Drive multiple drawable-failed
    /// `render(in:)` calls with an identical snapshot. Pre-fix,
    /// the second call would short-circuit on `frameKey ==
    /// lastFrameKey` (set during the first failed attempt) and the
    /// renderer would freeze: every subsequent call hit the skip
    /// path, so even when a drawable became available no encode
    /// would happen until something else invalidated the cache.
    /// Post-fix, the failed first call leaves `lastFrameKey`
    /// unchanged, so the second call enters the encode path again
    /// (and fails the same way — but does NOT skip).
    ///
    /// Discriminator: `currentDrawable` is queried only on the
    /// encode-attempt path. The skip-cache short-circuit returns
    /// before reaching `view.currentDrawable`. So a poisoned cache
    /// tallies fewer drawable queries than render calls.
    func test_render_drawableFailure_doesNotPoisonSkipCache() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = CountingNoDrawableMTKView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        let snapshot = try makeSmallSnapshot(text: "h7-regression")

        // Drive five renders with the IDENTICAL snapshot. Each one
        // must reach `view.currentDrawable` (and bail when it
        // returns nil). Pre-fix only the first call would touch
        // currentDrawable; the next four would short-circuit on
        // the now-poisoned skip cache, leaving the count at 1.
        // Post-fix every call goes through the drawable check,
        // count == 5.
        let renderCalls = 5
        for _ in 0..<renderCalls {
            renderer.render(in: view, snapshot: snapshot, focused: true)
            XCTAssertTrue(renderer.didFrameSkipLastRender,
                          "every drawable-failed render must report didFrameSkipLastRender = true")
        }

        XCTAssertEqual(
            view.currentDrawableQueries, renderCalls,
            "every render() with a fresh drawable must attempt drawable acquisition; "
            + "if this count is < \(renderCalls), the H7 regression is back: a "
            + "drawable-failed render poisoned `lastFrameKey` and subsequent renders "
            + "with the same FrameKey now short-circuit on the skip-cache without "
            + "ever re-attempting encode."
        )

        // Final: atlas still responds to lookups. Regression guard
        // against a state corruption that would surface as a freed
        // texture or stale cache after the failed-render barrage.
        let hEntry = renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("h"))
        XCTAssertFalse(hEntry?.isColor ?? true, "atlas must accept 'h' after the FrameKey skip-cache exercise")
    }

    /// Companion: pins the H7 contract more directly. After a single
    /// drawable-failed render, a SECOND render with the identical
    /// state must again attempt drawable acquisition — proving the
    /// failed first frame did NOT advance `lastFrameKey`. Pre-fix
    /// would skip the second drawable query.
    func test_render_failedFrame_doesNotAdvanceLastFrameKey() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = CountingNoDrawableMTKView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        let snapshot = try makeSmallSnapshot(text: "stable-h7")

        renderer.render(in: view, snapshot: snapshot, focused: true)
        let queriesAfterFirst = view.currentDrawableQueries
        XCTAssertEqual(queriesAfterFirst, 1,
                       "first render must attempt drawable acquisition exactly once")

        // Second render with the IDENTICAL state. Post-fix the cache
        // was NOT advanced on the first call's failure, so this call
        // also enters the drawable path. Pre-fix, the cache was
        // poisoned and this call short-circuits without touching
        // currentDrawable.
        renderer.render(in: view, snapshot: snapshot, focused: true)
        XCTAssertEqual(
            view.currentDrawableQueries, queriesAfterFirst + 1,
            "second render with identical state must also attempt drawable "
            + "acquisition — the failed first frame must not have advanced "
            + "the skip-cache (audit H7)"
        )
    }

    // MARK: - P4.12: backing-scale change + GPU device-loss defensive pins
    //
    // User-impact reviewer flagged two unverified paths that surface as
    // crashes today:
    //
    //   1. Backing-scale change (Retina ↔ 1× ↔ 3×): user drags the
    //      Blackbird window between displays of different pixel
    //      densities. `mtkView(_:drawableSizeWillChange:)` in
    //      TerminalView.swift recomputes the new scale and calls
    //      `MetalRenderer.reconfigure(metrics:scale:)`. The atlas must
    //      rasterise at the new pixel resolution AND the renderer must
    //      reset its frame-skip / per-row caches so the next frame
    //      doesn't reuse stale glyph IDs whose UV layout was issued
    //      against the old atlas. The reconfigure path was previously
    //      tested only at a single scale (test_reconfigureWithFreshMetricsSucceeds
    //      above); these tests exercise the cross-scale sweep that a
    //      laptop-on-external-monitor workflow hits routinely.
    //
    //   2. GPU device removal (eGPU hot-unplug): a Thunderbolt eGPU
    //      enclosure can be disconnected mid-session. Today the GPU
    //      selection policy avoids `isRemovable` devices entirely (see
    //      MetalDeviceSelectionTests.test_rejectsRemovableEvenIfLowPower),
    //      so the eGPU is never picked in the first place — but a
    //      future "pick GPU in Settings" feature that honours user
    //      overrides would expose us. The defensive line of last resort
    //      is the `currentDrawable == nil` guard inside `render(in:)`:
    //      a removed device returns nil drawables, and the renderer
    //      must take the early-return path without crashing. We can't
    //      simulate `MTLDevice` loss directly in xctest (no clean mock
    //      surface for a real `MTLDevice`), so we PIN the source-level
    //      defensive properties so a future refactor that strips them
    //      trips a test.
    //
    // Memory pre-flight per `feedback_test_memory_safety`:
    //   GlyphAtlas at scale s with 4096-cell capacity uses roughly
    //   (8 * s)² * (16 * s)² bytes for the mono texture (R8) plus 4×
    //   that for the color texture (BGRA8). At 13pt:
    //     scale 1.0 →   ~3 MB total atlas (mono+color)
    //     scale 2.0 →  ~15 MB total atlas
    //     scale 3.0 →  ~33 MB total atlas
    //   reconfigure() peaks at 2× during the swap (old + new alive).
    //   Worst case in the 2 → 1 → 3 sweep: 33 + 15 = ~48 MB peak,
    //   well within the 256 MB per-test budget. Wall-clock < 100 ms
    //   per test on an M1 (atlas init is ~10-20 ms; we do at most
    //   three).

    /// A backing-scale change is the most common atlas reconfigure
    /// path in real use: a laptop user with an external 1× monitor
    /// drags Blackbird between the laptop's Retina (2×) and the
    /// external (1×) displays. Each transition fires
    /// `mtkView(_:drawableSizeWillChange:)` (TerminalView.swift:1395),
    /// which calls `renderer.reconfigure(metrics:scale:newScale)`.
    ///
    /// What the renderer must do:
    ///   1. Rebuild the GlyphAtlas at the new pixel resolution so
    ///      glyphs stay sharp (atlas.scale == newScale post-call).
    ///   2. Reset the frame-skip cache so the very next render
    ///      doesn't short-circuit on a FrameKey from before the
    ///      scale change — those cached UVs were issued against the
    ///      previous atlas's slot layout and pointing them at the
    ///      new texture would silently render wrong glyphs.
    ///
    /// Pre-fix (audit M-20 + UR-1) the second invariant relied on a
    /// single explicit `lastFrameKey = nil` line inside reconfigure.
    /// We can't read `lastFrameKey` (private), but we CAN observe via
    /// `CountingNoDrawableMTKView` whether the render attempted to
    /// acquire a drawable. The skip-cache short-circuit returns BEFORE
    /// reaching `view.currentDrawable`, so a poisoned cache reads as
    /// "queried fewer times than render() was called". A reconfigure
    /// that fails to reset `lastFrameKey` would let the post-reconfigure
    /// render short-circuit on the prior FrameKey and silently ship
    /// glyphs at the wrong scale.
    ///
    /// Note: `didFrameSkipLastRender` is overloaded in production —
    /// it's set to true on BOTH the skip-cache short-circuit AND the
    /// drawable-acquire-failed path. The drawable-query count is
    /// the only public signal that distinguishes them; we use the
    /// same trick H7's tests use (CountingNoDrawableMTKView).
    @MainActor
    func test_reconfigure_acrossScales_resetsAtlasAndSkipCache() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = CountingNoDrawableMTKView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        let snapshot = try makeSmallSnapshot(text: "scale-sweep")

        // Pre-condition: render once at the renderer's default scale
        // (2.0) to populate the frame-skip cache. The render itself
        // takes the no-drawable path, but FrameKey/CacheKey state is
        // still updated up to the drawable-acquire point.
        XCTAssertEqual(renderer.atlas.scale, 2.0, "init seeds scale=2.0")
        renderer.render(in: view, snapshot: snapshot, focused: true)
        let queriesAfterFirst = view.currentDrawableQueries
        XCTAssertEqual(queriesAfterFirst, 1, "first render attempts drawable acquisition once")

        // Drag to 1× display (e.g. external monitor). The atlas must
        // rebuild at the new scale; the cell pixel dimensions shrink.
        XCTAssertTrue(
            renderer.reconfigure(metrics: metrics, scale: 1.0),
            "reconfigure to 1.0× must succeed on any host with a working GPU"
        )
        XCTAssertEqual(renderer.atlas.scale, 1.0, "atlas.scale must track the requested scale")
        let pxAt1x = renderer.atlas.cellPxHeight

        // The next render must NOT short-circuit on the previous
        // FrameKey — the atlas swap invalidated everything. If the
        // skip-cache wasn't reset by reconfigure, this render would
        // skip BEFORE touching currentDrawable and the query count
        // would stay flat at 1. Post-reconfigure (correct) the
        // render enters the encode path, queries currentDrawable
        // (gets nil here), and bails — count goes to 2.
        renderer.render(in: view, snapshot: snapshot, focused: true)
        XCTAssertEqual(
            view.currentDrawableQueries, queriesAfterFirst + 1,
            "post-reconfigure render must reach the drawable-acquire path — "
            + "if the cache wasn't reset by reconfigure(metrics:scale:), the "
            + "FrameKey would still match lastFrameKey and the render would "
            + "short-circuit before currentDrawable, leaving the count flat. "
            + "Audit UR-1: reconfigure must invalidate lastFrameKey in lockstep "
            + "with the atlas swap."
        )

        // Drag to 3× display (Liquid Retina XDR external). The atlas
        // rebuilds again at the new pixel density.
        XCTAssertTrue(
            renderer.reconfigure(metrics: metrics, scale: 3.0),
            "reconfigure to 3.0× must succeed (Liquid Retina XDR is real hardware)"
        )
        XCTAssertEqual(renderer.atlas.scale, 3.0)
        let pxAt3x = renderer.atlas.cellPxHeight
        XCTAssertGreaterThan(
            pxAt3x, pxAt1x,
            "3× cells must be larger in pixels than 1× cells (rendered at full pixel resolution)"
        )

        // One more render to confirm the second reconfigure also
        // reset the skip-cache. Same observable as before: the
        // drawable query count must advance.
        let queriesBeforeThird = view.currentDrawableQueries
        renderer.render(in: view, snapshot: snapshot, focused: true)
        XCTAssertEqual(
            view.currentDrawableQueries, queriesBeforeThird + 1,
            "render after the 1→3 reconfigure must also reach the drawable path"
        )

        // Atlas survives the full 2 → 1 → 3 sweep and still answers
        // glyph lookups. Regression guard against a swap that frees
        // the new atlas's texture or strands a stale reference.
        let sEntry2 = renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("s"))
        XCTAssertFalse(sEntry2?.isColor ?? true, "atlas must answer lookups after the 2 -> 1 -> 3 reconfigure sweep")
    }

    /// Defensive: backing-scale boundary inputs must be rejected
    /// rather than crashing. `mtkView(_:drawableSizeWillChange:)`
    /// already guards against `bounds.width == 0` and `newScale <= 0`
    /// at the call site (TerminalView.swift:1403-1405), but the
    /// renderer's `reconfigure(metrics:scale:)` is also reachable from
    /// other paths (font-size sync, future settings UI). The atlas
    /// initializer rejects scale ≤ 0 (GlyphAtlas.swift:139); the
    /// renderer surfaces that as `false` so callers can keep their
    /// own state in sync.
    ///
    /// Trapping rather than returning false would crash the whole
    /// process on a degenerate input from a future refactor — this
    /// pins the safer behaviour. Tested via reconfigure (atlas init
    /// is internal; the renderer's wrapper is what we care about).
    @MainActor
    func test_reconfigure_zeroScale_returnsFalseAndDoesNotCrash() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let originalScale = renderer.atlas.scale

        // Zero scale: GlyphAtlas init returns nil (degenerate cell
        // size), so reconfigure must return false and leave the
        // renderer in its previous state. Atomicity invariant from
        // the reconfigure doc-comment: "metrics only change if the
        // new atlas built successfully".
        XCTAssertFalse(
            renderer.reconfigure(metrics: metrics, scale: 0.0),
            "scale = 0 must be rejected — GlyphAtlas guards against zero-pixel cells"
        )
        XCTAssertEqual(
            renderer.atlas.scale, originalScale,
            "rejected reconfigure must NOT swap the atlas; previous one stays in place"
        )

        // Negative scale: same rejection path. Pin separately so a
        // future refactor that loosens one but not the other (e.g.
        // adds an `abs()` call) trips here.
        XCTAssertFalse(
            renderer.reconfigure(metrics: metrics, scale: -1.0),
            "negative scale must be rejected — pixel dimensions can't be negative"
        )
        XCTAssertEqual(renderer.atlas.scale, originalScale)

        // After two failed reconfigures the renderer must still be
        // usable. Regression guard against a partial-mutation bug
        // that left metrics or generation counters in a half-updated
        // state on the rejection path.
        let zEntry = renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("z"))
        XCTAssertFalse(zEntry?.isColor ?? true, "atlas must remain usable after two failed reconfigures")
    }

    /// Source pin: GPU device-loss surfaces as `view.currentDrawable
    /// == nil`. The renderer's defence is the guard at line ~1302 of
    /// MetalRenderer.swift:
    ///
    ///   guard let drawable = view.currentDrawable, ... else {
    ///     inflightSemaphore.signal(); return
    ///   }
    ///
    /// A future refactor that removes this guard (e.g. force-
    /// unwrapping `view.currentDrawable!` in a "fix latency" PR)
    /// would crash on eGPU hot-unplug, window minimisation, or
    /// drawable-pool exhaustion — none of which are testable from
    /// xctest because they require actual hardware events or system
    /// state. Pin the guard's existence at the source level so the
    /// regression surfaces as a CI failure rather than a customer
    /// crash report.
    ///
    /// Why a source pin instead of a runtime test: simulating
    /// MTLDevice loss requires either:
    ///   - a real eGPU enclosure (not present in CI),
    ///   - mocking MTLDevice (no clean Swift mock surface; MTLDevice
    ///     is a system-defined protocol with hundreds of methods and
    ///     opaque internal state),
    ///   - or a private API like `MTLDebugDevice` (Apple-internal,
    ///     not stable).
    /// The runtime tests above (test_render_drawableFailure_*,
    /// test_render_failedFrame_*) already exercise the nil-drawable
    /// PATH via `CountingNoDrawableMTKView`. This source pin asserts
    /// that the production code STILL HAS the defensive check that
    /// makes those tests meaningful in the first place.
    func test_metalRenderer_drawablePathHasNilGuard_sourcePin() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Renderer/MetalRenderer.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "MetalRenderer.swift not found at \(url.path) — `#filePath` arithmetic broke; "
            + "fix path resolution rather than downgrading to XCTSkip (matches the policy in "
            + "MetalDrawableCountSourcePinTests.locateTerminalViewSwift)"
        )
        let src = try String(contentsOf: url, encoding: .utf8)

        // The defensive guard. Two regressions to guard against:
        //   (a) Removing the `guard let drawable = view.currentDrawable`
        //       line entirely, replacing with `let drawable = view.currentDrawable!`.
        //   (b) Replacing the guard with `view.currentDrawable ??
        //       fallbackDrawable` where `fallbackDrawable` is itself
        //       not validated — same crash, one indirection deeper.
        //
        // We pin the literal pattern. A refactor that legitimately
        // restructures the path (e.g. extracts a helper function)
        // must update this test to point at the new shape.
        XCTAssertTrue(
            src.contains("guard let drawable = view.currentDrawable"),
            """
            MetalRenderer.swift no longer guards `view.currentDrawable` for nil. \
            This is the defensive line of last resort for GPU device loss \
            (eGPU hot-unplug, window minimisation, surface invalidation). \
            Removing it exposes Blackbird to crash-on-device-loss; if you \
            intentionally restructured the drawable-acquire path, update this \
            test to pin the new shape.
            """
        )

        // Companion: the `inflightSemaphore.signal()` path on guard
        // failure. Without the signal, the next render() blocks
        // forever on `inflightSemaphore.wait()` because the slot
        // we claimed before the guard never gets released. Audit
        // metal-renderer F20 reverted a "drawable-first" attempt
        // for exactly this reason.
        XCTAssertTrue(
            src.contains("inflightSemaphore.signal()"),
            """
            MetalRenderer.swift no longer signals the inflight semaphore on \
            drawable-acquire failure. A render() that claims a slot via wait() \
            and then bails on `currentDrawable == nil` MUST signal back, or \
            the 3-slot ring leaks one slot per failed frame and the 4th call \
            blocks forever (audit metal-renderer F20).
            """
        )

        // Proximity pin: the nil-drawable guard and the inflight-
        // semaphore signal MUST live in the same code path. The two
        // separate substring checks above pass independently even
        // if a future refactor moves them into unrelated branches —
        // e.g. the guard stays in `render(in:)` but the signal
        // migrates to a deinit handler, leaving the failed-render
        // path with no signal at all. Walk forward from the guard
        // line (only the FIRST occurrence — the test relies on
        // there being exactly one such guard in this file; adding
        // a second one is itself a flag worth investigating) and
        // assert `inflightSemaphore.signal()` appears within 50
        // lines. 50 is generous: the production path runs ~30
        // lines from guard to signal; doubling that lets a future
        // refactor reorganise the body without flaking, but still
        // catches a structural separation.
        let lines = src.split(separator: "\n", omittingEmptySubsequences: false)
        var guardLineIdx: Int? = nil
        for (idx, line) in lines.enumerated() {
            if line.contains("guard let drawable = view.currentDrawable") {
                guardLineIdx = idx
                break
            }
        }
        if let guardIdx = guardLineIdx {
            let scanWindow = 50
            let endIdx = min(guardIdx + scanWindow, lines.count)
            // The slot release is now a co-located CALL to `releaseSlotUnused()`
            // (the slot-lifecycle helper extracted from render()), or the bare
            // `inflightSemaphore.signal()` if a future refactor re-inlines it.
            // Either is the synchronous, same-code-path release F20 requires;
            // accept both so the pin survives the extraction while still catching
            // a regression that moves the release into a deinit/async context.
            var foundRelease = false
            for idx in guardIdx..<endIdx {
                if lines[idx].contains("releaseSlotUnused()")
                    || lines[idx].contains("inflightSemaphore.signal()") {
                    foundRelease = true
                    break
                }
            }
            XCTAssertTrue(
                foundRelease,
                "the nil-drawable guard and the inflight-semaphore release must " +
                "be in the same code path; they appear too far apart in the " +
                "file. Found `guard let drawable = view.currentDrawable` at " +
                "line \(guardIdx + 1) (1-based) but no `releaseSlotUnused()` / " +
                "`inflightSemaphore.signal()` within the next \(scanWindow) lines. " +
                "A refactor that separates them — e.g. moves the release into a " +
                "deinit handler or an async block — re-opens the slot-leak shape " +
                "that audit F20 fixed: render() claims a slot via wait(), bails on " +
                "nil drawable, and the slot is never released. Restore proximity " +
                "or update this test to point at the new co-located pair."
            )
        }
        // The co-located release goes through `releaseSlotUnused()`; pin that
        // the helper actually signals the semaphore (so the indirection can't
        // silently become a no-op that re-opens the F20 slot leak).
        XCTAssertNotNil(
            src.range(
                of: #"func releaseSlotUnused\(\)\s*\{\s*ring\.inflightSemaphore\.signal\(\)\s*\}"#,
                options: .regularExpression
            ),
            "releaseSlotUnused() must signal inflightSemaphore — the abort-1 path's " +
            "actual slot release. If this helper stops signalling, the nil-drawable " +
            "frame leaks its triple-buffer slot (audit F20)."
        )
        // If guardLineIdx is nil the substring assertion above already
        // failed with a more actionable message; no need to fail twice.
    }

    /// Source pin: the GPU-selection policy excludes removable
    /// (eGPU) devices. This is the FIRST line of defence against
    /// eGPU hot-unplug — by never picking the eGPU in the first
    /// place, we don't have to handle its removal mid-session.
    /// `MetalDeviceSelectionTests.test_rejectsRemovableEvenIfLowPower`
    /// pins this BEHAVIOURALLY; this test pins it at the SOURCE
    /// level so a future refactor that removes the `!$0.isRemovable`
    /// predicate trips a second test (defence in depth).
    ///
    /// The doc-comment on `chooseGPU` also documents the rationale
    /// — that documentation is itself load-bearing because it's the
    /// only signal a future engineer has that the predicate is a
    /// safety property rather than a stylistic choice. Pin its
    /// substring so a refactor that strips the comment also fails.
    func test_chooseGPU_excludesRemovable_sourcePin() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Renderer/MetalDeviceSelection.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "MetalDeviceSelection.swift not found at \(url.path)"
        )
        let src = try String(contentsOf: url, encoding: .utf8)

        // The selection predicate. Whitespace tolerant via separate
        // substring checks for the two halves so a future reformat
        // (e.g. multi-line predicate) doesn't break the pin.
        XCTAssertTrue(
            src.contains("isLowPower") && src.contains("!$0.isRemovable"),
            """
            chooseGPU(from:) no longer excludes removable devices. eGPU \
            hot-unplug would tear down all MTLResources bound to the \
            removed device, crashing the renderer. The `!$0.isRemovable` \
            predicate is the FIRST line of defence — restore it before \
            shipping. Memory file: project_release_adhoc_sparkle_crash.md \
            and the doc-comment on chooseGPU.
            """
        )

        // Rationale comment must mention eGPU / removable / unplug
        // so the predicate's intent survives a future audit.
        // Tolerant: any of these substrings is sufficient signal.
        let mentionsEgpu = src.contains("eGPU") || src.contains("Removable eGPU")
            || src.contains("removable")
        XCTAssertTrue(
            mentionsEgpu,
            """
            chooseGPU(from:) doc-comment no longer references eGPU / removable / \
            unplug. This rationale is the only signal a future engineer has \
            that `!$0.isRemovable` is a safety property (preventing \
            mid-session device loss) rather than a stylistic choice. Restore.
            """
        )
    }

    /// GAP NOTE for v1.0 (P4.12 follow-up):
    ///
    /// We do NOT have a runtime test that injects a nil MTLDevice
    /// into MetalRenderer.init or simulates a `MTLDeviceWasRemovedNotification`.
    /// The blockers:
    ///
    ///   - MTLDevice is an Apple system protocol; mocking it requires
    ///     stubbing dozens of methods (makeBuffer, makeTexture,
    ///     makeCommandQueue, makeDefaultLibrary, …) that the renderer
    ///     calls during init. A faithful mock would be hundreds of
    ///     lines of test code with its own bug surface.
    ///
    ///   - Simulating MTLDeviceWasRemovedNotification requires posting
    ///     to the system NotificationCenter from a private-API path
    ///     that Apple doesn't document. Even if it worked, no Blackbird
    ///     code today subscribes to that notification — the renderer
    ///     would not respond to the simulated event.
    ///
    /// What we DO have:
    ///
    ///   - MetalDeviceSelectionTests pins the `!$0.isRemovable`
    ///     predicate behaviourally, so an eGPU is never picked.
    ///   - test_metalRenderer_drawablePathHasNilGuard_sourcePin (above)
    ///     pins the `currentDrawable == nil` defensive guard at the
    ///     source level.
    ///   - test_render_drawableFailure_doesNotPoisonSkipCache + its
    ///     companion exercise the nil-drawable PATH at runtime via
    ///     CountingNoDrawableMTKView.
    ///
    /// What v1.0 should add (out of scope for P4.12):
    ///
    ///   - A "managed Metal device" abstraction layer behind an internal
    ///     protocol (mirroring GPUDeviceProperties), so a fake-device
    ///     test seam exists without mocking MTLDevice itself.
    ///   - Subscribe to MTLDeviceWasRemovedNotification at app launch
    ///     and surface a user-visible "GPU was disconnected; using
    ///     fallback" alert. Useful for the future "pick GPU in Settings"
    ///     feature (which would re-introduce the eGPU pick path).
    ///
    /// This documentation is itself the test artifact for the gap;
    /// no XCTAssert call here. Co-located with the source pins so
    /// it surfaces during P4.12 follow-up triage.
    func test_metalRenderer_deviceLossSimulation_documentedGap() {
        // Intentional no-op: see doc-comment above for the gap
        // analysis. This method exists so the comment is co-located
        // with the rest of the device-loss tests — `xcrun xctest
        // --list-tests` will surface it next to the others.
    }

    // MARK: - S2-006: aborted frames return their triple-buffer rotation turn
    //
    // The triple-buffer ring pairs a 3-slot semaphore with a rotating
    // frame index. The invariant: any ≤3 concurrent in-flight frames
    // occupy DISTINCT slots, which requires every consumed rotation
    // turn to hold its semaphore token until GPU completion. An aborted
    // frame (nil drawable / descriptor / command buffer) must give back
    // BOTH the token AND its rotation turn — returning the token while
    // keeping the rotation advance (or vice versa) eventually either
    // deadlocks the ring or lets two in-flight frames share a slot and
    // CPU-write a .storageModeShared instance buffer the GPU is still
    // reading (torn frames exactly under drawable-failure load).
    //
    // Memory pre-flight per `feedback_test_memory_safety`: one 20×8
    // BBTerm (~3 KB), one renderer (~4 MB instance buffers + atlas),
    // one 320×192 MTKView with a ≤3-drawable pool (~1 MB). Total well
    // under 10 MB; wall-clock dominated by 5 tiny GPU encodes (< 50 ms).

    /// MTKView that can be flipped per-call between vending a real
    /// drawable (stock CAMetalLayer behaviour — works offscreen in the
    /// xctest host, see the NoDrawableMTKView doc above) and failing
    /// the frame (nil drawable + nil descriptor → the aborted-frame
    /// path inside `render(in:)`).
    private final class TogglingDrawableMTKView: MTKView {
        var failFrame = false
        override var currentDrawable: CAMetalDrawable? {
            failFrame ? nil : super.currentDrawable
        }
        override var currentRenderPassDescriptor: MTLRenderPassDescriptor? {
            failFrame ? nil : super.currentRenderPassDescriptor
        }
    }

    private func makeTogglingView(device: MTLDevice) -> TogglingDrawableMTKView {
        let view = TogglingDrawableMTKView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        // Must match the renderer pipeline's colorAttachments[0] format
        // (same as TerminalView's init).
        view.colorPixelFormat = .bgra8Unorm
        return view
    }

    /// Blind regression pin for audit S2-006. Drives 8 render calls —
    /// strictly more than the 3-slot ring — alternating aborted frames
    /// (nil drawable) with successful encodes, each on a FRESH snapshot
    /// so the frame-skip cache can never short-circuit a call. Three
    /// observable contracts:
    ///   1. The sequence completes (no deadlock — a bookkeeping bug in
    ///      either direction starves the ring within 4 calls; a hang
    ///      here is the deliberate tripwire, same convention as
    ///      test_render_tripleBufferRing_noStarvationAcrossMixedPaths).
    ///   2. `didFrameSkipLastRender == true` after every aborted call.
    ///   3. `didFrameSkipLastRender == false` after every successful
    ///      encode — proving aborted frames didn't poison the rotation
    ///      or skip-cache state that subsequent encodes depend on.
    ///
    /// Hosts whose CAMetalLayer can't vend offscreen drawables (rare;
    /// some headless CI window servers) XCTSkip after the probe render,
    /// mirroring RealLatencyProbeWindowedTests' documented limitation.
    func test_render_abortedFramesReturnRotationTurn_acrossEightAlternatingCalls() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeTogglingView(device: device)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))

        // Probe: can this host vend an offscreen drawable at all? If
        // not, the success-path half of the contract is unobservable
        // here — skip rather than assert vacuously against abort-only
        // calls (NoDrawable-path coverage already exists above).
        term.input("seed")
        let seedSnap = try XCTUnwrap(term.snapshot())
        view.failFrame = false
        renderer.render(in: view, snapshot: seedSnap, focused: true)
        if renderer.didFrameSkipLastRender {
            throw XCTSkip(
                "xctest host cannot acquire an offscreen CAMetalLayer drawable "
                + "(view.currentDrawable == nil on the probe render); the "
                + "successful-encode half of the S2-006 contract is unobservable "
                + "here. Abort-path-only coverage lives in "
                + "test_render_noDrawablePath_doesNotLeakSemaphore."
            )
        }
        // Release the cached drawable so the next successful call gets a
        // fresh one instead of re-presenting the same CAMetalDrawable
        // (which logs `[API] Each CAMetalLayerDrawable can only be
        // presented once!` — see the NoDrawableMTKView rationale above).
        view.releaseDrawables()

        // 8 alternating calls: even indices abort, odd indices encode.
        // Every call feeds a byte first so each snapshot's sequenceID —
        // and therefore the FrameKey — differs, keeping the frame-skip
        // cache out of the picture for the whole sweep.
        for i in 0..<8 {
            let abort = (i % 2 == 0)
            view.failFrame = abort
            term.input("\(i)")
            let snap = try XCTUnwrap(term.snapshot())
            renderer.render(in: view, snapshot: snap, focused: true)
            if abort {
                XCTAssertTrue(
                    renderer.didFrameSkipLastRender,
                    "call \(i): an aborted (nil-drawable) frame must report "
                    + "didFrameSkipLastRender == true — nothing reached the screen"
                )
            } else {
                XCTAssertFalse(
                    renderer.didFrameSkipLastRender,
                    "call \(i): a successful encode after an aborted frame must "
                    + "report didFrameSkipLastRender == false. If this is true, "
                    + "the prior abort corrupted ring/rotation or skip-cache "
                    + "state and the renderer is no longer presenting (audit "
                    + "S2-006 regression)."
                )
                view.releaseDrawables()
            }
        }
    }

    // MARK: - S2-007: instance-buffer grow failure abandons the frame
    //
    // When a snapshot needs more per-cell instances than the current
    // instance buffers hold, the renderer grows them via
    // `device.makeBuffer`. Under memory pressure that allocation can
    // fail (returns nil). The frame MUST be abandoned — not presented
    // with a truncated/blank instance buffer — and the failure must
    // not be sticky: once allocation succeeds again, rendering resumes.
    //
    // Memory pre-flight per `feedback_test_memory_safety`: the startup
    // instance buffers are exactly 200×80 = 16 000 slots × 80 B =
    // 1 280 000 B × 3 ring slots ≈ 3.8 MB (observed through the device
    // seam), so a 200×80 snapshot fits exactly and can never trigger a
    // grow — the test grid must exceed 16 000 cells. 210×80 = 16 800
    // cells is the smallest comfortable overshoot: BBTerm grid ≈
    // 16 800 × ~16 B ≈ 270 KB; grown buffers ≤ 3 × (~33 600 instances
    // × 80 B) ≈ 8 MB on the success path. Total < 13 MB, well inside
    // the 256 MB budget — the 200×80 guidance exists for this budget
    // computation, which the 5% overshoot does not meaningfully move.

    /// MTLDevice is a huge @objc protocol, so a hand-written conforming
    /// mock is impractical. Instead: an NSObject that fast-forwards
    /// every message to a real system device, intercepting only the two
    /// buffer-allocation selectors so a settable threshold can make
    /// allocations larger than `failBuffersLargerThan` bytes fail
    /// (return nil) exactly like a device under memory pressure.
    /// `conforms(to:)` is overridden so the `as? MTLDevice` cast
    /// succeeds; all other selectors hit the real device via
    /// `forwardingTarget(for:)` with full fidelity.
    private final class AllocationCappedDevice: NSObject {
        let wrapped: MTLDevice
        /// Buffer requests STRICTLY larger than this many bytes fail.
        var failBuffersLargerThan: Int = .max
        /// Byte sizes of every refused request (diagnostic + proof the
        /// grow path was actually exercised, not silently skipped).
        private(set) var refusedAllocations: [Int] = []
        /// Largest granted request so far — after init + a small render
        /// this is the startup instance-buffer size, which makes a
        /// perfect cap: any grow must be strictly larger.
        private(set) var grantedMaxLength: Int = 0

        init(wrapping: MTLDevice) {
            self.wrapped = wrapping
            super.init()
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? { wrapped }
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || wrapped.responds(to: aSelector)
        }
        override func conforms(to aProtocol: Protocol) -> Bool {
            super.conforms(to: aProtocol) || wrapped.conforms(to: aProtocol)
        }

        @objc(newBufferWithLength:options:)
        func makeBuffer(length: Int, options: MTLResourceOptions) -> MTLBuffer? {
            if length > failBuffersLargerThan {
                refusedAllocations.append(length)
                return nil
            }
            grantedMaxLength = max(grantedMaxLength, length)
            return wrapped.makeBuffer(length: length, options: options)
        }

        @objc(newBufferWithBytes:length:options:)
        func makeBuffer(bytes: UnsafeRawPointer, length: Int, options: MTLResourceOptions) -> MTLBuffer? {
            if length > failBuffersLargerThan {
                refusedAllocations.append(length)
                return nil
            }
            grantedMaxLength = max(grantedMaxLength, length)
            return wrapped.makeBuffer(bytes: bytes, length: length, options: options)
        }
    }

    /// Blind regression pin for audit S2-007.
    ///
    /// 1. Build the renderer over the forwarding device (no cap) and
    ///    prove a small frame encodes on this host (else XCTSkip — no
    ///    offscreen drawables means the present/abandon distinction is
    ///    unobservable).
    /// 2. Cap allocations at the largest granted so far (the startup
    ///    instance-buffer size), then render a 210×80 fully bg-styled
    ///    snapshot that needs more instances than startup capacity.
    ///    The grow's makeBuffer returns nil → the render must return
    ///    without crashing and `didFrameSkipLastRender == true` (frame
    ///    abandoned, NOT presented).
    /// 3. Lift the cap and render the SAME snapshot again → the grow
    ///    succeeds and `didFrameSkipLastRender == false`, proving the
    ///    failure wasn't pinned (no poisoned skip-cache, no zombie
    ///    half-grown buffer state).
    func test_render_instanceBufferGrowFailure_abandonsFrame_andIsNotSticky() throws {
        let realDevice = try requireMetalDevice()
        let capped = AllocationCappedDevice(wrapping: realDevice)
        guard let proxyDevice = capped as? MTLDevice else {
            XCTFail(
                "AllocationCappedDevice failed the `as? MTLDevice` cast — the "
                + "conforms(to:) forwarding override is not being honoured by "
                + "the Swift runtime on this host; the S2-007 grow-failure "
                + "contract cannot be exercised without a device seam."
            )
            return
        }

        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(
            MetalRenderer(device: proxyDevice, metrics: metrics),
            "renderer must initialize over the forwarding device while no cap is set"
        )
        // The view talks to the SAME physical GPU via the real device,
        // so drawable textures and the renderer's (forwarded) resources
        // are device-compatible.
        let view = makeTogglingView(device: realDevice)

        // Step 1: baseline small frame — proves the host vends offscreen
        // drawables and records the startup buffer sizes in `granted`.
        let smallTerm = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 8)))
        smallTerm.input("baseline")
        let smallSnap = try XCTUnwrap(smallTerm.snapshot())
        renderer.render(in: view, snapshot: smallSnap, focused: true)
        if renderer.didFrameSkipLastRender {
            throw XCTSkip(
                "xctest host cannot acquire an offscreen CAMetalLayer drawable; "
                + "presented-vs-abandoned frames are indistinguishable here, so "
                + "the S2-007 contract is unobservable (same limitation as "
                + "RealLatencyProbeWindowedTests)."
            )
        }
        view.releaseDrawables()
        XCTAssertGreaterThan(capped.grantedMaxLength, 0,
                             "renderer init + first frame must have allocated at least one buffer "
                             + "through the forwarding device — if 0, the seam isn't intercepting")

        // Step 2: cap at the largest granted allocation. A grow request
        // (strictly larger than any startup buffer) now fails.
        capped.failBuffersLargerThan = capped.grantedMaxLength

        // Build the oversized snapshot: 210×80 grid (16 800 cells — the
        // startup buffers hold exactly 200×80 = 16 000 instance slots,
        // so this grid cannot fit without a grow), every cell carrying
        // an explicit red background + a glyph so every cell emits an
        // instance.
        let bigTerm = try XCTUnwrap(BBTerm(size: .init(cols: 210, rows: 80)))
        bigTerm.input("\u{1B}[41m" + String(repeating: "x", count: 210 * 80))
        let bigSnap = try XCTUnwrap(bigTerm.snapshot())

        renderer.render(in: view, snapshot: bigSnap, focused: true)
        XCTAssertFalse(
            capped.refusedAllocations.isEmpty,
            "the 210×80 fully-styled snapshot must force an instance-buffer "
            + "grow while the cap is active — zero refused allocations means "
            + "the harness never exercised the S2-007 failure path (snapshot "
            + "not large enough to exceed the startup instance capacity, or "
            + "the grow bypassed makeBuffer)"
        )
        XCTAssertTrue(
            renderer.didFrameSkipLastRender,
            "a frame whose instance-buffer grow failed must be ABANDONED "
            + "(didFrameSkipLastRender == true), not presented with a "
            + "truncated or blank instance buffer (audit S2-007)"
        )
        view.releaseDrawables()

        // Step 3: lift the cap; the same snapshot must now render. A
        // sticky failure (poisoned skip-cache from the abandoned frame,
        // or half-grown buffer state pinned at the old capacity) shows
        // up as didFrameSkipLastRender staying true.
        capped.failBuffersLargerThan = .max
        renderer.render(in: view, snapshot: bigSnap, focused: true)
        XCTAssertFalse(
            renderer.didFrameSkipLastRender,
            "once allocation succeeds again the SAME snapshot must encode "
            + "and present (didFrameSkipLastRender == false) — the grow "
            + "failure must not be sticky (audit S2-007)"
        )
    }
}
