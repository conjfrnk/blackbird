import AppKit

/// Minimal right-edge scroll indicator — a translucent pill whose size
/// reflects the viewport-to-buffer ratio and whose position reflects
/// `displayOffset` within the total scrollback.
///
/// Visibility is driven entirely by the snapshot:
///   - `historySize == 0`         → never shown (no content to scroll).
///   - `displayOffset == 0`       → fades out over 0.4s (you're at the bottom).
///   - `displayOffset > 0`        → visible full opacity.
///
/// Not interactive in v1 — it's a read-only hint. Drag-to-scroll is a
/// natural future extension but omitted to keep scope tight.
final class ScrollIndicator: NSView {
    private let thumbLayer = CALayer()
    private var fadeOutWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        thumbLayer.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        thumbLayer.cornerRadius = 2
        thumbLayer.opacity = 0
        layer?.addSublayer(thumbLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // pass-through

    /// Update the thumb geometry and visibility from the current snapshot.
    /// Safe to call from the main thread at any cadence.
    func update(displayOffset: Int, historySize: Int, rows: Int) {
        guard historySize > 0, rows > 0 else {
            setVisible(false, animated: false)
            return
        }

        // The buffer model: top = most ancient scrollback, bottom = live row.
        // Total buffer lines = historySize + rows. The viewport covers `rows`.
        // displayOffset is how many lines the viewport is scrolled ABOVE the
        // live grid — so displayOffset == historySize means "at the very top".
        let totalLines = CGFloat(historySize + rows)
        let viewportFraction = CGFloat(rows) / totalLines

        // Fraction scrolled from bottom (0.0) to top (1.0).
        let scrollFromBottom = CGFloat(displayOffset) / CGFloat(max(historySize, 1))

        let track = bounds.height
        let thumbHeight = max(24, track * viewportFraction)
        // Thumb y: at displayOffset == 0 (bottom) → thumb at bottom.
        //          at displayOffset == historySize (top) → thumb at top.
        let maxThumbY = track - thumbHeight
        let thumbY = maxThumbY * scrollFromBottom

        let thumbWidth: CGFloat = 4
        let pad: CGFloat = 3
        // Disable implicit Core Animation to avoid smearing during rapid
        // scroll — the geometry catches up every frame, so animating the
        // change would look behind.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.frame = NSRect(
            x: bounds.width - thumbWidth - pad,
            y: thumbY,
            width: thumbWidth,
            height: thumbHeight
        )
        CATransaction.commit()

        if displayOffset > 0 {
            setVisible(true, animated: false)
            scheduleAutoHide()
        } else {
            // At the bottom — fade out after a short delay.
            scheduleAutoHide()
        }
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1.0 : 0.0
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            thumbLayer.opacity = target
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.opacity = target
            CATransaction.commit()
        }
    }

    private func scheduleAutoHide() {
        fadeOutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.setVisible(false, animated: true)
        }
        fadeOutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}
