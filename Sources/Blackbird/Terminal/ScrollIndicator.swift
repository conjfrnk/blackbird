import AppKit
import os

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
    /// Diagnostic channel for the M-15 clamp. One-shot warning when the
    /// `displayOffset / historySize` ratio escapes `[0, 1]` — that
    /// signals an upstream regression in the Rust scroll math (or, on
    /// the negative branch, a future ABI sign change). The clamp
    /// silently corrects the visual; the log makes it discoverable via
    /// `log stream --predicate 'category == "scrollIndicator"'` in a
    /// release build. NO `#if DEBUG` gate — Release diagnosability
    /// matters more than the one-time line cost.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "scrollIndicator")
    private static let didLogOutOfRange = OSAllocatedUnfairLock(initialState: false)

    private let thumbLayer = CALayer()
    /// Parent layer for every prompt-mark tick so we can animate / fade the
    /// marks as a group without touching the thumb. Sits under the thumb so
    /// the thumb always paints on top of a mark at the current offset.
    private let marksContainer = CALayer()
    /// Pool of mark sublayers. Grown on demand, excess layers hidden rather
    /// than removed so rapid prompt emission doesn't thrash CALayer alloc.
    private var markLayers: [CALayer] = []
    private var fadeOutWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        marksContainer.opacity = 0
        layer?.addSublayer(marksContainer)
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
        // M-15 / EC-2: clamp to [0, 1]. Sibling of L-3's thumb-height
        // clamp — if `displayOffset > historySize` (regression in the
        // Rust scroll math, or a transient mis-snap), an unclamped
        // ratio paints the thumb above the track. The 0 floor guards
        // a hypothetical negative `displayOffset` (today bb_term_*
        // returns u32, but the Swift Int could carry a sign through a
        // future ABI change) — defense-in-depth, mirrors L-3 shape.
        let rawFromBottom = CGFloat(displayOffset) / CGFloat(max(historySize, 1))
        let scrollFromBottom = min(1, max(0, rawFromBottom))
        // Defense-in-depth observability. The clamp above hides a bad
        // upstream value; without a log, a regression in the Rust
        // scroll math would manifest only as a thumb that pins to the
        // edge with no breadcrumb. One-shot so a sustained regression
        // doesn't flood the unified log.
        if rawFromBottom > 1 || rawFromBottom < 0 {
            Self.didLogOutOfRange.withLock { didLog in
                if !didLog {
                    didLog = true
                    Self.logger.warning("scroll-from-bottom ratio out of [0,1]: displayOffset=\(displayOffset, privacy: .public) historySize=\(historySize, privacy: .public)")
                }
            }
        }

        let track = bounds.height
        // L-3 / RW-05: clamp the thumb height to the track so a very
        // small window can't make `thumbHeight > track`, which gives
        // `maxThumbY < 0` and renders the thumb above its parent's
        // origin. The 24pt floor still applies when the track is at
        // least that tall.
        let thumbHeight = min(track, max(24, track * viewportFraction))
        // Thumb y: at displayOffset == 0 (bottom) → thumb at bottom.
        //          at displayOffset == historySize (top) → thumb at top.
        let maxThumbY = max(0, track - thumbHeight)
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
            // In scrollback — keep the thumb visible and cancel any
            // pending fade so rapid output doesn't cause a fade blink.
            fadeOutWorkItem?.cancel()
            fadeOutWorkItem = nil
            setVisible(true, animated: false)
        } else if thumbLayer.opacity > 0, fadeOutWorkItem == nil {
            // Just returned to the live grid while still visible — start a
            // fade. Don't reschedule if one's already pending, otherwise
            // every new snapshot pushes the hide further out and the thumb
            // never disappears during active output.
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

    /// Render prompt-mark ticks along the track. Each mark's position is
    /// derived from its (linesScrolled, gridRow) anchor (audit S5-004) so
    /// marks slide upward as new content scrolls them into history — and
    /// keep sliding correctly after scrollback saturates, where the old
    /// history_size anchor froze.
    ///
    /// Call from the main thread whenever `TerminalSession.promptMarks`
    /// changes OR the displayOffset changes (so marks stay visually anchored
    /// during scroll). No-op while historySize == 0 (no buffer to position
    /// against).
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
        // Tick geometry: 8 pt tall × 2 pt wide, painted in the accent
        // colour at ~60 % alpha so the thumb over it still reads clearly.
        let tickHeight: CGFloat = 8
        let tickWidth: CGFloat = 2
        let pad: CGFloat = 3
        // Re-use or create one layer per mark. Excess hidden.
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
            // Distance in lines from the bottom-most (live) row: the
            // marked row started at gridRow (so rows-1-gridRow above
            // the bottom) and every line scrolled since pushes it one
            // further up (audit S5-004 anchor algebra). Marks pushed
            // past retention land outside [0, total) and hide.
            let scrolledSince = linesScrolled >= m.linesScrolled
                ? Int(clamping: linesScrolled - m.linesScrolled)
                : 0
            let dist = (rows - 1 - m.gridRow) + scrolledSince
            if dist < 0 || dist >= total {
                l.isHidden = true
                continue
            }
            let fraction = CGFloat(dist) / CGFloat(total)
            let y = fraction * max(0, track - tickHeight)
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
        // Fade container up when we have marks to show.
        marksContainer.opacity = 1
    }

    private func scheduleAutoHide() {
        fadeOutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.setVisible(false, animated: true)
            self?.fadeOutWorkItem = nil
        }
        fadeOutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }
}
