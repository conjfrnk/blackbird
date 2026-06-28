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
    /// The two render pipeline states, grouped into one value struct (Finding A
    /// field-clustering) so the renderer's stored-field count reflects concerns,
    /// not individual variables. `pipelineState` draws the instanced cell quads;
    /// `cursorPipelineState` draws the standalone bar / underline / unfocused-
    /// outline cursor (the focused block cursor renders via cell inversion, not
    /// through this pipeline). Both are immutable `let`s built once in `init`.
    /// Fields keep their exact prior names, so the encoders read
    /// `pipelines.pipelineState` / `pipelines.cursorPipelineState`.
    private struct Pipelines {
        let pipelineState: MTLRenderPipelineState
        let cursorPipelineState: MTLRenderPipelineState
    }
    private let pipelines: Pipelines
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
    ///
    /// Grouped into one value struct (Finding A: stored-field clustering) so
    /// the renderer's field count reflects concerns, not individual variables.
    /// Every field keeps its exact name + type; access is now `ring.<field>`.
    /// `inflightSemaphore` is a `let` holding a reference type — `ring` is one
    /// stored property of the class and is never copied, so there is exactly
    /// one semaphore across the renderer's lifetime. The slot-lifecycle helpers
    /// (`claimSlot`/`releaseSlotUnused`/`commitSlotRotation`/
    /// `rollbackSlotRotation`) stay methods on the renderer that read/write
    /// `ring.*`, so the S2-006/M-3/S2-007 wait/signal ordering is unchanged: a
    /// helper reads `ring.inflightSemaphore` (an instantaneous read of the
    /// reference) before calling `.wait()`/`.signal()`, holding no exclusive
    /// access to `ring` across the blocking call.
    private struct TripleBufferRing {
        var instanceBuffers: [MTLBuffer]
        var instanceCapacities: [Int]
        var frameIndex: Int = 0
        /// The slot the current `render(in:)` call has locked. Set after
        /// `inflightSemaphore.wait()`, read by `buildInstances` and the encoder,
        /// cleared on completion. Not thread-safe on its own — `render(in:)`
        /// always runs on the main thread.
        var currentSlot: Int = 0
        /// Three tokens match three buffers. Every `render(in:)` waits on one
        /// before touching its slot; the command buffer's completion handler
        /// signals. The GPU can run up to three frames ahead of the CPU;
        /// beyond that, the CPU blocks, which is the correct backpressure
        /// shape for a latency-sensitive text renderer.
        let inflightSemaphore = DispatchSemaphore(value: 3)
    }
    private var ring: TripleBufferRing
    /// Hard cap on `ring.instanceCapacities[slot]`. The grow path doubles the
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

    /// Theme-derived colour state (Finding A cluster). Grouped into one value
    /// struct; every field keeps its name/type and is read as `themeColors.<f>`.
    /// These feed `makeFrameKey`/`makeCacheKey` and the cell/cursor encoders;
    /// grouping is a pure relocation — the key values stay byte-identical.
    private struct ThemeColors {
        var cursorColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
        /// Accent colour applied by the fragment shader whenever a cell's
        /// `linkHover` attribute bit is set. Defaults to an sRGB approximation
        /// of macOS's `controlAccentColor` so the underline looks right even
        /// without a theme-provided override.
        var accentColor: SIMD4<Float> = SIMD4<Float>(0.0, 0.48, 1.0, 1.0)
        /// When a cell's resolved bg equals this value, we treat it as "default
        /// background" and skip drawing a bg quad. That lets the transparent
        /// clearColor show through — the window-level transparency effect.
        /// `0xFFFFFFFF` acts as a sentinel meaning "no theme bg configured yet".
        var defaultBgRgb: UInt32 = 0xFFFFFFFF
        /// Overall opacity applied to non-default cell backgrounds. 1.0 keeps
        /// them solid; lower values let the framebuffer (clearColor) peek
        /// through — used when the user wants even vim status lines to be
        /// translucent (keepBgOpaque == false in iTerm2 terms).
        var backgroundOpacity: Float = 1.0
        var keepBgOpaque: Bool = true
    }
    private var themeColors = ThemeColors()

    /// OSC 8 link id currently under the pointer. Cells with matching
    /// `link_id` receive the accent underline via the `linkHover`
    /// attribute bit. Zero means "no hovered link" — the renderer skips
    /// the underline branch entirely.
    private var hoveredLinkID: UInt16 = 0

    /// Optional "⌘-held, regex URL under pointer" range (Finding A cluster).
    /// Carries a buffer line (not screen row — survives scrolling) and an
    /// inclusive column range. The renderer applies the same `linkHover` accent
    /// underline to matching cells. `cmdHover.startCol < 0` is the sentinel for
    /// "no range" and disables the branch entirely.
    private struct CmdHover {
        var bufferLine: Int32 = 0
        var startCol: Int32 = -1
        var endCol: Int32 = -1
    }
    private var cmdHover = CmdHover()

    /// Layout offsets in points added to every cell and cursor, grouped into one
    /// value struct (Finding A field-clustering). `topInsetPoints` keeps text out
    /// of the titlebar region when the window uses `.fullSizeContentView` so the
    /// Metal clearColor can tint under the titlebar (TerminalView passes
    /// `safeAreaInsets.top` here on each layout); `leftInsetPoints` is its
    /// horizontal sibling (TerminalView passes `horizontalContentInsetPoints` on
    /// each `layout()`). Default zero keeps pre-feature behaviour for tests that
    /// build a renderer without a TerminalView. Both fields keep their exact
    /// prior names/types; access is now `insets.topInsetPoints` /
    /// `insets.leftInsetPoints`. They are independent scalars (never mutated via
    /// `&`-subscript) so grouping introduces no exclusivity hazard.
    private struct Insets {
        var topInsetPoints: Float = 0.0
        var leftInsetPoints: Float = 0.0
    }
    private var insets = Insets()

    public func setTopInsetPoints(_ points: Float) { insets.topInsetPoints = points }

    public func setLeftInsetPoints(_ points: Float) { insets.leftInsetPoints = points }

    #if DEBUG
    /// DEBUG-only accessor for unit tests asserting the renderer received
    /// the correct inset value from TerminalView.layout().
    public func leftInsetPointsForTesting() -> Float { insets.leftInsetPoints }
    #endif

    /// Cursor blink + last-position + user-shape-override state (Finding A
    /// cluster). Grouped into one value struct; fields read as
    /// `cursorState.<field>`.
    ///
    /// Blink: when enabled, the cursor renders for the first half of each
    /// ~1.06 s cycle and is skipped for the second half. The cycle resets every
    /// time the cursor moves (typing, arrow keys, output scrolling the prompt)
    /// so a moving cursor is always visible — just like xterm/iTerm/Terminal.app.
    private struct CursorState {
        var blinkEnabled: Bool = false
        var blinkPhaseStart: CFTimeInterval = 0
        var lastCursorRow: Int32 = -1
        var lastCursorCol: Int32 = -1
        /// User-pinned cursor shape. `nil` → follow the snapshot's DECSCUSR
        /// value (default behaviour). A non-nil value overrides the shape the
        /// shell most recently set, so users who want a bar cursor regardless
        /// of `\e[2 q'` / `\e[0 q'` get it.
        ///
        /// Cache invalidation runs through the frame-key / cache-key
        /// substitution in `render(in:)`: changing the override mutates
        /// `effectiveShape`, which flows into both keys and forces a rebuild.
        /// `setCursorShapeOverride` also nulls the last-keys so the override
        /// lands on the very next frame even if the snapshot is otherwise
        /// identical.
        var shapeOverride: UInt8? = nil
    }
    private var cursorState = CursorState()

    /// The pixel-affecting inputs shared by `FrameKey` (the per-frame skip
    /// cache) and `CacheKey` (the per-row rebuild cache). Extracted into one
    /// Equatable struct both keys embed so the ~23 fields are authored ONCE: a
    /// field added here must be populated in BOTH `makeFrameKey` and
    /// `makeCacheKey` (the compiler enforces it via the memberwise init), which
    /// converts the prior "add to one struct, forget the other" hazard (Part I
    /// §34 / M-20 / H3 — a dropped field silently misses redraws) into a build
    /// error. Equatable derives field-by-field, so embedding it leaves both
    /// keys' comparison semantics byte-identical to the prior flat layout.
    private struct VisualState: Equatable {
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
        /// Effective cursor shape: user override if set, else the snapshot's
        /// DECSCUSR shape. `setCursorShapeOverride` also invalidates the keys
        /// directly, so pinning a shape that happens to equal the current
        /// snapshot shape still repaints exactly once.
        let cursorShape: UInt8
        let cursorVisible: Bool
        /// Widened from UInt16 to UInt32: default scrollback is 100 000 lines
        /// and the Rust core caps at 200 000, both well past UInt16.max
        /// (65 535). A truncating narrowing here would silently wrap once the
        /// user scrolled past row 65 535, leaving the skip path unable to
        /// distinguish two visually-different scroll positions and dragging
        /// hover/selection/cursor uniforms out of alignment.
        let displayOffset: UInt32
        let topInsetPoints: Float
        /// Horizontal inset in points. Folded in for the same reason as
        /// `topInsetPoints` — a re-inset (theoretically possible if the
        /// font-size pref ever drives a different inset constant) must
        /// invalidate the skip caches.
        let leftInsetPoints: Float
        let defaultBgRgb: UInt32
        let backgroundOpacity: Float
        let keepBgOpaque: Bool
        let accentColor: SIMD4<Float>     // Equatable; avoids collision risk
        let cursorColor: SIMD4<Float>
        let blinkSkip: Bool
        /// ⌘-held regex URL range under pointer. Bundled in so the skip
        /// optimisations correctly repaint when the highlighted run changes
        /// without a new snapshot arriving (FrameKey) / when linkHover flags on
        /// those cells flip (CacheKey).
        let cmdHoverBufferLine: Int32
        let cmdHoverStartCol: Int32
        let cmdHoverEndCol: Int32
        /// `MetalRenderer.metricsGeneration` snapshot. Folded in so a metrics
        /// mutation (font-size change, future external setter) invalidates the
        /// caches automatically — without this, the invariant relied on every
        /// mutator remembering to null the keys by hand. Audit M-20.
        let metricsGeneration: UInt64
        /// `GlyphAtlas.generation` snapshot. A saturation flush bumps the atlas
        /// generation mid-encode (the `flushBarrier` only drains the GPU; it
        /// does NOT touch the keys). Cached `CellInstance`s carry baked-in UV
        /// coords pointing at slots the flush rewrites — a stale row would
        /// silently sample the post-flush occupant. Including generation forces
        /// a single re-encode / full rebuild after any flush, converting a
        /// persistent stale-glyph artifact into a self-correcting one. Audit H3.
        let atlasGeneration: UInt64
    }

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
    /// Equatable comes out to a handful of CPU instructions; the branch
    /// predictor handles the common "identical" case fast. The shared
    /// pixel-affecting fields live in `visual`; the three fields below are
    /// FrameKey-only (CacheKey deliberately excludes them — see `CacheKey`).
    private struct FrameKey: Equatable {
        /// Monotonic sequence id from BBSnapshot (0 when snapshot is nil).
        /// Intentionally NOT the handle pointer: the allocator can reuse an
        /// address after a snapshot is released, which would make two
        /// distinct snapshots look identical to pointer-equality and cause
        /// a popup-close or cursor-move repaint to be silently dropped.
        /// The sequence counter is assigned once at BBSnapshot init and
        /// never repeats within a process lifetime.
        let snapshotSeq: UInt64
        let cursorRow: Int32
        let cursorCol: Int32
        let visual: VisualState
    }
    /// Frame-skip + per-row rebuild cache (Finding A cluster). The mutable
    /// fields that together decide whether `render(in:)` can short-circuit and
    /// what it may reuse; grouped into one value struct so they read as a single
    /// concern (`skipCache.<field>`). The Mirror-based `CmdHoverHighlightTests`
    /// reflects through this container to reach `lastFrameKey`/`lastCacheKey`.
    private struct SkipCache {
        /// Last actually-encoded FrameKey. H7: assigned only on a committed
        /// encode and nil'd on grow-failure (S2-007); `nil` forces the next
        /// render to encode regardless of FrameKey equality.
        var lastFrameKey: FrameKey?
        var lastCacheKey: CacheKey?
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
        var lastRenderedSnapshotSeq: UInt64 = 0
        /// Per-row instance cache. Index i holds the CellInstances emitted by
        /// `CellInstanceBuilder.buildRow` for visible row i under the current CacheKey.
        /// Reused across frames when CacheKey is stable; only damaged rows
        /// (from `BBSnapshot.damagedRows`) are rebuilt. Flattened into the
        /// GPU instance buffer each frame — a ~1 MB memcpy that costs far
        /// less than iterating 16 000 cells.
        var rowInstanceCache: [[CellInstance]] = []
        /// Observable frame-skip signal. `true` when the most recent
        /// `render(in:snapshot:focused:selection:)` call short-circuited on
        /// `frameKey == lastFrameKey` (or otherwise returned without
        /// presenting a drawable); `false` on any path that actually touched
        /// the encode pipeline through `commit()`. Exposed read-only in all
        /// builds via `MetalRenderer.didFrameSkipLastRender`.
        var didFrameSkipLastRender: Bool = false
    }
    private var skipCache = SkipCache()

    /// Observable frame-skip signal — read-only public mirror of
    /// `skipCache.didFrameSkipLastRender`. TerminalView reads it to gate
    /// `LatencyProbe.shared.markPresented()`: calling `markPresented()` after a
    /// skipped render records phantom zero-latency samples, dragging p50/p99
    /// metrics artificially low. Not thread-safe; readers must observe it from
    /// the same queue as the `render` call (today: main).
    public var didFrameSkipLastRender: Bool { skipCache.didFrameSkipLastRender }

    #if DEBUG
    /// Test-only seam: force `lastFrameKey` to advance even when drawable
    /// acquisition fails. Used by `CmdHoverHighlightTests` (and similar)
    /// to verify FrameKey's Equatable contract via Mirror reflection in
    /// offscreen test environments where `view.currentDrawable == nil`.
    /// Production paths leave this `false`, preserving the H7 invariant
    /// that `lastFrameKey` records only actually-encoded frames.
    public var _testForceFrameKeyAdvanceOnFailedDrawable: Bool = false
    #endif

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
        /// The shared pixel-affecting inputs (selection, cursor shape/visibility,
        /// insets, colours, blink, cmd-hover range, atlas/metrics generations).
        /// Same struct `FrameKey` embeds — see `VisualState` for the per-field
        /// rationale (the displayOffset widening, the atlas/metrics-generation
        /// H3/M-20 invalidation, the cmd-hover bundling). CacheKey adds only the
        /// grid dims and omits FrameKey's snapshotSeq/cursorRow/cursorCol.
        let visual: VisualState
    }

    /// Debug kill-switches read once from the environment at init (Finding A
    /// field-clustering). Grouping the two `Bool`s into one value struct collapses
    /// two stored fields into one AND de-duplicates the identical env-flag parsing
    /// (one `envFlagSet`). Both are immutable `let`s evaluated once per renderer;
    /// changes require an app restart.
    ///
    /// - `dirtyRowsDisabled` (`BB_NO_DIRTY_ROWS=1`): force a full rebuild every
    ///   frame — useful when a "some rows look stale" artifact might be the
    ///   per-row cache.
    /// - `frameSkipDisabled` (`BB_NO_FRAME_SKIP=1`): disable the skip path
    ///   entirely so every `render(in:)` runs the full encode + present — useful
    ///   when a redraw artifact ("looks weird after closing popup X") might be
    ///   frame-skip.
    private struct DebugToggles {
        let dirtyRowsDisabled: Bool
        let frameSkipDisabled: Bool

        /// Read both flags from the environment. A flag is on when its variable
        /// is set to a non-empty value other than `"0"` — byte-identical to the
        /// two prior per-field closures.
        static func fromEnvironment() -> DebugToggles {
            DebugToggles(
                dirtyRowsDisabled: Self.envFlagSet("BB_NO_DIRTY_ROWS"),
                frameSkipDisabled: Self.envFlagSet("BB_NO_FRAME_SKIP")
            )
        }

        private static func envFlagSet(_ name: String) -> Bool {
            guard let cstr = getenv(name) else { return false }
            let raw = String(cString: cstr)
            return !raw.isEmpty && raw != "0"
        }
    }
    private let debugToggles = DebugToggles.fromEnvironment()

    public func setCursorBlinkEnabled(_ enabled: Bool) {
        if enabled != cursorState.blinkEnabled {
            cursorState.blinkEnabled = enabled
            cursorState.blinkPhaseStart = CACurrentMediaTime()
            // Reset the blink phase → visible cursor on the next frame
            // regardless of where in the cycle we were. Clearing the skip
            // cache forces that next frame to actually encode.
            skipCache.lastFrameKey = nil
        }
    }

    public func setCursorShapeOverride(_ shape: UInt8?) {
        if shape != cursorState.shapeOverride {
            cursorState.shapeOverride = shape
            skipCache.lastFrameKey = nil
            skipCache.lastCacheKey = nil
        }
    }

    public func setDefaultBgRgb(_ rgb: UInt32) { themeColors.defaultBgRgb = rgb }

    public func setBackgroundOpacity(_ opacity: Float, keepBgOpaque: Bool) {
        self.themeColors.backgroundOpacity = opacity
        self.themeColors.keepBgOpaque = keepBgOpaque
    }

    public func setCursorColor(rgb: UInt32) {
        // L-2 / RW-02: reuse the precomputed `inv255` constant the
        // F6 optimization introduced for `rgbToSIMD` (now homed on
        // `CellInstanceBuilder` alongside the cell colour math). Three
        // runtime divisions become three multiplies; one source for the
        // reciprocal across the renderer and the builder.
        let r = Float((rgb >> 16) & 0xFF) * CellInstanceBuilder.inv255
        let g = Float((rgb >> 8)  & 0xFF) * CellInstanceBuilder.inv255
        let b = Float(rgb & 0xFF) * CellInstanceBuilder.inv255
        // Audit L14. The cursor render pipeline (line ~573) is built
        // with the default no-blend state — opaque overwrite of the
        // already-composited cell layer. That's correct as long as
        // `cursorColor.w == 1.0`. A non-opaque cursor color would
        // write alpha < 1 into the bgra8Unorm framebuffer and the
        // CALayer compositor would let the window background bleed
        // through the cursor rectangle (definitely not the user's
        // intent for a "translucent cursor"). This setter is the
        // sole entry point to the field; pin the invariant here so
        // any future RGBA-accepting overload that omits the
        // hardcoded `1.0` would have to consciously re-enable
        // blending on the pipeline.
        let color = SIMD4<Float>(r, g, b, 1.0)
        precondition(color.w == 1.0, "cursorColor must be opaque (cursor pipeline has no blending — see audit L14)")
        themeColors.cursorColor = color
    }

    /// Replace the accent colour used for link-hover underlines. Themes
    /// that ship an accent override can plumb it through here; otherwise
    /// the default (controlAccentColor-equivalent sRGB blue) applies.
    public func setAccentColor(rgba: SIMD4<Float>) {
        themeColors.accentColor = rgba
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
        if cmdHover.bufferLine == bufferLine
            && cmdHover.startCol == startCol
            && cmdHover.endCol == endCol {
            return
        }
        cmdHover.bufferLine = bufferLine
        cmdHover.startCol = startCol
        cmdHover.endCol = endCol
        skipCache.lastCacheKey = nil
    }

    public init?(device: MTLDevice, metrics: CellMetrics, scale: CGFloat = 2.0) {
        // Pin CellInstance's stride / alignment contract with the shader
        // BEFORE we touch any GPU state. `precondition` so Release builds
        // crash here on layout drift rather than rendering scrambled UVs.
        // F-S4-001 — the test-target call site never ran in production.
        _pinCellInstanceLayout()
        _pinCursorUniformsLayout()
        // Audit follow-up (2026-04-29): the L-6 fix surfaced PSO failures
        // via NSError logging at the two `try device.makeRenderPipelineState`
        // catch sites. The `init?` body has six other failure paths that
        // were still silently `return nil`-ing — TerminalView's fatalError
        // text promises "see unified log under category=renderer" but
        // those promises were broken until each site logs which step
        // failed. Mechanical: one `Self.logger.error` per site so triage
        // can distinguish "no command queue" from "default library missing"
        // from "vertex_cell function missing", etc.
        guard let queue = device.makeCommandQueue() else {
            Self.logger.error("MetalRenderer.init: device.makeCommandQueue() returned nil")
            return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            Self.logger.error("MetalRenderer.init: device.makeDefaultLibrary() returned nil")
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vertex_cell"),
              let fragmentFn = library.makeFunction(name: "fragment_cell") else {
            Self.logger.error("MetalRenderer.init: cell shader makeFunction(vertex_cell/fragment_cell) returned nil")
            return nil
        }

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
            // Cast to NSError and log domain/code/desc/userInfo
            // explicitly. `String(describing:)` on the bare error sometimes
            // collapses the NSError into a one-line summary that drops
            // `userInfo` — which is exactly where the Metal shader-compiler
            // diagnostic block lands (`MTLRenderPipelineErrorDomain`,
            // `userInfo[NSLocalizedDescriptionKey]`, plus compiler logs).
            // Explicit access guarantees the diagnostic survives. Audit L-6
            // follow-up (2026-04-29).
            let ns = error as NSError
            Self.logger.error("cell render pipeline state creation failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            return nil
        }

        guard let cursorVertex = library.makeFunction(name: "vertex_cursor"),
              let cursorFragment = library.makeFunction(name: "fragment_cursor") else {
            Self.logger.error("MetalRenderer.init: cursor shader makeFunction(vertex_cursor/fragment_cursor) returned nil")
            return nil
        }
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
            // Same NSError-explicit shape as the cell PSO site above —
            // userInfo carries the Metal shader-compiler diagnostic
            // block. Audit L-6 follow-up (2026-04-29).
            let ns = error as NSError
            Self.logger.error("cursor render pipeline state creation failed: domain=\(ns.domain, privacy: .public) code=\(ns.code, privacy: .public) desc=\(ns.localizedDescription, privacy: .public) userInfo=\(String(describing: ns.userInfo), privacy: .public)")
            return nil
        }

        guard let atlas = GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: Self.atlasCapacity, scale: scale) else {
            Self.logger.error("MetalRenderer.init: GlyphAtlas init failed (capacityGlyphs=\(Self.atlasCapacity, privacy: .public) scale=\(Double(scale), privacy: .public))")
            return nil
        }

        // Start with space for a full 200x80 grid; grow as needed.
        let startCap = 200 * 80
        let bytes = startCap * MemoryLayout<CellInstance>.stride
        var buffers: [MTLBuffer] = []
        buffers.reserveCapacity(3)
        for i in 0..<3 {
            guard let b = device.makeBuffer(length: bytes, options: [.storageModeShared]) else {
                Self.logger.error("MetalRenderer.init: device.makeBuffer(length=\(bytes, privacy: .public)) returned nil for instance buffer \(i, privacy: .public) of 3")
                return nil
            }
            buffers.append(b)
        }

        self.device = device
        self.commandQueue = queue
        self.pipelines = Pipelines(pipelineState: pso, cursorPipelineState: cursorPSO)
        self.atlas = atlas
        self.metrics = metrics
        // Initial generation. Subsequent metrics mutations bump this
        // counter so FrameKey/CacheKey equality forces a rebuild even
        // if every other key field is identical. Audit M-20.
        self.metricsGeneration = 1
        self.ring = TripleBufferRing(
            instanceBuffers: buffers,
            instanceCapacities: [startCap, startCap, startCap]
        )
        // Wire the H6 GPU-CPU race barrier AFTER all stored properties
        // are initialized — the closure captures self, and Swift's
        // definite-init analysis forbids capturing self while any
        // stored property is still unset. Saturation flush rewrites
        // slot 0 of the shared-storage atlas textures; a no-op
        // `commit + waitUntilCompleted` here drains every prior frame's
        // command buffer so the GPU can no longer be sampling the slot
        // we're about to overwrite. Cost: one frame stall on the rare
        // flush event (saturation = hostile input).
        atlas.flushBarrier = { [weak self] in
            guard let self, let drain = self.commandQueue.makeCommandBuffer() else { return }
            drain.commit()
            drain.waitUntilCompleted()
        }
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
        // Re-wire the H6 saturation-flush barrier on the new atlas (the
        // old closure captured the renderer but lived on the prior
        // atlas instance, which is now released). Same drain semantics
        // as init — see the longer comment there.
        a.flushBarrier = { [weak self] in
            guard let self, let drain = self.commandQueue.makeCommandBuffer() else { return }
            drain.commit()
            drain.waitUntilCompleted()
        }
        // Re-warm the new atlas so the post-resize first repaint doesn't
        // pay for CoreText rasterisation of every visible character.
        a.prewarmCommonGlyphs()
        // A new atlas points to different texture contents; the skip
        // cache is now stale. Force the next render to encode and present
        // even if every FrameKey field matches the previous frame.
        self.skipCache.lastFrameKey = nil
        self.skipCache.lastCacheKey = nil
        self.skipCache.rowInstanceCache = []
        // Treat the atlas reconfigure as a fresh renderer: a seq the
        // caller used before the atlas swap is no longer meaningful,
        // and keeping the old value here would let a pre-reconfigure
        // seq trip the `snap.sequenceID > lastRenderedSnapshotSeq + 1`
        // coalesced-snapshot guard on what is really a clean start.
        self.skipCache.lastRenderedSnapshotSeq = 0
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
        self.skipCache.lastFrameKey = nil
        self.skipCache.lastCacheKey = nil
        self.skipCache.rowInstanceCache = []
        self.skipCache.lastRenderedSnapshotSeq = 0
    }

    /// Orchestrates per-row rebuild + GPU buffer flatten using the
    /// `rowInstanceCache`. Either rebuilds every row (full path) or only
    /// the rows alacritty's damage iterator flagged as changed (partial
    /// path). Returns the total instance count the encoder should draw.
    @discardableResult
    /// Returns the flattened instance count, or nil when the per-slot
    /// GPU buffer could not grow to hold it (audit S2-007). nil is
    /// distinct from 0 on purpose: 0 means "nothing styled to draw —
    /// encode and present an empty frame", nil means "this frame cannot
    /// be drawn — the caller must abandon the encode entirely instead of
    /// presenting a cleared drawable over valid content".
    private func buildInstances(
        snapshot: BBSnapshot,
        isSelected: (Int32, Int) -> Bool = { _, _ in false },
        blockCursorCell: (row: Int, col: Int)? = nil,
        partialRowsOnly: Set<Int>? = nil
    ) -> Int? {
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
        if skipCache.rowInstanceCache.count != rows {
            skipCache.rowInstanceCache = Array(repeating: [], count: rows)
        }

        // Cell-row → GPU-instance translation lives in `CellInstanceBuilder`
        // (the single-responsibility seam): capture this frame's visual inputs
        // by value plus the live atlas REFERENCE, then hand each row's target
        // array to `buildRow`. The builder never touches the ring / semaphore /
        // slot lifecycle — `render()` owns those; this method still owns the
        // flatten-into-slot-buffer + grow step below. Constructed once here so
        // both rebuild paths reuse it; the captured inputs only change through
        // the renderer's main-thread setters / `reconfigure`, never mid-build,
        // so the by-value snapshot is byte-identical to reading the fields
        // directly. The atlas stays a reference (it is a class) so a
        // rasterize-on-miss inside `buildRow` is visible to `encodeCells`.
        let builder = CellInstanceBuilder(
            metrics: metrics,
            hoveredLinkID: hoveredLinkID,
            cmdHoverBufferLine: cmdHover.bufferLine,
            cmdHoverStartCol: cmdHover.startCol,
            cmdHoverEndCol: cmdHover.endCol,
            defaultBgRgb: themeColors.defaultBgRgb,
            keepBgOpaque: themeColors.keepBgOpaque,
            backgroundOpacity: themeColors.backgroundOpacity,
            cursorColor: themeColors.cursorColor,
            leftInsetPoints: insets.leftInsetPoints,
            topInsetPoints: insets.topInsetPoints,
            atlas: atlas
        )

        if let damaged = partialRowsOnly {
            // Partial rebuild: only the rows alacritty says changed.
            // Iterate a sorted copy so we never hit the same row twice
            // if a future source deduplicates imperfectly.
            for row in damaged where row >= 0 && row < rows {
                // `removeAll(keepingCapacity: true)` reuses the prior
                // frame's backing buffer — we keep up to `cols` worth of
                // allocated slots, which is exactly the reserve size
                // `buildRow` asks for. No heap traffic in the
                // steady state.
                skipCache.rowInstanceCache[row].removeAll(keepingCapacity: true)
                builder.buildRow(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell,
                    into: &skipCache.rowInstanceCache[row]
                )
            }
        } else {
            // Full rebuild — cache key changed, first frame, or damage
            // exceeded the partial threshold.
            for row in 0..<rows {
                skipCache.rowInstanceCache[row].removeAll(keepingCapacity: true)
                builder.buildRow(
                    snapshot: snapshot,
                    row: row,
                    isSelected: isSelected,
                    blockCursorCell: blockCursorCell,
                    into: &skipCache.rowInstanceCache[row]
                )
            }
        }

        // Flatten into the current-slot GPU buffer. Even the partial path
        // copies every row — the CPU savings come from skipping the
        // per-cell inner work on unchanged rows, not from skipping the
        // memcpy (which is tiny: ~1 MB at 80-byte stride × 16k cells).
        let total = skipCache.rowInstanceCache.reduce(0) { $0 + $1.count }
        let slot = ring.currentSlot
        if total > ring.instanceCapacities[slot] {
            // Defense-in-depth on `* 2`: an unguarded `Int` multiply
            // would trap on overflow. Bounded today (GPU OOM
            // intervenes first) but the cap pins the contract at the
            // arithmetic site so a future regression that lets total
            // grow unboundedly can't crash the renderer mid-frame.
            // Audit L-21 (2026-04-29).
            let doubled = ring.instanceCapacities[slot]
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
                ring.instanceBuffers[slot] = newBuf
                ring.instanceCapacities[slot] = newCap
            } else {
                // Out-of-GPU-memory while growing — the frame cannot
                // be drawn. Return nil (NOT 0): the audit S2-007 trace
                // showed the old `return 0` let the render path continue
                // to endEncoding/present/commit with zero cell
                // instances, presenting a fully blank frame over valid
                // content — and because `lastFrameKey` had already been
                // advanced at encoder creation, the frame-skip cache
                // then pinned the blank frame until some unrelated
                // FrameKey field changed (with cursor blink off, until
                // the user typed). Log so the abandoned frame surfaces
                // in the unified log. Audit L-21 follow-up + S2-007.
                Self.logger.error("instance buffer grow failed: requested \(newCap, privacy: .public) instances (\(bufBytes, privacy: .public) bytes); abandoning frame")
                return nil
            }
        }

        let ptr = ring.instanceBuffers[slot].contents().assumingMemoryBound(to: CellInstance.self)
        var count = 0
        for row in 0..<rows {
            let rowInsts = skipCache.rowInstanceCache[row]
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

    /// Build the per-cell "is buffer-(line, col) inside this selection?"
    /// predicate consumed by `buildInstances` (Finding B seam — pulled out of
    /// `render()` as a pure factory over the selection; identical hit-test
    /// semantics to the prior inline closure). Captures `selection` by value, so
    /// the returned closure is independent of later mutation. Rectangular mode
    /// hits an axis-aligned bounding box; prose-style modes use the standard
    /// (start, end) sweep where interior lines select the full width.
    private static func makeSelectionPredicate(
        _ selection: Selection?
    ) -> (Int32, Int) -> Bool {
        return { line, col in
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
    }

    /// Whether the cursor is in its "off" blink phase this frame (so it should
    /// be skipped). Pure of GPU state — depends only on the blink pref, focus,
    /// the snapshot's cursor visibility, and `CACurrentMediaTime` vs
    /// `blinkPhaseStart`. 1.06 s period, off for the second half (≥ 0.53 s).
    private func computeBlinkSkip(snapshot: BBSnapshot?, focused: Bool) -> Bool {
        guard cursorState.blinkEnabled, focused, let s = snapshot, s.cursorVisible else {
            return false
        }
        let elapsed = CACurrentMediaTime() - cursorState.blinkPhaseStart
        let phase = elapsed.truncatingRemainder(dividingBy: 1.06)
        return phase >= 0.53
    }

    /// Build the per-frame visual-state key from every pixel-affecting input
    /// (snapshot seq, selection, cursor, insets, colours, blink, cmd-hover, and
    /// the metrics/atlas generations). Compared against `lastFrameKey` to skip
    /// an unchanged frame BEFORE the expensive drawable acquire. Pure: touches
    /// no GPU / semaphore / slot state.
    private func makeFrameKey(
        snapshot: BBSnapshot?,
        focused: Bool,
        selFields: (mode: UInt8, aLine: Int32, bLine: Int32, aCol: Int32, bCol: Int32),
        blinkSkip: Bool
    ) -> FrameKey {
        return FrameKey(
            snapshotSeq: snapshot?.sequenceID ?? 0,
            // `Int32(clamping:)` / `UInt8(clamping:)` for parity
            // with the M-16 displayOffset sites: defense-in-depth on
            // Rust-snapshot integers entering the FrameKey hot path.
            // Audit UR-2 (2026-04-29).
            cursorRow: Int32(clamping: snapshot?.cursorRow ?? -1),
            cursorCol: Int32(clamping: snapshot?.cursorCol ?? -1),
            visual: VisualState(
                hoveredLinkID: hoveredLinkID,
                selMode: selFields.mode,
                selALine: selFields.aLine,
                selBLine: selFields.bLine,
                selACol: selFields.aCol,
                selBCol: selFields.bCol,
                focused: focused,
                cursorShape: cursorState.shapeOverride ?? UInt8(clamping: snapshot?.cursorShape ?? 3),
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
                topInsetPoints: insets.topInsetPoints,
                leftInsetPoints: insets.leftInsetPoints,
                defaultBgRgb: themeColors.defaultBgRgb,
                backgroundOpacity: themeColors.backgroundOpacity,
                keepBgOpaque: themeColors.keepBgOpaque,
                accentColor: themeColors.accentColor,
                cursorColor: themeColors.cursorColor,
                blinkSkip: blinkSkip,
                cmdHoverBufferLine: cmdHover.bufferLine,
                cmdHoverStartCol: cmdHover.startCol,
                cmdHoverEndCol: cmdHover.endCol,
                metricsGeneration: metricsGeneration,
                atlasGeneration: atlas.generation
            )
        )
    }

    /// Build the partial-rebuild cache key: every input the per-row instance
    /// builder consumes (grid dims, selection, cursor, insets, colours, blink,
    /// cmd-hover, atlas/metrics generations). When this equals `lastCacheKey`
    /// the row cache is reusable and only alacritty's damaged rows need a
    /// rebuild. Pure: touches no GPU state. Sibling of `makeFrameKey` — same
    /// `clampDisplayOffset` (M-16) and generation rationale.
    private func makeCacheKey(
        snap: BBSnapshot,
        focused: Bool,
        selFields: (mode: UInt8, aLine: Int32, bLine: Int32, aCol: Int32, bCol: Int32),
        effectiveShape: UInt8,
        blinkSkip: Bool
    ) -> CacheKey {
        return CacheKey(
            cols: snap.cols,
            rows: snap.rows,
            visual: VisualState(
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
                topInsetPoints: insets.topInsetPoints,
                leftInsetPoints: insets.leftInsetPoints,
                defaultBgRgb: themeColors.defaultBgRgb,
                backgroundOpacity: themeColors.backgroundOpacity,
                keepBgOpaque: themeColors.keepBgOpaque,
                accentColor: themeColors.accentColor,
                cursorColor: themeColors.cursorColor,
                blinkSkip: blinkSkip,
                cmdHoverBufferLine: cmdHover.bufferLine,
                cmdHoverStartCol: cmdHover.startCol,
                cmdHoverEndCol: cmdHover.endCol,
                metricsGeneration: metricsGeneration,
                atlasGeneration: atlas.generation
            )
        )
    }

    // MARK: - Triple-buffer slot lifecycle
    //
    // The four phases of a frame's claim on a `.storageModeShared` instance
    // buffer slot, factored out of `render()` so the load-bearing S2-006 /
    // M-3 / S2-007 ordering invariants live in one named place each rather
    // than open-coded inline at the claim + two abort + commit sites.

    /// Block until a triple-buffer slot frees, then bind `currentSlot` to the
    /// current rotation index. Does NOT advance the rotation turn — that is
    /// consumed only on commitment (audit S2-006), so an aborted frame returns
    /// both its semaphore token (via `releaseSlotUnused`/`rollbackSlotRotation`)
    /// AND its turn, and the next attempt reuses the same untouched slot. (If
    /// the rotation advanced on claim, an aborted frame would leave the wait
    /// guard one frame too few — frame D could claim a slot frame A's GPU work
    /// is still reading, then CPU-write the shared buffer mid-read → torn frame.)
    private func claimSlot() -> Int {
        ring.inflightSemaphore.wait()
        ring.currentSlot = ring.frameIndex
        return ring.currentSlot
    }

    /// Return a slot token claimed but never committed (no drawable / encoder
    /// acquired). The rotation turn was never consumed, so nothing rolls back.
    private func releaseSlotUnused() {
        ring.inflightSemaphore.signal()
    }

    /// Consume the rotation turn for a frame we are committed to encoding
    /// (audit S2-006). The semaphore signal is DEFERRED to the GPU completion
    /// handler (audit M-3, strong-captured semaphore), NOT issued here — so the
    /// slot stays reserved until the GPU finishes reading it.
    private func commitSlotRotation() {
        ring.frameIndex = (ring.frameIndex + 1) % 3
    }

    /// Abort a frame AFTER its rotation turn was consumed (instance-buffer grow
    /// failure, audit S2-007): return the token and roll the rotation back to
    /// the claimed slot, so the next attempt reuses the same untouched slot.
    /// Order matches the original inline site: signal, then rollback.
    private func rollbackSlotRotation() {
        ring.inflightSemaphore.signal()
        ring.frameIndex = ring.currentSlot
    }

    /// Register the command buffer's completion handler: the DEFERRED half of
    /// the slot lifecycle (audit M-3). Signals `inflightSemaphore` once the GPU
    /// finishes reading the slot's instance buffer, and logs any GPU fault. MUST
    /// be called before `commit()` so there's no race with an immediate
    /// GPU-side completion.
    ///
    /// Also inspect `status`/`error` so GPU faults (device lost, page fault,
    /// shader trap) surface in the unified log instead of silently blanking the
    /// window. `privacy: .public` is load-bearing for readability — see
    /// `feedback_nslog_private_format`.
    ///
    /// Strong-capture the semaphore (NOT `[weak self]`): if the renderer deinits
    /// between `commit()` and the GPU completion firing, a weak `self?` resolves
    /// to nil and silently drops the `signal()`. The semaphore then deinits with
    /// an unbalanced wait/signal count and libdispatch aborts the process with
    /// `BUG IN CLIENT OF LIBDISPATCH: Semaphore object deallocated while in
    /// use`. The semaphore's lifetime is independent of `self`, so capturing it
    /// strongly here keeps the slot bookkeeping intact across renderer teardown
    /// — Apple's canonical pattern for triple-buffered Metal ring semaphores.
    /// The capture-list reads `self.ring.inflightSemaphore` synchronously at
    /// registration (on the main thread, `self` alive); the closure body then
    /// references only `semaphore` + the static `Self.logger`, so it captures
    /// the semaphore strongly and NEVER captures `self`. Audit M-3 (2026-04-29).
    private func registerSlotReleaseHandler(on buffer: MTLCommandBuffer) {
        buffer.addCompletedHandler { [semaphore = self.ring.inflightSemaphore] cb in
            if cb.status == .error {
                if let err = cb.error {
                    Self.logger.error("command buffer failed: \(String(describing: err), privacy: .public)")
                } else {
                    Self.logger.error("command buffer ended with .error status (no NSError)")
                }
            }
            semaphore.signal()
        }
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?, focused: Bool, selection: Selection? = nil) {
        // Compute the current frame's visual-state key BEFORE reaching for
        // currentDrawable. Acquiring a drawable is expensive (blocks on
        // the pool under contention); if nothing changed we shouldn't even
        // touch it. Note: blink state is computed here too because it
        // depends on CACurrentMediaTime.
        let blinkSkipNow = computeBlinkSkip(snapshot: snapshot, focused: focused)
        let selFields = Self.selectionFields(selection)
        let frameKey = makeFrameKey(
            snapshot: snapshot, focused: focused, selFields: selFields, blinkSkip: blinkSkipNow
        )
        if !debugToggles.frameSkipDisabled, frameKey == skipCache.lastFrameKey {
            // Nothing that affects pixels has changed since the last
            // presented frame. Skip the whole pipeline — no CPU instance
            // rebuild, no GPU encode, no drawable acquisition. The
            // compositor keeps displaying the previously-presented frame.
            // Semaphore NOT touched on the skip path: we never claimed
            // a slot, so we don't signal back.
            skipCache.didFrameSkipLastRender = true
            return
        }

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
        // Claim a triple-buffer slot (blocks until one frees). The rotation
        // turn is consumed only on commitment, NOT here — so an aborted frame
        // returns both its token and its turn. See `claimSlot` /
        // `commitSlotRotation` / `releaseSlotUnused` / `rollbackSlotRotation`
        // for the S2-006 ordering invariant this lifecycle encapsulates.
        let slot = claimSlot()

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            // Release the slot we just claimed — we're abandoning this
            // frame without encoding, so the GPU never reads the buffer. The
            // rotation turn was never consumed, so there is nothing to roll back.
            releaseSlotUnused()
            // No drawable was presented on this path either: tell
            // callers gating side effects (LatencyProbe.markPresented)
            // that the GPU did not actually paint a frame, so they
            // don't record a phantom zero-latency sample for the
            // pending keystroke.
            //
            // `lastFrameKey` is NOT advanced on this path. The skip-cache
            // invariant is "lastFrameKey records the last *encoded*
            // frame"; advancing it here would let the next call short-
            // circuit on `frameKey == lastFrameKey` and never re-encode
            // — a windowed minimise + identical state could freeze the
            // surface. Leaving it unchanged guarantees the next render
            // attempt enters the encode path again. Audit H7.
            skipCache.didFrameSkipLastRender = true
            #if DEBUG
            if _testForceFrameKeyAdvanceOnFailedDrawable {
                skipCache.lastFrameKey = frameKey
            }
            #endif
            return
        }

        // Drawable + descriptor + command buffer + encoder all live —
        // we are committed to encoding this frame. Advance the skip-
        // cache atomically with that commitment so an early-return
        // above leaves `lastFrameKey` pinned to the previous successful
        // frame (audit H7), and consume the rotation turn only now
        // (audit S2-006). The semaphore signal stays DEFERRED to the GPU
        // completion handler below (audit M-3).
        commitSlotRotation()
        skipCache.didFrameSkipLastRender = false
        skipCache.lastFrameKey = frameKey

        // Register the deferred slot-release + GPU-fault logging completion
        // handler (audit M-3). Must run before `commit()` so there's no race
        // with an immediate GPU-side completion. See
        // `registerSlotReleaseHandler` for the strong-captured-semaphore
        // rationale.
        registerSlotReleaseHandler(on: buffer)

        // Per-cell "is buffer-(line, col) inside the current selection?"
        // predicate, built once per frame (Finding B seam — see
        // `makeSelectionPredicate`). Called once per cell while building the
        // instance array.
        let isSelected = Self.makeSelectionPredicate(selection)

        if let snap = snapshot {
            // All per-frame viewport / cell-size / cursor-rect geometry (pure
            // math; see `computeFrameGeometry`). The blink-phase reset below is
            // the only stateful step and stays inline because it mutates
            // `cursorState`.
            let geo = computeFrameGeometry(
                snap: snap, view: view, blinkSkip: blinkSkipNow, focused: focused
            )
            // Reset the blink cycle every time the cursor moves so a moving
            // cursor is continuously visible. `computeFrameGeometry` already
            // captured the prior position into `geo.prevCursor*` / `geo.cursorMoved`
            // BEFORE this write, so the read-before-write order matches the prior
            // inline code (audit metal-renderer F3).
            if geo.cursorMoved {
                cursorState.lastCursorRow = geo.curRow
                cursorState.lastCursorCol = geo.curCol
                cursorState.blinkPhaseStart = CACurrentMediaTime()
            }

            // Decide what rows to rebuild this frame: the new CacheKey, the
            // cache-compatible / coalesced-snapshot flags, and the damaged-row
            // set (nil = full rebuild); see `planRowRebuild`. Pure — `render`
            // records the returned CacheKey only after the buildInstances commit
            // below (H7 / S2-007 ordering).
            let plan = planRowRebuild(
                snap: snap, focused: focused, selFields: selFields,
                blinkSkip: blinkSkipNow, geo: geo
            )

            guard let instanceCount = buildInstances(
                snapshot: snap,
                isSelected: isSelected,
                blockCursorCell: geo.blockCursorCell,
                partialRowsOnly: plan.partialRows
            ) else {
                // Instance-buffer grow failure (audit S2-007): abandon
                // the frame. End the encoder (required before the
                // uncommitted command buffer can be dropped), do NOT
                // present — presenting here would flash a cleared
                // drawable over valid content — and return the slot
                // token manually: the addCompletedHandler above only
                // fires for COMMITTED buffers, so without this signal
                // the ring leaks a slot and the 4th render call blocks
                // forever. Clear `lastFrameKey` so the next tick cannot
                // frame-skip against a key that was never presented
                // (the pinned-blank-frame half of the finding), and
                // leave lastCacheKey/lastRenderedSnapshotSeq stale so
                // the retry re-walks every row.
                encoder.endEncoding()
                // Return the slot token AND roll the rotation turn back to the
                // claimed slot together (audit S2-006/S2-007): a frame that won't
                // reach GPU completion must not consume a slot rotation, or each
                // abort makes the triple-buffer wait guard one frame too few.
                // render() is only entered from the MTKView draw callback, so no
                // interleaving caller can observe the rollback.
                rollbackSlotRotation()
                skipCache.lastFrameKey = nil
                skipCache.didFrameSkipLastRender = true
                return
            }
            skipCache.lastCacheKey = plan.cacheKey
            // Record the snapshot seq we just rendered. `lastRenderedSnapshot
            // Seq` drives the coalesced-snapshot detection on the next
            // render; updating it HERE (after the row cache is in sync
            // with `snap`) means a subsequent skipped-frame detection
            // measures gap from the last successful paint, not from an
            // aborted mid-encode state.
            skipCache.lastRenderedSnapshotSeq = snap.sequenceID
            if instanceCount > 0 {
                encodeCells(
                    encoder: encoder, slot: slot, instanceCount: instanceCount,
                    viewportPoints: geo.viewportPoints, cellSizePoints: geo.cellSizePoints
                )
            }
            if geo.cursorOnScreen && !geo.useCellInvertedCursor {
                encodeCursor(
                    encoder: encoder, snap: snap, screenCursorRow: geo.screenCursorRow,
                    shape: geo.shape, viewportPoints: geo.viewportPoints,
                    cellSizePoints: geo.cellSizePoints, focused: focused
                )
            }
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    /// Pure per-frame geometry produced by `computeFrameGeometry` and consumed by
    /// the rebuild planner + encoders. Carries no GPU handles — just the frame's
    /// viewport (drawable) and cell sizes, the resolved cursor shape/position, and
    /// the cursor-paint decision (`cursorOnScreen` / `useCellInvertedCursor` /
    /// `blockCursorCell`). `prevCursor*` / `cursorMoved` snapshot the cursor's
    /// prior grid position (read BEFORE `render` overwrites `cursorState.lastCursor*`)
    /// for the blink reset and the partial-rebuild vacated-row forcing.
    private struct FrameGeometry {
        let viewportPoints: SIMD2<Float>
        let cellSizePoints: SIMD2<Float>
        let screenCursorRow: Int
        let effectiveShape: UInt8
        let shape: UInt32
        let curRow: Int32
        let curCol: Int32
        let prevCursorRow: Int32
        let prevCursorCol: Int32
        let cursorMoved: Bool
        let cursorOnScreen: Bool
        let useCellInvertedCursor: Bool
        let blockCursorCell: (row: Int, col: Int)?
    }

    /// Compute this frame's viewport / cell-size / cursor-rect geometry. Pure: it
    /// reads `metrics`, `cursorState.shapeOverride`, and the snapshot/view but
    /// mutates nothing — the blink-phase reset that depends on `cursorMoved` stays
    /// in `render`. Extracted from `render()` so the orchestrator stays a thin
    /// wait→encode→commit shell over the load-bearing slot lifecycle.
    private func computeFrameGeometry(
        snap: BBSnapshot,
        view: MTKView,
        blinkSkip: Bool,
        focused: Bool
    ) -> FrameGeometry {
        // Viewport in points, not pixels. NDC conversion in the shader divides
        // point positions by the point viewport, giving a scale-independent result
        // that the hardware rasterizes to the drawable's pixel space. Text stays at
        // its absolute cell-sized position as the window grows/shrinks, with empty
        // space on the right/bottom when the grid hasn't caught up yet (which
        // synchronous session.resize now eliminates).
        let viewportPoints = SIMD2<Float>(
            Float(view.bounds.size.width),
            Float(view.bounds.size.height)
        )
        let cellSizePoints = SIMD2<Float>(
            Float(metrics.cellWidth),
            Float(metrics.cellHeight)
        )
        // Cursor position in viewport rows. When the user is scrolled back into
        // history (displayOffset > 0), the live cursor_row is offset downward
        // on-screen by that amount: rows 0..displayOffset-1 show scrollback, and
        // the live grid starts at screen row displayOffset. If the resulting row
        // falls below the viewport, the live cursor isn't visible and we skip
        // drawing it — scrolling back should never show a phantom cursor on a
        // scrollback line.
        let screenCursorRow = snap.cursorRow + snap.displayOffset
        // User's pinned shape (`cursorShapeOverride`) wins over the snapshot's
        // DECSCUSR shape. When nil, follow the shell. `UInt8(clamping:)` per UR-2 —
        // defense-in-depth on the Rust-snapshot cursorShape entering the cache key.
        let effectiveShape: UInt8 = cursorState.shapeOverride ?? UInt8(clamping: snap.cursorShape)
        let shape = UInt32(effectiveShape)
        // Cursor grid coordinates (`Int32(clamping:)` per UR-2). Captured here —
        // before `render` overwrites `cursorState.lastCursor*` — so the
        // partial-rebuild path can force-rebuild the row the cursor just vacated
        // (audit metal-renderer F3).
        let curRow = Int32(clamping: snap.cursorRow)
        let curCol = Int32(clamping: snap.cursorCol)
        let prevCursorRow = cursorState.lastCursorRow
        let prevCursorCol = cursorState.lastCursorCol
        let cursorMoved = curRow != cursorState.lastCursorRow || curCol != cursorState.lastCursorCol
        // `blinkSkip` is the value already computed for the frame-key check, passed
        // in so we never flicker from a phase transition between the key
        // computation and the draw.
        let cursorOnScreen =
            snap.cursorVisible &&
            shape != 3 &&                 // DECSCUSR hidden — skip entirely
            snap.cursorCol < snap.cols &&
            screenCursorRow < snap.rows &&
            !blinkSkip
        // Focused block cursor renders via cell inversion (so the glyph stays
        // visible). Bar / underline / unfocused-outline go through the cursor
        // pipeline. This mirrors iTerm2 behaviour and keeps reverse-video cells
        // intact when the cursor crosses them.
        let useCellInvertedCursor = cursorOnScreen && focused && shape == 0
        let blockCursorCell: (row: Int, col: Int)? = useCellInvertedCursor
            ? (row: screenCursorRow, col: snap.cursorCol)
            : nil
        return FrameGeometry(
            viewportPoints: viewportPoints,
            cellSizePoints: cellSizePoints,
            screenCursorRow: screenCursorRow,
            effectiveShape: effectiveShape,
            shape: shape,
            curRow: curRow,
            curCol: curCol,
            prevCursorRow: prevCursorRow,
            prevCursorCol: prevCursorCol,
            cursorMoved: cursorMoved,
            cursorOnScreen: cursorOnScreen,
            useCellInvertedCursor: useCellInvertedCursor,
            blockCursorCell: blockCursorCell
        )
    }

    /// The per-frame rebuild decision produced by `planRowRebuild`: the fresh
    /// `CacheKey` (recorded by `render` only AFTER a committed `buildInstances`,
    /// per H7/S2-007) and the partial-row set (`nil` = full rebuild).
    private struct RebuildPlan {
        let cacheKey: CacheKey
        let partialRows: Set<Int>?
    }

    /// Decide what this frame must rebuild: build the new `CacheKey`, test it
    /// against the cached one (+ row-count + the dirty-rows kill switch), detect a
    /// coalesced-snapshot gap, and resolve the damaged-row set via
    /// `decideRebuildRows`. Pure: it READS skip-cache state but mutates nothing —
    /// `render` records `lastCacheKey` / `lastRenderedSnapshotSeq` only after the
    /// buildInstances commit, preserving the H7/S2-007 ordering.
    private func planRowRebuild(
        snap: BBSnapshot,
        focused: Bool,
        selFields: (mode: UInt8, aLine: Int32, bLine: Int32, aCol: Int32, bCol: Int32),
        blinkSkip: Bool,
        geo: FrameGeometry
    ) -> RebuildPlan {
        // Decide whether to take the partial-rebuild path. The cache is
        // "compatible" when every visible-state input to the row builder matches
        // the prior frame (CacheKey equality). When it matches AND alacritty
        // reports partial damage with a manageable count, we only rebuild the
        // damaged rows — the rest are copied from rowInstanceCache unchanged.
        //
        // The row-count threshold (damage covering ≥ half the screen, applied in
        // `decideRebuildRows`) guards against the case where damage covers most of
        // the screen anyway: the per-row-skip overhead would exceed the savings.
        // Above the threshold, just rebuild everything.
        let newCacheKey = makeCacheKey(
            snap: snap, focused: focused, selFields: selFields,
            effectiveShape: geo.effectiveShape, blinkSkip: blinkSkip
        )
        let cacheCompatible = !debugToggles.dirtyRowsDisabled
            && skipCache.lastCacheKey == newCacheKey
            && skipCache.rowInstanceCache.count == snap.rows

        // Detect coalesced snapshots: `TerminalSession.publishPendingSnapshot`
        // coalesces rapid core snapshots into a single main-thread handoff,
        // dropping intermediate damage info on the floor. `BBSnapshot.sequenceID`
        // is a monotonic per-allocation counter incremented on every
        // `bb_term_take_snapshot`, so a jump of >1 between the previous rendered
        // snapshot and this one means ≥1 intermediate was skipped. The
        // partial-rebuild path keys off `damagedRows`, which alacritty resets on
        // each snapshot take — the skipped rows' damage is gone. Force a full
        // rebuild in that case; the CacheKey stays valid, we just re-walk every
        // row's cells once to catch the lost deltas. Fixes cmatrix / vim / nvim
        // streaming artifacts.
        let snapshotCoalesced: Bool =
            skipCache.lastRenderedSnapshotSeq > 0
            && snap.sequenceID > skipCache.lastRenderedSnapshotSeq + 1

        let partialRows = decideRebuildRows(
            snap: snap,
            cacheCompatible: cacheCompatible,
            snapshotCoalesced: snapshotCoalesced,
            cursorMoved: geo.cursorMoved,
            prevCursorRow: geo.prevCursorRow,
            prevCursorCol: geo.prevCursorCol,
            curRow: geo.curRow
        )
        return RebuildPlan(cacheKey: newCacheKey, partialRows: partialRows)
    }

    /// Decide the partial-rebuild row set for this frame, or nil to force a full
    /// rebuild. nil when the row cache is incompatible (CacheKey mismatch /
    /// disabled / row-count drift — passed in via `cacheCompatible`), when
    /// alacritty reports full damage, when an intermediate snapshot was coalesced
    /// away (its per-row damage is gone), or when damage is empty / covers ≥ half
    /// the screen (per-row-skip overhead would exceed the savings). Otherwise the
    /// damaged rows, plus the rows the cursor just left / moved to (metal-renderer
    /// F3 — pure cursor motion doesn't always flag those, leaving a ghost inverted
    /// cell). Pure given its arguments.
    private func decideRebuildRows(
        snap: BBSnapshot,
        cacheCompatible: Bool,
        snapshotCoalesced: Bool,
        cursorMoved: Bool,
        prevCursorRow: Int32,
        prevCursorCol: Int32,
        curRow: Int32
    ) -> Set<Int>? {
        guard cacheCompatible else { return nil }
        guard !snap.damageIsFull else { return nil }
        guard !snapshotCoalesced else { return nil }
        let damaged = snap.damagedRows
        if damaged.isEmpty || damaged.count >= (snap.rows + 1) / 2 {
            return nil
        }
        var rows = Set(damaged)
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
    }

    /// Encode the cell-instance draw: bind the pipeline, the slot's instance
    /// buffer, frame uniforms, the mono + colour atlases (colour bound
    /// unconditionally so the `BB_ATTR_IS_COLOR_GLYPH` shader branch is
    /// addressable), and draw `instanceCount` instanced quads.
    private func encodeCells(
        encoder: MTLRenderCommandEncoder,
        slot: Int,
        instanceCount: Int,
        viewportPoints: SIMD2<Float>,
        cellSizePoints: SIMD2<Float>
    ) {
        var uniforms = FrameUniforms(
            viewportPx: viewportPoints,
            cellSizePx: cellSizePoints,
            accentColor: themeColors.accentColor
        )
        encoder.setRenderPipelineState(pipelines.pipelineState)
        encoder.setVertexBuffer(ring.instanceBuffers[slot], offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.size, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentTexture(atlas.colorTexture, index: 1)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: instanceCount
        )
    }

    /// Encode the standalone cursor quad (bar / underline / unfocused outline —
    /// the focused block cursor renders via cell inversion, not here). Filled
    /// when focused, hollow when not.
    private func encodeCursor(
        encoder: MTLRenderCommandEncoder,
        snap: BBSnapshot,
        screenCursorRow: Int,
        shape: UInt32,
        viewportPoints: SIMD2<Float>,
        cellSizePoints: SIMD2<Float>,
        focused: Bool
    ) {
        var cu = CursorUniforms(
            viewportPx: viewportPoints,
            cursorPosPx: SIMD2<Float>(Float(snap.cursorCol) * Float(metrics.cellWidth) + insets.leftInsetPoints,
                                      Float(screenCursorRow) * Float(metrics.cellHeight) + insets.topInsetPoints),
            cellSizePx: cellSizePoints,
            color: themeColors.cursorColor,
            strokeWidthPx: 1.0,
            filled: focused ? 1.0 : 0.0,
            shape: shape,
            _pad: 0
        )
        encoder.setRenderPipelineState(pipelines.cursorPipelineState)
        encoder.setVertexBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
        encoder.setFragmentBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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

/// Audit L17. Mirror the `_cellInstanceLayoutPinned` precondition for
/// `CursorUniforms`. Swift inserts 8 bytes of alignment padding before
/// `color: SIMD4<Float>` (which requires 16-byte alignment) — total
/// stride is 64 bytes. The matching `CursorUniforms` struct in
/// `Shaders.metal` (around line 230) MUST stay byte-compatible: a
/// silent field addition on either side scrambles every cursor draw
/// and presents as "cursor renders at wrong screen position with
/// wrong color" — exactly the silent-corruption class the layout pin
/// catches at first render.
///
/// If this fires after a deliberate change: update Shaders.metal's
/// mirror struct first, rebuild, and only then update the constant.
private let _cursorUniformsLayoutPinned: Void = {
    precondition(MemoryLayout<CursorUniforms>.stride == 64,
                 "CursorUniforms stride drifted from the 64-byte contract "
                 + "mirrored in Shaders.metal — update the shader struct "
                 + "BEFORE widening this number. Actual stride: "
                 + "\(MemoryLayout<CursorUniforms>.stride)")
    precondition(MemoryLayout<CursorUniforms>.alignment == 16,
                 "CursorUniforms must keep 16-byte alignment so SIMD4 fields "
                 + "land on Metal's natural alignment.")
}()

@inline(never)
func _pinCursorUniformsLayout() { _ = _cursorUniformsLayoutPinned }
