import Metal
import MetalKit
import AppKit
import BBCore
import os

public final class MetalRenderer {

    /// Shared `os.Logger` for renderer diagnostics. GPU command-buffer errors
    /// (device lost, page fault, shader trap) and teardown-drain events route
    /// here so they survive in the unified log with readable `privacy: .public`
    /// strings — the project-wide rule from `feedback_nslog_private_format`:
    /// NSLog's runtime format redacts everything to `<private>`, which hides
    /// the diagnostic we actually need.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "renderer")

    /// One-shot guard for `clampDisplayOffset`. Set the first time a
    /// negative raw `displayOffset` reaches the cast site so the
    /// `.error` log fires once per process instead of every frame
    /// (a stuck-negative regression would otherwise drown the
    /// unified log). Renderer is main-thread only — `dispatchPrecondition`
    /// in `render(in:)` and `reconfigure(metrics:scale:)` enforces it —
    /// so a plain static-mutable Bool is safe without a lock.
    /// Audit M-16 follow-up (2026-04-29).
    private static var negativeDisplayOffsetWarned = false

    /// Clamp a raw `Int` displayOffset into `UInt32` and one-shot warn
    /// if it was ever negative. Today BBCore's snapshot accessor wraps
    /// a Rust `u32` so the negative branch is unreachable, but the
    /// clamp is the contract pin (M-16) and the warning is the early
    /// signal for a regression that lets the contract drift. Two call
    /// sites (FrameKey + CacheKey); both per-frame, so the helper
    /// avoids duplicating the comment block at each one.
    private static func clampDisplayOffset(_ raw: Int) -> UInt32 {
        if raw < 0, !MetalRenderer.negativeDisplayOffsetWarned {
            MetalRenderer.negativeDisplayOffsetWarned = true
            logger.error("displayOffset went negative (\(raw, privacy: .public)); clamping to 0. BBCore contract violated — investigate scrollback math.")
        }
        return UInt32(clamping: raw)
    }

    /// Glyph atlas slots. 4096 covers ASCII + Latin supplements + common CJK
    /// + box-drawing + emoji-presentation for typical workloads without
    /// hitting the "atlas full → new glyphs render as blanks" cliff that a
    /// smaller cap (prior 1024) would reach on a day of mixed-locale output.
    /// R8Unorm texture at default cell size ≈ 9 MB, trivial on any Mac we
    /// support.
    static let atlasCapacity = 4096

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let cursorPipelineState: MTLRenderPipelineState
    /// External read-only by design. A direct `renderer.atlas = newAtlas`
    /// write would publish a fresh `GlyphAtlas` whose `generation`
    /// counter restarts at 0; if `lastCacheKey.atlasGeneration` was also
    /// 0 (no previous saturation flush) the renderer's per-row cache
    /// would silently match against the new atlas's UV layout while
    /// holding pre-swap UV coordinates — wrong glyphs that look right.
    /// Funnel all swaps through `reconfigure(metrics:scale:)`, which
    /// invalidates `lastFrameKey` / `lastCacheKey` / `rowInstanceCache`
    /// in lockstep. Audit UR-1 (2026-04-29).
    public private(set) var atlas: GlyphAtlas
    /// External read-only by design. Pairs with `metricsGeneration`
    /// below: the only writer is `reconfigure(metrics:scale:)`, which
    /// bumps the generation in lockstep so the FrameKey / CacheKey
    /// short-circuits invalidate on the very next frame. A direct
    /// `renderer.metrics = newMetrics` write would skip the bump and
    /// strand the renderer on stale cell sizes. Audit UR-7 (2026-04-29).
    public private(set) var metrics: CellMetrics
    /// Bumped on every mutation of `self.metrics`. Folded into both
    /// `FrameKey` and `CacheKey` so the frame-skip and per-row caches
    /// invalidate automatically when metrics change. With `metrics`
    /// now `public private(set)` (Audit UR-7) external direct writes
    /// are impossible — the only writer is `reconfigure(metrics:scale:)`,
    /// which bumps this counter in lockstep, so the invariant
    /// "FrameKey contains everything that affects pixels" is enforced
    /// by construction. Mirrors the `atlas.generation` pattern already
    /// in `CacheKey` (which solves the same post-flush-stale-UV problem
    /// for the atlas). Audit M-20 (2026-04-29).
    public private(set) var metricsGeneration: UInt64 = 0

    /// Triple-buffered instance-data ring. Each `render(in:)` call writes to
    /// the buffer at `frameIndex` and advances the index; the command buffer
    /// holds a reference to that specific buffer until the GPU is done
    /// reading. Without triple-buffering, `.storageModeShared` lets the CPU
    /// start writing the next frame while the GPU is still sampling the
    /// previous one — a data race that shows up as flicker/tearing under
    /// fast typing on loaded systems. Three buffers + a 3-slot semaphore
    /// match Apple's canonical "MTKView drawable pool" sizing.
    ///
    /// Each buffer grows independently — capacity is tracked per-slot so
    /// a ring reallocation only rebuilds the slot that overflowed, not
    /// all three.
    private var instanceBuffers: [MTLBuffer]
    private var instanceCapacities: [Int]
    /// Hard cap on `instanceCapacities[slot]`. The grow path doubles the
    /// current capacity each time it overflows; bounded today only by
    /// "GPU OOM intervenes first" (Audit L-21). Defense-in-depth: cap
    /// the doubling so an Int multiply can't overflow in pathological
    /// futures. 4 million CellInstances at ~80 bytes/instance ≈ 320 MB
    /// per slot — orders of magnitude above any realistic terminal
    /// grid (BBCore caps at MAX_DIM=4096 per side; even a degenerate
    /// 4096x4096 grid is only 16M cells split across rows that don't
    /// all paint). Sized to fit GPU memory comfortably while leaving
    /// the trap for `* 2` overflow well out of reach.
    private static let instanceCapacityHardCap = 4 * 1024 * 1024
    private var frameIndex: Int = 0
    /// The slot the current `render(in:)` call has locked. Set after
    /// `inflightSemaphore.wait()`, read by `buildInstances` and the encoder,
    /// cleared on completion. Not thread-safe on its own — `render(in:)`
    /// always runs on the main thread.
    private var currentSlot: Int = 0
    /// Three tokens match three buffers. Every `render(in:)` waits on one
    /// before touching its slot; the command buffer's completion handler
    /// signals. The GPU can run up to three frames ahead of the CPU;
    /// beyond that, the CPU blocks, which is the correct backpressure
    /// shape for a latency-sensitive text renderer.
    private let inflightSemaphore = DispatchSemaphore(value: 3)

    private var cursorColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
    /// Accent colour applied by the fragment shader whenever a cell's
    /// `linkHover` attribute bit is set. Defaults to an sRGB approximation
    /// of macOS's `controlAccentColor` so the underline looks right even
    /// without a theme-provided override.
    private var accentColor: SIMD4<Float> = SIMD4<Float>(0.0, 0.48, 1.0, 1.0)
    /// OSC 8 link id currently under the pointer. Cells with matching
    /// `link_id` receive the accent underline via the `linkHover`
    /// attribute bit. Zero means "no hovered link" — the renderer skips
    /// the underline branch entirely.
    private var hoveredLinkID: UInt16 = 0
    /// Optional "⌘-held, regex URL under pointer" range. Carries a buffer
    /// line (not screen row — survives scrolling) and an inclusive column
    /// range. The renderer applies the same `linkHover` accent underline
    /// to matching cells. `cmdHoverStartCol < 0` is the sentinel for "no
    /// range" and disables the branch entirely.
    private var cmdHoverBufferLine: Int32 = 0
    private var cmdHoverStartCol: Int32 = -1
    private var cmdHoverEndCol: Int32 = -1
    /// When a cell's resolved bg equals this value, we treat it as "default
    /// background" and skip drawing a bg quad. That lets the transparent
    /// clearColor show through — the window-level transparency effect.
    /// `0xFFFFFFFF` acts as a sentinel meaning "no theme bg configured yet".
    private var defaultBgRgb: UInt32 = 0xFFFFFFFF
    /// Overall opacity applied to non-default cell backgrounds. 1.0 keeps
    /// them solid; lower values let the framebuffer (clearColor) peek
    /// through — used when the user wants even vim status lines to be
    /// translucent (keepBgOpaque == false in iTerm2 terms).
    private var backgroundOpacity: Float = 1.0
    private var keepBgOpaque: Bool = true

    /// Vertical offset (in points) added to every cell and cursor. Used by
    /// TerminalView to keep text out of the titlebar region when the window
    /// uses `.fullSizeContentView` so the Metal clearColor can tint under the
    /// titlebar. TerminalView passes `safeAreaInsets.top` here on each layout.
    private var topInsetPoints: Float = 0.0

    public func setTopInsetPoints(_ points: Float) { topInsetPoints = points }

