import AppKit

/// The borderless, non-activating hover-tooltip panel for `TerminalView`'s
/// link-hover preview. Lifted off the view (REFACTOR.md Area 3: hover concerns →
/// `TooltipController`) so the panel + label lifecycle is owned here rather than
/// being two more `internal` view fields, and so the panel layout is no longer
/// tangled with the URL scrubbing.
///
/// SECURITY: `show(text:near:)` takes an ALREADY-scrubbed, length-clamped
/// string. The credential redaction (H3) + C0/bidi display scrub + 512-char
/// clamp run at the call site, BEFORE this — a tooltip must never render a raw
/// OSC 8 href, which could carry a U+202E that visually flips the rest of the
/// line and defeats the hover-to-verify gesture.
final class TooltipController {
    private var panel: NSPanel?
    private var label: NSTextField?

    /// Show `text` (pre-scrubbed + clamped by the caller) just below-right of
    /// `screenPoint`, a screen-space anchor. The panel + label are reused across
    /// shows. `.nonactivatingPanel` keeps the terminal key + first responder so
    /// a hover-peek doesn't disrupt typing.
    func show(text: String, near screenPoint: NSPoint) {
        let (panel, label) = ensurePanel()
        label.stringValue = text
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
        // Anchor just below-right of the pointer.
        let origin = NSPoint(
            x: screenPoint.x + 12,
            y: screenPoint.y - panelSize.height - 12
        )
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFront(nil)
    }

    /// Hide the tooltip. Keeps the panel allocated for the next show.
    func dismiss() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let label {
            return (panel, label)
        }
        let panel = NSPanel(
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

        self.panel = panel
        self.label = lbl
        return (panel, lbl)
    }
}
