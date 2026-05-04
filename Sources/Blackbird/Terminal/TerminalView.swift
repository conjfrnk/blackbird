import AppKit
import Carbon.HIToolbox
import CoreText
import Combine
import Metal
import MetalKit
// `os.Logger` is used by `securityLogger` (Release-visible, audit
// channel) and by the DEBUG-only fpsLogger / keyLogger / hoverLogger.
// The audit-H1 fix moved security logging out of the DEBUG block, so
// the import must follow.
import os

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

/// MTKView that renders a BBSnapshot via Metal (`MetalRenderer` +
/// `GlyphAtlas` + per-cell instancing) and forwards keyboard input
/// through `KeyEncoder` to a `TerminalSession`. ProMotion 120 Hz is
/// achieved via `CAMetalLayer.maximumDrawableCount = 3` (the comment
/// further down in `setupTerminalView` explains the coalescer
/// interaction).
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

    /// Snapshot of the preferences fields this view actually observes —
    /// `fontName`, `fontSize`, and `optionKey`. Used by the preferences
    /// Combine sink to short-circuit when the emitted
    /// `objectWillChange` was driven by an unrelated property (theme
    /// swap, translucency slider, etc.). Audit terminal-view-1 F4.
    private struct PrefsObservedKey: Equatable {
        let fontName: String
        let fontSize: Double
        let optionKey: Preferences.OptionKey
    }
    private var lastObservedPrefsKey: PrefsObservedKey?

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
            // Reset both the value-cache identity AND the line-offsets
            // table. They're correlated: lineOffsets is computed from the
            // cached value, so any path that recomputes value MUST also
            // discard the offsets. Without the lineOffsets reset, an
            // a11y line accessor running between this didSet and the
            // next `accessibilityValue()` call would build offsets
            // against the OLD value and cache them under whatever
            // identity gets stamped next.
            a11yCache.snapshotIdentity = nil
            a11yCache.lineOffsets = nil
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
    /// render path uses `currentSnapshot`. Visibility relaxed from
    /// `private` to `internal` so `installSnapshotForTests` (in
    /// `TerminalView+Accessibility.swift`) can write it; no production
    /// caller touches this field — the `#if DEBUG` guard keeps it out of
    /// release builds entirely.
    #if DEBUG
    var a11ySnapshotOverride: A11ySnapshotSource?
    /// Test-only override for the ⌘-click URL resolver. When set, the click
    /// path goes through this fake instead of building a
    /// `SnapshotHyperlinkResolver` from `currentSnapshot`. Production leaves
    /// it nil.
    // `internal` so `TerminalView+Hover.swift` / `TerminalView+...
    // .swift` can read (and tests via installHyperlinkSnapshotForTests
    // can write) across file boundaries. Production never mutates this
    // — the DEBUG guard keeps the member out of release builds.
    var hyperlinkResolverOverride: HyperlinkResolver?
    #endif

    /// Hook for opening a URL on ⌘-click. Production hands the URL to
    /// `NSWorkspace`; tests inject a recording fake so assertions can
    /// match what the click path actually dispatched.
    var urlOpener: URLOpener = DefaultURLOpener()

    // MARK: - Hover state (OSC 8 dwell tooltip + hover underline)

    /// Buffer row under the cursor on the last `mouseMoved` delivery, used
    /// to cancel the dwell timer as soon as the pointer leaves the current
    /// cell. `nil` means the pointer is outside the grid.
    var lastHoverCell: (row: Int, col: Int)?       // internal for TerminalView+Hover.swift
    /// Link id under the pointer right now, or 0 when the hovered cell has
    /// no OSC 8 attribution. The renderer reads this each frame to draw
    /// the accent underline on every cell sharing the id.
    var hoveredLinkID: UInt32 = 0                 // internal for TerminalView+Hover.swift

    /// Latched ⌘-modifier state. Updated via `flagsChanged`, reconciled
    /// against `NSEvent.modifierFlags` on every `mouseMoved` (so a key
    /// release missed during a focus switch is caught on the next
    /// mouse movement), and force-cleared on `didResignKeyNotification`
    /// so a stale "⌘ held" can't survive a tab or window switch.
    var cmdModifierHeld: Bool = false             // internal for TerminalView+Hover.swift

    /// While ⌘ is held and the pointer rests on a regex-detected URL,
    /// this holds the match so `clearHover`, the cursor updater, and
    /// the renderer can coordinate without re-running the scan. Cleared
    /// when ⌘ releases, the pointer leaves the match, or the view loses
    /// focus.
    var cmdHoverURLMatch: URLMatch?               // internal for TerminalView+Hover.swift

    /// Lazily computed URL match list for the current snapshot. Rebuilt
    /// only when `snapshot.sequenceID` changes so trackpad-cadence
    /// `mouseMoved` with ⌘ held costs O(1) lookups, not an O(rows × cols)
    /// scan per move. Audit cwd-hyperlink F7.
    ///
    /// `cachedURLMatchesSeq` is `Optional<UInt64>` rather than a `0`
    /// sentinel: "never scanned" and "scanned at seq 0" would otherwise
    /// compare equal and skip a legitimate scan. BBSnapshot's allocator
    /// today starts at 1 (see BBTerm.allocateSequence) but we don't want
    /// correctness to depend on that.
    var cachedURLMatches: [URLMatch] = []         // internal for TerminalView+Hover.swift
    var cachedURLMatchesSeq: UInt64?              // internal for TerminalView+Hover.swift
    /// Trackpad pinch gesture accumulator. Magnification events deliver
    /// fractional deltas; we wait until the running sum crosses ±0.15
    /// before bumping `Preferences.shared.fontSize`. Without the accumulator
    /// a single flick would fire dozens of font-size changes and fly past
    /// the intended zoom level.
    private var pinchAccumulator: CGFloat = 0
    /// Scheduled tooltip reveal. Cancelled on pointer movement, scroll,
    /// keydown, or view teardown.
    var hoverTooltipItem: DispatchWorkItem?       // internal for TerminalView+Hover.swift
    /// Lightweight panel that shows the resolved URL after the 500 ms dwell.
    /// Kept around between shows so repeated hovers don't thrash NSPanel
    /// allocation; hidden when not in use.
    var hoverTooltipPanel: NSPanel?               // internal for TerminalView+Hover.swift
    var hoverTooltipLabel: NSTextField?           // internal for TerminalView+Hover.swift
    /// Tracking area that delivers `mouseMoved` / `mouseExited`. Rebuilt on
    /// bounds changes via `updateTrackingAreas`.
    var hoverTrackingArea: NSTrackingArea?        // internal for TerminalView+Hover.swift

    /// Paired coordinate used by DEC 1003 any-event mouse tracking to
    /// dedupe repeated motion reports on the same cell.
    /// `lastReportedMotionCell` lives here because extensions cannot
    /// declare stored properties; both the mouse-reporting section
    /// (which reads the termMode bits) and the hover extension (which
    /// fires the report from `mouseMoved`) share it.
    struct BBXYPoint: Equatable { let col: Int; let row: Int }
    var lastReportedMotionCell: BBXYPoint?

    /// ⌘ + right-drag resizes the window from the nearest corner. The
    /// types + stored property live here (not on the mouse extension)
    /// because Swift disallows stored properties on extensions. The
    /// mouse extension references these by name only.
    enum ResizeCorner { case topLeft, topRight, bottomLeft, bottomRight }
    struct ResizeContext {
        let corner: ResizeCorner
        let startMouseGlobal: CGPoint
        let startFrame: CGRect
    }
    var resizeContext: ResizeContext?

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
    /// Optional capture closure for `pasteText(_:)`. Fires with the pre-
    /// encoding string the paste pipeline received, before CRLF /
    /// control / bracketed-paste sanitisation. Used by `DragDropTests`
    /// to assert that the drop integration produces the right shell-
    /// quoted command-line — the sanitisers have their own coverage.
    var pasteTextRecorderForTests: ((String) -> Void)?
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

    // Public read; writer is `internal` so the hover extension's
    // `expandSelectionUnderAnchor()` and the mouse-selection path on
    // the main class can update the selection. Tests with
    // `@testable import Blackbird` can also write it directly —
    // `didSet` below repaints regardless of the writer, so no gesture
    // path is bypassed for redraw purposes. No production caller
    // outside the view writes this.
    public internal(set) var selection: Selection? {
        didSet {
            if oldValue != selection { setNeedsDisplay(bounds) }
        }
    }
    var isDragging = false                        // internal for TerminalView+Mouse.swift

    /// Repeating timer that drives edge-autoscroll while the user is
    /// dragging a selection past the top/bottom of the viewport. AppKit
    /// only delivers `mouseDragged` on pointer motion, so a user who
    /// holds the pointer stationary past the edge would otherwise see
    /// the autoscroll stall (the selection can't grow into scrollback
    /// rows that are off-screen). Fires at a modest ~60 Hz cadence so
    /// short-duration holds don't feel jittery. Audit terminal-view-2
    /// F2.
    var selectionAutoscrollTimer: Timer?          // internal for TerminalView+Mouse.swift
    /// Latest scroll direction the autoscroll timer is running with: +1
    /// for "reveal older rows" (drag past the top), -1 for "reveal
    /// newer rows" (drag past the bottom). Stored so the timer fires
    /// can replay the same direction without recomputing on each tick.
    var selectionAutoscrollDirection: Int32 = 0   // internal for TerminalView+Mouse.swift

    // `internal` (no modifier) so `TerminalView+Accessibility.swift`'s
    // `isAccessibilityElement` / `accessibilityChildren` can test for
    // its presence across the file boundary. Only `installFindBar()`
    // and the FindBarDelegate close/open path mutate it.
    var findBar: FindBar?
    var findMatches: [(line: Int32, startCol: Int, endCol: Int)] = []   // internal for TerminalView+Find.swift
    var findCurrentIndex: Int = 0                                       // internal for TerminalView+Find.swift
    var findQuery: String = ""                                          // internal for TerminalView+Find.swift
    /// `BBSnapshot.sequenceID` of the snapshot `findMatches` was scanned
    /// against. `nil` when no scan has run yet (or the cache was just
    /// cleared). Used by `advanceFind` / `highlightCurrentMatch` to
    /// detect that output arrived between `performSearch` and the user
    /// pressing ⌘G — in that case the stored (line, col) tuples may
    /// reference cells that now hold different text, so we re-run
    /// `performSearch` against the live snapshot before advancing.
    /// Same `Optional<UInt64>` shape as `cachedURLMatchesSeq` (above) so
    /// "never scanned" and "scanned at seq 0" don't collide. Audit
    /// findbar-selection F11.
    var findMatchesSeq: UInt64?                                         // internal for TerminalView+Find.swift
    /// Monotonic ID assigned to each background regex scan. The latest
    /// scan's ID is `activeRegexSearchID`; when a scan publishes
    /// results, it sets `regexSearchCompletedID = mySearchID` so the
    /// 250 ms timeout sibling task knows whether to fire its
    /// "regex too complex" banner. All three fields are touched only
    /// on the main thread (see TerminalView+Find.swift).
    /// Audit findbar-selection F2.
    var regexSearchIDCounter: UInt64 = 0
    var activeRegexSearchID: UInt64 = 0
    var regexSearchCompletedID: UInt64 = 0

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
    /// Diagnostic channel for the hover/cmd-URL-highlight path. Used only
    /// to log near-misses (cache populated, match lookup returned nil) so
    /// a column-mapping or wrap-join regression is discoverable via
    /// `log stream --predicate 'category == "hover"'`. Off the hot path.
    static let hoverLogger = Logger(subsystem: "dev.conjfrnk.blackbird",  // internal for TerminalView+Hover.swift
                                                category: "hover")
    #endif

    /// Production-visible channel for security-relevant decisions —
    /// blocked OSC 8 phishing-shape clicks, paste-scrub drops, and
    /// similar. Stays outside `#if DEBUG` so a release user reporting
    /// "the link won't open" can `log stream --predicate 'category ==
    /// "security"'` and find a breadcrumb. Privacy: log the decision
    /// shape with `.public`, never log keystrokes / paste contents.
    static let securityLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "security")

    /// Production-visible channel for the mouse-event path's defensive
    /// guards. Right now used only by the M-17 nil-snap warning — a
    /// click that lands before the first BBSnapshot publish maps to a
    /// synthetic 80×24 zero-history grid; without the log, the broken
    /// selection that follows has no breadcrumb. One-shot lock keeps
    /// repeated pre-publish clicks from spamming the unified log.
    /// Internal because both `TerminalView+Mouse.swift` callsites of
    /// `bufferPoint` share the same one-shot.
    static let mouseLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                    category: "mouse")

    /// Production-visible channel for renderer-state mismatches that
    /// the user can surface in support reports. Today this only flags a
    /// failed atlas reconfigure on the font-change path — without it, a
    /// user reporting "I changed font size and nothing happened" has no
    /// breadcrumb the support engineer can correlate against.
    static let rendererLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "renderer")
    static let didLogEarlyClick = OSAllocatedUnfairLock(initialState: false)

    /// One-shot warning for the M-17 pre-first-publish click race. Both
    /// `bufferPointFromEvent` and `bufferPointFromLocalPoint` early-
    /// return into this when `currentSnapshot == nil`; the shared lock
    /// ensures the log fires at most once per process lifetime even
    /// across the two callsites.
    static func logEarlyClickOnce() {
        didLogEarlyClick.withLock { didLog in
            if !didLog {
                didLog = true
                mouseLogger.warning("click before first snapshot publish — bufferPoint returning origin sentinel against synthetic grid")
            }
        }
    }

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
            // MetalRenderer.init? returns nil for any of: command queue
            // creation, default library load, vertex/fragment function
            // lookup, render pipeline state creation, atlas allocation,
            // or instance buffer allocation. The actual error from the
            // failing path is logged via `MetalRenderer.logger` (audit
            // L-6) — `log stream --predicate 'category == "renderer"'`
            // shows the underlying NSError (shader compile error,
            // descriptor mismatch, GPU memory pressure, etc.). The
            // pre-fix message claimed "command queue" specifically,
            // which misled triage when the actual failure was a PSO.
            fatalError("MetalRenderer init failed; see unified log under category=\"renderer\" for the underlying error")
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
        // vblank rate. On a 60 Hz display that's 60 fps; on a ProMotion
        // panel macOS's display coalescer promotes us to 120 fps once
        // the drawable pool size is set to 3 (see below) — verified
        // 8.40 ms steady-state on a built-in Liquid Retina XDR. A
        // 2-deep pool flagged the workload as not-keeping-up and capped
        // at 60 fps even with this hint set. Keep the DEBUG fps
        // diagnostic below as a standing sensor for future regressions.
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

        // Audit terminal-view-1 F3+F4. Preferences.objectWillChange fires
        // on EVERY `@Published` mutation across the preferences object —
        // theme swap, translucency slider, bell mode, etc. — not just the
        // font/encoder-relevant ones. Two-layer mitigation:
        //   F3: subscribe with `.receive(on: DispatchQueue.main)` so the
        //       downstream work is hopped to main exactly once; the old
        //       inner `DispatchQueue.main.async` added a redundant runloop
        //       tick when the publisher was already emitting on main.
        //   F4: dedupe via a cached `(fontName, fontSize, optionKey)`
        //       tuple; skip the NSFontManager / CellMetrics / renderer
        //       work when none of the three observed keys actually moved.
        //       Cuts NSFont lookups from "one per unrelated pref" to
        //       "one per real font/option change".
        //
        // ⚠ FEEDBACK-LOOP HAZARD — DO NOT WRITE USERDEFAULTS HERE. Any write
        // to UserDefaults (directly or via a framework like Sparkle) fires
        // NSUserDefaultsDidChangeNotification, which SwiftUI's global
        // UserDefaultObserver bridges back into Preferences.objectWillChange,
        // re-firing THIS sink indefinitely. See commit 982b719 for the
        // manifest of that hazard in AppDelegate. This closure is safe: it
        // only reads prefs and pushes into CellMetrics / renderer / encoder.
        prefsCancellable = Preferences.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let p = Preferences.shared
                let key = PrefsObservedKey(
                    fontName: p.fontName,
                    fontSize: p.fontSize,
                    optionKey: p.optionKey
                )
                if key == self.lastObservedPrefsKey {
                    return
                }
                self.lastObservedPrefsKey = key
                self.syncFontFromPreferences()
                self.syncEncoderFromPreferences()
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
        guard renderer.reconfigure(metrics: newMetrics, scale: scale) else {
            // Mirror the sibling `mtkView(_:drawableSizeWillChange:)`
            // log: a failed reconfigure (e.g., MTLDevice couldn't allocate
            // a larger atlas at the new font size) leaves the user staring
            // at unchanged metrics with no audit trail. Surface enough
            // context that a support reporter pasting `log show --predicate
            // 'category == "renderer"'` can correlate the moment with a
            // pref change.
            Self.rendererLogger.error(
                "syncFontFromPreferences reconfigure failed — keeping cellW=\(self.metrics.cellWidth, privacy: .public) cellH=\(self.metrics.cellHeight, privacy: .public); requested cellW=\(newMetrics.cellWidth, privacy: .public) cellH=\(newMetrics.cellHeight, privacy: .public) scale=\(scale, privacy: .public)"
            )
            return
        }
        self.metrics = newMetrics
        if let window {
            // Pixel-precise resize: no contentResizeIncrements re-set here
            // either (the original setter shipped before pixel-precise drag).
            // Keep contentMinSize in sync with the new cell size; otherwise
            // bumping the font up doesn't prevent the user from dragging
            // the window below the new font's 20-col / 4-row minimum — they'd
            // end up with a window too small to read comfortably.
            window.contentMinSize = NSSize(
                width: newMetrics.cellWidth * 20 + 2 * Self.horizontalContentInsetPoints,
                height: newMetrics.cellHeight * 4 + 28 + Self.bottomContentInsetPoints
            )
        }
        // Force a grid recomputation on the next layout — propagateResize
        // compares against lastPropagatedSize, so clear it.
        lastPropagatedSize = nil
        // Async resize — font change is a one-off, not a drag loop, so we
        // don't need the sync-return-with-snapshot guarantee. Using the
        // async path prevents coreQueue backlog (shell streaming output)
        // from blocking main while the pref change is applied.
        propagateResize(async: true)
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
        renderer.setLeftInsetPoints(Float(Self.horizontalContentInsetPoints))
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

    /// Space reserved on the left and right of the grid so text never kisses
    /// the window edge. Mirrored on both sides — total horizontal padding is
    /// `2 * horizontalContentInsetPoints`. Sub-cell pixel leftover from
    /// pixel-precise window resize gets absorbed into the right side, so the
    /// effective right inset floats from `horizontalContentInsetPoints` to
    /// `horizontalContentInsetPoints + cellWidth - 1`.
    public static let horizontalContentInsetPoints: CGFloat = 8

    /// Top-left pixel origin of cell `(row, col)` in this view's local
    /// (top-down) coordinate space. Single source of truth for the
    /// grid → view mapping; every callsite that previously did
    /// `col * cellWidth` and `row * cellHeight` directly should route
    /// through this helper so the inset can never drift out of sync.
    public func cellOriginPx(row: Int, col: Int) -> CGPoint {
        let x = Self.horizontalContentInsetPoints + CGFloat(col) * metrics.cellWidth
        let y = titlebarOnlyTopInset + CGFloat(row) * metrics.cellHeight
        return CGPoint(x: x, y: y)
    }

    /// Inverse of `cellOriginPx`. Maps a view-local (top-down) point to a
    /// `(row, col)` cell coordinate. **Does not know the live grid size** —
    /// row/col are only clamped to a generic 100_000-cell sanity cap, so
    /// callers that need a tight `[0, cols)` / `[0, rows)` clamp must
    /// re-clamp against the current `BBSnapshot`. Selection sites that
    /// also need scrollback awareness should use
    /// `Selection.bufferPoint(forView:…, leftInsetPoints:)` instead.
    /// Points inside the left/top inset clamp to `col 0` / `row 0`;
    /// non-finite or absurd-magnitude inputs clamp to the origin sentinel
    /// rather than trapping at `Int(NaN)` / `Int(±Inf)`.
    public func cellAt(point: CGPoint) -> (row: Int, col: Int) {
        let cw = metrics.cellWidth
        let ch = metrics.cellHeight
        guard cw > 0, ch > 0 else { return (0, 0) }
        // Mirror `Selection.bufferPoint(forView:…)`'s defensive clamp so a
        // stray Core Animation NaN or a misbehaving input device can't
        // crash the app at `Int(NaN)` / `Int(±Inf)`. Same `sanePx` ceiling.
        let sanePx: CGFloat = 1_000_000
        let safeX = point.x.isFinite ? min(max(0, point.x), sanePx) : 0
        let safeY = point.y.isFinite ? min(max(0, point.y), sanePx) : 0
        let xInGrid = safeX - Self.horizontalContentInsetPoints
        let yInGrid = safeY - titlebarOnlyTopInset
        let rawCol = Int(max(0, xInGrid) / cw)
        let rawRow = Int(max(0, yInGrid) / ch)
        let col = max(0, min(rawCol, 100_000))
        let row = max(0, min(rawRow, 100_000))
        return (row, col)
    }

    /// Strip the titlebar (top), bottom corner clearance, and L+R inset
    /// from a raw view-bounds size to get the rectangle that actually
    /// hosts the grid. Single source of truth for the formula — both
    /// `propagateResize` and `MainWindowController.startSession` route
    /// through it so the start-size and the first SIGWINCH can never
    /// disagree on what "usable area" means.
    public static func usableViewSize(
        forBounds bounds: CGSize,
        titlebarTopInset: CGFloat,
        metrics: CellMetrics
    ) -> CGSize {
        let usableWidth = max(
            metrics.cellWidth,
            bounds.width - 2 * Self.horizontalContentInsetPoints
        )
        let usableHeight = max(
            metrics.cellHeight,
            bounds.height - titlebarTopInset - Self.bottomContentInsetPoints
        )
        return CGSize(width: usableWidth, height: usableHeight)
    }

    private func propagateResize(async asyncResize: Bool = false) {
        let usable = Self.usableViewSize(
            forBounds: bounds.size,
            titlebarTopInset: titlebarOnlyTopInset,
            metrics: metrics
        )
        let grid = metrics.grid(forPixelSize: usable)
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
        // Without an attached session there's nothing to forward to. The
        // size is still recorded above so resize-math tests can assert
        // against it without spinning up a real PTY.
        guard let session else { return }
        // Drag path uses sync `resize` so each frame renders at the right
        // grid size (avoids one-frame-at-old-grid jitter). Font-change path
        // (and any other non-drag caller) uses `resizeAsync` to keep the
        // main thread from blocking on coreQueue when a chatty shell has a
        // feed backlog — otherwise clicking "Size: 14" in Settings while
        // something's streaming output beachballs for hundreds of ms.
        if asyncResize {
            session.resizeAsync(to: size)
        } else {
            session.resize(to: size)
        }
    }

    #if DEBUG
    /// DEBUG-only accessor so unit tests can assert what the most recent
    /// `propagateResize` call computed for the grid.
    public func lastPropagatedSizeForTesting() -> PTY.Size? { lastPropagatedSize }
    #endif

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
        // Bugs #14 + #15: invalidate the active selection on snapshot
        // transitions that move the cells its BufferPoints address.
        //
        //  - #14 (column reflow): `Selection.anchor` / `cursor` are
        //    `BufferPoint(line, col)` pinned to the pre-reflow grid. When
        //    the user shrinks the window's cols (alacritty's wrapped
        //    scrollback re-wraps on column changes — *not* on row-only
        //    changes), the buffer line/col those points named now refer
        //    to a different cell. Re-mapping is impossible without
        //    retaining the original byte stream, so the safe choice is to
        //    drop the selection. We compare against the previous
        //    snapshot's `cols` so a row-only resize (no scrollback
        //    reflow) preserves the selection — typical e.g. when the
        //    user drags only the bottom edge of the window.
        //
        //  - #15 (alt-screen exit/enter): `CSI ?1049h` swaps the visible
        //    grid for a fresh alt-screen and `?1049l` restores the prior
        //    main-screen content; either edge means the lines the
        //    selection points into have been replaced. `BBSnapshot.termMode`
        //    surfaces the `.altScreen` bit (see BBTerm.swift), so detect
        //    the toggle and clear.
        //
        // Both checks are gated on a non-nil prior snapshot so the very
        // first render() (where `currentSnapshot` is still nil) doesn't
        // misfire — there's no live selection at session start anyway.
        //  - H-6 (history collapsed by ⌘K): `TerminalSession.clearAll()`
        //    calls `bb_term_clear_all`, which drops the entire scrollback
        //    ring. A selection that pointed into history now references
        //    deleted lines — copy returns blank. The cols/altScreen gates
        //    above don't fire (cols unchanged, no alt-screen toggle), so
        //    we need an explicit "history just collapsed to zero" predicate.
        //    Picked "was-non-zero, now-zero" rather than "shrank" so a
        //    natural scrollback eviction (history wraps at the cap) — which
        //    keeps history positive — doesn't drop a live selection.
        if selection != nil, let prev = currentSnapshot {
            let colsChanged = prev.cols != snapshot.cols
            let altScreenChanged = prev.termMode.contains(.altScreen)
                != snapshot.termMode.contains(.altScreen)
            let historyCollapsed = prev.historySize > 0 && snapshot.historySize == 0
            if colsChanged || altScreenChanged || historyCollapsed {
                selection = nil
            }
        }
        self.currentSnapshot = snapshot
        // If ⌘ is held while the grid reshapes under the pointer (scrolling
        // output, screen clear), re-resolve the regex URL at the current
        // hover cell. `mouseMoved` wouldn't fire — the pointer didn't
        // physically move — but the row/col under the pointer now maps to
        // a different buffer line. Without this call the renderer keeps
        // painting the previous URL's range even though the URL itself
        // scrolled away. Gated on `cmdModifierHeld` so the scan cache
        // stays cold when the feature isn't engaged.
        if cmdModifierHeld {
            reevaluateCmdHoverHighlight()
        }
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
        // M-7 / RW-04: also kill the selection autoscroll timer. `deinit`
        // already invalidates it (terminal-view-2 F2), but tab tear-out
        // moves the view between windows WITHOUT calling deinit. Between
        // `viewWillMove` and `viewDidMoveToWindow` `self.window` is nil;
        // an active timer firing in that gap would call
        // `session?.scroll(delta:)` against stale window coordinates.
        selectionAutoscrollTimer?.invalidate()
        selectionAutoscrollTimer = nil
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
            // If the user switched INTO this tab while already holding
            // ⌘ (Cmd-Tab, or Cmd-` within the group), `flagsChanged`
            // didn't fire — modifier events only route to the key
            // window's first responder. Sync from the current global
            // state so the next hover evaluation sees the right flag.
            // Re-evaluation itself is deferred to the next mouseMoved:
            // we don't know the pointer's current cell on the new tab
            // until it reports in.
            self?.syncCmdModifierHeld(fromEventFlags: NSEvent.modifierFlags)
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
            // Wipe modifier + hover state so a missed ⌘-release during
            // focus loss (flagsChanged fires only for the key window)
            // doesn't leave a stale ⌘-hover highlight painted into the
            // next focus cycle. mouseMoved will sync back as soon as the
            // pointer moves over the view again.
            self?.resetModifierAndHoverState()
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
        // Selection-autoscroll timer, if the user torn the view down
        // mid-drag (rare but possible on app quit). Invalidate directly
        // rather than via the nil-checking helper so we don't swallow
        // the intent in the unlikely case the property access races
        // the deinit. Audit terminal-view-2 F2.
        selectionAutoscrollTimer?.invalidate()
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
        // Sibling of setTopInsetPoints — keep the two inset setters in
        // lockstep so a layout-transition race that runs draw(in:) before
        // layout() can't paint cells at the unset default of x=0 for one
        // frame. Cheap (no per-frame state, no FrameKey churn since
        // currentLeftInset is constant for the view's lifetime).
        renderer.setLeftInsetPoints(Float(Self.horizontalContentInsetPoints))
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
        // screen" for probe purposes. The renderer can short-circuit
        // (frameKey unchanged → no encode, no present; drawable
        // unavailable → semaphore released without paint), and on those
        // paths nothing reached the screen. Reading
        // `didFrameSkipLastRender` filters those out so we don't record
        // phantom zero-latency samples that drag p50/p99 down. When the
        // skip flag is set the pending keystroke timestamp stays armed
        // and the next *real* presented frame consumes it.
        if !renderer.didFrameSkipLastRender {
            LatencyProbe.shared.markPresented()
        }
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
            findMatchesSeq = nil
            findCurrentIndex = 0
            findQuery = ""
            setNeedsDisplay(bounds)
            return
        }

        // Audit terminal-view-1 F3. Each `.sink` below previously wrapped
        // its body in `DispatchQueue.main.async` — a no-op hop when the
        // publisher already emits on main (TerminalSession coalesces to
        // main via `publishPendingSnapshot`), and a UI-touch-off-main
        // hazard if it ever doesn't. Declaring `.receive(on:
        // DispatchQueue.main)` upstream shifts the whole closure onto
        // main exactly once; saves a runloop tick per update on the
        // snapshot path (which feeds the renderer's keystroke→pixel
        // cadence) and makes the thread contract explicit at the
        // subscription point rather than implicit at every call site.
        session.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                guard let self, let snap else { return }
                self.render(snapshot: snap)
            }
            .store(in: &cancellables)

        session.$title
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                guard let self else { return }
                // Tab labels in AppKit's native tab group mirror window.title,
                // so one write covers both the titlebar and the tab. When the
                // shell hasn't emitted OSC 0/2 yet (stock zsh/bash until the
                // user configures precmd), fall back to the session's default
                // (shell basename) set by MainWindowController.
                let fallback = self.window?.title ?? "Blackbird"
                let useTitle = title?.isEmpty == false ? title : fallback
                self.window?.title = useTitle ?? "Blackbird"
            }
            .store(in: &cancellables)

        session.$bellCounter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] counter in
                guard let self else { return }
                guard counter > self.lastBellCounter else { return }
                self.lastBellCounter = counter
                self.flashBell()
            }
            .store(in: &cancellables)
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
            let termModeForCtrl = currentSnapshot?.termMode ?? []
            let kittyActive = termModeForCtrl.contains(.disambiguateEscCodes)
                || termModeForCtrl.contains(.reportAllKeysAsEsc)
            let modifyOther = termModeForCtrl.contains(.modifyOtherKeys)
            // Route Ctrl+letter through the encoder whenever a TUI opted
            // into a protocol that expects CSI-u or CSI 27 shape for
            // Ctrl-combinations: Kitty flag 1, Kitty flag 8, or xterm
            // modifyOtherKeys (Emacs, tmux extended-keys, nvim auto-
            // request). Without this, the fast path would send a bare
            // 0x01 for Ctrl+A even though the TUI asked for the
            // protocol-framed form (F-S3-002).
            if kittyActive || modifyOther {
                // Fall through — encoder picks the right protocol and
                // handles Ctrl + C0-aliasing letters too.
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
        if !bytes.isEmpty {
            sendToSession(bytes)
            return
        }
        // Audit M3. Encoder produced no bytes — typical for F13–F24
        // and Mac system keys (brightness, media, eject) where
        // `event.charactersIgnoringModifiers` is empty or a private-
        // use scalar that doesn't map to a shell-meaningful sequence.
        // Without the super-forward, AppKit's responder chain never
        // sees the event: F15 brightness-up (and similar) is silently
        // swallowed while Blackbird is key. Mirroring keyUp's
        // empty-bytes fall-through (line ~1828) lets the menu chain
        // and accelerator handlers process the system key.
        super.keyDown(with: event)
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
        let pb = NSPasteboard.general
        if clean.isEmpty {
            // Sanitization dropped everything — likely a user who selected
            // a span that was entirely bidi-overrides / control bytes.
            // Clear the pasteboard rather than leaving the previous copy
            // stale; that's more honest UX than ⌘C appearing to succeed
            // while keeping the last clipboard content intact. Audit
            // terminal-view-2 F3.
            pb.clearContents()
            return
        }
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

    /// Cheap pre-compile gate to catch the standard first-order ReDoS
    /// shapes (nested quantifiers on a capture group, alternations of
    /// overlapping branches) before handing the pattern to
    /// NSRegularExpression. NSRegularExpression has no match timeout API,
    /// so a pattern like `(a+)+$` on a long row can backtrack for
    /// seconds on the main thread. These aren't exhaustive — a
    /// determined adversary can sidestep the heuristic checks — but they
    /// knock out the textbook cases without false-positive'ing on
    /// ordinary find queries. The 250 ms background-execution timeout in
    /// `performSearch` is the real backstop; this gate is the cheap
    /// first line of defence. Length cap keeps the find field a
    /// "substring with options" UI, not a regex playground.
    /// Audit findbar-selection F2.
    static func isReasonableRegexPattern(_ pattern: String) -> Bool {
        if pattern.count > 256 { return false }
        // Normalise non-capturing groups so `(?:a+)+` trips the same
        // substring checks as `(a+)+`. Keep the original around for the
        // alternation regex below — stripping the `?:` doesn't change
        // the topology of `(...|...)`.
        let normalised = pattern.replacingOccurrences(of: "(?:", with: "(")
        let dangerous = [
            "(.*)+", "(.+)+", "(.*)*", "(.+)*",
            "(a+)+", "(a*)*", "(a+)*", "(a*)+",
            "([^x]+)+", "([^x]*)*",
            "(\\w+)+", "(\\w*)*", "(\\d+)+", "(\\d*)*",
            "(\\s+)+", "(\\s*)*",
            "(.+)+$", "(.*)+$",
        ]
        for shape in dangerous where normalised.contains(shape) {
            return false
        }
        // Also strip one extra layer of grouping so `(((a+)))+` reduces
        // to `((a+))+` → `(a+)+`. Iterate a few times: in practice nobody
        // legitimately wraps a quantified atom in five layers of parens,
        // and bounded iteration keeps this O(n).
        var stripped = normalised
        for _ in 0..<5 {
            let next = stripped.replacingOccurrences(of: "((", with: "(")
                .replacingOccurrences(of: "))", with: ")")
            if next == stripped { break }
            stripped = next
        }
        for shape in dangerous where stripped.contains(shape) {
            return false
        }
        // Alternation inside a quantified group — `(a|aa)+`, `(x|xx)*` —
        // is the second textbook ReDoS class (overlapping alternatives).
        // The pattern is `( <stuff> | <stuff> ) [+*]` with no nested
        // parens in the body (good enough for the common case; nested
        // alternation can still slip through but is much rarer in
        // hostile-but-short find queries).
        if let altRe = try? NSRegularExpression(
            pattern: #"\([^()|]*\|[^()|]*\)\s*[+*]"#,
            options: []
        ) {
            let ns = pattern as NSString
            if altRe.firstMatch(in: pattern, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                return false
            }
        }
        // Audit M4. Group whose body contains a quantifier (`+`, `*`,
        // or a brace `{n,…}`) AND is followed by another quantifier
        // is the same exponential-backtrack class as `(a+)+` —
        // `(a{1,})+`, `(.+){2,5}`, `(\w*){1,3}` etc. all fall here.
        // The substring list above only catches the bare-quantifier
        // form; the brace form was the documented gap.
        // Body restriction `[^()]*` keeps this O(n) without nested
        // backtracking. Non-capturing groups `(?:…)` survive in the
        // raw pattern (the substring scan above runs against the
        // `(?:`→`(` normalisation, but this regex runs against the
        // unnormalised pattern); a non-capturing form like
        // `(?:a{1,})+` still matches because `?:a{1,}` is a valid
        // body — the `?:` falls inside `[^()]*` and the `{` is the
        // body quantifier the regex looks for.
        if let braceRe = try? NSRegularExpression(
            pattern: #"\([^()]*[+*{][^()]*\)\s*[+*{]"#,
            options: []
        ) {
            let ns = pattern as NSString
            if braceRe.firstMatch(in: pattern, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                return false
            }
        }
        // Defensive: more than 6 unbounded quantifiers (`+`, `*`,
        // `{n,}`) in a single query is a strong "this isn't a real find
        // query" signal. Counts apply to escaped metacharacters too —
        // not perfect, but the cost of a false positive on a legitimate
        // query with seven quantifiers is "user uses a different tool",
        // versus the cost of a false negative which is a frozen UI.
        var quantCount = 0
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            if c == "+" || c == "*" {
                quantCount += 1
            } else if c == "{" {
                // Treat any `{` as a possible quantifier; we don't
                // bother parsing `{n,m}` precisely.
                quantCount += 1
            }
            i = pattern.index(after: i)
        }
        if quantCount > 6 { return false }
        return true
    }

    @objc public override func selectAll(_ sender: Any?) {
        guard let snap = currentSnapshot else { return }
        // Match Terminal.app: ⌘A selects the full retained buffer —
        // scrollback history through the bottom visible row. Buffer
        // lines run from -historySize (oldest retained) through
        // rows-1 (current live bottom). Audit terminal-view-2 F19.
        let topLine    = -Int32(clamping: snap.historySize)
        let bottomLine = Int32(clamping: snap.rows - 1)
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

    // MARK: - ⌘-click URL resolution (OSC 8 first, regex fallback)

    /// Resolve a click to a URL. OSC 8 attribution on the cell wins; only
    /// when the cell has no OSC 8 href do we fall back to regex URL
    /// detection (matching pre-Task-7 behaviour for tools that don't emit
    /// OSC 8 hyperlinks). Returns nil when neither path produces a URL.
    ///
    /// `screenRow` is 0-based from the top of the visible viewport — OSC 8
    /// attribution is stored keyed to screen cells, not buffer lines.
    func resolveClickURL(screenRow: Int, col: Int) -> URL? {
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
        // OSC 8 anchor-divergence gate. The href and the visible text
        // are decoupled in OSC 8 — a hostile remote can render
        // `https://apple.com/login` while the click target is
        // `https://evil.tld/login`. The hover tooltip shows the href
        // (after the audit C1 scrub), but ⌘-click is single-action
        // and never gives the dwell tooltip a chance to surface. Block
        // the click when the rendered anchor claims a different host
        // than the href; the user can ⌥⌘-click after dwelling on the
        // tooltip to get the real destination if they really meant to
        // open the divergent target. Regex-fallback URLs have no
        // separate anchor (the URL IS the visible text), so the gate
        // applies only to the OSC 8 path. Audit high-1.
        let acceptOSC8: (HyperlinkResolver, URL) -> URL? = { resolver, url in
            guard let allowedURL = allow(url) else { return nil }
            // P2-01: divergence detection runs unconditionally now that
            // `osc8AnchorText` returns a non-optional String. An empty
            // anchor short-circuits inside `anchorDivergesFromHost` (no
            // URL-shaped match → not divergent).
            let anchor = resolver.osc8AnchorText(row: screenRow, col: col)
            if OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: anchor, url: allowedURL
            ) {
                Self.securityLogger.warning(
                    """
                    OSC 8 click blocked: anchor / href host mismatch \
                    (potential phishing). \
                    href=\(allowedURL.absoluteString, privacy: .public)
                    """
                )
                return nil
            }
            return allowedURL
        }
        // OSC 8 attribution wins when present: either we accept it
        // (allowed scheme + non-divergent anchor) or we block fully —
        // we do NOT fall through to regex on a blocked OSC 8. Falling
        // through would let a hostile remote whose href is divergent
        // smuggle the user to the visible anchor URL via the regex
        // fallback, which is a different shape of the same trust
        // violation. Regex is consulted only when the cell carries no
        // OSC 8 attribution at all.
        #if DEBUG
        if let override = hyperlinkResolverOverride {
            if let raw = override.osc8URL(row: screenRow, col: col) {
                return acceptOSC8(override, raw)
            }
            return allow(override.regexURL(row: screenRow, col: col))
        }
        #endif
        guard let snap = currentSnapshot else { return nil }
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        if let raw = resolver.osc8URL(row: screenRow, col: col) {
            return acceptOSC8(resolver, raw)
        }
        return allow(resolver.regexURL(row: screenRow, col: col))
    }

    // MARK: - NSAccessibility -------------------------------------------

    /// Cached accessibility value keyed by snapshot identity. Building the
    /// string walks the entire grid (rows × cols) and allocates a fresh
    /// `String` per row, so VoiceOver's habit of polling `accessibilityValue`
    /// many times per snapshot would otherwise turn into a per-frame tax on
    /// the main thread. Identity-via-raw-pointer works because BBSnapshot
    /// instances are immutable + ref-counted: equal address ⇒ equal content.
    ///
    /// Visibility: the struct and property are `internal` so the
    /// extension file `TerminalView+Accessibility.swift` can read/write
    /// them. Swift's `private` doesn't cross file boundaries even for
    /// extensions on the same type.
    struct A11yCache {
        var snapshotIdentity: UnsafeRawPointer? = nil
        var value: String = ""
        /// Number of times `accessibilityValue()` walked the grid. Used by
        /// tests to assert the cache short-circuits repeat reads.
        var computations: Int = 0
        /// Per-line UTF-16 code-unit offsets, computed lazily on first
        /// `accessibilityRange(forLine:)` / `accessibilityLine(for:)` call.
        /// Element `i` is the UTF-16 code-unit index of the FIRST character
        /// of line `i` in `value`; the last element equals
        /// `value.utf16.count` (NOT `value.count`, which is the grapheme-
        /// cluster count and would diverge for any value containing emoji
        /// or other multi-code-unit scalars). `nil` until first line-
        /// related call after a snapshot swap.
        ///
        /// Why UTF-16 code units: NSAccessibility's `NSRange`-based API
        /// is defined in terms of UTF-16 code units (matching NSTextView).
        /// Using grapheme indices would silently mis-count whenever the
        /// terminal renders an emoji.
        ///
        /// Why on the cache (not free): a VO line-by-line read traverses
        /// every line in order, calling `accessibilityRange(forLine:)`
        /// once per line. Recomputing the offsets per call would turn an
        /// O(N) read into O(N²) for grids with hundreds of lines.
        /// Invalidated alongside `value` on snapshot identity change.
        var lineOffsets: [Int]? = nil
    }

    var a11yCache = A11yCache()

    #if DEBUG
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

    /// Synthesise the anchor text for the click-divergence test: walk
    /// `rows[row]` over the span's column range and slice out the
    /// substring. Tests that don't construct spans with rendered
    /// anchor text (most of them) pass `rows: []` and get the empty
    /// string here, which short-circuits divergence detection (no
    /// URL-shaped claim in the anchor).
    func osc8AnchorText(row: Int, col: Int) -> String {
        for span in spans where span.row == row && span.cols.contains(col) {
            guard row >= 0, row < rows.count else { return "" }
            let line = rows[row]
            let chars = Array(line)
            let lo = max(0, span.cols.lowerBound)
            let hi = min(chars.count, span.cols.upperBound)
            guard lo < hi else { return "" }
            return String(chars[lo..<hi])
        }
        return ""
    }

    func regexURL(row: Int, col: Int) -> URL? {
        guard row >= 0, row < rows.count else { return nil }
        let line = rows[row]
        let nsLine = line as NSString
        // I-2 / SI-03: match the production `URLDetector.regex` exactly.
        // The earlier test-fake pattern included `file` in the scheme
        // alternation, but production excludes it (KNOWN_ISSUES.md
        // documents `file://` as intentionally not clickable). Tests
        // that injected `file://` rows were exercising the policy gate
        // against an input the production detector would never produce.
        let pattern = #"(?i)(?:https?|ftp)://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        // Pattern is a constant; force-try so a bad edit fails loudly.
        let regex = try! NSRegularExpression(pattern: pattern)
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
        findMatchesSeq = nil
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
        findMatchesSeq = nil
        findCurrentIndex = 0
        findBar?.setMatchCount(0, of: 0)
        // F5: re-run the search after the byte stream has had a chance to
        // land, so the label reads the live post-replace count (standard
        // VS Code / TextEdit behaviour).
        reRunSearchAfterReplace()
    }

    /// Re-run the current find query on the next runloop tick. Called after
    /// a successful replace so the match label reflects the edited line
    /// instead of stale "0/0". Scheduled async so the shell has a moment
    /// to echo the DEL+replacement bytes back through the render pipeline;
    /// the snapshot observer (see `currentSnapshot.didSet`) also schedules
    /// a refresh, so this double-booking is harmless — `performSearch`
    /// overwrites the match array atomically. Audit findbar-selection F5.
    fileprivate func reRunSearchAfterReplace() {
        #if DEBUG
        // In tests there's no shell to echo bytes; skip the async hop so
        // assertions against `findMatches` don't race the dispatch.
        if replaceByteCapture != nil { return }
        #endif
        let query = findQuery
        guard !query.isEmpty, findBar != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.findQuery.isEmpty, self.findBar != nil else { return }
            self.performSearch(query: query)
        }
    }

    /// Replace all find matches with `replacement`, processing right-to-left so
    /// earlier column indices stay valid as the shell receives each replacement.
    /// Matches not on the live input line are skipped; if any were skipped a
    /// warning is shown in the find bar.
    ///
    /// F4 (findbar-selection): when a match sits on the row immediately
    /// above the cursor AND that row looks soft-wrap-filled (its last cell
    /// is non-blank — shells fill right up to the wrap column before
    /// wrapping), refuse with a warning. Without the wrap-flag FFI we
    /// can't be certain; erring on the side of refusal avoids emitting
    /// DEL bytes that overshoot into wrapped prior content. Rows with a
    /// trailing blank are treated as unrelated scrollback and their
    /// matches are silently skipped, preserving the documented behaviour
    /// for non-wrapped off-line matches.
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
        // Wrap-ambiguity guard: a match on the row immediately above the
        // cursor *might* be a soft-wrap continuation of the input line.
        // A shell that's soft-wrapped typically fills right up to the
        // right edge (last cell non-blank); a scrollback row usually has
        // trailing blanks. Refuse only when the prior row's last cell is
        // non-blank AND contains a match — otherwise fall through to the
        // scrollback-skip path. Audit findbar-selection F4.
        let priorRow = cursorLine - 1
        if matches.contains(where: { $0.line == priorRow }),
           snap.cols > 0,
           let priorLastCell = snap.character(at: snap.cols - 1, row: Int(priorRow)),
           !priorLastCell.isWhitespace {
            findBar?.showTransientMessage("Refusing: matches span a possible wrapped input line")
            return
        }
        // Process right-to-left so earlier col indices remain valid.
        for m in inputLineMatches.sorted(by: { $0.startCol > $1.startCol }) {
            sendReplacement(match: m, replacement: replacement)
        }
        // All input-line matches have been spliced; invalidate the cache.
        findMatches.removeAll()
        findMatchesSeq = nil
        findCurrentIndex = 0
        findBar?.setMatchCount(0, of: 0)
        if hadOffLine {
            findBar?.showTransientMessage("Replaced input-line matches (scrollback skipped)")
        } else {
            // F5: re-run the search so the user sees fresh match counts
            // against the newly-edited line. Without this, the label reads
            // "No matches" even though the replacement string may itself
            // match the query. `performSearch` short-circuits on an empty
            // query; scheduling is deferred to the next runloop tick so
            // the shell has time to echo the bytes back.
            reRunSearchAfterReplace()
        }
    }

    /// Emits DEL×N bytes to erase the matched span, then the UTF-8 replacement.
    /// `N` is the number of *shell-input characters* in the match — equal to
    /// the number of non-spacer cells in `[startCol, endCol]` on the match
    /// row. A wide CJK glyph counts as one DEL even though it occupies two
    /// columns; without this distinction the column-span DEL count would
    /// overshoot by one per wide grapheme and erase characters to the left
    /// of the actual match. Audit H6.
    private func sendReplacement(
        match m: (line: Int32, startCol: Int, endCol: Int),
        replacement: String
    ) {
        let snap = effectiveSnapshot()
        let screenRow = Int(m.line) + (snap?.displayOffset ?? 0)
        // Use the cell-walked count when we have a snapshot row to walk;
        // fall back to the col span for scrollback / no-snapshot test
        // paths (those don't match wide chars in practice — replace
        // requires the match be on the cursor line, which is always
        // in viewport).
        let matchLen = snap?.nonSpacerCellCount(
            row: screenRow, startCol: m.startCol, endCol: m.endCol
        ) ?? (m.endCol - m.startCol + 1)
        guard matchLen > 0 else { return }
        let delBytes = Data(repeating: 0x7F, count: matchLen)
        // Scrub the replacement bytes through the same pipeline paste
        // uses. The find-bar Replace field accepts arbitrary user input
        // — typed or pasted via NSTextField's own paste handler, which
        // bypasses our paste sanitizer. A user pasting a Trojan-Source
        // RLO into Replace would otherwise smuggle the bidi byte
        // straight into the shell. Same C0/C1/bidi/ZWJ/tag-block list
        // as the paste pipeline. Audit M10.
        let cleanedReplacement = Self.stripBidiOverrides(
            Self.sanitizePasteControls(Data(replacement.utf8))
        )
        #if DEBUG
        if let capture = replaceByteCapture {
            capture(delBytes)
            if !cleanedReplacement.isEmpty { capture(cleanedReplacement) }
            return
        }
        #endif
        guard let session else { return }
        session.send(delBytes)
        if !cleanedReplacement.isEmpty {
            session.send(cleanedReplacement)
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