    /// Whether the cursor should blink when the window is focused. When on,
    /// the cursor renders for the first half of each ~1.06 s cycle and is
    /// skipped for the second half. The cycle resets every time the cursor
    /// moves (typing, arrow keys, output scrolling the prompt) so a moving
    /// cursor is always visible — just like xterm/iTerm/Terminal.app.
    private var cursorBlinkEnabled: Bool = false
    private var blinkPhaseStart: CFTimeInterval = 0
    private var lastCursorRow: Int32 = -1
    private var lastCursorCol: Int32 = -1

    /// Identity of every input that affects pixels on screen, packed for
    /// Equatable comparison. When `render()` is called with a key equal to
    /// the one rendered last frame, the GPU already holds the correct
    /// pixels: we skip buildInstances, encoding, and present entirely.
    /// CAMetalLayer's compositor retains the previously presented drawable
    /// so the screen stays correct.
    ///
    /// Typed storage (struct, not a hash) because hashing would either:
    ///   - be too loose (collisions silently miss redraws), or
    ///   - pay the Hashable overhead every frame anyway.
    /// Equatable on 13 fields comes out to a handful of CPU instructions;
    /// the branch predictor handles the common "identical" case fast.
    private struct FrameKey: Equatable {
        /// Monotonic sequence id from BBSnapshot (0 when snapshot is nil).
        /// Intentionally NOT the handle pointer: the allocator can reuse an
        /// address after a snapshot is released, which would make two
        /// distinct snapshots look identical to pointer-equality and cause
        /// a popup-close or cursor-move repaint to be silently dropped.
        /// The sequence counter is assigned once at BBSnapshot init and
        /// never repeats within a process lifetime.
        let snapshotSeq: UInt64
        let hoveredLinkID: UInt16
        /// Flattened selection identity. 0 mode tag means "no selection"; 1-4
        /// are the four Selection.Mode variants. Separate fields for
        /// anchor/cursor line/col avoid the bit-packing collision risk of
        /// squeezing four values into a single UInt64 with overlapping bit
        /// ranges (two different selections could coincide on the packed
        /// result, which would silently drop a selection-change repaint).
        let selMode: UInt8
        let selALine: Int32
        let selBLine: Int32
        let selACol: Int32
        let selBCol: Int32
        let focused: Bool
        let cursorRow: Int32
        let cursorCol: Int32
        let cursorShape: UInt8
        let cursorVisible: Bool
        /// Widened from UInt16 to UInt32: default scrollback is 100 000 lines
        /// and the Rust core caps at 200 000, both well past UInt16.max
        /// (65 535). A truncating narrowing here would silently wrap once
        /// the user scrolled past row 65 535, leaving the frame-skip path
        /// unable to distinguish two visually-different scroll positions
        /// and dragging hover/selection/cursor uniforms out of alignment.
        let displayOffset: UInt32
        let topInsetPoints: Float
        let defaultBgRgb: UInt32
        let backgroundOpacity: Float
        let keepBgOpaque: Bool
        let accentColor: SIMD4<Float>     // Equatable; avoids collision risk
        let cursorColor: SIMD4<Float>
        let blinkSkip: Bool
        /// ⌘-held regex URL range under pointer. Bundled into FrameKey so
        /// the frame-skip optimisation correctly repaints when the
        /// highlighted run changes without a new snapshot arriving.
        let cmdHoverBufferLine: Int32
        let cmdHoverStartCol: Int32
        let cmdHoverEndCol: Int32
        /// `MetalRenderer.metricsGeneration` snapshot. Folded in so a
        /// metrics mutation (font-size change, future external setter)
        /// invalidates the frame-skip cache automatically — without
        /// this, the invariant relied on every mutator remembering to
        /// null `lastFrameKey` by hand. Mirrors `CacheKey.atlasGeneration`.
        /// Audit M-20.
        let metricsGeneration: UInt64
    }
    private var lastFrameKey: FrameKey?
    /// Observable frame-skip signal. `true` when the most recent
    /// `render(in:snapshot:focused:selection:)` call short-circuited on
    /// `frameKey == lastFrameKey` (or otherwise returned without
    /// presenting a drawable); `false` on any path that actually touched
    /// the encode pipeline through `commit()`. Promoted from a DEBUG-only
    /// test seam to public-readable in all builds because TerminalView
    /// needs it to gate `LatencyProbe.shared.markPresented()` — calling
    /// `markPresented()` after a skipped render records phantom zero-
    /// latency samples, dragging p50/p99 metrics artificially low.
    /// Not thread-safe; readers must observe it from the same queue as
    /// the `render` call (today: main).
    public private(set) var didFrameSkipLastRender: Bool = false

    /// Strict subset of FrameKey fields that decide whether a prior frame's
    /// per-row cache is still visually correct: everything in FrameKey
    /// EXCEPT `snapshotSeq`, `cursorRow`, and `cursorCol`. Snapshot
    /// sequence changing is the normal "new content" path; cursor movement
    /// is covered by alacritty's damage tracking (it damages both the old
    /// and new cursor cells). A mismatch on any other field invalidates
    /// the whole cache and forces a full rebuild — selection sweeps,
    /// theme hot-swaps, display-offset changes, etc.
    private struct CacheKey: Equatable {
        let cols: Int
        let rows: Int
        let hoveredLinkID: UInt16
        let selMode: UInt8
        let selALine: Int32
        let selBLine: Int32
        let selACol: Int32
        let selBCol: Int32
        let focused: Bool
        /// Effective cursor shape: user override if set, else the snapshot's
        /// DECSCUSR shape. `setCursorShapeOverride` also invalidates
        /// `lastCacheKey` directly, so pinning a shape that happens to equal
        /// the current snapshot shape still repaints exactly once.
        let cursorShape: UInt8
        let cursorVisible: Bool
        /// Same UInt16 → UInt32 widening as `FrameKey.displayOffset`. See
        /// the rationale on that field; a stale per-row cache from a
        /// truncated scroll position would let scrollback rows render
        /// against the wrong selection / hover state.
        let displayOffset: UInt32
        let topInsetPoints: Float
        let defaultBgRgb: UInt32
        let backgroundOpacity: Float
        let keepBgOpaque: Bool
        let accentColor: SIMD4<Float>
        let cursorColor: SIMD4<Float>
        let blinkSkip: Bool
        /// ⌘-held regex URL range (same fields as FrameKey). A change to
        /// the range alone — no new snapshot — must invalidate the
        /// per-row cache since linkHover flags on those cells flip.
        let cmdHoverBufferLine: Int32
        let cmdHoverStartCol: Int32
        let cmdHoverEndCol: Int32
        /// `GlyphAtlas.generation` at the time this row cache was
        /// built. The atlas saturation flush rewrites slot 0..N with
        /// fresh glyphs, but our cached `CellInstance`s carry baked-in
        /// UV coords pointing at those slots. A stale row would
        /// silently sample the post-flush occupant of its cells'
        /// slots — visible-but-undamaged rows render the wrong
        /// glyphs until the row is independently damaged. Including
        /// generation in the key forces a full rebuild on every
        /// flush. Audit H3.
        let atlasGeneration: UInt64
        /// `MetalRenderer.metricsGeneration` at the time this row cache
        /// was built. Cached `CellInstance`s carry baked-in pixel
        /// positions computed against the metrics that were live when
        /// the row was built; a metrics change (font size flip)
        /// invalidates those positions. Including generation here
        /// forces a full rebuild whenever metrics rotate, even on a
        /// path that didn't go through `reconfigure`. Audit M-20.
        let metricsGeneration: UInt64
    }
    private var lastCacheKey: CacheKey?

    /// Sequence id of the snapshot that drove the most-recent `render(in:)`
    /// call. Used to detect coalesced intermediate snapshots: if a render
    /// receives a snapshot whose `sequenceID` jumped by more than 1, the
    /// main-queue coalescer in `TerminalSession.publishPendingSnapshot`
    /// dropped one or more intermediate snapshots on the floor, along
    /// with their damage sets. Alacritty's damage tracking reset on each
    /// `bb_term_take_snapshot`, so the latest snapshot's `damagedRows`
    /// only covers the delta since the *most recent* take — rows that
    /// changed in the skipped snapshots but not in the latest one would
    /// stay at their stale cached content on a partial rebuild.
    /// Full screen programs (cmatrix, vim, nvim alt-screen) expose this
    /// as tearing streams because they write hundreds of cells per
    /// mainloop tick while the main queue is still running the last
    /// render. Detecting the gap and forcing a full rebuild trades a
    /// tiny bit of CPU work for visual correctness under redraw load.
    private var lastRenderedSnapshotSeq: UInt64 = 0

    /// Per-row instance cache. Index i holds the CellInstances emitted by
    /// buildRowInstances for visible row i under the current CacheKey.
    /// Reused across frames when CacheKey is stable; only damaged rows
    /// (from `BBSnapshot.damagedRows`) are rebuilt. Flattened into the
    /// GPU instance buffer each frame — a ~1 MB memcpy that costs far
    /// less than iterating 16 000 cells.
    private var rowInstanceCache: [[CellInstance]] = []

