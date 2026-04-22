import AppKit
import Carbon.HIToolbox
import CoreText
import Combine
import Metal
import MetalKit
#if DEBUG
import os
#endif

/// Fixed-cell metrics derived from a monospaced font.
public struct CellMetrics {
    public let font: NSFont
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(font: NSFont) {
        self.font = font
        let ct = font as CTFont
        self.ascent = CTFontGetAscent(ct)
        self.descent = CTFontGetDescent(ct)
        self.leading = CTFontGetLeading(ct)
        // Floor both metrics at 1pt so downstream grid math and atlas
        // texture sizing never hit a division-by-zero or a zero-sized
        // Metal texture. The settings picker only lists monospace families
        // (for which both dimensions are real positive numbers), but an
        // exotic font or a manually-edited UserDefault can still sneak
        // through and we don't want to crash the app in response.
        //
        // isFinite sanitisation catches NaN/Infinity from a malformed font
        // — rare but not impossible on a user-installed font. max(1, NaN)
        // would produce NaN (NaN propagates through max), which then traps
        // Int(NaN) later in grid(forPixelSize:). Normalise first.
        let rawCellHeight = (ascent + descent + leading).rounded()
        self.cellHeight = rawCellHeight.isFinite ? max(1, rawCellHeight) : 1
        // Measure the advance of 'M' — a reliable monospace cell width.
        var glyph = CGGlyph(0)
        var chars: [UniChar] = [UInt16(("M" as Character).asciiValue ?? 77)]
        CTFontGetGlyphsForCharacters(ct, &chars, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        let rawCellWidth = advance.width.rounded()
        self.cellWidth = rawCellWidth.isFinite ? max(1, rawCellWidth) : 1
    }

    public func grid(forPixelSize size: CGSize) -> (cols: Int, rows: Int) {
        // Defensive: `size` is a CGSize from AppKit bounds in practice,
        // so always finite and within reasonable screen pixel counts.
        // Guard against two pathologies at the `Int(Double)` cast:
        //   1. NaN / ±Infinity traps the cast outright (stray Core
        //      Animation value, misbehaving input device).
        //   2. Finite-but-absurd values (e.g. 1e20) traps because
        //      Int can't hold them.
        // Clamp to a sane pixel count first; clamps apply per-axis
        // so a valid axis keeps its real measurement.
        let sanePx: CGFloat = 1_000_000   // far larger than any real display
        let w = size.width.isFinite ? min(max(0, size.width), sanePx) : 0
        let h = size.height.isFinite ? min(max(0, size.height), sanePx) : 0
        let cols = max(1, Int(w / cellWidth))
        let rows = max(1, Int(h / cellHeight))
        return (cols, rows)
    }
}

/// MTKView that renders a BBSnapshot via Metal and forwards keyboard input
/// through a KeyEncoder to a TerminalSession.
///
/// Plan 3 Task 1: clears to solid black via MetalRenderer. Task 2+ adds
/// shader pipeline, glyph atlas, and per-cell instancing for 120Hz performance.
public final class TerminalView: MTKView, MTKViewDelegate {

    public weak var session: TerminalSession? {
        didSet { subscribeToSession() }
    }

    public let renderer: MetalRenderer
    public private(set) var metrics: CellMetrics
    public private(set) var encoder: KeyEncoder = {
        // Match the user's current Option-key preference on construction so
        // the first keystroke respects it. syncEncoderFromPreferences
        // refreshes this on subsequent changes.
        let isMeta = Preferences.shared.optionKey == .meta
        return KeyEncoder(optionIsMeta: isMeta)
    }()

    private var prefsCancellable: AnyCancellable?

    /// Latest `BBSnapshot` published by the session. Read by the renderer
    /// path, the accessibility cache, and the IME extension (which needs
    /// the cursor coordinates for the candidate-window anchor). Internal
    /// so the `TerminalView+IME.swift` extension can see it; no setter is
    /// exposed — `render(snapshot:)` is the only writer.
    ///
    /// The `didSet` invalidates `a11yCache` on every swap. The cache is
    /// keyed on `BBSnapshot.a11yIdentity`, which is a raw pointer into the
    /// FFI's heap — after the old snapshot is released, the allocator is
    /// free to hand the same slab back to the next snapshot (ABA). Without
    /// this reset, `accessibilityValue()` could hit the old cache and
    /// return stale text that the grid no longer contains (VoiceOver would
    /// read content the user is no longer seeing).
    var currentSnapshot: BBSnapshot? {
        didSet {
            a11yCache.snapshotIdentity = nil
            // Find-match coordinates are relative to the buffer at the
            // time performSearch ran. Any snapshot swap may have scrolled
            // history, wrapped lines, or overwritten matched rows; rerun
            // the search against the fresh grid so ⌘G cycles live hits
            // instead of ghost rows. Debounce via the displaylink so a
            // burst of snapshots collapses to one re-scan. Audit
            // findbar-selection F11.
            if findBar != nil, !findQuery.isEmpty {
                scheduleFindRefresh()
            }
        }
    }

    /// Track that a find-refresh is pending so concurrent snapshot bursts
    /// collapse to one main-queue dispatch.
    private var findRefreshPending: Bool = false

    private func scheduleFindRefresh() {
        guard !findRefreshPending else { return }
        findRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.findRefreshPending = false
            // Query could have been cleared by the time the dispatch fires
            // (FindBar closed, user cleared the field). Early-return then.
            guard !self.findQuery.isEmpty, self.findBar != nil else { return }
            self.performSearch(query: self.findQuery)
        }
    }
    /// Optional test-only override that feeds the NSAccessibility value
    /// path without a real `BBTerm`. Production never sets this — the live
    /// render path uses `currentSnapshot`.
    #if DEBUG
    private var a11ySnapshotOverride: A11ySnapshotSource?
    /// Test-only override for the ⌘-click URL resolver. When set, the click
    /// path goes through this fake instead of building a
    /// `SnapshotHyperlinkResolver` from `currentSnapshot`. Production leaves
    /// it nil.
    private var hyperlinkResolverOverride: HyperlinkResolver?
    #endif

    /// Hook for opening a URL on ⌘-click. Production hands the URL to
    /// `NSWorkspace`; tests inject a recording fake so assertions can
    /// match what the click path actually dispatched.
    var urlOpener: URLOpener = DefaultURLOpener()

    // MARK: - Hover state (OSC 8 dwell tooltip + hover underline)

    /// Buffer row under the cursor on the last `mouseMoved` delivery, used
    /// to cancel the dwell timer as soon as the pointer leaves the current
    /// cell. `nil` means the pointer is outside the grid.
    private var lastHoverCell: (row: Int, col: Int)?
    /// Link id under the pointer right now, or 0 when the hovered cell has
    /// no OSC 8 attribution. The renderer reads this each frame to draw
    /// the accent underline on every cell sharing the id.
    private var hoveredLinkID: UInt32 = 0
    /// Trackpad pinch gesture accumulator. Magnification events deliver
    /// fractional deltas; we wait until the running sum crosses ±0.15
    /// before bumping `Preferences.shared.fontSize`. Without the accumulator
    /// a single flick would fire dozens of font-size changes and fly past
    /// the intended zoom level.
    private var pinchAccumulator: CGFloat = 0
    /// Scheduled tooltip reveal. Cancelled on pointer movement, scroll,
    /// keydown, or view teardown.
    private var hoverTooltipItem: DispatchWorkItem?
    /// Lightweight panel that shows the resolved URL after the 500 ms dwell.
    /// Kept around between shows so repeated hovers don't thrash NSPanel
    /// allocation; hidden when not in use.
    private var hoverTooltipPanel: NSPanel?
    private var hoverTooltipLabel: NSTextField?
    /// Tracking area that delivers `mouseMoved` / `mouseExited`. Rebuilt on
    /// bounds changes via `updateTrackingAreas`.
    private var hoverTrackingArea: NSTrackingArea?
    private var cancellables: [AnyCancellable] = []
    private let scrollIndicator = ScrollIndicator(frame: .zero)

    /// Active IME composition buffer. Non-nil while the user is in a
    /// `setMarkedText` → `insertText`/`unmarkText` cycle. The NSTextInputClient
    /// conformance lives in `TerminalView+IME.swift`; this property is the
    /// one piece of shared state keyDown and the IME path both inspect.
    var composition: TerminalView.Composition?
    /// Flag raised by `insertText(_:)` for the duration of a single
    /// `keyDown(with:)` pass. Lets keyDown tell "the IME already committed
    /// bytes for this event" apart from "no IME activity at all" after
    /// `inputContext?.handleEvent` returns — in the former case we must
    /// NOT fall through to the encoder path or the shell would see the
    /// character twice. Cleared at the top of keyDown.
    var didInsertTextViaIME: Bool = false
    /// CALayer-backed subview that paints the in-flight preedit glyphs plus
    /// a dotted underline. Created lazily when composition starts; removed
    /// when the user commits or cancels so idle sessions keep a clean tree.
    var preeditOverlay: PreeditOverlayView?

    #if DEBUG
    /// Optional PTY-byte recorder for tests. When set, `sendToSession(_:)`
    /// appends here instead of calling through to the real PTY — lets the
    /// IME tests assert exactly which commits reach the shell.
    var ptyRecorderForTests: RecordingPTY?
    /// Overrides the cursor coordinates that the IME path reads from the
    /// snapshot. Lets `testFirstRectReturnsCursorCellRect` pin a specific
    /// (row, col) without feeding the full BBTerm state machine.
    var cursorOverrideForTests: (row: Int, col: Int)?
    /// Optional byte-capture closure for the replace path. When set,
    /// `sendReplacement` appends bytes here instead of calling `session.send`.
    /// Lets integration tests assert the exact DEL×N + replacement byte
    /// sequence without a real PTY.
    var replaceByteCapture: ((Data) -> Void)?
    /// Test-only snapshot override for the replace path. When set, replace
    /// helpers read cursor position from this value instead of `currentSnapshot`.
    var replaceSnapshotForTests: BBSnapshot?
    /// Test-only find-matches override for the replace path.
    var replaceFindMatchesForTests: [(line: Int32, startCol: Int, endCol: Int)]?
    #endif

    private final class FlashView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let bellFlashView: FlashView = {
        let v = FlashView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.alphaValue = 0
        return v
    }()
    private var lastBellCounter: UInt64 = 0

    public private(set) var selection: Selection? {
        didSet {
            if oldValue != selection { setNeedsDisplay(bounds) }
        }
    }
    private var isDragging = false

    private var findBar: FindBar?
    private var findMatches: [(line: Int32, startCol: Int, endCol: Int)] = []
    private var findCurrentIndex: Int = 0
    private var findQuery: String = ""

    /// True while an active drag with file URLs is hovering the view. Drives
    /// the accent-coloured drop-target ring. Set by the NSDraggingDestination
    /// callbacks in TerminalView+Dragging.swift.
    var isDropTargeted: Bool = false {
        didSet {
            guard oldValue != isDropTargeted else { return }
            dropHighlightView.isHidden = !isDropTargeted
        }
    }

    /// Accent-coloured border overlay shown while a file drag is hovering.
    /// Implemented as an NSBox rather than a Metal draw because the view is
    /// an MTKView — compositing an AppKit child over the Metal layer is
    /// simpler, hit-transparent, and cheap to show/hide on a dragging
    /// enter/exit event. Sized in `layout()`; initially hidden.
    private let dropHighlightView: NSBox = {
        let b = NSBox(frame: .zero)
        b.boxType = .custom
        b.borderType = .lineBorder
        b.borderColor = .controlAccentColor
        b.borderWidth = 2
        b.cornerRadius = 4
        b.fillColor = .clear
        b.titlePosition = .noTitle
        b.isHidden = true
        return b
    }()

