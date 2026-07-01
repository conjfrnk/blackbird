import CoreGraphics

/// Shared pixel-coordinate sanitization for the view↔buffer geometry paths.
///
/// Several hot paths convert a `CGFloat` pixel coordinate (mouse location,
/// view size, IME caret offset) into a grid `Int` via `Int(_:)`. That cast
/// **traps** on two pathologies:
///   1. NaN / ±Infinity — a stray Core Animation value, a misbehaving input
///      device, or a bridged `CGPoint` from an assistive tool.
///   2. Finite-but-absurd magnitudes (e.g. `1e300`) that exceed `Int.max`.
///
/// Every clamp site used to declare its own `let sanePx: CGFloat = 1_000_000`
/// and repeat `value.isFinite ? min(max(0, value), sanePx) : 0`. That literal
/// and that idiom now live here exactly once (REFACTOR.md Part III §4 / Part VI
/// acceptance §3: the `sanePx` constant must appear in ≤ 1 file).
extension CGFloat {
    /// The largest sane pixel magnitude — far beyond any real display, but
    /// small enough that `Int(_:)` of `value / cellSize` can't trap. The single
    /// definition of the ceiling that callers used to inline as `1_000_000`.
    static let sanePx: CGFloat = 1_000_000

    /// `self` clamped to a usable pixel coordinate before a pixel→cell
    /// `Int(_:)` cast: non-finite → `0`, otherwise `min(max(0, self), sanePx)`.
    /// The canonical full-sanitize idiom shared by `CellMetrics.grid`,
    /// `Selection.bufferPoint`, and the `TerminalView` mouse/IME geometry.
    var sanitizedPixel: CGFloat {
        isFinite ? Swift.min(Swift.max(0, self), CGFloat.sanePx) : 0
    }
}