    /// Kill switch for the dirty-rows fast path. Set `BB_NO_DIRTY_ROWS=1`
    /// and restart to force a full rebuild every frame — useful when
    /// debugging a "some rows look stale" artifact to confirm whether
    /// the cache is responsible. Evaluated once per renderer.
    private let dirtyRowsDisabled: Bool = {
        guard let cstr = getenv("BB_NO_DIRTY_ROWS") else { return false }
        let raw = String(cString: cstr)
        return !raw.isEmpty && raw != "0"
    }()

    /// Runtime escape hatch. Set the env var `BB_NO_FRAME_SKIP=1` and
    /// restart to disable the skip path entirely — every draw(in:) call
    /// runs the full encode + present. Useful when a user reports a
    /// redraw artifact ("looks weird after closing popup X") and we
    /// want to A/B test whether frame-skip is responsible. Evaluated
    /// once per renderer via `getenv` — changes require an app restart.
    private let frameSkipDisabled: Bool = {
        guard let cstr = getenv("BB_NO_FRAME_SKIP") else { return false }
        let raw = String(cString: cstr)
        return !raw.isEmpty && raw != "0"
    }()

    public func setCursorBlinkEnabled(_ enabled: Bool) {
        if enabled != cursorBlinkEnabled {
            cursorBlinkEnabled = enabled
            blinkPhaseStart = CACurrentMediaTime()
            // Reset the blink phase → visible cursor on the next frame
            // regardless of where in the cycle we were. Clearing the skip
            // cache forces that next frame to actually encode.
            lastFrameKey = nil
        }
    }

    /// User-pinned cursor shape. `nil` → follow the snapshot's DECSCUSR
    /// value (default behaviour). A non-nil value overrides the shape the
    /// shell most recently set, so users who want a bar cursor regardless
    /// of `\e[2 q'` / `\e[0 q'` get it.
    ///
    /// Cache invalidation runs through the frame-key / cache-key
    /// substitution in `draw(in:)`: changing the override mutates
    /// `effectiveShape`, which flows into both keys and forces a rebuild.
    /// We also null the last-keys here so the override lands on the very
    /// next frame even if the snapshot is otherwise identical.
    private var cursorShapeOverride: UInt8? = nil

    public func setCursorShapeOverride(_ shape: UInt8?) {
        if shape != cursorShapeOverride {
            cursorShapeOverride = shape
            lastFrameKey = nil
            lastCacheKey = nil
        }
    }

    public func setDefaultBgRgb(_ rgb: UInt32) { defaultBgRgb = rgb }

    public func setBackgroundOpacity(_ opacity: Float, keepBgOpaque: Bool) {
        self.backgroundOpacity = opacity
        self.keepBgOpaque = keepBgOpaque
    }

    public func setCursorColor(rgb: UInt32) {
        // L-2 / RW-02: use the precomputed `inv255` constant the
        // F6 optimization introduced for `rgbToSIMD`. Three runtime
        // divisions become three multiplies; consistency with the
        // rest of the renderer.
        let r = Float((rgb >> 16) & 0xFF) * Self.inv255
        let g = Float((rgb >> 8)  & 0xFF) * Self.inv255
        let b = Float(rgb & 0xFF) * Self.inv255
        cursorColor = SIMD4<Float>(r, g, b, 1.0)
    }

    /// Replace the accent colour used for link-hover underlines. Themes
    /// that ship an accent override can plumb it through here; otherwise
    /// the default (controlAccentColor-equivalent sRGB blue) applies.
    public func setAccentColor(rgba: SIMD4<Float>) {
        accentColor = rgba
    }

    /// Set the OSC 8 link id currently under the pointer. The next frame
    /// highlights every cell whose `link_id` matches. Passing 0 clears the
    /// highlight.
    public func setHoveredLinkID(_ id: UInt16) {
        hoveredLinkID = id
    }

    /// Set the cell range for a ⌘-held regex URL under the pointer. The
    /// next frame applies the accent underline to every cell in
    /// `bufferLine` between `startCol` and `endCol` inclusive. Pass
    /// `startCol < 0` to clear.
    ///
    /// Buffer-line (not screen-row) keying means the highlight survives
    /// scrollback motion without the caller having to re-resolve the
    /// pointer cell on every snapshot. `lastCacheKey` is invalidated on
    /// any change so the per-row cache doesn't stick.
    ///
    /// IMPORTANT: callers must force a redraw on their own (`needsDisplay
    /// = true` on the MTKView) after calls that change the range. The
    /// renderer invalidates its per-frame cache but does not schedule a
    /// repaint on its own. Pattern mirrors `setHoveredLinkID`. Skipping
    /// the redraw leaves the cache invalidated but unpainted — the next
    /// unrelated frame will look correct, but interim frames show stale
    /// pixels.
    public func setCmdHoverRange(bufferLine: Int32, startCol: Int32, endCol: Int32) {
        if cmdHoverBufferLine == bufferLine
            && cmdHoverStartCol == startCol
            && cmdHoverEndCol == endCol {
            return
        }
        cmdHoverBufferLine = bufferLine
        cmdHoverStartCol = startCol
        cmdHoverEndCol = endCol
        lastCacheKey = nil
    }