    #if DEBUG
    private var frameCount = 0
    private var lastFrameLogTime = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval = 0
    private var frameIntervalMinMs: Double = .infinity
    private var frameIntervalMaxMs: Double = 0
    private var frameIntervalSumMs: Double = 0
    // `os.Logger` (not `NSLog`) so `privacy: .public` markers on string
    // interpolations actually take effect — NSLog builds its format string
    // at runtime, which defeats the compile-time qualifier and redacts the
    // entire message as `<private>` in the unified log.
    private static let fpsLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                          category: "fps")
    /// Companion to `fpsLogger` for the keyDown debug breadcrumbs. Same
    /// readability rationale: NSLog redacted these to `<private>` so a
    /// `log stream` filter on the keyboard category produced unreadable
    /// lines. Routing through `os.Logger` with explicit `privacy: .public`
    /// keeps the keystroke trail visible in Console.
    private static let keyLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                          category: "keyboard")
    #endif

    public init(frame frameRect: NSRect, device: MTLDevice) {
        // TerminalView is the authoritative owner of CellMetrics; the renderer
        // shares this same instance so layout and rendering never diverge.
        let prefs = Preferences.shared
        let font = Self.resolveFont(name: prefs.fontName, size: CGFloat(prefs.fontSize))
        let metrics = CellMetrics(font: font)
        // The atlas rasterizes glyphs at pixel resolution for sharp text on
        // Retina displays. Use the primary screen's scale at construction;
        // if the window later moves to a display with a different scale the
        // atlas will still render correctly (linear filtering covers mild
        // upsampling), just without re-rasterizing at the new resolution.
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        guard let renderer = MetalRenderer(device: device, metrics: metrics, scale: scale) else {
            fatalError("Metal device could not produce a command queue")
        }
        self.renderer = renderer
        self.metrics = metrics
        super.init(frame: frameRect, device: device)
        self.delegate = self
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Must match the render pipeline's colorAttachments[0].pixelFormat
        // set up by MetalRenderer (Task 2+).
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        // MTKView's internal CVDisplayLink drives `draw(in:)` at the screen's
        // vblank rate. On a 60 Hz display that's 60 fps; on a ProMotion panel
        // we'd *like* 120 fps but empirically macOS's coalescer refuses to
        // promote the display for this workload no matter which API we use
        // to request it — `preferredFramesPerSecond = 120`, `NSView.
        // displayLink` / `NSWindow.displayLink` / `NSScreen.displayLink`
        // with `preferredFrameRateRange = (80,120,120)` (or strict
        // (120,120,120)) all fire every *other* vblank on the built-in
        // Liquid Retina XDR (8.33 ms link.duration, 16.67 ms actual spacing).
        // The DEBUG fps diagnostic below is a standing regression sensor:
        // if a future macOS or a config change ever does promote us, we'll
        // see mean interval drop to ~8.3 ms without code changes here.
        self.preferredFramesPerSecond = 120
        // Drawable-pool sizing. Apple's default is 3. An earlier iteration
        // set this to 2 on the theory that fewer drawables = lower latency,
        // but in practice macOS's display-coalescer appears to read the
        // 2-deep pool as "this app isn't keeping up" and never promotes
        // the compositor to 120 Hz on ProMotion panels — the fps
        // diagnostic (logged every second in DEBUG) stuck at 60 regardless
        // of which display-link API we used to request 120. Ghostty uses
        // 3 and gets 120; trying that here. The third drawable is one
        // frame of headroom for the ring in `MetalRenderer`; with
        // `presentsWithTransaction = false` it does NOT add input-to-
        // pixel latency (CAMetalLayer only queues the most recent pending
        // present when the display-link fires). Keep `displaySyncEnabled`
        // on so we never tear; a future path can flip it off for the
        // duration of a cat / log-tail burst if it proves worth it.
        if let metalLayer = self.layer as? CAMetalLayer {
            metalLayer.maximumDrawableCount = 3
            metalLayer.displaySyncEnabled = true
            // Pin the colorspace to sRGB so Display P3 panels don't
            // reinterpret our 8-bit RGB values in P3-native primaries
            // (reds +~30% saturated, greens shifted). Audit metal-renderer
            // F10. The pixel format is `.bgra8Unorm` (not `_srgb`), so the
            // shader operates in gamma-encoded space by design — matching
            // Terminal.app / Alacritty's effective behavior. If a future
            // commit flips to `_srgb` with linear shader math, this
            // colorspace must track (sRGB decode is the matching choice).
            metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        // Minimal right-edge scroll indicator (pass-through hit testing —
        // never swallows mouse events). Positioned in layout() so it tracks
        // the bottom inset shared with the grid.
        addSubview(scrollIndicator)

        bellFlashView.frame = bounds
        bellFlashView.autoresizingMask = [.width, .height]
        addSubview(bellFlashView)

        // Drop-target ring sits on top of the bell flash so a dropped file
        // feedback never gets visually swamped by a simultaneous ^G bell.
        // Autoresizes with the view so layout() only adjusts explicit frames.
        dropHighlightView.frame = bounds
        dropHighlightView.autoresizingMask = [.width, .height]
        addSubview(dropHighlightView)

        prefsCancellable = Preferences.shared.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.syncFontFromPreferences()
                    self?.syncEncoderFromPreferences()
                }
            }

        // Push the system accent into the renderer immediately so the
        // hyperlink hover underline matches whatever accent the user
        // picked in System Settings — not the hardcoded macOS Blue that
        // the renderer defaults to. The drop-target ring (`dropHighlightView`
        // above) already follows `NSColor.controlAccentColor`; without
        // this we'd paint two different "accents" in the same window.
        pushSystemAccentToRenderer()
        // Observe accent changes so Settings → Appearance → Accent swap
        // reflects live. The accent observer is process-global (not bound
        // to any specific window), so it lives in `accentObservers` — a
        // dedicated array that survives `viewDidMoveToWindow` (which tears
        // down and rebuilds `focusObservers` to re-bind to the new window).
        // Otherwise, the first re-parenting — e.g. dragging a tab out to a
        // new window — would silently drop accent tracking everywhere.
        accentObservers.append(NotificationCenter.default.addObserver(
            forName: NSColor.systemColorsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pushSystemAccentToRenderer()
            self.needsDisplay = true
        })
    }

    /// Read `NSColor.controlAccentColor`, convert to sRGB, and hand the
    /// components to the renderer as the accent uniform. Falls back to
    /// the macOS Blue sRGB values if the accent colour can't be
    /// represented in sRGB for some reason — matches what the renderer
    /// defaults to anyway.
    private func pushSystemAccentToRenderer() {
        let sRGB = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        let r = Float(sRGB?.redComponent ?? 0.0)
        let g = Float(sRGB?.greenComponent ?? 0.48)
        let b = Float(sRGB?.blueComponent ?? 1.0)
        let a = Float(sRGB?.alphaComponent ?? 1.0)
        renderer.setAccentColor(rgba: SIMD4<Float>(r, g, b, a))
    }

    /// Rebuild the KeyEncoder if the user flipped Option between Meta and
    /// Native. Cheap (one ref + Bool) so we call it on every preference
    /// emission; the actual rebuild only happens when optionIsMeta differs
    /// from the current encoder's setting.
    private func syncEncoderFromPreferences() {
        let wantMeta = Preferences.shared.optionKey == .meta
        if encoder.optionIsMeta != wantMeta {
            encoder = KeyEncoder(optionIsMeta: wantMeta)
        }
    }

    /// Rebuild metrics/atlas when Preferences.fontName or fontSize changes.
    /// Called on every objectWillChange emission; compares against the
    /// currently-applied font to avoid redundant atlas rebuilds.
    private func syncFontFromPreferences() {
        let p = Preferences.shared
        let wantName = p.fontName
        let wantSize = CGFloat(p.fontSize)
        if metrics.font.familyName == wantName && metrics.font.pointSize == wantSize {
            return
        }
        let newFont = Self.resolveFont(name: wantName, size: wantSize)
        let newMetrics = CellMetrics(font: newFont)
        // Rasterise at the window's current screen's scale — not the primary
        // screen's. Otherwise a Blackbird window sitting on a 1x external
        // display would re-atlas at 2x (from the Retina primary) and glyphs
        // would be drawn oversampled, then downsampled in the compositor for
        // a faintly blurry look. drawableSizeWillChange corrects this on
        // display migration; doing it up front at the font-change path keeps
        // the initial atlas sharp for users who never drag across displays.
        let scale = window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        // Only commit the new metrics if the renderer actually rebuilt its
        // atlas; otherwise grid math and glyph rasterisation would drift
        // apart (cells laid out at new size but drawn with an old-size
        // atlas → smeared / wrong-sized glyphs).
        guard renderer.reconfigure(metrics: newMetrics, scale: scale) else { return }
        self.metrics = newMetrics
        if let window {
            // Window resize increments should follow the new cell size too.
            window.contentResizeIncrements = NSSize(
                width: newMetrics.cellWidth,
                height: newMetrics.cellHeight
            )
            // Keep contentMinSize in sync. Otherwise bumping the font up
            // doesn't prevent the user from dragging the window below the
            // new font's 20-col / 4-row minimum — they'd end up with a
            // window too small to read comfortably.
            window.contentMinSize = NSSize(
                width: newMetrics.cellWidth * 20,
                height: newMetrics.cellHeight * 4 + 28 + Self.bottomContentInsetPoints
            )
        }
        // Force a grid recomputation on the next layout — propagateResize
        // compares against lastPropagatedSize, so clear it.
        lastPropagatedSize = nil
        propagateResize()
        // Re-layout the scroll indicator (its Y depends on cellHeight).
        needsLayout = true
    }

    /// Top chrome height that excludes AppKit's phantom reservation for
    /// the suppressed native tab bar. Uses `NSWindow.frameRect(forContentRect:
    /// styleMask:)` on the window's real style mask minus `.fullSizeContentView`
    /// — the delta between that and the window's content-view height is the
    /// pure titlebar offset.
    var titlebarOnlyTopInset: CGFloat {
        guard let window else { return 28 }
        var maskWithoutFullSize = window.styleMask
        maskWithoutFullSize.remove(.fullSizeContentView)
        let contentRectForStyle = NSWindow.contentRect(
            forFrameRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: maskWithoutFullSize
        )
        let titlebar = 100 - contentRectForStyle.height
        return max(22, titlebar)
    }

    public override func layout() {
        super.layout()
        let bottom = Self.bottomContentInsetPoints
        let top = titlebarOnlyTopInset
        renderer.setTopInsetPoints(Float(top))
        let width: CGFloat = 10
        scrollIndicator.frame = NSRect(
            x: bounds.width - width,
            y: bottom,
            width: width,
            height: max(0, bounds.height - bottom - top)
        )
        // Re-anchor the IME preedit overlay to the current cursor cell
        // whenever our bounds change — a window resize mid-composition
        // would otherwise leave the overlay stranded at stale pixel
        // coordinates until the user committed or cancelled.
        if composition != nil {
            refreshPreeditOverlay()
        }
    }


    public required init(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    /// NSView's default returns `true` when the view is non-opaque — and our
    /// MTKView is non-opaque whenever the user enables translucency, so by
    /// default AppKit quietly converts every click-drag inside the terminal
    /// into a window drag (mouseDown still fires, but the first mouseDragged
    /// is intercepted). Pin this to `false` so click-drag always reaches
    /// `mouseDragged(with:)` for text selection; explicit ⌘-drag still moves
    /// the window via `performDrag(with:)` in `mouseDown`.
    public override var mouseDownCanMoveWindow: Bool { false }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // Drag ended — commit the real grid size now. The renderer's stretched
        // viewport (used during drag) flips back to the bounds-based viewport
        // on the next frame, and the shell gets a single SIGWINCH to the
        // final dimensions.
        propagateResize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Propagate to the session on every frame-size change. During live
        // resize this fires many times per second; propagateResize's
        // lastPropagatedSize dedup skips calls that didn't cross a cell
        // boundary. Programmatic / zoom / first-appear paths also land
        // here.
        propagateResize()
    }

    private var lastPropagatedSize: PTY.Size?
    private var lastSafeAreaTop: Float = -1

    /// Space reserved at the bottom of the view so the last grid row never
    /// runs into the window's rounded corner. macOS window corner radius is
    /// ~10 pt; keep the bottom row one cell-height above so descenders and
    /// block cursors clear comfortably. Matches the feel of Terminal.app and
    /// iTerm2, which both leave breathing room below the prompt.
    public static let bottomContentInsetPoints: CGFloat = 10

    private func propagateResize() {
        guard let session else { return }
        // `.fullSizeContentView` means our bounds include the titlebar region —
        // subtract it (via titlebarOnlyTopInset) so we don't size the grid as
        // though we had titlebar-height extra rows of real estate.
        let usableHeight = max(
            metrics.cellHeight,
            bounds.height - titlebarOnlyTopInset - Self.bottomContentInsetPoints
        )
        let grid = metrics.grid(forPixelSize: CGSize(width: bounds.width, height: usableHeight))
        guard grid.cols > 0, grid.rows > 0 else { return }
        // `grid` is bounded by CellMetrics.sanePx (1M px / min cell size),
        // so in theory cols/rows can exceed UInt16.max on a degenerate
        // combination (1×1 cell on a 1 Mpx viewport). `clamping:` avoids
        // the trap; TerminalSession.resize clamps again to ≤1000 so the
        // real dimensions never go past the grid allocator's ceiling.
        let size = PTY.Size(
            cols: UInt16(clamping: grid.cols),
            rows: UInt16(clamping: grid.rows)
        )
        guard size != lastPropagatedSize else { return }
        lastPropagatedSize = size
        // TerminalSession.resize is synchronous — returns after the snapshot
        // is in place so the next MTKView frame renders at the new size.
        session.resize(to: size)
    }

    // MARK: - Rendering

    public func applyTheme(_ palette: ThemePalette) {
        let bgR = Double((palette.background >> 16) & 0xFF) / 255.0
        let bgG = Double((palette.background >> 8)  & 0xFF) / 255.0
        let bgB = Double(palette.background & 0xFF) / 255.0
        let (opacity, blurRadius) = Preferences.shared.translucencyResolved
        // clearColor gets the theme bg at user opacity. Cells with default bg
        // skip their bg quad (in buildInstances) so clearColor shows — that's
        // where the desktop bleed-through happens.
        clearColor = MTLClearColor(red: bgR, green: bgG, blue: bgB, alpha: opacity)
        themeDefaultBgRgb = palette.background
        themeDefaultFgRgb = palette.foreground
        renderer.setDefaultBgRgb(palette.background)
        renderer.setCursorColor(rgb: palette.cursor)
        // Single slider — explicit colors (status lines, highlights) fade
        // with the window. Users who want solid highlights just lower
        // translucency.
        renderer.setBackgroundOpacity(Float(opacity), keepBgOpaque: false)
        renderer.setCursorBlinkEnabled(Preferences.shared.cursorBlink)
        renderer.setCursorShapeOverride(Preferences.shared.cursorShape.rendererOverride)
        setWindowAppearance(opacity: opacity, themeBg: (bgR, bgG, bgB))
        window?.setBackgroundBlurRadius(blurRadius)
        // If an IME composition is in flight when the theme changes, repaint
        // the preedit overlay so its fg/bg track the new palette. Without
        // this the overlay holds its pre-change colours until the next
        // setMarkedText/insertText callback — visible to anyone mid-kana
        // composition at the moment they toggle light/dark.
        if composition != nil {
            refreshPreeditOverlay()
        }
    }

    /// Theme's default background RGB, captured so the renderer can skip
    /// drawing a bg quad for cells at the default bg (they inherit the
    /// transparent clearColor). Internal so `TerminalView+IME.swift`'s
    /// preedit-overlay path can render against the same theme bg that
    /// committed text will land on.
    var themeDefaultBgRgb: UInt32 = 0x000000

    /// Theme's default foreground RGB. Cached so the IME preedit overlay
    /// can render composing glyphs in the same colour committed text will
    /// land in, rather than AppKit's `.labelColor` (which ignores the
    /// Blackbird theme and flips to white on dark system appearance even
    /// under a light theme).
    var themeDefaultFgRgb: UInt32 = 0xFFFFFF

    private func setWindowAppearance(opacity: Double, themeBg: (r: Double, g: Double, b: Double)) {
        let transparent = opacity < 0.999
        layer?.isOpaque = !transparent
        guard let window else { return }
        window.isOpaque = !transparent
        // Always strip the titlebar material — even at fully opaque. If we
        // let AppKit draw its default chrome over the top, it reads as a
        // separate lighter bar against the Metal-tinted body. With it off,
        // the full-size content view's Metal clearColor fills the titlebar
        // region too, continuous with the body. Traffic lights and the
        // title text still render on top as usual.
        window.titlebarAppearsTransparent = true
        // Paint backgroundColor with the same tint the Metal clearColor
        // uses, so any pre-first-frame or resize-tear area matches instead
        // of flashing to NSWindow's default gray.
        window.backgroundColor = NSColor(
            calibratedRed: themeBg.r,
            green: themeBg.g,
            blue: themeBg.b,
            alpha: opacity
        )
        // Pin the window's effective appearance to the theme's lightness, not
        // the OS's. Otherwise the title text (drawn by AppKit in labelColor)
        // and the traffic-light tinting follow the OS appearance — a dark
        // theme under Light OS mode renders a dark title on a dark bg and
        // the title becomes unreadable. Rec. 709 luminance on the theme bg
        // picks dark vs light; AppKit then handles the label + chrome
        // coloring automatically.
        let luminance = 0.2126 * themeBg.r + 0.7152 * themeBg.g + 0.0722 * themeBg.b
        window.appearance = NSAppearance(named: luminance > 0.5 ? .aqua : .darkAqua)
    }

    public func render(snapshot: BBSnapshot) {
        let wasFocusMode = currentSnapshot?.termMode.contains(.focusInOut) ?? false
        let nowFocusMode = snapshot.termMode.contains(.focusInOut)
        self.currentSnapshot = snapshot
        // MTKView redraws on CADisplayLink cadence; no needsDisplay needed.
        // Scroll indicator consumes the same snapshot — keep it in lockstep
        // with the grid so a sudden `clear` or big output reshapes the thumb
        // on the frame the viewport itself changes.
        scrollIndicator.update(
            displayOffset: snapshot.displayOffset,
            historySize: snapshot.historySize,
            rows: snapshot.rows
        )
        // Paint OSC 133 prompt ticks along the track so the user can see
        // at a glance how far apart their prompts are (and how far up
        // they've scrolled). No-op when the shell isn't sourcing the
        // integration snippet — promptMarks stays empty.
        if let s = session {
            scrollIndicator.updatePromptMarks(
                s.promptMarks,
                historySize: snapshot.historySize,
                rows: snapshot.rows,
                accentColor: NSColor.controlAccentColor
            )
        }
        // Shell just enabled DECSET 1004 (focus events). If the window is
        // already key — typical: vim's init.vim or tmux's .conf flips this
        // on before the user interacts — notify the app of current focus
        // state. Without this, the "first" focus event the app sees is the
        // next NSWindow.didResignKey, which misregisters the initial state.
        if !wasFocusMode, nowFocusMode, window?.isKeyWindow == true {
            sendFocusEventIfNeeded(gained: true)
        }
    }

    private var focusObservers: [NSObjectProtocol] = []

    /// Observers for OS-level state that affects the target frame rate:
    /// `isLowPowerModeEnabled`, thermal state, and window occlusion.
    /// Kept separate from `focusObservers` so the two reset cycles in
    /// `viewDidMoveToWindow` don't cross-contaminate (power/thermal
    /// observers are process-global and don't re-register on window
    /// swap; occlusion observers bind to the current window and do).
    private var powerObservers: [NSObjectProtocol] = []
    private var occlusionObservers: [NSObjectProtocol] = []

    /// Process-global observers that must survive re-parenting between
    /// windows. `viewDidMoveToWindow` unconditionally tears down
    /// `focusObservers`; anything we want to keep live across a tab-drag-out
    /// / window-swap goes here and is torn down only in `deinit`.
    ///
    /// Currently holds the `NSColor.systemColorsDidChangeNotification`
    /// observer that drives the live accent-colour push into the renderer.
    private var accentObservers: [NSObjectProtocol] = []

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // Drop the hover tooltip before the window reference changes. The
        // panel is parented to the current window; leaving it up across a
        // reparent lands it at stale coordinates (and, if the old window
        // is being torn down, against a freed NSWindow). Audit
        // terminal-view-2 F19.
        hoverTooltipItem?.cancel()
        hoverTooltipItem = nil
        hoverTooltipPanel?.orderOut(nil)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Register every time the view attaches to a new window — AppKit
        // doesn't carry dragging-destination registration across window
        // moves reliably, and this is idempotent so repeated calls are safe.
        // The NSDraggingDestination conformance lives in
        // TerminalView+Dragging.swift.
        registerForDraggedTypes([.fileURL])
        #if DEBUG
        if let screen = window?.screen {
            // `maximumFramesPerSecond` is the panel's native ceiling (60 on
            // standard Retina, 120 on ProMotion). Logged once per window
            // attach so the periodic fps line below can be sanity-checked
            // against the expected rate.
            let maxFPS = screen.maximumFramesPerSecond
            Self.fpsLogger.log("attached to screen '\(screen.localizedName, privacy: .public)' @ \(maxFPS, privacy: .public) Hz max")
        }
        #endif

        // Tear down any stale focus observers (e.g. view moved between
        // windows), then re-attach to the new window. Focus-event reporting
        // requires us to notify the shell/TUI with CSI I / CSI O every time
        // this tab becomes key or resigns key — but only while the app has
        // enabled mode 1004.
        for token in focusObservers {
            NotificationCenter.default.removeObserver(token)
        }
        focusObservers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        focusObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.sendFocusEventIfNeeded(gained: true)
            self?.enableSecureEventInputIfNeeded()
        })
        focusObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.sendFocusEventIfNeeded(gained: false)
            self?.disableSecureEventInputIfHeld()
            // Tear down any in-flight IME composition so a stale preedit
            // can't commit into the next-focused terminal on Cmd-Tab. See
            // `discardCompositionOnResignKey()` for the rationale.
            self?.discardCompositionOnResignKey()
        })
        #if DEBUG
        // Window-attach logging (above) fires once per view⇄window pairing,
        // not when the user drags the window between displays — the view's
        // `window` property doesn't change on a screen move. Observe the
        // window's own screen-change notification so the DEBUG fps log can
        // be sanity-checked against whichever display the view is actually
        // presenting on right now.
        focusObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self, let screen = self.window?.screen else { return }
            Self.fpsLogger.log("window moved to screen '\(screen.localizedName, privacy: .public)' @ \(screen.maximumFramesPerSecond, privacy: .public) Hz max")
        })
        #endif

        // Rebuild every frame-rate-related observer from scratch. Each
        // viewDidMoveToWindow may cross a screen boundary (different
        // nativeMaxFPS), a window change (different occlusionState
        // source), or a re-attach after some other view moved between
        // windows. Simplest correct behavior: tear down, rebuild.
        for token in powerObservers {
            NotificationCenter.default.removeObserver(token)
        }
        powerObservers.removeAll()
        for token in occlusionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        occlusionObservers.removeAll()

        // Window-bound: occlusion + screen-change both affect the
        // target rate via `applyPowerAwareFrameRate`.
        occlusionObservers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })
        occlusionObservers.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })

        // Process-global: low-power mode + thermal state.
        powerObservers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })
        powerObservers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyPowerAwareFrameRate()
        })

        // Seed the rate from current state rather than waiting for a
        // first notification that may never fire in a short session.
        applyPowerAwareFrameRate()
    }

    /// Asymmetric hysteresis on thermal-driven frame-rate throttling.
    /// `.fair` is the boundary state macOS toggles between when sampling
    /// drifts around a warmth threshold — without a guard, the fps would
    /// pulse 120 → 30 → 120 several times per minute on a machine hovering
    /// near the edge. Once we've throttled, require `.nominal` (not just
    /// `.fair`) to come back up; once unthrottled, require `.serious` or
    /// worse to throttle. `.fair` is a no-op in either direction.
    /// Audit latency-power F5.
    private var isThermalThrottled: Bool = false

    /// Read current NSProcessInfo + occlusion state, compute the
    /// target frame rate via `preferredFrameRate(...)`, and apply it
    /// to this MTKView. Safe to call from any notification handler.
    private func applyPowerAwareFrameRate() {
        let info = ProcessInfo.processInfo
        let isOccluded: Bool = {
            guard let window else { return false }
            return !window.occlusionState.contains(.visible)
        }()
        let nativeMax = window?.screen?.maximumFramesPerSecond ?? 60
        // Apply thermal hysteresis before consulting preferredFrameRate:
        // the pure function reacts to `.serious`/`.critical`, so we stretch
        // the observed state to `.serious` while throttled until we see a
        // definite `.nominal` return, and vice-versa for promotion.
        let rawThermal = info.thermalState
        let effectiveThermal: ProcessInfo.ThermalState
        switch rawThermal {
        case .nominal:
            isThermalThrottled = false
            effectiveThermal = .nominal
        case .fair:
            // No transition: preserve the current throttled state. Report
            // the pure function whatever keeps the output stable.
            effectiveThermal = isThermalThrottled ? .serious : .fair
        case .serious, .critical:
            isThermalThrottled = true
            effectiveThermal = rawThermal
        @unknown default:
            effectiveThermal = rawThermal
        }
        let target = preferredFrameRate(
            isOccluded: isOccluded,
            isLowPowerMode: info.isLowPowerModeEnabled,
            thermalState: effectiveThermal,
            nativeMaxFPS: nativeMax
        )
        switch target {
        case .paused:
            self.isPaused = true
        case .fps(let n):
            self.preferredFramesPerSecond = n
            self.isPaused = false
        }
    }

    deinit {
        for token in focusObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in powerObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in occlusionObservers {
            NotificationCenter.default.removeObserver(token)
        }
        for token in accentObservers {
            NotificationCenter.default.removeObserver(token)
        }
        // Tear down any pending hover tooltip. The DispatchWorkItem
        // captures self weakly so it won't crash on late fire, but the
        // panel would otherwise linger briefly after the view is gone.
        hoverTooltipItem?.cancel()
        hoverTooltipPanel?.orderOut(nil)
        // Release our EnableSecureEventInput refcount if the window
        // closed while still key. Without this pair, secure-input mode
        // leaks system-wide until the next reboot.
        disableSecureEventInputIfHeld()
    }

    /// Whether THIS view currently owns a matched `EnableSecureEventInput`
    /// refcount. Flipped on window-key gain / loss so the Disable call is
    /// paired 1:1 with the Enable — mismatched refcounts at app quit would
    /// leak secure-input mode system-wide until a reboot.
    private var ownsSecureInput: Bool = false

    /// Ask the OS to route keyboard events exclusively to the focused
    /// process (us). Other apps — keyloggers, TextExpander, Keyboard
    /// Maestro, AX-based automation — stop seeing keystrokes directed at
    /// the terminal. The cost is real: legitimate productivity tools stop
    /// working while focus is here. Terminal.app and iTerm2 both enable
    /// this by default because a shell prompt takes passwords (sudo, ssh,
    /// gpg unlock, 1Password CLI) and that content must not be
    /// observable by user-land peers.
    ///
    /// `EnableSecureEventInput` is refcounted by the OS; pair every Enable
    /// with exactly one Disable on blur so multi-window setups don't drift.
    private func enableSecureEventInputIfNeeded() {
        guard !ownsSecureInput else { return }
        EnableSecureEventInput()
        ownsSecureInput = true
    }

    /// Release our refcount, if any. Safe to call more than once — the
    /// `ownsSecureInput` flag prevents a double-release that would under-
    /// counts the global state and disable secure input system-wide.
    ///
    /// Audit terminal-view-1 F16: macOS refcounts per-process so the OS
    /// auto-releases on process exit, but `deinit` isn't guaranteed to
    /// run during termination and a pending modal (e.g. the close-confirm
    /// alert) can delay Disable past the next user action. Public so
    /// AppDelegate can call it from `applicationWillTerminate` as
    /// defence-in-depth.
    public func disableSecureEventInputIfHeld() {
        guard ownsSecureInput else { return }
        DisableSecureEventInput()
        ownsSecureInput = false
    }

    /// xterm focus-in/out reports. Enabled by the running program via
    /// DECSET 1004; tmux, neovim's `FocusGained/FocusLost` autocmds, and
    /// some shells (zsh vi-mode helpers) lean on this to refresh state
    /// exactly when the user's attention moves.
    private func sendFocusEventIfNeeded(gained: Bool) {
        guard let session,
              currentSnapshot?.termMode.contains(.focusInOut) == true
        else { return }
        // CSI I on focus gain, CSI O on focus loss. Two bytes after ESC [.
        let final: UInt8 = gained ? 0x49 : 0x4F    // 'I' / 'O'
        session.send(Data([0x1B, 0x5B, final]))
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // setFrameSize + viewDidEndLiveResize own the points-based resize
        // path; we mustn't double-fire SIGWINCH from here (zoom button etc.).
        // What this callback IS good for: detecting a backing-scale change,
        // which happens when the window moves between displays of different
        // densities (1x external, 2x Retina, 3x Liquid Retina XDR, etc.).
        // Re-rasterise the atlas at the new pixel resolution so glyphs stay
        // sharp on the new display. Do nothing if the scale hasn't moved.
        guard bounds.width > 0 else { return }
        let newScale = size.width / bounds.width
        guard newScale > 0 else { return }
        if abs(newScale - renderer.atlas.scale) > 0.01 {
            // Check the return value the same way syncFontFromPreferences
            // does — a failed reconfigure (e.g. MTLDevice couldn't
            // allocate a bigger atlas texture on a hot-unplugged
            // display) leaves the renderer in its previous state and
            // should be surfaced rather than silently eaten. Audit
            // terminal-view-1 F7.
            if !renderer.reconfigure(metrics: metrics, scale: newScale) {
                #if DEBUG
                Self.fpsLogger.log(
                    "drawableSizeWillChange reconfigure failed, atlas stays at \(self.renderer.atlas.scale, privacy: .public)x"
                )
                #endif
            }
        }
    }

    public func draw(in view: MTKView) {
        // Top chrome is always just the titlebar — our custom tab bar
        // lives INSIDE the titlebar row (iTerm2/Safari style), not as
        // a separate strip below it, so the text grid should start
        // right below the titlebar regardless of tab count.
        //
        // We can't use `titlebarOnlyTopInset` directly: when the native
        // tab bar is suppressed via view-walk, AppKit still reserves
        // its 36pt of layout in `safeAreaInsets` and `contentLayoutRect`
        // even though the views are hidden and our custom pills occupy
        // the titlebar itself — so titlebarOnlyTopInset jumps 32 → 68 on
        // every 2-tab window and the prompt drops a row.
        //
        // Instead, compute the real titlebar height from the window's
        // style: (window frame height) − (contentRect for the same style
        // with NO tab-bar reservation). This gives us the stable titlebar
        // content offset (~28 pt on standard windows), independent of
        // AppKit's phantom tab-bar bookkeeping.
        let currentTop = Float(titlebarOnlyTopInset)
        renderer.setTopInsetPoints(currentTop)
        if currentTop != lastSafeAreaTop {
            lastSafeAreaTop = currentTop
            // SIGWINCH must NOT run synchronously from the MTKViewDelegate
            // draw callback: `session.resize(to:)` is a blocking call that
            // re-enters the snapshot publisher and burns main-thread cycles
            // during frame assembly (defeats ProMotion's 120 Hz promotion
            // and storms the PTY when the titlebar inset jitters during
            // fullscreen/style-mask transitions). Defer to the next runloop
            // turn. `propagateResize` dedups against `lastPropagatedSize`, so
            // scheduling when the grid hasn't actually changed is a no-op.
            lastPropagatedSize = nil
            DispatchQueue.main.async { [weak self] in
                self?.propagateResize()
            }
        }
        let focused = window?.isKeyWindow ?? false
        // Hovered OSC 8 link id is set by `mouseMoved`; the renderer reads
        // it here so cells with a matching `link_id` get the accent-
        // underline attribute bit this frame. UInt32 → UInt16 is lossy
        // in principle (link ids are stored as u16 in BBCell), but the
        // snapshot API returns u32 to leave room for future expansion —
        // truncation here is safe because the FFI only ever returns ids
        // that originated as u16.
        renderer.setHoveredLinkID(UInt16(truncatingIfNeeded: hoveredLinkID))
        renderer.render(in: view, snapshot: currentSnapshot, focused: focused, selection: selection)
        // Any frame after a keystroke counts as "the keystroke landed on
        // screen" for probe purposes. The renderer's frame-skip path returns
        // early on unchanged state, so we only reach here on presented frames
        // — close enough to true input→pixel for a diagnostic probe.
        LatencyProbe.shared.markPresented()
        #if DEBUG
        // Count draws and sample the interval between consecutive calls so
        // the periodic log can distinguish "N fps with 16.67ms spacing" (60 Hz
        // vsync'd) from "N fps with 8.33ms spacing" (120 Hz vsync'd) from
        // "N fps with wildly uneven spacing" (MTKView stalling). Use
        // CACurrentMediaTime (mach_absolute_time) rather than Date — Date is
        // wall-clock and drifts; we want strict monotonic elapsed here.
        let nowMedia = CACurrentMediaTime()
        if lastFrameTime != 0 {
            let dtMs = (nowMedia - lastFrameTime) * 1000.0
            frameIntervalSumMs += dtMs
            if dtMs < frameIntervalMinMs { frameIntervalMinMs = dtMs }
            if dtMs > frameIntervalMaxMs { frameIntervalMaxMs = dtMs }
        }
        lastFrameTime = nowMedia
        frameCount += 1
        let elapsed = nowMedia - lastFrameLogTime
        if elapsed >= 1.0 {
            let intervals = max(1, frameCount - 1)
            let mean = frameIntervalSumMs / Double(intervals)
            let screenName = window?.screen?.localizedName ?? "nil"
            let maxFPS = window?.screen?.maximumFramesPerSecond ?? -1
            let minMs = frameIntervalMinMs.isFinite ? frameIntervalMinMs : 0
            // Ask CoreGraphics for the display's *current* mode refresh rate,
            // independent of MTKView's internal timer. If this returns 120
            // but we're drawing at 60 fps, the issue is MTKView's display
            // link (not ProMotion being clamped by System Settings).
            var hwHz: Double = -1
            if let sNum = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let cgID = CGDirectDisplayID(sNum.uint32Value)
                if let mode = CGDisplayCopyDisplayMode(cgID) {
                    hwHz = mode.refreshRate
                }
            }
            let line = String(
                format: "%d fps over %.2fs — interval min/mean/max = %.2f/%.2f/%.2f ms — screen '%@' (max %d Hz, hw mode %.2f Hz)",
                frameCount, elapsed, minMs, mean, frameIntervalMaxMs,
                screenName, maxFPS, hwHz
            )
            Self.fpsLogger.log("\(line, privacy: .public)")
            frameCount = 0
            frameIntervalMinMs = .infinity
            frameIntervalMaxMs = 0
            frameIntervalSumMs = 0
            lastFrameLogTime = nowMedia
        }
        #endif
    }

    // MARK: - Session observation

    private func subscribeToSession() {
        cancellables.removeAll()
        // Reset the bell de-dup counter so a fresh session's first bell
        // (counter=1) always flashes, even if a prior session's counter
        // had grown past 0. Only matters if the view ever reuses sessions;
        // still belt-and-braces.
        lastBellCounter = 0
        // Clear the stale snapshot + find-match state BEFORE returning on
        // a nil session — otherwise the previous session's grid lingers
        // on screen (rendered from `currentSnapshot`) after `view.session =
        // nil`, which is the most likely "stale snapshot" footgun. Audit
        // terminal-view-1 F5.
        guard let session else {
            currentSnapshot = nil
            findMatches.removeAll()
            findCurrentIndex = 0
            findQuery = ""
            setNeedsDisplay(bounds)
            return
        }

        session.$snapshot.sink { [weak self] snap in
            guard let self, let snap else { return }
            DispatchQueue.main.async {
                self.render(snapshot: snap)
            }
        }.store(in: &cancellables)

        session.$title.sink { [weak self] title in
            guard let self else { return }
            DispatchQueue.main.async {
                // Tab labels in AppKit's native tab group mirror window.title,
                // so one write covers both the titlebar and the tab. When the
                // shell hasn't emitted OSC 0/2 yet (stock zsh/bash until the
                // user configures precmd), fall back to the session's default
                // (shell basename) set by MainWindowController.
                let fallback = self.window?.title ?? "Blackbird"
                let useTitle = title?.isEmpty == false ? title : fallback
                self.window?.title = useTitle ?? "Blackbird"
            }
        }.store(in: &cancellables)

        session.$bellCounter.sink { [weak self] counter in
            guard let self else { return }
            guard counter > self.lastBellCounter else { return }
            self.lastBellCounter = counter
            DispatchQueue.main.async { self.flashBell() }
        }.store(in: &cancellables)
    }

    private func flashBell() {
        guard Preferences.shared.bell == .visual else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            bellFlashView.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self?.bellFlashView.animator().alphaValue = 0
            }
        }
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        // Typing dismisses any dwell-tooltip the pointer might be about
        // to reveal — otherwise a hovered URL tooltip would obscure the
        // user's own output as it scrolls past.
        cancelHoverTooltip()
        #if DEBUG
        let keyCode = event.keyCode
        let modBits = UInt(event.modifierFlags.rawValue)
        let chDesc = event.characters?.debugDescription ?? "nil"
        let chIgn = event.charactersIgnoringModifiers?.debugDescription ?? "nil"
        Self.keyLogger.debug(
            "keyDown keyCode=\(keyCode, privacy: .public) flags=0x\(String(modBits, radix: 16), privacy: .public) chars=\(chDesc, privacy: .public) charsIgnoring=\(chIgn, privacy: .public)"
        )
        #endif

        // ⌘-prefixed events never encode into PTY bytes. They're reserved for
        // application-level shortcuts (menu items, window management). This
        // enforces the spec's ⌘C/⌃C strict separation: ⌃C always sends 0x03
        // (via KeyEncoder's control path), ⌘C is never re-encoded as 'c'.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        guard let session else {
            #if DEBUG
            Self.keyLogger.debug("keyDown: no session, passing to super")
            #endif
            super.keyDown(with: event)
            return
        }

        // Stamp the keystroke entry point for the input→pixel latency probe.
        // No-op unless BB_LATENCY_PROBE=1. Placed after the ⌘ / no-session
        // early returns so only keystrokes that actually dispatch toward the
        // PTY get measured. The single-slot design collapses bursts to the
        // most recent keystroke, which is exactly what the user perceives.
        LatencyProbe.shared.markKeystroke()

        // Any shell-bound keystroke also cancels an active selection.
        if selection != nil { selection = nil }

        // Any non-⌘ keystroke represents user input headed for the shell, so
        // snap the viewport back to the live grid first. Users reading
        // scrollback get pulled back to the prompt the moment they type —
        // matching Terminal.app and iTerm2. No-op when already at bottom.
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }

        // Hand the event to the IME first. If macOS's input context is in
        // the middle of a composition (Japanese kana → kanji, Korean
        // combining jamo, Option-E dead key → ´) it'll call back into this
        // view's NSTextInputClient methods (setMarkedText / insertText /
        // unmarkText). Two outcomes we need to distinguish afterwards:
        //
        //   - Still composing (preedit visible): `hasMarkedText()` is true.
        //     The keystroke has been absorbed; do NOT also encode it.
        //
        //   - Committed a grapheme during this event: `insertText` ran and
        //     emitted bytes via `sendToSession`. `didInsertTextViaIME` is
        //     the flag that records this. Falling through to the encoder
        //     would double-write the character.
        //
        //   - IME did nothing: the flag stays false and `hasMarkedText`
        //     stays false. Fall through to the existing encoder path.
        didInsertTextViaIME = false
        inputContext?.handleEvent(event)
        if hasMarkedText() || didInsertTextViaIME { return }

        // Fast path for control characters: macOS translates Ctrl+letter into
        // the corresponding control byte (0x01-0x1A) in event.characters.
        // Send that byte directly to the PTY without round-tripping through
        // the encoder. This is the most reliable path for Ctrl+C (0x03),
        // Ctrl+D (0x04), Ctrl+Z (0x1A), etc.
        //
        // When the TUI has enabled kitty's disambiguate-escape-codes flag, the
        // four aliasing letters (Ctrl+i, Ctrl+m, Ctrl+[, Ctrl+h) must NOT take
        // the fast path — they need to become `CSI <cp>;5u` sequences so the
        // TUI can distinguish them from Tab / Enter / Esc / Backspace.
        if event.modifierFlags.contains(.control) {
            #if DEBUG
            Self.keyLogger.debug("keyDown: Control modifier detected")
            #endif
            let kittyActive = currentSnapshot?.termMode.contains(.disambiguateEscCodes) ?? false
            let baseLetter = event.charactersIgnoringModifiers?.lowercased().first
            let collidesWithC0: Bool = {
                guard let c = baseLetter else { return false }
                return c == "i" || c == "m" || c == "[" || c == "h"
            }()
            if kittyActive && collidesWithC0 {
                // Fall through — encoder will emit CSI u for the four
                // C0-aliasing letters under kitty disambiguation.
            } else if let chars = event.characters,
               let scalar = chars.unicodeScalars.first,
               scalar.value >= 1, scalar.value <= 0x1F {
                // Synchronous write so there's no perceptible latency before
                // the line discipline sees the byte. From here the kernel
                // does exactly the right thing — without any kill() from us:
                //
                //   ISIG on  (shell prompt, `sleep 100`, cmatrix cbreak):
                //     0x03 matches c_cc[VINTR] → echo `^C\n` (ECHOCTL) →
                //     SIGINT to fg pgroup → shell/sleep handles, prints the
                //     new prompt on the next line. Order is correct because
                //     the echo and the signal come from the same code path
                //     inside the tty layer.
                //
                //   ISIG off (nvim, tmux, htop — apps in raw mode):
                //     byte passes through to the app's stdin untouched. The
                //     app handles Ctrl+C internally (cancel op, close prompt)
                //     instead of dying from a "deadly signal".
                //
                // Getting VINTR/VSUSP/VEOF/VERASE right required passing nil
                // termios to forkpty (see PTY.swift) so the kernel's
                // TTYDEF_* defaults apply. Without that, c_cc was all-zeros
                // and Ctrl+C was just data.
                session.sendImmediate(Data([UInt8(scalar.value)]))
                return
            }
            // Fast path didn't match — fall through to encoder which also
            // handles Ctrl via controlByte().
            #if DEBUG
            Self.keyLogger.debug("keyDown: fast path didn't match, trying encoder")
            #endif
        }

        let mods = KeyEncoder.Modifiers(event: event)
        let termMode = currentSnapshot?.termMode ?? []

        if let special = Self.specialKey(for: event) {
            let appCursor = termMode.contains(.appCursor)
            let appKeypad = termMode.contains(.appKeypad)
            let bytes = encoder.encodeSpecial(
                special,
                modifiers: mods,
                applicationCursorKeys: appCursor,
                applicationKeypad: appKeypad
            )
            if !bytes.isEmpty { sendToSession(bytes) }
            return
        }

        // NSTextInputClient now owns the dead-key + composition path. The
        // previous `charactersIgnoringModifiers` / `characters` ternary for
        // Native-Option dead keys (Option+E → ´) is dead code: the input
        // context calls `setMarkedText("´")` before we ever reach this
        // branch, and the follow-up keystroke commits through
        // `insertText("é")`. `charactersIgnoringModifiers` is the right
        // source here for every remaining non-special printable — Meta
        // mode still wants the un-Option'd base letter so that Option+E
        // encodes to ESC "e" rather than ESC "´".
        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let bytes = encoder.encode(chars: chars, modifiers: mods, mode: termMode)
        #if DEBUG
        if !bytes.isEmpty {
            let hex = bytes.map { String(format: "0x%02x", $0) }.joined(separator: " ")
            Self.keyLogger.debug(
                "keyDown encoder produced \(bytes.count, privacy: .public) bytes: \(hex, privacy: .public)"
            )
        } else {
            Self.keyLogger.debug(
                "keyDown encoder produced empty data for chars=\(chars.debugDescription, privacy: .public) mods=\(mods.rawValue, privacy: .public)"
            )
        }
        #endif
        if !bytes.isEmpty { sendToSession(bytes) }
    }

    /// Key release. Only surfaces bytes when Kitty progressive-enhancement
    /// flag 2 (`reportEventTypes`) is active — the encoder's release path
    /// returns empty `Data` otherwise, and no shell binding depends on
    /// post-keystroke traffic we synthesise ourselves. Audit key-encoder F1
    /// (partial — flag 2 of the four progressive-enhancement flags).
    public override func keyUp(with event: NSEvent) {
        guard let session else {
            super.keyUp(with: event)
            return
        }
        if event.modifierFlags.contains(.command) {
            super.keyUp(with: event)
            return
        }
        let termMode = currentSnapshot?.termMode ?? []
        // Fast path: if the TUI hasn't enabled release reporting the
        // encoder will return empty anyway, so skip the whole work.
        guard termMode.contains(.reportEventTypes) else {
            super.keyUp(with: event)
            return
        }
        let mods = KeyEncoder.Modifiers(event: event)
        if let special = Self.specialKey(for: event) {
            // SpecialKey release isn't encoded in flag 2 today — the
            // Kitty spec only defines release events for the
            // CSI-u-emitting subset. Arrow / F-key releases fall through
            // unchanged until flag 8 (all-keys-as-CSI-u) is implemented.
            _ = special
            super.keyUp(with: event)
            return
        }
        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let bytes = encoder.encode(
            chars: chars, modifiers: mods, mode: termMode, eventType: .release
        )
        if !bytes.isEmpty {
            sendToSession(bytes)
        } else {
            super.keyUp(with: event)
        }
    }

    /// Resolve a font from the preferences value. `name` can be either:
    ///   - a family name like "Hack Nerd Font Mono" (what the Settings font
    ///     picker stores — it iterates `availableFontFamilies`),
    ///   - a PostScript name like "HackNerdFontMono-Regular" or
    ///     "SFMono-Regular" (older stored values).
    ///
    /// NSFontManager.font(withFamily:traits:weight:size:) handles the family
    /// case cleanly; NSFont(name:size:) handles the PS-name case. Fall back
    /// to the system monospace font so a typo'd preferences value can't
    /// leave the user with an unreadable terminal.
    private static func resolveFont(name: String, size: CGFloat) -> NSFont {
        let mgr = NSFontManager.shared
        // 5 is the regular weight in the NSFontManager scale (0…15).
        if let f = mgr.font(withFamily: name, traits: [], weight: 5, size: size) {
            return f
        }
        if let f = NSFont(name: name, size: size) {
            return f
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func specialKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        let key = event.specialKey
        switch key {
        case NSEvent.SpecialKey.upArrow:    return .up
        case NSEvent.SpecialKey.downArrow:  return .down
        case NSEvent.SpecialKey.leftArrow:  return .left
        case NSEvent.SpecialKey.rightArrow: return .right
        case NSEvent.SpecialKey.home:       return .home
        case NSEvent.SpecialKey.end:        return .end
        case NSEvent.SpecialKey.pageUp:     return .pageUp
        case NSEvent.SpecialKey.pageDown:   return .pageDown
        // NSEvent.SpecialKey.delete is the Backspace key. We intentionally do
        // NOT map it to SpecialKey.delete (CSI 3 ~) — Backspace must send the
        // DEL byte (0x7F), which the char-based path produces naturally from
        // event.charactersIgnoringModifiers. Only forward-delete maps here.
        case NSEvent.SpecialKey.deleteForward: return .delete
        case NSEvent.SpecialKey.f1:  return .f1
        case NSEvent.SpecialKey.f2:  return .f2
        case NSEvent.SpecialKey.f3:  return .f3
        case NSEvent.SpecialKey.f4:  return .f4
        case NSEvent.SpecialKey.f5:  return .f5
        case NSEvent.SpecialKey.f6:  return .f6
        case NSEvent.SpecialKey.f7:  return .f7
        case NSEvent.SpecialKey.f8:  return .f8
        case NSEvent.SpecialKey.f9:  return .f9
        case NSEvent.SpecialKey.f10: return .f10
        case NSEvent.SpecialKey.f11: return .f11
        case NSEvent.SpecialKey.f12: return .f12
        default:
            // Keypad keys aren't exposed via NSEvent.specialKey.
            // NSEvent.modifierFlags.numericPad fires for external
            // numeric-keypad keys (and for the arrow-cluster on some
            // layouts — hence the explicit keyCode check). Only detect
            // the digit / operator keypad keys, never the arrows
            // (arrows route through the existing specialKey mapping
            // above via NSEvent.SpecialKey.*Arrow).
            if event.modifierFlags.contains(.numericPad) {
                return keypadKey(for: event)
            }
            return nil
        }
    }

    /// Map a numeric-keypad NSEvent to the matching SpecialKey. Returns
    /// nil for anything outside the explicit keypad scan-code set so
    /// the caller's default path can handle arrows (which also carry
    /// `.numericPad` on some keyboards).
    private static func keypadKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        // Virtual key codes from Carbon/HIToolbox are stable across
        // keyboard layouts. Hard-coded here rather than via
        // kVK_ANSI_Keypad0 constants because those live in Carbon, and
        // Blackbird doesn't otherwise link that umbrella.
        switch event.keyCode {
        case 82: return .kp0
        case 83: return .kp1
        case 84: return .kp2
        case 85: return .kp3
        case 86: return .kp4
        case 87: return .kp5
        case 88: return .kp6
        case 89: return .kp7
        case 91: return .kp8
        case 92: return .kp9
        case 76: return .kpEnter
        case 69: return .kpPlus
        case 78: return .kpMinus
        case 67: return .kpMultiply
        case 75: return .kpDivide
        case 65: return .kpDecimal
        case 81: return .kpEquals
        default: return nil
        }
    }

    // MARK: - Paste

    @objc public func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(str)
    }

    /// Shared paste implementation: applies CRLF normalisation, wraps in
    /// bracketed-paste markers when the app has enabled mode 2004, and sends
    /// to the session. Used by both the menu/keyboard paste action and the
    /// drag-and-drop code path (file URLs are shell-quoted into a single
    /// string which is then fed through here).
    func pasteText(_ text: String) {
        guard let session else { return }
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }
        let normalized = Self.normalizePasteLineEndings(Data(text.utf8))
        // Strip C0 controls (except TAB/LF) and DEL unconditionally. Pasted
        // payload is "user typing" — Ctrl+C, Ctrl+Z, ESC inside the content
        // can break out of bracketed paste (CVE-2026-26982 class in Ghostty
        // <1.3.0) and execute arbitrary bytes as shell input. The sanitizer
        // replaces blocked bytes with space so column-formatted paste still
        // lines up.
        let cleaned = Self.sanitizePasteControls(normalized)
        // Drop explicit bidi control characters — Trojan Source (Boucher &
        // Anderson 2021). An adversarial webpage / remote can render as
        // `rm -rf harmless` while the copied bytes are `rm -rf ~`, exploiting
        // LRO / RLO overrides to hide the real command. Legitimate RTL
        // (Arabic / Hebrew) text never needs explicit overrides; Unicode
        // bidi algorithm handles it implicitly. Stripping is safe.
        let bytes = Self.stripBidiOverrides(cleaned)
        let bracketedPaste = currentSnapshot?.termMode.contains(.bracketedPaste) ?? false
        if bracketedPaste {
            var wrapped = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC[200~
            wrapped.append(Self.sanitizeBracketedPaste(bytes))
            wrapped.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))  // ESC[201~
            session.send(wrapped)
        } else {
            session.send(bytes)
        }
    }

    /// Collapse CRLF → LF in pasted content. Cross-platform clipboards (Windows,
    /// web copy) often carry CRLF; the PTY's ICRNL flag then maps the CR to an
    /// extra LF, so a two-line paste becomes four shell prompts. Matches
    /// Terminal.app / iTerm2 behaviour. Lone CR is left alone — it's rare in
    /// real paste content and some applications still want it as Enter.
    static func normalizePasteLineEndings(_ input: Data) -> Data {
        guard input.contains(0x0D) else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b = input[i]
            if b == 0x0D {
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == 0x0A {
                    out.append(0x0A)
                    i = input.index(after: next)
                    continue
                }
            }
            out.append(b)
            i = input.index(after: i)
        }
        return out
    }

    /// Replace C0 + C1 control bytes (other than TAB / LF / CR) and DEL
    /// with a space. Applied before *every* paste, whether bracketed or
    /// not.
    ///
    /// Rationale: a pasted payload can carry `0x03` (Ctrl+C), `0x1A`
    /// (Ctrl+Z), `0x1B` (ESC), or `0x7F` (DEL) in the C0 set, each of
    /// which — delivered raw to the shell — either interrupts the
    /// current line and runs the bytes that follow (the iTerm2 /
    /// Ghostty CVE-2026-26982 class) or drives the remote into an
    /// unexpected mode via escape sequences embedded in plain text.
    ///
    /// The same applies to the **C1 set** (0x80–0x9F), which xterm's
    /// `allowC1Printable` default treats as control bytes. Encoded in
    /// UTF-8 as `0xC2 0x80 … 0xC2 0x9F`, these include 0x9B (CSI),
    /// 0x9D (OSC), 0x90 (DCS) — ESC-free alternate forms of the same
    /// attack surface. A sanitizer that only strips ESC leaves the
    /// door open; we strip both lead bytes of the C1 UTF-8 sequence
    /// so the decoded scalar never reaches the parser.
    ///
    /// Replacing with space keeps byte offsets stable so column-
    /// formatted paste still lines up. Matches Ghostty ≥1.3.0 and
    /// xterm's default paste sanitizer.
    static func sanitizePasteControls(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b = input[i]
            // TAB / LF / CR pass through — legitimate whitespace in paste.
            // (CR is normalised to LF upstream, but a lone CR arriving
            // from an old-Mac-encoded file is still valid input.)
            if b == 0x09 || b == 0x0A || b == 0x0D {
                out.append(b)
                i = input.index(after: i)
                continue
            }
            // C0 (0x00–0x1F excluding TAB/LF/CR) and DEL (0x7F) → space.
            if b < 0x20 || b == 0x7F {
                out.append(0x20)
                i = input.index(after: i)
                continue
            }
            // C1 controls encoded as UTF-8: lead 0xC2 followed by a byte
            // in 0x80–0x9F. Replace the whole two-byte scalar with a
            // single space so the parser never sees 0x9B / 0x9D / 0x90.
            // This doesn't strip lone continuation bytes (those are
            // invalid UTF-8 and handled by the parser's UTF-8 state
            // machine); we only match the valid C1 encoding pattern.
            if b == 0xC2,
               input.index(after: i) < input.endIndex {
                let next = input[input.index(after: i)]
                if (0x80...0x9F).contains(next) {
                    out.append(0x20)
                    i = input.index(i, offsetBy: 2)
                    continue
                }
            }
            out.append(b)
            i = input.index(after: i)
        }
        return out
    }

    /// Drop every Unicode bidi formatting / isolate / mark control from
    /// a paste payload. Targets a dozen codepoints across three UTF-8
    /// length classes:
    ///
    ///   U+061C  ALM   D8 9C         Arabic letter mark (2-byte)
    ///   U+180E  MVS   E1 A0 8E      Mongolian vowel separator (3-byte)
    ///   U+200E  LRM   E2 80 8E      left-to-right mark
    ///   U+200F  RLM   E2 80 8F      right-to-left mark
    ///   U+202A  LRE   E2 80 AA      left-to-right embedding
    ///   U+202B  RLE   E2 80 AB      right-to-left embedding
    ///   U+202C  PDF   E2 80 AC      pop directional formatting
    ///   U+202D  LRO   E2 80 AD      left-to-right override  ← Trojan Source
    ///   U+202E  RLO   E2 80 AE      right-to-left override  ← Trojan Source
    ///   U+2066  LRI   E2 81 A6      left-to-right isolate
    ///   U+2067  RLI   E2 81 A7      right-to-left isolate
    ///   U+2068  FSI   E2 81 A8      first strong isolate
    ///   U+2069  PDI   E2 81 A9      pop directional isolate
    ///
    /// These are rare in legitimate text — Unicode's bidirectional
    /// algorithm handles Arabic / Hebrew automatically; explicit
    /// formatting is a spoofing hammer. iTerm2's "Filter control
    /// sequences on paste" option applies the same policy; the extra
    /// codepoints here match CVE-2021-42574 follow-up advisories that
    /// broadened the list beyond the original nine overrides.
    static func stripBidiOverrides(_ input: Data) -> Data {
        // Fast path: no 0xD8 / 0xE1 / 0xE2 byte means no match at all.
        guard input.contains(where: { $0 == 0xD8 || $0 == 0xE1 || $0 == 0xE2 })
        else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b0 = input[i]
            let remaining = input.distance(from: i, to: input.endIndex)

            // 2-byte: U+061C  (D8 9C)
            if b0 == 0xD8, remaining >= 2,
               input[input.index(after: i)] == 0x9C {
                i = input.index(i, offsetBy: 2)
                continue
            }

            // 3-byte sequences: E1 A0 8E (U+180E); E2 8x xx for several.
            if remaining >= 3 {
                let b1 = input[input.index(i, offsetBy: 1)]
                let b2 = input[input.index(i, offsetBy: 2)]
                if b0 == 0xE1, b1 == 0xA0, b2 == 0x8E {
                    i = input.index(i, offsetBy: 3)
                    continue
                }
                if b0 == 0xE2 {
                    // U+200E / U+200F: E2 80 8E / 8F
                    if b1 == 0x80 && (b2 == 0x8E || b2 == 0x8F) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                    // U+202A..U+202E: E2 80 AA..AE
                    if b1 == 0x80 && (0xAA...0xAE).contains(b2) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                    // U+2066..U+2069: E2 81 A6..A9
                    if b1 == 0x81 && (0xA6...0xA9).contains(b2) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                }
            }

            out.append(b0)
            i = input.index(after: i)
        }
        return out
    }

    /// Strip any literal `ESC [ 2 0 1 ~` terminators from a bracketed-paste
    /// payload so they can't prematurely close the paste window and let
    /// subsequent bytes execute as shell input — the classic paste-injection
    /// attack. Copying another terminal's output that happens to include
    /// that exact sequence is the realistic trigger. We only redact the
    /// closing marker (ESC[200~ inside a paste is harmless — bracketed paste
    /// doesn't nest).
    ///
    /// Post-`sanitizePasteControls` this is largely redundant (ESC is
    /// already stripped), but we keep the second-stage defence so a future
    /// refactor that loosens the controls pass doesn't silently re-open the
    /// nested-paste attack surface.
    static func sanitizeBracketedPaste(_ input: Data) -> Data {
        let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        guard input.count >= terminator.count else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let remaining = input.distance(from: i, to: input.endIndex)
            if remaining >= terminator.count {
                var match = true
                for k in 0..<terminator.count {
                    if input[input.index(i, offsetBy: k)] != terminator[k] {
                        match = false
                        break
                    }
                }
                if match {
                    i = input.index(i, offsetBy: terminator.count)
                    continue
                }
            }
            out.append(input[i])
            i = input.index(after: i)
        }
        return out
    }

    // MARK: - Drag and drop

    // The `NSDraggingDestination` overrides live on the main class so they
    // sit next to the `isDropTargeted` stored state they mutate. The pure
    // formatters (`shellQuote`, `joinedDroppedPaths`) stay in
    // TerminalView+Dragging.swift so they can be unit-tested without
    // constructing a drag fake.

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggingPasteboardHasFileURLs(sender) else { return [] }
        isDropTargeted = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Re-answer the accepted operation on each move so the OS keeps the
        // copy-cursor badge for the whole hover, not just the initial enter.
        guard draggingPasteboardHasFileURLs(sender) else { return [] }
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Always clear the ring before returning — whether we accept the
        // drop or not, the drag is over.
        defer { isDropTargeted = false }
        let pb = sender.draggingPasteboard
        let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        // Keep only file-scheme URLs. `readObjects(forClasses: [NSURL.self])`
        // can also return https: URLs from a web-browser drag; those would
        // turn into garbage arguments if we blindly `path`-stringified them.
        let paths = items.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            return url.path
        }
        guard !paths.isEmpty else { return false }
        pasteText(Self.joinedDroppedPaths(paths))
        return true
    }

    @objc public func copy(_ sender: Any?) {
        guard let sel = selection, let session, let snap = currentSnapshot else { return }
        let (start, end) = Self.copyRange(for: sel, cols: snap.cols)
        let raw = session.textRange(from: start, to: end, rectangular: sel.mode == .rectangular)
        guard !raw.isEmpty else { return }
        // Cap + scrub before writing. A compromised remote can spam the
        // scrollback with bidi-override + C0 payloads; if the user
        // selects that span and copies, those bytes land on the system
        // clipboard and poison every subsequent paste into Safari /
        // Mail / Chat. 16 MiB covers every realistic "select the whole
        // world" case. Same sanitizer as paste-inbound (symmetric).
        let copyMax = 16 * 1024 * 1024
        let data = Data(raw.utf8).prefix(copyMax)
        let scrubbed = Self.stripBidiOverrides(
            Self.sanitizePasteControls(Data(data))
        )
        let clean = String(decoding: scrubbed, as: UTF8.self)
        guard !clean.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clean, forType: .string)
    }

    /// Compute the (start, end) buffer points to pass into
    /// `TerminalSession.textRange` given a selection and the current grid
    /// width. Pure so the mode-specific fixups can be unit-tested.
    ///
    /// `.line` mode highlights full rows on screen; mirror that in the copy
    /// so triple-click + drag yields "every whole line between the anchor
    /// and the pointer" instead of truncating the first/last line to the
    /// pointer's column. All other modes copy the normalized pair as-is.
    static func copyRange(for selection: Selection, cols: Int) -> (start: BufferPoint, end: BufferPoint) {
        let (a, b) = selection.normalized
        switch selection.mode {
        case .line:
            return (
                BufferPoint(line: a.line, col: 0),
                BufferPoint(line: b.line, col: max(0, cols - 1))
            )
        case .character, .word, .rectangular:
            return (a, b)
        }
    }

    @objc public override func selectAll(_ sender: Any?) {
        guard let snap = currentSnapshot else { return }
        // "All visible" = top row of the current viewport through bottom row.
        // Buffer line for the top of the viewport is -displayOffset.
        let topLine    = -Int32(snap.displayOffset)
        let bottomLine = Int32(snap.rows - 1) - Int32(snap.displayOffset)
        let top = BufferPoint(line: topLine,    col: 0)
        let bot = BufferPoint(line: bottomLine, col: snap.cols - 1)
        selection = Selection(anchor: top, cursor: bot, mode: .character)
    }

    @objc public func performFindPanelAction(_ sender: Any?) {
        // Cocoa's Edit > Find submenu maps ⌘F to this selector.
        if findBar == nil { installFindBar() }
        findBar?.focus()
    }

    @objc public func performFindNextAction(_ sender: Any?)     { advanceFind(direction: .forward) }
    @objc public func performFindPreviousAction(_ sender: Any?) { advanceFind(direction: .backward) }

    /// ⌘⌥C: toggle case-sensitive find. Installs the find bar if
    /// needed so the menu item works even when the bar is closed.
    @objc public func toggleFindCaseSensitive(_ sender: Any?) {
        if findBar == nil { installFindBar() }
        findBar?.toggleCaseSensitive(sender)
    }

    /// ⌘⌥R: toggle regex find.
    @objc public func toggleFindRegex(_ sender: Any?) {
        if findBar == nil { installFindBar() }
        findBar?.toggleRegexMode(sender)
    }

    @objc public func clearBufferAndScrollback(_ sender: Any?) {
        session?.clearAll()
    }

    @objc public func increaseFontSize(_ sender: Any?) {
        let p = Preferences.shared
        p.fontSize = min(32, p.fontSize + 1)
    }

    @objc public func decreaseFontSize(_ sender: Any?) {
        let p = Preferences.shared
        p.fontSize = max(9, p.fontSize - 1)
    }

    @objc public func resetFontSize(_ sender: Any?) {
        Preferences.shared.fontSize = 13
    }

    /// Scroll the viewport up to the previous OSC 133 prompt mark. Hooked
    /// to the "View → Previous Prompt" menu item (⌘⇧↑). No visible effect
    /// unless the user has sourced the bundled shell-integration snippet,
    /// because otherwise the session has no prompt marks recorded.
    @objc public func jumpToPreviousPrompt(_ sender: Any?) {
        if session?.jumpToPreviousPrompt() != true {
            // Ring empty (no shell integration, or no commands yet) OR
            // already at the oldest prompt. NSBeep is the standard macOS
            // "no-op" feedback — quiet, doesn't steal focus. Audit
            // terminal-view-2 F25.
            NSSound.beep()
        }
    }

    /// Scroll the viewport down to the next (newer) OSC 133 prompt mark.
    /// No-op when the user isn't already cycling through prompts — the
    /// newest prompt is always live.
    @objc public func jumpToNextPrompt(_ sender: Any?) {
        if session?.jumpToNextPrompt() != true {
            NSSound.beep()
        }
    }

    /// Trackpad pinch-to-zoom → font-size step. Accumulate the continuous
    /// magnification delta and trigger one step per threshold crossing.
    /// 0.15 is the same threshold Safari / Xcode use for "gesture felt a
    /// click worth"; finer values fire too aggressively on a single finger
    /// slip, coarser miss small deliberate zooms.
    public override func magnify(with event: NSEvent) {
        pinchAccumulator += event.magnification
        while pinchAccumulator >= 0.15 {
            increaseFontSize(nil)
            pinchAccumulator -= 0.15
        }
        while pinchAccumulator <= -0.15 {
            decreaseFontSize(nil)
            pinchAccumulator += 0.15
        }
    }

    // MARK: - macOS Services + Look Up

    /// Expose the current selection to the Services menu and Look Up
    /// (three-finger tap, Ctrl-⌘-D). Without this override, NSResponder's
    /// default returns nil for our view and macOS hides the Services
    /// submenu entirely. Accepts string-type sends; we never accept
    /// pasteboard-originated changes here (paste still routes through
    /// `paste(_:)` so the TUI's bracketed-paste / sanitizer stays in play).
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == .string, returnType == nil, selectedStringForServices() != nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Called by the Services infrastructure when the user picks
    /// "Services → …" on a selection; writes the selection text onto the
    /// supplied pasteboard so the chosen service can read it.
    /// Part of the informal `NSServicesMenuRequestor` protocol — not an
    /// `NSResponder` override, so no `override` keyword.
    @objc public func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.string), let text = selectedStringForServices() else {
            return false
        }
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    /// Three-finger tap / Force Touch on the trackpad triggers
    /// `quickLook(with:)` on the responder chain. Preview the current
    /// selection (or the hovered OSC-8 link URL when no selection) in an
    /// NSPopover anchored under the pointer — Ghostty / Safari / Xcode
    /// idiom. Falls back to `super` when nothing useful is under the
    /// pointer so macOS can still offer dictionary lookup / media preview
    /// for other responder hits.
    public override func quickLook(with event: NSEvent) {
        // Priority: selection wins (user picked it explicitly) > hovered
        // OSC-8 URL (already highlighted). Nothing actionable → defer
        // to AppKit's default behaviour (dictionary / None).
        let text: String? = {
            if let sel = selectedStringForServices(), !sel.isEmpty {
                return sel
            }
            if let snap = currentSnapshot, hoveredLinkID != 0,
               let url = snap.linkURL(id: hoveredLinkID) {
                return url
            }
            return nil
        }()
        guard let text else {
            super.quickLook(with: event)
            return
        }

        // Pointer position for the popover anchor. event.locationInWindow
        // is in window space; convert to view space for the popover's
        // positioning rect.
        let pointInView = convert(event.locationInWindow, from: nil)
        // Anchor a 1-pt rect at the pointer so the popover arrows find
        // a precise spot. AppKit expands as needed to place the popover.
        let anchor = NSRect(origin: pointInView, size: NSSize(width: 1, height: 1))

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 6
        label.preferredMaxLayoutWidth = 420
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = {
            let vc = NSViewController()
            vc.view = container
            return vc
        }()
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    /// Selection → String without the clipboard scrubbing step. Services
    /// and Look Up get the raw text: the downstream app may legitimately
    /// want formatting characters the clipboard-sanitizer would strip,
    /// and any bidi overrides won't reach Safari/Mail via this path (it
    /// goes through an NSPasteboard the service owns, then a UI chosen
    /// by the user — we never copy onto the general pasteboard here).
    private func selectedStringForServices() -> String? {
        guard let sel = selection, let session, let snap = currentSnapshot else {
            return nil
        }
        let (start, end) = Self.copyRange(for: sel, cols: snap.cols)
        let text = session.textRange(from: start, to: end, rectangular: sel.mode == .rectangular)
        return text.isEmpty ? nil : text
    }

    private func installFindBar() {
        let h: CGFloat = 32
        // Sit just below the titlebar, not under it.
        let top = titlebarOnlyTopInset
        let bar = FindBar(frame: NSRect(x: 0, y: bounds.height - h - top, width: bounds.width, height: h))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.delegate = self
        addSubview(bar)
        findBar = bar
    }

    fileprivate func advanceFind(direction: FindBar.Direction) {
        guard !findMatches.isEmpty else { return }
        switch direction {
        case .forward:  findCurrentIndex = (findCurrentIndex + 1) % findMatches.count
        case .backward: findCurrentIndex = (findCurrentIndex - 1 + findMatches.count) % findMatches.count
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    fileprivate func performSearch(query: String) {
        findQuery = query
        findMatches.removeAll()
        findCurrentIndex = 0
        guard let session, let snap = currentSnapshot, !query.isEmpty else {
            findBar?.setMatchCount(0, of: 0)
            selection = nil
            return
        }
        let opts = findBar?.options ?? FindBar.Options()
        // Compile the regex once. An invalid regex silently degrades to
        // zero matches (UI placeholder signals regex mode is on; bad
        // patterns just don't match anything until the user fixes them).
        let stringOptions: String.CompareOptions = {
            var s: String.CompareOptions = []
            if !opts.caseSensitive { s.insert(.caseInsensitive) }
            return s
        }()
        let regex: NSRegularExpression?
        if opts.regex {
            var regexOpts: NSRegularExpression.Options = []
            if !opts.caseSensitive { regexOpts.insert(.caseInsensitive) }
            regex = try? NSRegularExpression(pattern: query, options: regexOpts)
            if regex == nil {
                // Invalid pattern — show 0 matches, no crash. User sees
                // the counter stay at 0/0 while they fix the expression.
                findBar?.setMatchCount(0, of: 0)
                selection = nil
                return
            }
        } else {
            regex = nil
        }
        // Search the entire retained buffer: from -historySize through rows-1.
        let topLine: Int32 = -Int32(clamping: snap.historySize)
        let bottomLine = Int32(clamping: snap.rows - 1)
        if topLine > bottomLine { return }
        let findMatchLimit = 10_000
        outer: for ln in topLine...bottomLine {
            let hay = session.textRange(
                from: BufferPoint(line: ln, col: 0),
                to:   BufferPoint(line: ln, col: snap.cols - 1),
                rectangular: false
            )
            guard !hay.isEmpty else { continue }
            if let re = regex {
                let ns = hay as NSString
                re.enumerateMatches(
                    in: hay,
                    options: [],
                    range: NSRange(location: 0, length: ns.length)
                ) { result, _, stop in
                    guard let r = result?.range, r.length > 0 else { return }
                    // Translate UTF-16 range to grapheme-cell positions
                    // the same way URLDetector does; simple 1:1 holds for
                    // ASCII (the dominant case) but keeps correct counts
                    // for non-BMP scalars appearing in the haystack.
                    let startCol = r.location
                    let endCol = r.location + r.length - 1
                    findMatches.append((line: ln, startCol: startCol, endCol: endCol))
                    if findMatches.count >= findMatchLimit { stop.pointee = true }
                }
                if findMatches.count >= findMatchLimit { break outer }
            } else {
                var cursor = hay.startIndex
                while let r = hay.range(of: query, options: stringOptions, range: cursor..<hay.endIndex) {
                    let startCol = hay.distance(from: hay.startIndex, to: r.lowerBound)
                    let endCol   = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                    findMatches.append((line: ln, startCol: startCol, endCol: endCol))
                    cursor = r.upperBound
                    if findMatches.count >= findMatchLimit { break outer }
                }
            }
        }
        findBar?.setMatchCount(findCurrentIndex, of: findMatches.count)
        highlightCurrentMatch()
    }

    private func highlightCurrentMatch() {
        guard !findMatches.isEmpty, findCurrentIndex < findMatches.count else {
            selection = nil
            return
        }
        let m = findMatches[findCurrentIndex]
        selection = Selection(
            anchor: BufferPoint(line: m.line, col: m.startCol),
            cursor: BufferPoint(line: m.line, col: m.endCol),
            mode: .character
        )
        // Scroll the match into view. displayOffset is how many lines
        // the viewport is above the live grid; positive delta to scroll()
        // means "show older content" (upward).
        guard let snap = currentSnapshot else { return }
        let displayRowForMatch = Int(m.line) + snap.displayOffset
        if displayRowForMatch < 0 {
            session?.scroll(delta: Int32(clamping: -displayRowForMatch))
        } else if displayRowForMatch >= snap.rows {
            session?.scroll(delta: Int32(clamping: snap.rows - 1 - displayRowForMatch))
        }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):                      return selection != nil
        case #selector(selectAll(_:)):                 return currentSnapshot != nil
        case #selector(paste(_:)):
            // Paste needs BOTH a session to receive the bytes AND string
            // content on the pasteboard. Before this check, a paste on a
            // view with no session silently dropped the clipboard content
            // instead of clearly disabling the menu item.
            // Audit terminal-view-2 F13.
            return session != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(performFindPanelAction(_:)):    return currentSnapshot != nil
        case #selector(performFindNextAction(_:)):     return !findMatches.isEmpty
        case #selector(performFindPreviousAction(_:)): return !findMatches.isEmpty
        case #selector(toggleFindCaseSensitive(_:)):
            item.state = (findBar?.options.caseSensitive == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(toggleFindRegex(_:)):
            item.state = (findBar?.options.regex == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(clearBufferAndScrollback(_:)):  return session != nil
        case #selector(jumpToPreviousPrompt(_:)),
             #selector(jumpToNextPrompt(_:)):
            // Same pattern: disabling until OSC 133 marks exist is more
            // honest than beeping on every press.
            return (session?.promptMarks.isEmpty == false)
        case #selector(increaseFontSize(_:)),
             #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)): return session != nil
        default:                                       return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        // Surface "Open Link" / "Copy Link" when the right-click lands on
        // a resolvable URL (OSC 8 hyperlink or regex-detected). Safari-
        // parity affordance; without it users can only reach URLs via
        // ⌘-click which is hidden UI. Audit terminal-view-2 F27.
        let p = bufferPointFromEvent(event)
        let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
        if let url = resolveClickURL(screenRow: screenRow, col: p.col) {
            let openItem = NSMenuItem(title: "Open Link",
                                      action: #selector(openResolvedLink(_:)),
                                      keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = url
            let copyLinkItem = NSMenuItem(title: "Copy Link",
                                          action: #selector(copyResolvedLink(_:)),
                                          keyEquivalent: "")
            copyLinkItem.target = self
            copyLinkItem.representedObject = url
            m.addItem(openItem)
            m.addItem(copyLinkItem)
            m.addItem(NSMenuItem.separator())
        }
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        copyItem.target = self
        pasteItem.target = self
        m.addItem(copyItem)
        m.addItem(pasteItem)
        return m
    }

    @objc private func openResolvedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        urlOpener.open(url)
    }

    @objc private func copyResolvedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }

    // MARK: - Mouse reporting

    private func mouseReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseReportClick) || mode.contains(.mouseMotion) || mode.contains(.mouseDrag)
    }

    private func sgrMouseEnabled() -> Bool {
        currentSnapshot?.termMode.contains(.sgrMouse) ?? false
    }

    public override func mouseDown(with event: NSEvent) {
        // ⌘-click on a URL → open it. Runs before mouse-reporting and
        // selection so TUIs can't swallow the gesture. Restricted to
        // non-mouse-reporting context (or ⌥-held inside a TUI) so that
        // vim's own <C-click> binding still works when the TUI asks for
        // the click.
        //
        // If no URL is under the click, ⌘-drag acts like a titlebar drag
        // and moves the window (matches iTerm2 "⌘-drag to move"). Any view
        // can initiate window drag by calling `performDrag(with:)`; the
        // call blocks until the mouse is released, so this returns cleanly
        // without triggering the selection path below.
        if event.modifierFlags.contains(.command) {
            let underlyingOption = event.modifierFlags.contains(.option)
            if !mouseReportingEnabled() || underlyingOption {
                let p = bufferPointFromEvent(event)
                // Buffer-relative line → screen row. OSC 8 attribution is
                // keyed on screen-space cells since the snapshot only carries
                // the visible viewport. When the user is scrolled back into
                // history the regex path still honours buffer coordinates
                // (URLDetector output uses buffer lines).
                let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
                if let url = resolveClickURL(screenRow: screenRow, col: p.col) {
                    urlOpener.open(url)
                    return
                }
            }
            // No URL under the click — treat as window drag.
            window?.performDrag(with: event)
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, let session {
            sendMouseEvent(event, button: 0, press: true, session: session)
            return
        }
        let point = bufferPointFromEvent(event)
        // Shift-click extends the current selection from its ANCHOR to the
        // click point — the standard macOS / iTerm2 gesture for precise
        // selection adjustment. Without it, shift-click would start a new
        // zero-width selection, discarding whatever the user just carefully
        // selected. Audit findbar-selection F17.
        if event.clickCount == 1,
           event.modifierFlags.contains(.shift),
           let existing = selection {
            selection = Selection(anchor: existing.anchor, cursor: point, mode: existing.mode)
            isDragging = true
            return
        }
        let mode: Selection.Mode
        switch event.clickCount {
        case 3: mode = .line
        case 2: mode = .word
        default:
            // ⌥-drag for rectangular (column-block) selection — iTerm2 /
            // Terminal.app default. ⌘ is reserved for URL-open / window-drag
            // and never reaches here (the .command branch above returns).
            mode = event.modifierFlags.contains(.option) ? .rectangular : .character
        }
        selection = Selection(anchor: point, cursor: point, mode: mode)
        isDragging = true
        if mode == .word || mode == .line {
            expandSelectionUnderAnchor()
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if isDragging {
            isDragging = false
            // A zero-width selection means the user clicked without
            // dragging — no content to show, so clear. Applies to every
            // mode: .character clicks leave anchor == cursor directly;
            // .word / .line clicks that landed on non-word cells also
            // leave anchor == cursor (expandSelectionUnderAnchor is a
            // no-op there); .rectangular clicks start at anchor == cursor
            // and only grow during the drag.
            if let s = selection, s.anchor == s.cursor {
                selection = nil
            }
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, let session {
            sendMouseEvent(event, button: 0, press: false, session: session)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        // ⌘ + right-drag → resize the window from the corner nearest the
        // click. Matches the borderless-window idiom from apps like iTerm2
        // and VS Code: ⌘-drag moves, ⌘-right-drag resizes. Anchor the
        // OPPOSITE corner so dragging from (say) the top-right pulls the
        // top-right while bottom-left stays pinned.
        if event.modifierFlags.contains(.command), let win = window {
            let local = convert(event.locationInWindow, from: nil)
            let left = local.x < bounds.width / 2
            // AppKit's Y-axis points up, so "below the midline" = smaller y.
            let lower = local.y < bounds.height / 2
            let corner: ResizeCorner = switch (left, lower) {
                case (true,  true):  .bottomLeft
                case (false, true):  .bottomRight
                case (true,  false): .topLeft
                case (false, false): .topRight
            }
            resizeContext = ResizeContext(
                corner: corner,
                startMouseGlobal: NSEvent.mouseLocation,
                startFrame: win.frame
            )
            return
        }
        // ⌥+right-click escapes a TUI's mouse capture just like ⌥+left-click
        // and ⌥+scroll do elsewhere. Without this, vim / tmux / htop eat
        // every right-click and the Copy/Paste context menu is unreachable.
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.rightMouseDown(with: event)
            return
        }
        sendMouseEvent(event, button: 2, press: true, session: session)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if let ctx = resizeContext, let win = window {
            let now = NSEvent.mouseLocation
            let dx = now.x - ctx.startMouseGlobal.x
            let dy = now.y - ctx.startMouseGlobal.y
            var frame = ctx.startFrame
            switch ctx.corner {
            case .topLeft:
                frame.origin.x    += dx
                frame.size.width  -= dx
                frame.size.height += dy
            case .topRight:
                frame.size.width  += dx
                frame.size.height += dy
            case .bottomLeft:
                frame.origin.x    += dx
                frame.size.width  -= dx
                frame.origin.y    += dy
                frame.size.height -= dy
            case .bottomRight:
                frame.size.width  += dx
                frame.origin.y    += dy
                frame.size.height -= dy
            }
            // Clamp to contentMinSize (set by MainWindowController). When the
            // dragged corner would shrink the window below the minimum, pin
            // its corresponding edge instead of letting the opposite corner
            // drift.
            let minContent = win.contentMinSize
            let chrome = win.frame.height - (win.contentView?.bounds.height ?? win.frame.height)
            let minWidth  = max(minContent.width, 200)
            let minHeight = max(minContent.height + chrome, 120)
            if frame.size.width < minWidth {
                if ctx.corner == .topLeft || ctx.corner == .bottomLeft {
                    frame.origin.x = ctx.startFrame.maxX - minWidth
                }
                frame.size.width = minWidth
            }
            if frame.size.height < minHeight {
                if ctx.corner == .bottomLeft || ctx.corner == .bottomRight {
                    frame.origin.y = ctx.startFrame.maxY - minHeight
                }
                frame.size.height = minHeight
            }
            win.setFrame(frame, display: true)
            return
        }
        super.rightMouseDragged(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        if resizeContext != nil {
            resizeContext = nil
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.rightMouseUp(with: event)
            return
        }
        sendMouseEvent(event, button: 2, press: false, session: session)
    }

    // MARK: - Middle-mouse button reporting
    //
    // xterm mouse protocol: button 1 = middle. Many TUIs (nvim, less,
    // tmux) expect middle-click to paste or to trigger a custom binding;
    // without these hooks the event never reaches the shell. Mirrors the
    // left/right handlers: ⌥ escapes reporting so the user can still
    // paste locally over a TUI. Audit terminal-view-2 F9.

    public override func otherMouseDown(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.otherMouseDown(with: event)
            return
        }
        sendMouseEvent(event, button: 1, press: true, session: session)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session,
              anyEventMouseEnabled() || dragReportingEnabled() else {
            super.otherMouseDragged(with: event)
            return
        }
        // xterm motion reporting: button + 32 for drag-with-button-held.
        sendMouseEvent(event, button: 1 + 32, press: true, session: session)
    }

    public override func otherMouseUp(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.otherMouseUp(with: event)
            return
        }
        sendMouseEvent(event, button: 1, press: false, session: session)
    }

    /// True when the TUI enabled DEC mode 1003 (any-event tracking —
    /// cursor motion without a button). Implied by the SGR mouse mode
    /// bit being set alongside motion; narrower predicate than
    /// `mouseReportingEnabled` so we only fire no-button motion
    /// reports when explicitly asked. Audit terminal-view-2 F14.
    private func anyEventMouseEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseMotion)
    }

    private func dragReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseDrag)
    }

    private enum ResizeCorner { case topLeft, topRight, bottomLeft, bottomRight }
    private struct ResizeContext {
        let corner: ResizeCorner
        let startMouseGlobal: CGPoint
        let startFrame: CGRect
    }
    private var resizeContext: ResizeContext?

    public override func scrollWheel(with event: NSEvent) {
        // Scrolling moves the grid beneath the pointer — the cell the
        // user was dwelling on now has different content, so any pending
        // tooltip would pop up with a stale URL. Cancel both the pending
        // reveal and the accent underline; the next mouseMoved delivery
        // will repaint them against the fresh cell if appropriate.
        cancelHoverTooltip()
        clearHoveredLink()
        // The cached hover cell is also stale once the grid moved, so the
        // next mouseMoved will re-resolve the link id even if the pointer
        // hasn't physically moved a pixel between the scroll and the next
        // delivery (otherwise updateHover would early-return on the same
        // (row, col) and leave hoveredLinkID at zero).
        lastHoverCell = nil
        guard let session else { super.scrollWheel(with: event); return }
        // ⌥-scroll bypasses mouse reporting so the user can always reach
        // scrollback locally, even inside a TUI that captured the wheel.
        // Matches the ⌥-click escape on mouseDown.
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld {
            // Mouse mode: forward as SGR/X10 scroll events.
            // Wheel up = button 64, wheel down = button 65.
            if event.scrollingDeltaY > 0 {
                sendMouseEvent(event, button: 64, press: true, session: session)
            } else if event.scrollingDeltaY < 0 {
                sendMouseEvent(event, button: 65, press: true, session: session)
            }
        } else {
            // Normal mode: scroll the display through scrollback history.
            // Two input types to reconcile:
            //
            //   Trackpad / Magic Mouse (hasPreciseScrollingDeltas == true):
            //     scrollingDeltaY is in points. Scaling by cellHeight gives
            //     pixel-accurate scrolling (move the pointer one row's worth
            //     of points → scroll one row). Multiply by 2 so a casual
            //     two-finger flick covers ~2 screenfuls, matching Terminal.app
            //     feel.
            //
            //   Classic wheel (hasPreciseScrollingDeltas == false):
            //     scrollingDeltaY is ~1 per physical click. 3 lines per click
            //     is the common terminal-emulator default (alacritty, kitty).
            //
            // Rounding away from zero ensures tiny trackpad flicks register
            // at least one line instead of truncating to 0. Clamp before
            // casting to Int32 — a misbehaving input device or a NaN delta
            // would otherwise trap the app in `Int32(Double)` on overflow.
            let delta = event.scrollingDeltaY
            let rawUnclamped: Double = event.hasPreciseScrollingDeltas
                ? Double(delta) / Double(metrics.cellHeight) * 2.0
                : Double(delta) * 3.0
            let raw = rawUnclamped.isFinite ? rawUnclamped : 0
            let clamped = min(Double(Int32.max), max(Double(Int32.min), raw))
            let lines = Int32(clamped.rounded(.toNearestOrAwayFromZero))
            if lines != 0 {
                session.scroll(delta: lines)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if isDragging, var sel = selection {
            // Autoscroll when dragging past the viewport edges so the user
            // can select into scrollback / future output.
            //
            // scroll(delta:) follows alacritty's convention:
            //   positive → show older (scrollback), negative → show newer.
            // AppKit coords place y=0 at the visual bottom, so:
            //   - cursor near the TOP (high y)    → reveal older content → +1
            //   - cursor near the BOTTOM (low y) → reveal newer content → -1
            // The previous signs were swapped, so autoscroll fought the drag.
            let local = convert(event.locationInWindow, from: nil)
            // Top edge is `titlebarOnlyTopInset` below the raw view top because
            // the titlebar sits in the upper inset under fullSizeContentView.
            if local.y > bounds.height - titlebarOnlyTopInset - metrics.cellHeight {
                session?.scroll(delta: 1)
            } else if local.y < metrics.cellHeight {
                session?.scroll(delta: -1)
            }
            sel.cursor = bufferPointFromEvent(event)
            selection = sel
            return
        }
        // No selection in progress — forward to PTY if the app asked for
        // motion/drag reporting.
        if let mode = currentSnapshot?.termMode,
           (mode.contains(.mouseMotion) || mode.contains(.mouseDrag)),
           let session {
            sendMouseEvent(event, button: 32, press: true, session: session)
        }
    }

    private func bufferPointFromEvent(_ event: NSEvent) -> BufferPoint {
        let local = convert(event.locationInWindow, from: nil)
        let snap = currentSnapshot
        // Pass the text-area height (bounds minus the titlebar inset), since
        // `.fullSizeContentView` means `bounds.height` includes the titlebar
        // region which the text grid doesn't occupy.
        return bufferPoint(
            forView: local,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight,
            viewportHeight: bounds.height - titlebarOnlyTopInset,
            displayOffset: snap?.displayOffset ?? 0,
            cols: snap?.cols ?? 80,
            rows: snap?.rows ?? 24
        )
    }

    // MARK: - ⌘-click URL resolution (OSC 8 first, regex fallback)

    /// Resolve a click to a URL. OSC 8 attribution on the cell wins; only
    /// when the cell has no OSC 8 href do we fall back to regex URL
    /// detection (matching pre-Task-7 behaviour for tools that don't emit
    /// OSC 8 hyperlinks). Returns nil when neither path produces a URL.
    ///
    /// `screenRow` is 0-based from the top of the visible viewport — OSC 8
    /// attribution is stored keyed to screen cells, not buffer lines.
    private func resolveClickURL(screenRow: Int, col: Int) -> URL? {
        // Whatever the URL origin — OSC 8 attribution or regex detection —
        // the final NSWorkspace.open surface is the same hostile one.
        // Apply the allowlist on every exit path so a future loosening
        // of the regex (e.g. to include `ssh://`) doesn't silently light
        // up a new attack path. OSC8URLPolicy is intentionally named
        // generically: it's the single URL-open policy for the app.
        let allow: (URL?) -> URL? = { url in
            guard let url, OSC8URLPolicy.isAllowed(url) else { return nil }
            return url
        }
        #if DEBUG
        if let override = hyperlinkResolverOverride {
            if let u = allow(override.osc8URL(row: screenRow, col: col)) { return u }
            return allow(override.regexURL(row: screenRow, col: col))
        }
        #endif
        guard let snap = currentSnapshot else { return nil }
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        if let u = allow(resolver.osc8URL(row: screenRow, col: col)) { return u }
        return allow(resolver.regexURL(row: screenRow, col: col))
    }

    // MARK: - Hover dwell tooltip + accent underline

    /// Install a full-bounds tracking area that delivers `mouseMoved` even
    /// when no buttons are down. Recreated on every bounds change; the
    /// `.inVisibleRect` option makes AppKit re-resolve the rect on each
    /// delivery so tab splits / window resizes don't leave a stale region.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
            hoverTrackingArea = nil
        }
        let ta = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved,
                .mouseEnteredAndExited,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        hoverTrackingArea = ta
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = bufferPointFromEvent(event)
        let screenRow = Int(point.line) + (currentSnapshot?.displayOffset ?? 0)
        let col = point.col
        updateHover(screenRow: screenRow, col: col, locationInWindow: event.locationInWindow)
        // DEC mode 1003 — any-event tracking. When the TUI has asked for
        // motion reports (without requiring a button), emit a motion
        // event even in the no-button case. xterm uses button 35 (32 +
        // 3 "release", which the protocol uses to mean "no button
        // currently pressed"). Fires only when the hover cell actually
        // changed so we don't flood the PTY at pointer-update cadence.
        // Audit terminal-view-2 F14.
        if let session, mouseReportingEnabled(), anyEventMouseEnabled(),
           !event.modifierFlags.contains(.option),
           lastReportedMotionCell != BBXYPoint(col: col, row: screenRow) {
            lastReportedMotionCell = BBXYPoint(col: col, row: screenRow)
            sendMouseEvent(event, button: 35, press: true, session: session)
        }
    }

    private struct BBXYPoint: Equatable { let col: Int; let row: Int }
    /// Last (col, row) reported via DEC 1003 any-event tracking, for
    /// per-cell deduplication. Reset by leaving the view.
    private var lastReportedMotionCell: BBXYPoint?

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func updateHover(screenRow: Int, col: Int, locationInWindow: NSPoint) {
        // Resolve the OSC 8 link id for the cell under the pointer. A
        // test-supplied fake may override; otherwise consult the live
        // snapshot directly. `linkID` bounds-checks internally, so an
        // out-of-grid coordinate just returns 0 (which clears the hover).
        //
        // Gate on `OSC8URLPolicy` so cells whose OSC 8 target fails the
        // scheme allowlist (javascript:, data:, custom handlers) don't
        // paint a hover underline or fire a tooltip. The click path is
        // already blocked upstream — showing an affordance for a no-op
        // click would be misleading.
        let newLinkID: UInt32 = {
            #if DEBUG
            if let override = hyperlinkResolverOverride {
                // Fakes answer via osc8URL — collapse URL presence into a
                // stable non-zero id so the renderer underline path still
                // fires without us needing a real link-id table in tests.
                return override.osc8URL(row: screenRow, col: col) != nil ? UInt32(bitPattern: Int32(-1)) : 0
            }
            #endif
            guard let snap = currentSnapshot else { return 0 }
            let id = snap.linkID(row: screenRow, col: col)
            guard id != 0,
                  let raw = snap.linkURL(id: id),
                  let url = URL(string: raw),
                  OSC8URLPolicy.isAllowed(url)
            else { return 0 }
            return id
        }()

        // Same cell as last move → nothing to update except the tooltip
        // position is already correct. Bail to avoid timer churn.
        if let last = lastHoverCell, last.row == screenRow, last.col == col {
            return
        }
        lastHoverCell = (row: screenRow, col: col)

        if newLinkID != hoveredLinkID {
            hoveredLinkID = newLinkID
            // Redraw so the accent underline picks up / drops off the cells
            // sharing the new hovered id.
            needsDisplay = true
        }

        // Reset any pending tooltip when the pointer moves to a different
        // cell. Production matches VS Code / iTerm2 feel: tooltip appears
        // only after a steady dwell.
        hoverTooltipItem?.cancel()
        hoverTooltipItem = nil
        dismissHoverTooltip()

        guard newLinkID != 0 else { return }

        // Resolve the URL so the tooltip shows the href, not just "there is
        // a link here". For the test fake this goes through osc8URL; for
        // production it's the snapshot's link table.
        let resolvedURLString: String? = {
            #if DEBUG
            if let override = hyperlinkResolverOverride {
                return override.osc8URL(row: screenRow, col: col)?.absoluteString
            }
            #endif
            return currentSnapshot?.linkURL(id: newLinkID)
        }()
        guard let urlString = resolvedURLString else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHoverTooltip(urlString: urlString, anchor: locationInWindow)
        }
        hoverTooltipItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func clearHover() {
        lastHoverCell = nil
        cancelHoverTooltip()
        clearHoveredLink()
    }

    /// Cancel any pending tooltip reveal and drop the tooltip panel if it's
    /// up. Does NOT clear the accent underline / hovered-link id — that
    /// belongs to `clearHoveredLink()`. Called from keyDown so typing
    /// dismisses the dwell tooltip without simultaneously stripping the
    /// underline off the link the user is still hovering. (Previously this
    /// did clear the link id too, so a single keystroke killed the underline
    /// until the pointer physically moved off and back onto the link.)
    private func cancelHoverTooltip() {
        hoverTooltipItem?.cancel()
        hoverTooltipItem = nil
        dismissHoverTooltip()
    }

    /// Drop the accent underline + hovered-link id and force a repaint.
    /// Called from `clearHover` (mouseExited / scroll-invalidates-cache) and
    /// `deinit`. Decoupled from the tooltip so keyDown can dismiss the
    /// tooltip alone without disturbing the underline.
    private func clearHoveredLink() {
        guard hoveredLinkID != 0 else { return }
        hoveredLinkID = 0
        // Push the cleared id straight to the renderer so the next frame
        // drops the underline even before the usual draw-path plumbing runs.
        renderer.setHoveredLinkID(0)
        needsDisplay = true
    }

    private func showHoverTooltip(urlString: String, anchor: NSPoint) {
        guard let window else { return }
        let panel: NSPanel
        let label: NSTextField
        if let existingPanel = hoverTooltipPanel, let existingLabel = hoverTooltipLabel {
            panel = existingPanel
            label = existingLabel
        } else {
            // .nonactivatingPanel keeps the terminal's key-window / first-
            // responder state intact while the tooltip is visible, so a
            // hover-peek doesn't disrupt typing.
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 20),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true

            let container = NSView(frame: .zero)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            container.layer?.cornerRadius = 4
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor = NSColor.separatorColor.cgColor

            let lbl = NSTextField(labelWithString: "")
            lbl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            lbl.textColor = .labelColor
            lbl.lineBreakMode = .byTruncatingMiddle
            lbl.maximumNumberOfLines = 1
            container.addSubview(lbl)
            panel.contentView = container

            hoverTooltipPanel = panel
            hoverTooltipLabel = lbl
            label = lbl
        }
        // Clamp the displayed URL. A misbehaving remote could stuff
        // megabytes of OSC 8 target into the link table; sizing an
        // NSTextField against it would hang the UI and push the panel
        // off-screen. 512 chars covers every realistic URL; anything
        // over that gets an ellipsis so the user still sees the origin.
        let maxDisplay = 512
        label.stringValue = urlString.count > maxDisplay
            ? String(urlString.prefix(maxDisplay)) + "…"
            : urlString
        label.sizeToFit()
        let padX: CGFloat = 8, padY: CGFloat = 4
        let labelFrame = NSRect(
            x: padX, y: padY,
            width: min(label.frame.width, 600),
            height: label.frame.height
        )
        label.frame = labelFrame
        let panelSize = NSSize(
            width: labelFrame.width + padX * 2,
            height: labelFrame.height + padY * 2
        )
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)

        // Anchor just below the pointer. Convert the view-local anchor to
        // screen space via the window's coordinate system.
        let windowPoint = anchor
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let origin = NSPoint(
            x: screenPoint.x + 12,
            y: screenPoint.y - panelSize.height - 12
        )
        panel.setFrame(
            NSRect(origin: origin, size: panelSize),
            display: true
        )
        panel.orderFront(nil)
    }

    private func dismissHoverTooltip() {
        hoverTooltipPanel?.orderOut(nil)
    }

    /// Grow the current `.word` or `.line` selection outward from `anchor`.
    /// `.word` uses the shared `wordRange(around:in:displayOffset:)` helper;
    /// `.line` selects the entire grid line.
    private func expandSelectionUnderAnchor() {
        guard var sel = selection, let snap = currentSnapshot else { return }
        switch sel.mode {
        case .word:
            if let (a, b) = wordRange(around: sel.anchor, in: snap, displayOffset: snap.displayOffset) {
                sel.anchor = a
                sel.cursor = b
                selection = sel
            }
        case .line:
            sel.anchor = BufferPoint(line: sel.anchor.line, col: 0)
            sel.cursor = BufferPoint(line: sel.cursor.line, col: snap.cols - 1)
            selection = sel
        default:
            break
        }
    }

    private func sendMouseEvent(_ event: NSEvent, button: Int, press: Bool, session: TerminalSession) {
        let loc = convert(event.locationInWindow, from: nil)
        // Paranoia. `event.locationInWindow` is a CGFloat; a misbehaving
        // input device or a bridged NaN / Infinity can slip through, and
        // `Int(NaN)` / `Int(±Inf)` trap. Guard before the cast rather
        // than after — the scrollWheel path already uses this pattern.
        guard loc.x.isFinite, loc.y.isFinite else { return }
        let rowY = (bounds.height - titlebarOnlyTopInset - loc.y) / metrics.cellHeight
        let colX = loc.x / metrics.cellWidth
        // Clamp to a sane cell range so oversized coordinates (user
        // scrolled the window off the right edge of a 200k-col display)
        // don't overflow Int32 when encodeMouseReport stringifies them.
        // Division of a finite by a positive cellWidth/Height is finite,
        // so no second isFinite check is needed.
        let maxCol = 10_000, maxRow = 10_000
        let col = max(0, min(maxCol, Int(colX)))
        let row = max(0, min(maxRow, Int(rowY)))
        guard let bytes = Self.encodeMouseReport(
            sgr: sgrMouseEnabled(),
            button: button,
            press: press,
            col: col,
            row: row
        ) else { return }
        session.send(bytes)
    }

    // MARK: - NSAccessibility -------------------------------------------

    /// Cached accessibility value keyed by snapshot identity. Building the
    /// string walks the entire grid (rows × cols) and allocates a fresh
    /// `String` per row, so VoiceOver's habit of polling `accessibilityValue`
    /// many times per snapshot would otherwise turn into a per-frame tax on
    /// the main thread. Identity-via-raw-pointer works because BBSnapshot
    /// instances are immutable + ref-counted: equal address ⇒ equal content.
    private struct A11yCache {
        var snapshotIdentity: UnsafeRawPointer? = nil
        var value: String = ""
        /// Number of times `accessibilityValue()` walked the grid. Used by
        /// tests to assert the cache short-circuits repeat reads.
        var computations: Int = 0
    }

    private var a11yCache = A11yCache()

    public override func isAccessibilityElement() -> Bool {
        // When the find bar is installed, declaring ourselves a leaf would
        // hide its text fields and buttons from VoiceOver entirely — AppKit
        // stops descending into subviews of an accessibility-leaf parent.
        // Become a container in that mode; `accessibilityChildren()` below
        // exposes the find bar (and every other subview) so VO can reach
        // them. When the bar is absent, keep the leaf behaviour so VO
        // focus lands on a single "Terminal" element (matches what
        // `testStaticTextRole` pins).
        findBar == nil
    }

    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    public override func accessibilityLabel() -> String? { "Terminal" }

    public override func accessibilityHelp() -> String? {
        "Terminal output. Scroll back to read earlier content."
    }

    public override func accessibilityChildren() -> [Any]? {
        // Only meaningful when we're in container mode (find bar visible).
        // AppKit ignores `accessibilityChildren()` on a leaf, but returning
        // the default (super) here keeps behaviour symmetric in case a
        // future tool inspects the value directly.
        guard let bar = findBar else { return super.accessibilityChildren() }
        // Order matters for VO navigation: bar on top visually, every
        // other subview below. Covers drop-highlight / bell flash / scroll
        // indicator in case any of them ever grow accessibility affordances.
        var kids: [Any] = [bar]
        for sub in subviews where sub !== bar {
            kids.append(sub)
        }
        return kids
    }

    public override func accessibilityValue() -> Any? {
        // Test overrides take precedence so headless tests can inject a
        // deterministic grid without a running BBTerm. Under production
        // builds the #if DEBUG branch compiles out entirely.
        #if DEBUG
        let source: A11ySnapshotSource? = a11ySnapshotOverride ?? currentSnapshot
        #else
        let source: A11ySnapshotSource? = currentSnapshot
        #endif
        guard let source else { return "" }
        let identity = source.a11yIdentity
        if a11yCache.snapshotIdentity == identity {
            return a11yCache.value
        }
        let computed = source.visibleRowsAsText()
            .map { $0.trimmingTrailingWhitespace() }
            .joined(separator: "\n")
        a11yCache.snapshotIdentity = identity
        a11yCache.value = computed
        a11yCache.computations += 1
        return computed
    }

    #if DEBUG
    /// Test introspection for the a11y cache. Lets `AccessibilityTests`
    /// assert that `accessibilityValue()` short-circuits when the snapshot
    /// hasn't changed.
    var accessibilityCacheStatsForTests: (computations: Int, snapshotIdentity: UnsafeRawPointer?) {
        (a11yCache.computations, a11yCache.snapshotIdentity)
    }

    /// Headless constructor for tests. Uses the system Metal device so the
    /// renderer's command-queue requirement is satisfied; tests never call
    /// `draw(in:)` so no frames are rendered. Skips the test entirely on
    /// hosts without a Metal device (CI runners sometimes don't have one).
    static func makeHeadlessForTests() -> TerminalView? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100),
            device: device
        )
    }

    /// Install a fake snapshot that the a11y value path will consume.
    /// Assigns a fresh identity each call so cache invalidation is exercised.
    func installSnapshotForTests(rows: [String]) {
        a11ySnapshotOverride = A11yFakeSnapshot(rows: rows)
        // New identity ⇒ next accessibilityValue() must recompute.
        a11yCache.snapshotIdentity = nil
    }

    /// Test mutator for `urlOpener`. Kept as a DEBUG property so production
    /// code can't accidentally repoint it — the click path uses the
    /// internal `urlOpener` directly.
    var urlOpenerForTests: URLOpener {
        get { urlOpener }
        set { urlOpener = newValue }
    }

    /// Install a fake hyperlink resolver that answers both OSC 8 and regex
    /// queries without needing a live `BBTerm`. `rows` is the visible grid
    /// as strings (one per row) and `spans` describes every OSC 8 region.
    /// Any cell inside a span resolves its `osc8URL`; everything else
    /// falls through to regex detection against the row text.
    func installHyperlinkSnapshotForTests(
        rows: [String],
        linkAt spans: [(row: Int, cols: Range<Int>, url: String)]
    ) {
        hyperlinkResolverOverride = FakeHyperlinkSnapshot(rows: rows, spans: spans)
    }

    /// Exercise the production ⌘-click resolution against the current
    /// snapshot (real or fake). Tests call this instead of synthesising
    /// NSEvents so the mouse-reporting / option-modifier gating above
    /// doesn't need a full windowed host.
    func performCmdClickForTests(row: Int, col: Int) {
        if let url = resolveClickURL(screenRow: row, col: col) {
            urlOpener.open(url)
        }
    }

    /// Swap the encoder's Option-is-Meta setting without going through the
    /// full `Preferences.shared` publisher chain. IME tests use this to pin
    /// Native-Option mode before exercising dead-key composition.
    func setOptionIsMetaForTests(_ flag: Bool) {
        if encoder.optionIsMeta != flag {
            encoder = KeyEncoder(optionIsMeta: flag)
        }
    }

    /// Pin the cursor row/col that the IME path reads for
    /// `firstRect(forCharacterRange:…)`. Lets tests assert the candidate-
    /// window anchor without feeding the Rust term a full grid of input.
    func installCursorForTests(row: Int, col: Int) {
        cursorOverrideForTests = (row: row, col: col)
    }

    /// Read the effective frame-rate cap that the power-aware controller
    /// has applied to this MTKView. Returns `0` when the view is paused
    /// (occluded, or the policy chose `.paused`); otherwise the current
    /// `preferredFramesPerSecond`. Used by `PowerAwareRenderingTests` to
    /// assert the notification observers actually drive
    /// `applyPowerAwareFrameRate()` — without this hook, the observer
    /// plumbing is invisible from the test harness.
    var _testOnly_currentFrameRateCap: Int {
        return self.isPaused ? 0 : self.preferredFramesPerSecond
    }

    /// Force-run the power-aware-rate recompute as if a notification had
    /// fired. Tests use this to validate the `applyPowerAwareFrameRate`
    /// path when they can't guarantee a notification observer fires
    /// synchronously on the current RunLoop iteration.
    func _testOnly_applyPowerAwareFrameRate() {
        self.applyPowerAwareFrameRate()
    }
    #endif

    /// Pure encoder for xterm mouse reports — extracted so the branches that
    /// matter for correctness (SGR 1006 vs X10 fallback, press/release,
    /// wheel/motion) can be unit-tested without synthesizing NSEvents.
    ///
    /// - `sgr`: true when the app enabled SGR extended mouse reporting
    ///   (mode 1006). The final byte `M`/`m` distinguishes press from
    ///   release and the button number is carried verbatim.
    /// - `button`: the xterm button number — 0/1/2 for left/middle/right,
    ///   32 for motion-with-button, 64/65 for wheel up/down.
    /// - `press`: false for release events. In the X10 fallback (modes
    ///   1000/1002/1003), release always reports button bits = 3 regardless
    ///   of which button was released.
    ///
    /// Returns `nil` when X10 can't represent the position (cols/rows
    /// beyond 223). SGR has no such limit.
    static func encodeMouseReport(
        sgr: Bool,
        button: Int,
        press: Bool,
        col: Int,
        row: Int
    ) -> Data? {
        // Defensive guards — callers today pass 0…65 for button and
        // clamp col/row to 10 000, but a future caller outside the
        // TerminalView flow could exceed those bounds. X10's 6-byte
        // encoding traps on `UInt8(cbButton + 32)` when `cbButton >
        // 223`, and SGR's `\(button)` stringifies every value
        // including pathological ones. Reject up-front so the trap
        // surface stays bounded to this function, not the caller.
        guard (0..<224).contains(button), col >= 0, row >= 0 else { return nil }
        if sgr {
            // SGR 1006: ESC [ < button ; col+1 ; row+1 M/m
            let finalChar: Character = press ? "M" : "m"
            let seq = "\u{1B}[<\(button);\(col + 1);\(row + 1)\(finalChar)"
            return Data(seq.utf8)
        }
        // X10/normal: ESC [ M cb cx cy (6-byte, cx/cy capped at 223).
        guard col < 223, row < 223 else { return nil }
        let cbButton = press ? button : 3
        let cb = UInt8(cbButton + 32)
        let cx = UInt8(col + 33)
        let cy = UInt8(row + 33)
        return Data([0x1B, 0x5B, 0x4D, cb, cx, cy])
    }
}

