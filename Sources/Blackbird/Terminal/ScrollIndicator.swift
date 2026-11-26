import AppKit
import os

final class ScrollIndicator: NSView {
    nonisolated private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "scrollIndicator")
    private static let didLogOutOfRange = OSAllocatedUnfairLock(initialState: false)

    private let thumbLayer = CALayer()
    /// Sits under the thumb so the thumb always paints on top of a mark at the current offset.
    private let marksContainer = CALayer()
    private var markLayers: [CALayer] = []
    private var fadeOutWorkItem: DispatchWorkItem?

    // MARK: - Geometry & timing

    private static let edgePad: CGFloat = 3
    private static let minThumbHeight: CGFloat = 24
    private static let autoHideDelay: TimeInterval = 1.2
    private static let fadeAnimationDuration: CFTimeInterval = 0.25

    /// `fraction`: 0 = bottom, 1 = top. Shared by the thumb and the prompt-mark ticks so the two stay in lockstep.
    private static func yForFraction(
        _ fraction: CGFloat, elementHeight: CGFloat, track: CGFloat
    ) -> CGFloat {
        fraction * max(0, track - elementHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        marksContainer.opacity = 0
        layer?.addSublayer(marksContainer)
        thumbLayer.backgroundColor = gridOverlayTint
        thumbLayer.cornerRadius = 2
        thumbLayer.opacity = 0
        layer?.addSublayer(thumbLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbLayer.backgroundColor = gridOverlayTint
        CATransaction.commit()
    }

    func update(displayOffset: Int, historySize: Int, rows: Int) {
        guard historySize > 0, rows > 0 else {
            setVisible(false, animated: false)
            return
        }

        // `displayOffset` is how many lines the viewport is scrolled above the live grid; `historySize` is the very top.
        let totalLines = CGFloat(historySize + rows)
        let viewportFraction = CGFloat(rows) / totalLines

        // Clamp: `displayOffset > historySize` would paint the thumb above the track.
        let rawFromBottom = CGFloat(displayOffset) / CGFloat(max(historySize, 1))
        let scrollFromBottom = min(1, max(0, rawFromBottom))
        if rawFromBottom > 1 || rawFromBottom < 0 {
            Self.didLogOutOfRange.withLock { didLog in
                if !didLog {
                    didLog = true
                    Self.logger.warning("scroll-from-bottom ratio out of [0,1]: displayOffset=\(displayOffset, privacy: .public) historySize=\(historySize, privacy: .public)")
                }
            }
        }

        let track = bounds.height
        // Clamp to the track: `thumbHeight > track` gives a negative max y and a thumb above its parent's origin.
        let thumbHeight = min(track, max(Self.minThumbHeight, track * viewportFraction))
        let thumbY = Self.yForFraction(scrollFromBottom, elementHeight: thumbHeight, track: track)

        let thumbWidth: CGFloat = 4
        let pad = Self.edgePad
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
            fadeOutWorkItem?.cancel()
            fadeOutWorkItem = nil
            setVisible(true, animated: false)
        } else if thumbLayer.opacity > 0, fadeOutWorkItem == nil {
            // Never reschedule a pending fade: every new snapshot would push the hide further out
            // and the thumb would never disappear during active output.
            scheduleAutoHide()
        }
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        let target: Float = visible ? 1.0 : 0.0
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(Self.fadeAnimationDuration)
            thumbLayer.opacity = target
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.opacity = target
            CATransaction.commit()
        }
    }

    func updatePromptMarks(
        _ marks: [TerminalSession.PromptMark],
        linesScrolled: UInt64,
        historySize: Int,
        rows: Int,
        accentColor: NSColor
    ) {
        let total = historySize + rows
        guard total > 0, !marks.isEmpty else {
            marksContainer.opacity = 0
            return
        }
        let track = bounds.height
        let tickHeight: CGFloat = 8
        let tickWidth: CGFloat = 2
        let pad = Self.edgePad
        while markLayers.count < marks.count {
            let l = CALayer()
            l.cornerRadius = 1
            marksContainer.addSublayer(l)
            markLayers.append(l)
        }
        let color = accentColor.withAlphaComponent(0.65).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<markLayers.count {
            let l = markLayers[i]
            if i >= marks.count {
                l.isHidden = true
                continue
            }
            let m = marks[i]
            // Lines above the live bottom row: the mark started rows-1-gridRow above it and every line
            // scrolled since pushes it one further up. Marks past retention land outside [0, total).
            let scrolledSince = linesScrolled >= m.linesScrolled
                ? Int(clamping: linesScrolled - m.linesScrolled)
                : 0
            let dist = (rows - 1 - m.gridRow) + scrolledSince
            if dist < 0 || dist >= total {
                l.isHidden = true
                continue
            }
            let fraction = CGFloat(dist) / CGFloat(total)
            let y = Self.yForFraction(fraction, elementHeight: tickHeight, track: track)
            l.isHidden = false
            l.backgroundColor = color
            l.frame = NSRect(
                x: bounds.width - tickWidth - pad,
                y: y,
                width: tickWidth,
                height: tickHeight
            )
        }
        CATransaction.commit()
        marksContainer.opacity = 1
    }

    private func scheduleAutoHide() {
        fadeOutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.setVisible(false, animated: true)
            self?.fadeOutWorkItem = nil
        }
        fadeOutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideDelay, execute: item)
    }
}

extension NSView {
    /// `TerminalView.setWindowAppearance` pins the window's appearance to the theme's lightness,
    /// so `effectiveAppearance` tracks the theme background, not the OS.
    var gridOverlayTint: CGColor {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.25).cgColor
    }
}