    public init?(device: MTLDevice, metrics: CellMetrics, scale: CGFloat = 2.0) {
        // Pin CellInstance's stride / alignment contract with the shader
        // BEFORE we touch any GPU state. `precondition` so Release builds
        // crash here on layout drift rather than rendering scrambled UVs.
        // F-S4-001 — the test-target call site never ran in production.
        _pinCellInstanceLayout()
        guard let queue = device.makeCommandQueue() else { return nil }
        guard let library = device.makeDefaultLibrary() else { return nil }
        guard let vertexFn = library.makeFunction(name: "vertex_cell"),
              let fragmentFn = library.makeFunction(name: "fragment_cell") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        // `.bgra8Unorm` (NOT `_srgb`) is a deliberate choice: every color
        // flowing through the shader — theme fg/bg, accent, selection
        // tint, cursor — is uploaded as sRGB-encoded u8→f32 (see
        // `rgbToSIMD`) and blended numerically in that space. The
        // CAMetalLayer colorspace is pinned to sRGB on the window side
        // (TerminalView:348-359), which tells macOS's compositor to
        // interpret the written bytes as sRGB-encoded without an extra
        // decode pass. Net result matches Terminal.app / Alacritty /
        // iTerm2 (pre-rework) — a mathematically-approximate blend that
        // is mildly gamma-incorrect at anti-aliased glyph edges but
        // perceptually consistent across themes and displays.
        //
        // Switching to `.bgra8Unorm_srgb` with linear shader math would
        // produce correct-by-physics blending (heavier-looking glyph
        // edges on light-on-dark text) but would require updating every
        // upload path to write linear floats; deferred as a future
        // toggle. Audit metal-renderer F9 / shaders F1 / glyph-atlas F10.
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // Surface the underlying NSError from `makeRenderPipelineState` —
        // a `try?` collapse here used to look like "renderer init returned
        // nil for an unknowable reason" downstream, and the upstream
        // fatalError ("Metal device could not produce a command queue")
        // misled triage. The PSO can fail for shader-compile errors,
        // descriptor mismatches, vertex-attribute layout drift, etc. —
        // all of which the NSError describes far better than a nil bubble
        // up. Audit L-6 (2026-04-29).
        let pso: MTLRenderPipelineState
        do {
            pso = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            Self.logger.error("cell render pipeline state creation failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        guard let cursorVertex = library.makeFunction(name: "vertex_cursor"),
              let cursorFragment = library.makeFunction(name: "fragment_cursor") else { return nil }
        let cursorDesc = MTLRenderPipelineDescriptor()
        cursorDesc.vertexFunction = cursorVertex
        cursorDesc.fragmentFunction = cursorFragment
        cursorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Cursor is opaque white — no blending.
        // Same do/catch shape as the cell PSO above. Audit L-6.
        let cursorPSO: MTLRenderPipelineState
        do {
            cursorPSO = try device.makeRenderPipelineState(descriptor: cursorDesc)
        } catch {
            Self.logger.error("cursor render pipeline state creation failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        guard let atlas = GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            return nil
        }

        // Start with space for a full 200x80 grid; grow as needed.
        let startCap = 200 * 80
        let bytes = startCap * MemoryLayout<CellInstance>.stride
        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(3)
        for _ in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: [.storageModeShared]) else {
                return nil
            }
            buffers.append(b)
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pso
        self.cursorPipelineState = cursorPSO
        self.atlas = atlas
        self.metrics = metrics
        // Initial generation. Subsequent metrics mutations bump this
        // counter so FrameKey/CacheKey equality forces a rebuild even
        // if every other key field is identical. Audit M-20.
        self.metricsGeneration = 1
        self.instanceBuffers = buffers
        self.instanceCapacities = [startCap, startCap, startCap]
        // Warm ASCII + box-drawing into the atlas before the first draw so
        // no user keystroke pays for the CTLineCreate path on the hot
        // first-paint. Safe: this is a plain call into `lookupOrInsert`,
        // which is idempotent.
        //
        // Logged under the shared startup telemetry gate so users can
        // see it alongside shell-spawn / first-byte timings via
        //   log stream --predicate 'category == "startup"'
        // Release builds stay silent unless BLACKBIRD_STARTUP_LOG=1.
        let t0 = CACurrentMediaTime()
        atlas.prewarmCommonGlyphs()
        if StartupTelemetry.isEnabled {
            let dt = (CACurrentMediaTime() - t0) * 1000
            StartupTelemetry.logger.log(
                "atlas prewarm \(dt, format: .fixed(precision: 1), privacy: .public)ms"
            )
        }
    }

    /// Rebuild metrics + atlas for a new font size. Safe to call from the
    /// main thread — allocations happen synchronously, but the next draw
    /// picks up the new atlas immediately.
    ///
    /// Atomic: metrics only change if the new atlas built successfully.
    /// Returns `true` on success, `false` when the atlas couldn't be
    /// allocated (e.g., GPU memory pressure) so callers can keep their
    /// own mirror of metrics in sync.
    @discardableResult
    public func reconfigure(metrics newMetrics: CellMetrics, scale: CGFloat) -> Bool {
        // The skip-cache + per-row cache are read/written from `render(in:)`
        // on the main thread; any mutation here must match that contract or
        // a concurrent render would see half-updated state. Enforce it —
        // comments elsewhere in the file claim main-thread but nothing was
        // asserting it.
        dispatchPrecondition(condition: .onQueue(.main))
        guard let a = GlyphAtlas(device: device, metrics: newMetrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            return false
        }
        self.metrics = newMetrics
        // Bump alongside the metrics mutation so the FrameKey /
        // CacheKey short-circuits invalidate on the next frame. With
        // `metrics` `public private(set)` (UR-7) this method is the
        // only writer, so the bump-on-every-mutation invariant holds
        // by construction. Audit M-20.
        self.metricsGeneration &+= 1
        self.atlas = a
        // Re-warm the new atlas so the post-resize first repaint doesn't
        // pay for CoreText rasterisation of every visible character.
        a.prewarmCommonGlyphs()
        // A new atlas points to different texture contents; the skip
        // cache is now stale. Force the next render to encode and present
        // even if every FrameKey field matches the previous frame.
        self.lastFrameKey = nil
        self.lastCacheKey = nil
        self.rowInstanceCache = []
        // Treat the atlas reconfigure as a fresh renderer: a seq the
        // caller used before the atlas swap is no longer meaningful,
        // and keeping the old value here would let a pre-reconfigure
        // seq trip the `snap.sequenceID > lastRenderedSnapshotSeq + 1`
        // coalesced-snapshot guard on what is really a clean start.
        self.lastRenderedSnapshotSeq = 0
        return true
    }

    /// Clear the frame-skip cache. Call after any mutation that changes
    /// what pixels the GPU would produce given the same FrameKey —
    /// currently only the atlas reconfigure and blink-phase reset hit this.
    /// Left `public` so callers outside the renderer (e.g. a future theme
    /// hot-swap that only mutates the palette) can force a repaint.
    public func invalidate() {
        // Same main-thread contract as `reconfigure` — see note there.
        dispatchPrecondition(condition: .onQueue(.main))
        self.lastFrameKey = nil
        self.lastCacheKey = nil
        self.rowInstanceCache = []
        self.lastRenderedSnapshotSeq = 0
    }

    /// Rebuild instances for a single visible row into `out`, consulting
    /// snapshot cells, selection, hover, and cursor-inversion state. Pure
    /// apart from the output parameter — does not touch GPU buffers or
    /// cache state. Called by `buildInstances` for every row on a full
    /// rebuild, or only for the damaged rows on a partial rebuild.
    ///
    /// Appends to `out` in place (pre-cleared by the caller with
    /// `removeAll(keepingCapacity: true)`) instead of returning a fresh
    /// `[CellInstance]`: rows emit a variable count of instances (blank
    /// cells contribute nothing; wide-glyph rows emit fewer than cols;
    /// selection/link-hover may push to 1-per-cell), and on a partial
    /// rebuild the caller would otherwise free the prior array's storage
    /// and allocate a new one each frame. Keeping the backing buffer
    /// eliminates up to 80 heap alloc/free pairs per full rebuild, which
    /// at 120 Hz is ~9 600 heap operations/sec off the CPU. Audit
    /// metal-renderer F5.
    private func buildRowInstances(
        snapshot: BBSnapshot,
        row: Int,
        isSelected: (Int32, Int) -> Bool,
        blockCursorCell: (row: Int, col: Int)?,
        into out: inout [CellInstance]
    ) {
        let selectionTint = SIMD4<Float>(0.25, 0.45, 0.90, 1.0)
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)
        let cellsPtr = snapshot.cellsPointer
        let cols = snapshot.cols
        let hoveredID = hoveredLinkID
        // Row in *buffer* space (scrollback-adjusted) — the ⌘-hover range
        // is keyed on buffer line so the underline survives scrolling
        // without the caller re-resolving the pointer on every snapshot.
        // `Int32(clamping:)` for parity with the M-16 sites: the
        // subtraction operates on `Int`s sourced from BBCore, and a
        // future regression that lets either operand exceed Int32's
        // range (or pushes the difference negative-overflow) would
        // trap the renderer mid-frame. Clamping keeps the contract
        // pinned at the cast site. Audit UR-2 (2026-04-29).
        let rowBufferLine = Int32(clamping: row - snapshot.displayOffset)
        let cmdHoverActiveOnThisRow =
            cmdHoverStartCol >= 0
            && cmdHoverBufferLine == rowBufferLine
        // Upper bound: every cell emits at most one instance. Reserve so
        // the common case avoids growing the array — a no-op when `out`
        // already has >= cols capacity from the prior frame.
        out.reserveCapacity(cols)

        for col in 0..<cols {
            let idx = row * cols + col
            // `cellsPtr` is a raw pointer; reading past `cellCount` would
            // be UB, not a trap. Same invariant alacritty guarantees but
            // re-checked here so a buggy snapshot can't cascade.
            if idx >= snapshot.cellCount { break }
            let cell = cellsPtr[idx]
            let scalar = cell.ch
            var fg = Self.rgbToSIMD(cell.fg)
            var bg = Self.rgbToSIMD(cell.bg)
            let attrs: SIMD4<UInt32> = {
                var flags: UInt32 = 0
                if hoveredID != 0 && cell.link_id == hoveredID {
                    flags |= CellAttributeMask.linkHover.rawValue
                }
                // ⌘-held regex URL highlight: the same accent underline
                // the OSC 8 hover uses, but gated on a buffer-line range
                // instead of a link id. Applies only when the cell falls
                // inside the active range on the active buffer line.
                if cmdHoverActiveOnThisRow {
                    let c = Int32(col)
                    if c >= cmdHoverStartCol && c <= cmdHoverEndCol {
                        flags |= CellAttributeMask.linkHover.rawValue
                    }
                }
                // Translate cell_flags bits that the shader needs to
                // render into our flat renderer-side bitset. Cell flags
                // live in Rust-stable constants (BBCore bridging header);
                // mapping here keeps the shader ignorant of the Rust
                // layout so a future cell_flags reshuffle stays local.
                let cf = cell.flags
                if (cf & UInt16(STRIKE)) != 0 {
                    flags |= CellAttributeMask.strike.rawValue
                }
                if (cf & UInt16(UNDERLINE)) != 0 {
                    flags |= CellAttributeMask.underline.rawValue
                }
                if (cf & UInt16(UNDERLINE_DOUBLE)) != 0 {
                    flags |= CellAttributeMask.underlineDouble.rawValue
                }
                if (cf & UInt16(UNDERCURL)) != 0 {
                    flags |= CellAttributeMask.undercurl.rawValue
                }
                if (cf & UInt16(UNDERLINE_DOTTED)) != 0 {
                    flags |= CellAttributeMask.underlineDotted.rawValue
                }
                if (cf & UInt16(UNDERLINE_DASHED)) != 0 {
                    flags |= CellAttributeMask.underlineDashed.rawValue
                }
                // Pack CSI 58 underline colour into attrs.z. The shader
                // treats UNDERLINE_COLOR_UNSET as "fall back to fg",
                // so the cheapest path is to forward the u32 as-is.
                return SIMD4<UInt32>(flags, 0, cell.underline_color, 0)
            }()
            // Reverse video (SGR 7): swap the cell's fg and bg so the
            // glyph reads against the inverted highlight. Forces a bg
            // quad (we can't skip drawing into the clearColor because
            // the "new bg" is the original fg, which is a real colour).
            let reverse = (cell.flags & UInt16(REVERSE)) != 0
            if reverse {
                let orig = fg
                fg = bg
                bg = orig
            }
            // DIM (SGR 2): halve the fg brightness so dimmed text reads
            // softer without affecting bg. Applied after REVERSE so the
            // resulting glyph colour is what's visibly dimmed.
            if (cell.flags & UInt16(DIM)) != 0 {
                fg.x *= 0.5
                fg.y *= 0.5
                fg.z *= 0.5
            }
            // Treat the theme's default bg as "no bg" so the transparent
            // clearColor can show through. Cells with explicit colors
            // (vim highlights, status lines, syntax bg) still draw their
            // bg quad; whether they stay solid or become translucent is
            // a user choice (keepBgOpaque).
            //
            // The "no bg quad" decision compares against the active
            // theme's `defaultBgRgb`, NOT a literal 0x000000. On themes
            // whose default bg isn't black (Atom dark = 0x282C34,
            // Catppuccin Mocha = 0x1E1E2E, Solarized = 0x002B36 …) an
            // explicit `\x1b[40m` (palette black) IS a real background
            // the user wants painted. Pre-fix the literal-zero check
            // collapsed `cell.bg == 0x000000` to "no bg" and a vim
            // status line / htop column that uses ANSI black silently
            // showed the theme's default bg through. Audit H2.
            let isDefaultBg = !reverse && cell.bg == defaultBgRgb
            let hasBg = Self.shouldPaintBgQuad(
                cellBg: cell.bg, defaultBg: defaultBgRgb, reverse: reverse
            )

            // Determine the bg alpha for what we'll write into
            // CellInstance:
            //   - Default bg → alpha 0 so the shader's mix() produces a
            //     transparent result where the glyph doesn't cover —
            //     clearColor (already transparent) shows through.
            //   - Explicit bg, keepBgOpaque on → alpha 1 (unchanged).
            //   - Explicit bg, keepBgOpaque off → alpha = opacity.
            let bgAlpha: Float
            if isDefaultBg {
                bgAlpha = 0.0
            } else if keepBgOpaque {
                bgAlpha = 1.0
            } else {
                bgAlpha = backgroundOpacity
            }
            bg.w = bgAlpha

            // `Int32(clamping:)` per UR-2 — same defense-in-depth
            // rationale as the `rowBufferLine` site above.
            let bufferLine = Int32(clamping: row) - Int32(clamping: snapshot.displayOffset)
            let selected = isSelected(bufferLine, col)
            var effectiveBg = selected ? selectionTint : bg
            var effectiveHasBg = selected ? true : hasBg

            // Invert at the cursor cell so the block cursor shows the
            // underlying glyph in reverse-video. Selection wins over
            // the cursor (matches iTerm2: selection highlight spans a
            // cell even if the cursor is on it).
            if !selected,
               let bc = blockCursorCell,
               bc.row == row,
               bc.col == col {
                // Use whatever the cell's bg *would* have been (explicit
                // or theme-default) as the glyph colour, so the
                // character reads against the cursor's body.
                let resolvedBg: UInt32 = hasBg ? cell.bg : defaultBgRgb
                fg = Self.rgbToSIMD(resolvedBg)
                effectiveBg = cursorColor
                effectiveBg.w = 1.0
                effectiveHasBg = true
            }

            let xPx = Float(col) * cellW
            let yPx = Float(row) * cellH + topInsetPoints

            // WIDE_CHAR_SPACER / LEADING_WIDE_CHAR_SPACER sit to the right
            // of (or on the wrapped-leading col before) a wide glyph. The
            // wide glyph's 2x quad already covers this column, so any
            // draw here would overpaint its right half. Skip unless the
            // selection highlight needs a bg quad — in that case the
            // highlight must span both halves of the wide cell.
            let isSpacer = (cell.flags &
                (UInt16(WIDE_CHAR_SPACER) | UInt16(LEADING_WIDE_CHAR_SPACER))) != 0
            if isSpacer {
                if selected || effectiveHasBg || attrs.x != 0 {
                    out.append(CellInstance(
                        cellPosPx: SIMD2<Float>(xPx, yPx),
                        quadSizePx: SIMD2<Float>(cellW, cellH),
                        uvOrigin: .zero,
                        uvSize: .zero,
                        fgColor: fg,
                        bgColor: effectiveBg,
                        attrs: attrs
                    ))
                }
                continue
            }

            // WIDE_CHAR cells carry a CJK / wide-emoji glyph that logically
            // spans two cells. The atlas rasterises them into a 2x-wide
            // slot and reports a doubled uvSize.x; we draw a 2x-wide quad
            // so the full glyph lands on screen.
            let isWide = (cell.flags & UInt16(WIDE_CHAR)) != 0
            let quadW = isWide ? cellW * 2.0 : cellW
            let quadSize = SIMD2<Float>(quadW, cellH)

            // Render cell if it has a glyph OR a non-default background.
            if scalar != 0 && scalar != 0x20 /* space */ {
                let glyphStyle = GlyphAtlas.Style(
                    bold: (cell.flags & UInt16(BOLD)) != 0,
                    italic: (cell.flags & UInt16(ITALIC)) != 0
                )
                if let us = Unicode.Scalar(scalar),
                   let entry = atlas.lookupOrInsert(
                       scalar: us, wide: isWide, style: glyphStyle) {
                    // Tell the fragment shader to sample the color
                    // atlas (texture 1) instead of the mono coverage
                    // atlas (texture 0) for this cell. Emoji + other
                    // CTFont `colorGlyphs`-reporting families land
                    // here. Atlas `Entry.isColor` is the single source
                    // of truth; the shader branches on this bit.
                    var colorAttrs = attrs
                    if entry.isColor {
                        colorAttrs.x |= CellAttributeMask.isColorGlyph.rawValue
                    }
                    out.append(CellInstance(
                        cellPosPx: SIMD2<Float>(xPx, yPx),
                        quadSizePx: quadSize,
                        uvOrigin: entry.uvOrigin,
                        uvSize: entry.uvSize,
                        fgColor: fg,
                        bgColor: effectiveBg,
                        attrs: colorAttrs
                    ))
                }
            } else if effectiveHasBg || attrs.x != 0 {
                // Space with colored background (status lines, vim highlights),
                // inside an active selection, or carrying an accent
                // attribute (link hover). Draw a full-cell quad with
                // zero coverage so the shader's bg/accent paths still fire.
                out.append(CellInstance(
                    cellPosPx: SIMD2<Float>(xPx, yPx),
                    quadSizePx: quadSize,
                    uvOrigin: .zero,
                    uvSize: .zero,
                    fgColor: fg,
                    bgColor: effectiveBg,
                    attrs: attrs
                ))
            }
        }
    }

    /// Pure decision: should `buildInstances` emit a background quad
    /// for this cell?
    ///
    /// `true` when:
    ///   - the cell has REVERSE attribute (the swapped-in fg is a real
    ///     palette colour the user wants painted), OR
    ///   - the cell's `bg` differs from the active theme's
    ///     `defaultBgRgb` (an explicit `\x1b[4Nm` SGR set this cell's
    ///     background to a palette colour, and even palette black on a
    ///     non-black theme is "explicit" — the user wants it painted).
    ///
    /// Pre-fix this compared `cell.bg` to literal `0x000000`, which on
    /// non-black themes (Atom dark, Catppuccin, Solarized …) silently
    /// dropped every `\x1b[40m` quad: vim status lines, htop column
    /// shading, syntax highlights using ANSI black all leaked the
    /// theme bg through. Audit H2.
    ///
    /// Internal so MetalRendererTests can pin the decision table.
    static func shouldPaintBgQuad(
        cellBg: UInt32, defaultBg: UInt32, reverse: Bool
    ) -> Bool {
        if reverse { return true }
        return cellBg != defaultBg
    }

    /// Orchestrates per-row rebuild + GPU buffer flatten using the
    /// `rowInstanceCache`. Either rebuilds every row (full path) or only
    /// the rows alacritty's damage iterator flagged as changed (partial
    /// path). Returns the total instance count the encoder should draw.
    @discardableResult
    private func buildInstances(
        snapshot: BBSnapshot,
        isSelected: (Int32, Int) -> Bool = { _, _ in false },
        blockCursorCell: (row: Int, col: Int)? = nil,
        partialRowsOnly: Set<Int>? = nil
    ) -> Int {
        let rows = snapshot.rows
        let cols = snapshot.cols
        let needed = cols * rows
        // Defensive bound — see original comment on the single-loop
        // version. Same invariant, same bail-out on violation.
        guard snapshot.cellCount >= needed else { return 0 }

        // Re-size the per-row cache when grid dims changed. Shrinking is
        // handled by assignment (old entries over the new row count are
        // dropped). Growing initializes new rows to empty so the partial
        // path — which assumes the cache is indexable for every visible
        // row — stays sound.
        if rowInstanceCache.count != rows {
            rowInstanceCache = Array(repeating: [], count: rows)
        }

        if let damaged = partialRowsOnly {
            // Partial rebuild: only the rows alacritty says changed.
            // Iterate a sorted copy so we never hit the same row twice
            // if a future source deduplicates imperfectly.
            for row in damaged where row >= 0 && row < rows {
                // `removeAll(keepingCapacity: true)` reuses the prior
                // frame's backing buffer — we keep up to `cols` worth of
                // allocated slots, which is exactly the reserve size
                // `buildRowInstances` asks for. No heap traffic in the
                // steady state.
                rowInstanceCache[row].removeAll(keepingCapacity: true)
                buildRowInstances(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell,
                    into: &rowInstanceCache[row]
                )
            }
        } else {
            // Full rebuild — cache key changed, first frame, or damage
            // exceeded the partial threshold.
            for row in 0..<rows {
                rowInstanceCache[row].removeAll(keepingCapacity: true)
                buildRowInstances(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell,
                    into: &rowInstanceCache[row]
                )
            }
        }

        // Flatten into the current-slot GPU buffer. Even the partial path
        // copies every row — the CPU savings come from skipping the
        // per-cell inner work on unchanged rows, not from skipping the
        // memcpy (which is tiny: ~1 MB at 80-byte stride × 16k cells).
        let total = rowInstanceCache.reduce(0) { $0 + $1.count }
        let slot = currentSlot
        if total > instanceCapacities[slot] {
            // Defense-in-depth on `* 2`: an unguarded `Int` multiply
            // would trap on overflow. Bounded today (GPU OOM
            // intervenes first) but the cap pins the contract at the
            // arithmetic site so a future regression that lets total
            // grow unboundedly can't crash the renderer mid-frame.
            // Audit L-21 (2026-04-29).
            let doubled = instanceCapacities[slot]
                .multipliedReportingOverflow(by: 2)
            let proposed: Int
            if doubled.overflow {
                // We've already exceeded UInt63. Saturate to the hard
                // cap; if `total` itself is also above the cap, the
                // makeBuffer call below will fail and we'll skip the
                // frame on the next branch.
                proposed = Self.instanceCapacityHardCap
            } else {
                proposed = min(doubled.partialValue, Self.instanceCapacityHardCap)
            }
            let newCap = max(total, proposed)
            // Surfacing a cap-exceeded workload separately from a GPU
            // OOM: when `total` itself is above the hard cap, the
            // doubling math saturated but the user's grid is genuinely
            // beyond what the renderer was sized for — different bug
            // class than `makeBuffer` returning nil under memory
            // pressure. One-line warning so a release-mode log can
            // tell the two apart. Audit L-21 follow-up (2026-04-29).
            if total > Self.instanceCapacityHardCap {
                Self.logger.error("instance count \(total, privacy: .public) exceeds hard cap \(Self.instanceCapacityHardCap, privacy: .public); attempting allocation anyway (workload outgrew renderer sizing — investigate grid dims / row paint logic)")
            }
            let bufBytes = newCap * MemoryLayout<CellInstance>.stride
            if let newBuf = device.makeBuffer(
                length: bufBytes,
                options: [.storageModeShared]
            ) {
                instanceBuffers[slot] = newBuf
                instanceCapacities[slot] = newCap
            } else {
                // Out-of-GPU-memory while growing — skip frame. Next
                // repaint will retry. Log so a silently-stale frame
                // surfaces in the unified log instead of just looking
                // like the renderer skipped a tick. Audit L-21
                // follow-up (2026-04-29).
                Self.logger.error("instance buffer grow failed: requested \(newCap, privacy: .public) instances (\(bufBytes, privacy: .public) bytes); skipping frame")
                return 0
            }
        }

        let ptr = instanceBuffers[slot].contents().assumingMemoryBound(to: CellInstance.self)
        var count = 0
        for row in 0..<rows {
            let rowInsts = rowInstanceCache[row]
            if rowInsts.isEmpty { continue }
            rowInsts.withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                // memcpy — safe because CellInstance is POD and the GPU
                // buffer is non-overlapping with the Swift Array storage.
                ptr.advanced(by: count).initialize(from: base, count: src.count)
                count += src.count
            }
        }
        return count
    }