// MARK: - Modifier mapping

extension KeyEncoder.Modifiers {
    init(event: NSEvent) {
        var mods: KeyEncoder.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }
}

#if DEBUG
/// Test-only snapshot source. Emits the rows it was constructed with
/// verbatim, and uses its own `ObjectIdentifier` as a stable-but-unique
/// raw-pointer identity. Living in the Blackbird module (not BBCore) keeps
/// it out of shipping binaries via the #if DEBUG guard around the whole
/// file scope.
final class A11yFakeSnapshot: A11ySnapshotSource {
    private let rows: [String]
    init(rows: [String]) { self.rows = rows }

    func visibleRowsAsText() -> [String] { rows }

    var a11yIdentity: UnsafeRawPointer {
        // ObjectIdentifier wraps the class-instance address; unwrapping
        // guarantees a non-null pointer unique for the life of this
        // instance, which is exactly the cache-key contract we need.
        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }
}

/// Test-only hyperlink resolver. Production goes through
/// `SnapshotHyperlinkResolver`, which needs a real `BBSnapshot`; this fake
/// answers both OSC 8 and regex queries from plain strings so tests can
/// exercise the ⌘-click path without starting a PTY.
final class FakeHyperlinkSnapshot: HyperlinkResolver {
    struct Span {
        let row: Int
        let cols: Range<Int>
        let url: URL?
    }

