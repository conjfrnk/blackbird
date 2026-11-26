import AppKit

/// SECURITY: `show(text:near:)` takes an already credential-redacted, C0/bidi-scrubbed,
/// length-clamped string; the caller scrubs. A raw OSC 8 href must never be rendered here.
final class TooltipController {
    private var panel: NSPanel?
    private var label: NSTextField?

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
        var origin = NSPoint(
            x: screenPoint.x + 12,
            y: screenPoint.y - panelSize.height - 12
        )
        // AppKit never nudges a borderless panel back on-screen: flip above the pointer, then clamp.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            if origin.y < bounds.minY {
                origin.y = screenPoint.y + 12
            }
            origin.x = max(bounds.minX, min(origin.x, bounds.maxX - panelSize.width))
            origin.y = max(bounds.minY, min(origin.y, bounds.maxY - panelSize.height))
        }
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        panel.orderFront(nil)
    }

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