    /// Extract selection endpoints into fields that feed `FrameKey`
    /// directly. Previously a `packSelection -> UInt64` helper was used,
    /// but its bit ranges overlapped (`aLine << 32` and `bLine << 16`
    /// shared bits 32-47; `aCol << 8` and `bCol` shared bits 8-15),
    /// which let two different selections produce the same packed token
    /// and get silently coalesced by frame-skip. Use five separate
    /// fields — zero-filled for the "no selection" case — so FrameKey's
    /// synthesised Equatable gives an exact match.
    private static func selectionFields(
        _ sel: Selection?
    ) -> (mode: UInt8, aLine: Int32, bLine: Int32, aCol: Int32, bCol: Int32) {
        guard let s = sel else { return (0, 0, 0, 0, 0) }
        let (a, b) = s.normalized
        let modeTag: UInt8 = {
            switch s.mode {
            case .character:   return 1
            case .word:        return 2
            case .line:        return 3
            case .rectangular: return 4
            }
        }()
        return (
            mode: modeTag,
            aLine: a.line,
            bLine: b.line,
            aCol: Int32(clamping: a.col),
            bCol: Int32(clamping: b.col)
        )
    }

    /// `1.0 / 255.0` precomputed so `rgbToSIMD` can multiply instead of
    /// dividing. Called up to `2 * cols * rows` times per full rebuild
    /// (fg + bg per cell) — at 200x80 that's 32 000 calls/frame. FP-div
    /// is ~15 cycles on modern cores; multiplying by a constant is ~4.
    /// Audit metal-renderer F6.
    private static let inv255: Float = 1.0 / 255.0