    private let rows: [String]
    private let spans: [Span]

    init(rows: [String], spans: [(row: Int, cols: Range<Int>, url: String)]) {
        self.rows = rows
        self.spans = spans.map {
            Span(row: $0.row, cols: $0.cols, url: URL(string: $0.url))
        }
    }

    func osc8URL(row: Int, col: Int) -> URL? {
        for span in spans where span.row == row && span.cols.contains(col) {
            return span.url
        }
        return nil
    }

    func regexURL(row: Int, col: Int) -> URL? {
        guard row >= 0, row < rows.count else { return nil }
        let line = rows[row]
        let nsLine = line as NSString
        // Same pattern the production `URLDetector` uses so fallback
        // semantics match. The regex is rebuilt per call — fine for tests,
        // the grid is tiny.
        let pattern = #"(?i)(?:https?|ftp|file)://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: nsLine.length)
        var found: URL?
        regex.enumerateMatches(in: line, range: range) { result, _, stop in
            guard var r = result?.range else { return }
            // Trim trailing punctuation that production trims too, so the
            // fallback URL matches what the real URLDetector would return.
            while r.length > 0 {
                let last = nsLine.character(at: r.location + r.length - 1)
                if ".,);:]}>'\"".utf16.contains(last) { r.length -= 1 } else { break }
            }
            guard r.length > 0 else { return }
            if col >= r.location && col < r.location + r.length {
                let sub = nsLine.substring(with: r)
                if let url = URL(string: sub) {
                    found = url
                    stop.pointee = true
                }
            }
        }
        return found
    }
}
#endif

