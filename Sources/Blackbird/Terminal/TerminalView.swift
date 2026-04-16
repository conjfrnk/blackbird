import AppKit
import CoreText
import Combine
import Metal
import MetalKit

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
        self.cellHeight = (ascent + descent + leading).rounded()
        // Measure the advance of 'M' — a reliable monospace cell width.
        var glyph = CGGlyph(0)
        var chars: [UniChar] = [UInt16(("M" as Character).asciiValue ?? 77)]
        CTFontGetGlyphsForCharacters(ct, &chars, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        self.cellWidth = advance.width.rounded()
    }

    public func grid(forPixelSize size: CGSize) -> (cols: Int, rows: Int) {
        let cols = max(1, Int(size.width / cellWidth))
        let rows = max(1, Int(size.height / cellHeight))
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
    public let metrics: CellMetrics
    public let encoder = KeyEncoder()

    private var currentSnapshot: BBSnapshot?
    private var cancellables: [AnyCancellable] = []

    public init(frame frameRect: NSRect, device: MTLDevice) {
        guard let renderer = MetalRenderer(device: device) else {
            fatalError("Metal device could not produce a command queue")
        }
        self.renderer = renderer
        self.metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        super.init(frame: frameRect, device: device)
        self.delegate = self
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Must match the render pipeline's colorAttachments[0].pixelFormat
        // set up by MetalRenderer (Task 2+).
        self.colorPixelFormat = .bgra8Unorm
        self.framebufferOnly = true
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.preferredFramesPerSecond = 120
    }

    public required init(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        propagateResize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Outside live resize (e.g., zoom button, programmatic resize), still
        // propagate. During live resize, viewDidEndLiveResize handles the final
        // commit so we avoid thrashing PTY + core during the drag.
        if !inLiveResize {
            propagateResize()
        }
    }

    private func propagateResize() {
        guard let session else { return }
        let grid = metrics.grid(forPixelSize: bounds.size)
        session.resize(to: .init(cols: UInt16(grid.cols), rows: UInt16(grid.rows)))
    }

    // MARK: - Rendering

    public func render(snapshot: BBSnapshot) {
        self.currentSnapshot = snapshot
        // MTKView redraws on CADisplayLink cadence; no needsDisplay needed.
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Intentionally empty: setFrameSize + viewDidEndLiveResize already
        // cover the points-based resize path. Adding a PTY resize here would
        // double-fire SIGWINCH on every non-live resize (zoom button, etc).
        // This hook remains for future per-pixel tracking (e.g., Retina
        // scale-factor changes) but doesn't drive the grid geometry today.
    }

    public func draw(in view: MTKView) {
        renderer.render(in: view, snapshot: currentSnapshot)
    }

    // MARK: - Session observation

    private func subscribeToSession() {
        cancellables.removeAll()
        guard let session else { return }

        session.$snapshot.sink { [weak self] snap in
            guard let self, let snap else { return }
            DispatchQueue.main.async {
                self.render(snapshot: snap)
            }
        }.store(in: &cancellables)

        session.$title.sink { [weak self] title in
            guard let self else { return }
            DispatchQueue.main.async {
                self.window?.title = title ?? "Blackbird"
            }
        }.store(in: &cancellables)
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        // ⌘-prefixed events never encode into PTY bytes. They're reserved for
        // application-level shortcuts (menu items, window management). This
        // enforces the spec's ⌘C/⌃C strict separation: ⌃C always sends 0x03
        // (via KeyEncoder's control path), ⌘C is never re-encoded as 'c'.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        guard let session else { super.keyDown(with: event); return }
        let mods = KeyEncoder.Modifiers(event: event)

        if let special = Self.specialKey(for: event) {
            let bytes = encoder.encodeSpecial(special, modifiers: mods)
            if !bytes.isEmpty { session.send(bytes) }
            return
        }

        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let bytes = encoder.encode(chars: chars, modifiers: mods)
        if !bytes.isEmpty { session.send(bytes) }
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
        default: return nil
        }
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