    private static func rgbToSIMD(_ rgb: UInt32) -> SIMD4<Float> {
        // Unpack the 24-bit colour into a 4-lane SIMD so the float
        // conversion and scaling are vectorised as a single op. `1.0`
        // in the alpha lane lands in the default fully-opaque result;
        // callers that need a different alpha (e.g. background-opacity
        // plumbing) mutate `.w` after the call.
        let bytes = SIMD4<UInt32>(
            (rgb >> 16) & 0xFF,
            (rgb >> 8) & 0xFF,
            rgb & 0xFF,
            0
        )
        var result = SIMD4<Float>(bytes) * Self.inv255
        result.w = 1.0
        return result
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?, focused: Bool, selection: Selection? = nil) {
        // Compute the current frame's visual-state key BEFORE reaching for
        // currentDrawable. Acquiring a drawable is expensive (blocks on
        // the pool under contention); if nothing changed we shouldn't even
        // touch it. Note: blink state is computed here too because it
        // depends on CACurrentMediaTime.
        let blinkSkipNow: Bool = {
            guard cursorBlinkEnabled, focused, let s = snapshot, s.cursorVisible else {
                return false
            }
            let elapsed = CACurrentMediaTime() - blinkPhaseStart
            let phase = elapsed.truncatingRemainder(dividingBy: 1.06)
            return phase >= 0.53
        }()
        let selFields = Self.selectionFields(selection)
        let frameKey = FrameKey(
            snapshotSeq: snapshot?.sequenceID ?? 0,
            hoveredLinkID: hoveredLinkID,
            selMode: selFields.mode,
            selALine: selFields.aLine,
            selBLine: selFields.bLine,
            selACol: selFields.aCol,
            selBCol: selFields.bCol,
            focused: focused,
            // `Int32(clamping:)` / `UInt8(clamping:)` for parity
            // with the M-16 displayOffset sites: defense-in-depth on
            // Rust-snapshot integers entering the FrameKey hot path.
            // Audit UR-2 (2026-04-29).
            cursorRow: Int32(clamping: snapshot?.cursorRow ?? -1),
            cursorCol: Int32(clamping: snapshot?.cursorCol ?? -1),
            cursorShape: cursorShapeOverride ?? UInt8(clamping: snapshot?.cursorShape ?? 3),
            cursorVisible: snapshot?.cursorVisible ?? false,
            // `clampDisplayOffset` not `UInt32(_:)` — defense-in-depth on
            // the hot per-frame path. Today `BBSnapshot.displayOffset`
            // returns `Int` from a Rust `u32` so it's never negative,
            // but a future regression that lets a negative slip through
            // would trap the renderer mid-frame; clamping pins the
            // contract at the cast site, and the helper one-shots a
            // `.error` log so the violation surfaces without spamming.
            // Audit M-16 / UR follow-up (2026-04-29).
            displayOffset: Self.clampDisplayOffset(snapshot?.displayOffset ?? 0),
            topInsetPoints: topInsetPoints,
            defaultBgRgb: defaultBgRgb,
            backgroundOpacity: backgroundOpacity,
            keepBgOpaque: keepBgOpaque,
            accentColor: accentColor,
            cursorColor: cursorColor,
            blinkSkip: blinkSkipNow,
            cmdHoverBufferLine: cmdHoverBufferLine,
            cmdHoverStartCol: cmdHoverStartCol,
            cmdHoverEndCol: cmdHoverEndCol,
            metricsGeneration: metricsGeneration
        )
        if !frameSkipDisabled, frameKey == lastFrameKey {
            // Nothing that affects pixels has changed since the last
            // presented frame. Skip the whole pipeline — no CPU instance
            // rebuild, no GPU encode, no drawable acquisition. The
            // compositor keeps displaying the previously-presented frame.
            // Semaphore NOT touched on the skip path: we never claimed
            // a slot, so we don't signal back.
            didFrameSkipLastRender = true
            return
        }
        didFrameSkipLastRender = false

        lastFrameKey = frameKey

        // Lock a slot BEFORE acquiring the drawable. Flipping this order
        // (drawable-first) was attempted as metal-renderer F20 and
        // caused full-screen programs (cmatrix, vim, nvim alt-screen)
        // to glitch: waiting on the semaphore while holding a drawable
        // starves `CAMetalLayer`'s 3-slot drawable pool, because the
        // compositor can't hand out a new drawable for the next vsync
        // while one is pinned to our CPU-side wait. The correct
        // invariant is: drawable lifetime ≤ encode time, always
        // shorter than a vsync interval. Audit metal-renderer F20
        // reverted 2026-04-22.
        inflightSemaphore.wait()
        currentSlot = frameIndex
        frameIndex = (frameIndex + 1) % 3
        let slot = currentSlot

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            // Release the slot we just claimed — we're abandoning this
            // frame without encoding, so the GPU never reads the buffer.
            inflightSemaphore.signal()
            // No drawable was presented on this path either: tell
            // callers gating side effects (LatencyProbe.markPresented)
            // that the GPU did not actually paint a frame, so they
            // don't record a phantom zero-latency sample for the
            // pending keystroke.
            didFrameSkipLastRender = true
            return
        }