extension TerminalView: FindBarDelegate {
    public func findBar(_ bar: FindBar, didChangeQuery query: String) {
        performSearch(query: query)
    }

    public func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {
        advanceFind(direction: direction)
    }

    public func findBar(_ bar: FindBar, didChangeOptions options: FindBar.Options) {
        // Re-run the current query with the new options. Safe no-op
        // when the query is empty (performSearch short-circuits).
        performSearch(query: findQuery)
    }

    public func findBarDidClose(_ bar: FindBar) {
        findBar?.removeFromSuperview()
        findBar = nil
        // F10: wipe match state so ⌘G after close doesn't cycle stale
        // coordinates against a mutated buffer or a new (yet-unissued) query.
        findMatches.removeAll()
        findCurrentIndex = 0
        findQuery = ""
        // F30: deliberately preserve `selection` so Esc-then-⌘C on a found
        // match still copies. The selection is wiped by the next mouse click
        // or shell-bound keystroke (see keyDown handler).
        window?.makeFirstResponder(self)
    }

    public func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String) {
        switch kind {
        case .current: replaceCurrentMatch(with: replacement)
        case .all:     replaceAllMatches(with: replacement)
        }
    }

    /// F3: TUI-guard. Refuses replace when the terminal mode indicates a
    /// full-screen TUI is running (vim, less, htop) — alt-screen, any
    /// mouse-reporting flag, or bracketed-paste active. In those modes the
    /// DEL+UTF-8 byte stream emitted by `sendReplacement` would be
    /// interpreted as key input by the TUI instead of readline-style erase.
    public func findBarShouldAllowReplace(_ bar: FindBar) -> Bool {
        guard let mode = effectiveSnapshot()?.termMode else {
            // No snapshot yet → nothing to replace anyway; err on "allow" so
            // tests that don't stub a snapshot still exercise the old path.
            return true
        }
        let tuiSignals: BBTermMode = [
            .altScreen,
            .mouseReportClick,
            .mouseMotion,
            .mouseDrag,
            .sgrMouse,
            .bracketedPaste,
        ]
        return mode.intersection(tuiSignals).isEmpty
    }
}

