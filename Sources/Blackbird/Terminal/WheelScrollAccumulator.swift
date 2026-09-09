import Foundation

/// Converts a stream of `NSEvent.scrollWheel` deltas into a whole number of
/// terminal "lines" for the two paths that forward the wheel to the
/// application rather than to local scrollback: xterm mouse reports
/// (button 64/65) and DEC 1007 alternate-scroll cursor keys.
///
/// AppKit delivers a trackpad flick as dozens of events with sub-cell
/// `scrollingDeltaY` values plus momentum. Emitting one report per event
/// (the behaviour through v0.8.0) sent `less`/vim/tmux a 3-line step for
/// every one of them — far too fast, and jittery fingers produced reports
/// for zero visible motion. Alacritty and kitty accumulate points and emit
/// one unit per cell height; this does the same.
///
/// Pure value type. One instance per view; `reset()` when the pointer
/// leaves the view or the mode changes so a stale remainder can't leak into
/// the next gesture.
public struct WheelScrollAccumulator: Equatable {
    /// Points accumulated toward the next whole line (precise devices only).
    private var remainder: Double = 0

    public init() {}

    /// Number of lines for this event, signed like `deltaY` (positive =
    /// the direction AppKit reports as "content moves up", i.e. the user
    /// wants newer content — xterm button 65 / ↓).
    ///
    /// - Parameters:
    ///   - deltaY: `event.scrollingDeltaY`.
    ///   - precise: `event.hasPreciseScrollingDeltas` (trackpad / Magic
    ///     Mouse deliver points; a classic wheel delivers ~1 per notch).
    ///   - pointsPerLine: how many points of finger travel equal one line
    ///     — the cell height in points.
    ///   - linesPerNotch: lines per classic-wheel notch.
    public mutating func lines(
        deltaY: Double,
        precise: Bool,
        pointsPerLine: Double,
        linesPerNotch: Int
    ) -> Int {
        guard deltaY.isFinite, deltaY != 0 else { return 0 }
        if !precise {
            // Classic wheel: one event per notch, magnitude ≈ 1. Round away
            // from zero so a fractional notch (some mice report 0.1 steps)
            // still moves, and clamp before the Int conversion.
            let notches = deltaY.rounded(.toNearestOrAwayFromZero)
            let raw = notches * Double(max(1, linesPerNotch))
            return Int(min(Double(Int32.max), max(Double(Int32.min), raw)))
        }
        guard pointsPerLine.isFinite, pointsPerLine > 0 else { return 0 }
        // A direction change discards the remainder: the user reversed, so
        // the partial line in the old direction must not be credited to
        // the new one.
        if (remainder > 0 && deltaY < 0) || (remainder < 0 && deltaY > 0) {
            remainder = 0
        }
        remainder += deltaY
        let whole = (remainder / pointsPerLine).rounded(.towardZero)
        remainder -= whole * pointsPerLine
        let clamped = min(Double(Int32.max), max(Double(Int32.min), whole))
        return Int(clamped)
    }

    public mutating func reset() {
        remainder = 0
    }
}