        // Signal the slot free when the GPU finishes reading it. Must be
        // registered before `commit()` so there's no race with an immediate
        // GPU-side completion.
        //
        // Also inspect `status`/`error` so GPU faults (device lost, page
        // fault, shader trap) surface in the unified log instead of
        // silently blanking the window. `privacy: .public` is load-bearing
        // for readability — see `feedback_nslog_private_format`.
        //
        // Strong-capture the semaphore (NOT `[weak self]`): if the renderer
        // deinits between `commit()` and the GPU completion firing, a weak
        // `self?` resolves to nil and silently drops the `signal()`. The
        // semaphore then deinits with an unbalanced wait/signal count and
        // libdispatch aborts the process with `BUG IN CLIENT OF
        // LIBDISPATCH: Semaphore object deallocated while in use`. The
        // semaphore's lifetime is independent of `self`, so capturing it
        // strongly here keeps the slot bookkeeping intact across renderer
        // teardown — Apple's canonical pattern for triple-buffered Metal
        // ring semaphores. Audit M-3 (2026-04-29).
        buffer.addCompletedHandler { [semaphore = self.inflightSemaphore] cb in
            if cb.status == .error {
                if let err = cb.error {
                    Self.logger.error("command buffer failed: \(String(describing: err), privacy: .public)")
                } else {
                    Self.logger.error("command buffer ended with .error status (no NSError)")
                }
            }
            semaphore.signal()
        }

        // Build a cheap closure that answers "is buffer-(line, col) inside
        // the current selection?". Called once per cell while building the
        // instance array. Rectangular mode hits an axis-aligned bounding
        // box; prose-style modes use the standard (start, end) sweep where
        // interior lines select the full width.
        let isSelected: (Int32, Int) -> Bool = { [selection] line, col in
            guard let sel = selection else { return false }
            let (a, b) = sel.normalized
            switch sel.mode {
            case .rectangular:
                let lo = min(a.line, b.line), hi = max(a.line, b.line)
                let cLo = min(a.col, b.col), cHi = max(a.col, b.col)
                return line >= lo && line <= hi && col >= cLo && col <= cHi
            case .line:
                // Line mode always highlights whole rows between a.line and
                // b.line — the drag path keeps anchor/cursor on their
                // original col, so without this the last (or first) dragged
                // line would only highlight up to the pointer's column.
                return line >= a.line && line <= b.line
            case .character, .word:
                if line < a.line || line > b.line { return false }
                if a.line == b.line { return col >= a.col && col <= b.col }
                if line == a.line { return col >= a.col }
                if line == b.line { return col <= b.col }
                return true
            }
        }