// MARK: - Replace helpers

extension TerminalView {
    /// Replace the current find match with `replacement`. Only works when the
    /// match is on the live input line (cursor row). Otherwise a transient
    /// warning is shown in the find bar.
    func replaceCurrentMatch(with replacement: String) {
        let matches = effectiveFindMatches()
        guard !matches.isEmpty, findCurrentIndex < matches.count else { return }
        let m = matches[findCurrentIndex]
        guard isOnLiveInputLine(m) else {
            findBar?.showTransientMessage("Only input-line matches can be replaced")
            return
        }
        sendReplacement(match: m, replacement: replacement)
        // The replacement edits the shell line; every recorded match on that
        // line has now shifted or vanished. Drop the cache so find-next
        // doesn't scroll to a stale coordinate.
        findMatches.removeAll()
        findCurrentIndex = 0
        findBar?.setMatchCount(0, of: 0)
    }

    /// Replace all find matches with `replacement`, processing right-to-left so
    /// earlier column indices stay valid as the shell receives each replacement.
    /// Matches not on the live input line are skipped; if any were skipped a
    /// warning is shown in the find bar.
    func replaceAllMatches(with replacement: String) {
        let matches = effectiveFindMatches()
        guard !matches.isEmpty else { return }
        guard let snap = effectiveSnapshot() else { return }
        let cursorLine = Int32(snap.cursorRow)
        let inputLineMatches = matches.filter { $0.line == cursorLine }

        let hadOffLine = inputLineMatches.count < matches.count
        if inputLineMatches.isEmpty {
            findBar?.showTransientMessage("No input-line matches to replace")
            return
        }
        // Process right-to-left so earlier col indices remain valid.
        for m in inputLineMatches.sorted(by: { $0.startCol > $1.startCol }) {
            sendReplacement(match: m, replacement: replacement)
        }
        // All input-line matches have been spliced; invalidate the cache.
        findMatches.removeAll()
        findCurrentIndex = 0
        findBar?.setMatchCount(0, of: 0)
        if hadOffLine {
            findBar?.showTransientMessage("Replaced input-line matches (scrollback skipped)")
        }
    }

    /// Emits DEL×N bytes to erase the matched span, then the UTF-8 replacement.
    private func sendReplacement(
        match m: (line: Int32, startCol: Int, endCol: Int),
        replacement: String
    ) {
        let matchLen = m.endCol - m.startCol + 1
        guard matchLen > 0 else { return }
        let delBytes = Data(repeating: 0x7F, count: matchLen)
        #if DEBUG
        if let capture = replaceByteCapture {
            capture(delBytes)
            if !replacement.isEmpty { capture(Data(replacement.utf8)) }
            return
        }
        #endif
        guard let session else { return }
        session.send(delBytes)
        if !replacement.isEmpty {
            session.send(Data(replacement.utf8))
        }
    }

    /// Returns true when the match's buffer line equals the cursor's buffer line,
    /// i.e. the match is on the live shell input line.
    private func isOnLiveInputLine(_ m: (line: Int32, startCol: Int, endCol: Int)) -> Bool {
        guard let snap = effectiveSnapshot() else { return false }
        return m.line == Int32(snap.cursorRow)
    }

    /// The snapshot to use for replace logic: test override when set, else the live one.
    private func effectiveSnapshot() -> BBSnapshot? {
        #if DEBUG
        if let override = replaceSnapshotForTests { return override }
        #endif
        return currentSnapshot
    }

    /// The find-matches array to use for replace logic: test override when set, else live.
    private func effectiveFindMatches() -> [(line: Int32, startCol: Int, endCol: Int)] {
        #if DEBUG
        if let override = replaceFindMatchesForTests { return override }
        #endif
        return findMatches
    }

    /// Responder action for ⌘⌥E. Behaviour:
    ///   - Bar hidden  → install the bar, expand the replace row, focus find field.
    ///   - Bar visible, replace collapsed → expand the replace row.
    ///   - Bar visible, replace already expanded → trigger replace-current on
    ///     the active match (same effect as clicking the "Replace" button).
    @objc public func performReplaceCurrent(_ sender: Any?) {
        if findBar == nil {
            installFindBar()
            findBar?.setReplaceVisible(true)
            findBar?.focus()
            return
        }
        guard let bar = findBar else { return }
        if !bar.isReplaceVisible {
            bar.setReplaceVisible(true)
            return
        }
        bar.triggerReplaceCurrent()
    }
}