        if let snap = snapshot {
            // Viewport in points, not pixels. NDC conversion in the shader
            // divides point positions by point viewport, giving a scale-
            // independent result that the hardware rasterizes to the drawable's
            // pixel space. Text stays at its absolute cell-sized position as
            // the window grows/shrinks, with empty space on the right/bottom
            // when the grid hasn't caught up yet (which synchronous
            // session.resize now eliminates).
            let viewportPoints = SIMD2<Float>(
                Float(view.bounds.size.width),
                Float(view.bounds.size.height)
            )
            let cellSizePoints = SIMD2<Float>(
                Float(metrics.cellWidth),
                Float(metrics.cellHeight)
            )
            // Cursor position in viewport rows. When the user is scrolled back
            // into history (displayOffset > 0), the live cursor_row is offset
            // downward on-screen by that amount: rows 0..displayOffset-1 show
            // scrollback, and the live grid starts at screen row displayOffset.
            // If the resulting row falls below the viewport, the live cursor
            // isn't visible and we skip drawing it — scrolling back should
            // never show a phantom cursor on a scrollback line.
            let screenCursorRow = snap.cursorRow + snap.displayOffset
            // User's pinned shape (`cursorShapeOverride`) wins over the
            // snapshot's DECSCUSR shape. When nil, follow the shell. Used
            // everywhere below — `useCellInvertedCursor`, the "hidden"
            // short-circuit, and the cache key.
            // `UInt8(clamping:)` per UR-2 — defense-in-depth on the
            // Rust-snapshot cursorShape entering the cache key path.
            let effectiveShape: UInt8 = cursorShapeOverride ?? UInt8(clamping: snap.cursorShape)
            let shape = UInt32(effectiveShape)
            // Reset the blink cycle every time the cursor moves, so a
            // moving cursor is continuously visible. Tracked in
            // grid-coordinate space (cursorRow/Col), not screen row.
            // `Int32(clamping:)` per UR-2 — defense-in-depth on
            // Rust-snapshot cursor coordinates.
            let curRow = Int32(clamping: snap.cursorRow)
            let curCol = Int32(clamping: snap.cursorCol)
            // Capture the prior cursor position BEFORE overwriting
            // `lastCursorRow` — the partial-rebuild path below needs it
            // to force-rebuild the row the cursor just vacated. Audit
            // metal-renderer F3.
            let prevCursorRow = lastCursorRow
            let prevCursorCol = lastCursorCol
            let cursorMoved = curRow != lastCursorRow || curCol != lastCursorCol
            if cursorMoved {
                lastCursorRow = curRow
                lastCursorCol = curCol
                blinkPhaseStart = CACurrentMediaTime()
            }
            // blinkSkip already computed for the frame-key check above.
            // Reuse that value so we never flicker from a phase transition
            // that happens between the key computation and the draw.
            let blinkSkip = blinkSkipNow
            let cursorOnScreen =
                snap.cursorVisible &&
                shape != 3 &&                 // DECSCUSR hidden — skip entirely
                snap.cursorCol < snap.cols &&
                screenCursorRow < snap.rows &&
                !blinkSkip
            // Focused block cursor renders via cell inversion (so the glyph
            // stays visible). Bar / underline / unfocused-outline go through
            // the cursor pipeline below. This mirrors iTerm2 behaviour and
            // keeps reverse-video cells intact when the cursor crosses them.
            let useCellInvertedCursor = cursorOnScreen && focused && shape == 0
            let blockCursorCell: (row: Int, col: Int)? = useCellInvertedCursor
                ? (row: screenCursorRow, col: snap.cursorCol)
                : nil

            // Decide whether to take the partial-rebuild path. The cache
            // is "compatible" when every visible-state input to the row
            // builder matches the prior frame (CacheKey equality). When
            // it matches AND alacritty reports partial damage with a
            // manageable count, we only rebuild the damaged rows — the
            // rest are copied from rowInstanceCache unchanged.
            //
            // The row-count threshold (rows / 2) guards against the case
            // where damage covers most of the screen anyway: the
            // per-row-skip overhead would exceed the savings. Above the
            // threshold, just rebuild everything.
            let newCacheKey = CacheKey(
                cols: snap.cols,
                rows: snap.rows,
                hoveredLinkID: hoveredLinkID,
                selMode: selFields.mode,
                selALine: selFields.aLine,
                selBLine: selFields.bLine,
                selACol: selFields.aCol,
                selBCol: selFields.bCol,
                focused: focused,
                cursorShape: effectiveShape,
                cursorVisible: snap.cursorVisible,
                // Sibling of the FrameKey site — same clamping rationale,
                // routed through `clampDisplayOffset` for the one-shot
                // negative-detected warning. Audit M-16 (2026-04-29).
                displayOffset: Self.clampDisplayOffset(snap.displayOffset),
                topInsetPoints: topInsetPoints,
                defaultBgRgb: defaultBgRgb,
                backgroundOpacity: backgroundOpacity,
                keepBgOpaque: keepBgOpaque,
                accentColor: accentColor,
                cursorColor: cursorColor,
                blinkSkip: blinkSkipNow,
                cmdHoverBufferLine: cmdHoverBufferLine,
                cmdHoverStartCol: cmdHoverStartCol,
                cmdHoverEndCol: cmdHoverEndCol,
                atlasGeneration: atlas.generation,
                metricsGeneration: metricsGeneration
            )
            let cacheCompatible = !dirtyRowsDisabled
                && lastCacheKey == newCacheKey
                && rowInstanceCache.count == snap.rows

            // Detect coalesced snapshots: `TerminalSession.publishPending
            // Snapshot` coalesces rapid core snapshots into a single main-
            // thread handoff, dropping intermediate damage info on the
            // floor. `BBSnapshot.sequenceID` is a monotonic per-allocation
            // counter incremented on every `bb_term_take_snapshot`, so a
            // jump of >1 between the previous rendered snapshot and this
            // one means ≥1 intermediate was skipped. The partial-rebuild
            // path keys off `damagedRows`, which alacritty resets on each
            // snapshot take — the skipped rows' damage is gone. Force a
            // full rebuild in that case; the cache's CacheKey stays
            // valid, we just re-walk every row's cells once to catch the
            // lost deltas. Fixes cmatrix / vim / nvim streaming artifacts.
            let snapshotCoalesced: Bool =
                lastRenderedSnapshotSeq > 0
                && snap.sequenceID > lastRenderedSnapshotSeq + 1

            let partialRows: Set<Int>? = {
                guard cacheCompatible else { return nil }
                guard !snap.damageIsFull else { return nil }
                guard !snapshotCoalesced else { return nil }
                let damaged = snap.damagedRows
                if damaged.isEmpty || damaged.count >= (snap.rows + 1) / 2 {
                    return nil
                }
                var rows = Set(damaged)
                // Force-rebuild the row the cursor just left AND the row
                // it moved to, even when alacritty's damage iterator did
                // not flag them. The partial-rebuild fast path would
                // otherwise leave a ghost inverted cell in the old row
                // (and occasionally miss painting the new one) whenever
                // pure cursor motion happens without a content delta — a
                // common case in empty-prompt arrow-key editing. Cheap
                // insurance; at most two extra row rebuilds per frame.
                // Audit metal-renderer F3.
                if cursorMoved {
                    let prevScreenRow = Int(prevCursorRow) + Int(snap.displayOffset)
                    if prevScreenRow >= 0 && prevScreenRow < snap.rows {
                        rows.insert(prevScreenRow)
                    }
                    let newScreenRow = Int(curRow) + Int(snap.displayOffset)
                    if newScreenRow >= 0 && newScreenRow < snap.rows {
                        rows.insert(newScreenRow)
                    }
                    _ = prevCursorCol // silence unused warning; col-level precision not needed
                }
                return rows
            }()

            let instanceCount = buildInstances(
                snapshot: snap,
                isSelected: isSelected,
                blockCursorCell: blockCursorCell,
                partialRowsOnly: partialRows
            )
            lastCacheKey = newCacheKey
            // Record the snapshot seq we just rendered. `lastRenderedSnapshot
            // Seq` drives the coalesced-snapshot detection on the next
            // render; updating it HERE (after the row cache is in sync
            // with `snap`) means a subsequent skipped-frame detection
            // measures gap from the last successful paint, not from an
            // aborted mid-encode state.
            lastRenderedSnapshotSeq = snap.sequenceID
            if instanceCount > 0 {
                var uniforms = FrameUniforms(
                    viewportPx: viewportPoints,
                    cellSizePx: cellSizePoints,
                    accentColor: accentColor
                )
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBuffer(instanceBuffers[slot], offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                // Color atlas bound unconditionally. Fragment shader
                // branches on `BB_ATTR_IS_COLOR_GLYPH` to pick which
                // texture to sample; Metal requires both bindings to be
                // addressable for the shader to compile.
                encoder.setFragmentTexture(atlas.colorTexture, index: 1)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: instanceCount
                )
            }
            if cursorOnScreen && !useCellInvertedCursor {
                var cu = CursorUniforms(
                    viewportPx: viewportPoints,
                    cursorPosPx: SIMD2<Float>(Float(snap.cursorCol) * Float(metrics.cellWidth),
                                              Float(screenCursorRow) * Float(metrics.cellHeight) + topInsetPoints),
                    cellSizePx: cellSizePoints,
                    color: cursorColor,
                    strokeWidthPx: 1.0,
                    filled: focused ? 1.0 : 0.0,
                    shape: shape,
                    _pad: 0
                )
                encoder.setRenderPipelineState(cursorPipelineState)
                encoder.setVertexBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
                encoder.setFragmentBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    deinit {
        // DispatchSemaphore's contract: "all associated waits must be
        // balanced before deallocation, or the program traps." If a window
        // closes while frames are still in flight, the GPU completion
        // handlers haven't run yet, so our inflightSemaphore has
        // outstanding waits without matching signals. Deallocating it in
        // that state aborts the process.
        //
        // The fix is simple: commit an empty command buffer on our queue
        // and `waitUntilCompleted`. The empty buffer orders behind any
        // real frames already committed, and waiting for it forces every
        // prior completion handler to run — which signals the semaphore
        // back to balance. Then deinit of the semaphore is safe.
        //
        // Called on whatever thread releases the last strong ref (usually
        // main, but not guaranteed). `waitUntilCompleted` is documented
        // safe from any thread; no additional synchronisation needed.
        //
        // `makeCommandBuffer()` can return nil when the queue is full or
        // in error state. Pre-fix L-22, that case was a silent swallow:
        // combined with the M-3 `[weak self]` semaphore-signal miss
        // (now landed strong-captured), it formed the actual semaphore-
        // trap chain — no drain → no completion → no signal → semaphore
        // deinits unbalanced → libdispatch aborts. Post-M-3 the chain
        // is broken at the signal site, so this branch is purely
        // diagnostic; log so a future drift makes itself visible. One
        // retry is cheap and covers transient queue-full pressure;
        // beyond that we accept the diagnostic and proceed (the
        // semaphore is already balanced via M-3's strong-captured
        // signal). Audit L-22 / NA-2 (2026-04-29).
        var drained = false
        var drainAttempt = -1
        for attempt in 0..<2 {
            if let drain = commandQueue.makeCommandBuffer() {
                drain.commit()
                drain.waitUntilCompleted()
                drained = true
                drainAttempt = attempt
                break
            }
        }
        if !drained {
            Self.logger.error("MetalRenderer.deinit: drain commandBuffer creation failed (both attempts); relying on M-3 strong-captured signal to balance the semaphore")
        } else if drainAttempt > 0 {
            // Succeeded on retry — first attempt failed. Surfaces queue
            // pressure as an early warning before it escalates to both
            // attempts failing. Audit L-22 follow-up (2026-04-29).
            Self.logger.notice("MetalRenderer.deinit: drain commandBuffer succeeded on attempt \(drainAttempt + 1, privacy: .public); queue was momentarily unable to vend a buffer")
        }
        #if DEBUG
        if drained && drainAttempt == 0 {
            Self.logger.debug("MetalRenderer deinit — in-flight frames drained")
        }
        #endif
    }
}

struct FrameUniforms {
    var viewportPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    /// sRGB RGBA colour used by the cell fragment shader for accent-
    /// attribute underlines. Task 7 uses this for OSC 8 hover highlight.
    /// Plumbed from the theme accent; defaults to a controlAccentColor-like
    /// blue so the renderer has something usable even before the theme
    /// installs one.
    var accentColor: SIMD4<Float>
}

struct CursorUniforms {
    var viewportPx: SIMD2<Float>
    var cursorPosPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var color: SIMD4<Float>
    var strokeWidthPx: Float
    var filled: Float       // 1.0 = solid block (window focused), 0.0 = outline
    var shape: UInt32       // 0 = block, 1 = bar, 2 = underline, 3 = hidden
    var _pad: Float         // keeps struct layout / alignment stable
}
