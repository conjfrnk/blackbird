import Foundation

public struct WheelScrollAccumulator: Equatable {
    private var remainder: Double = 0

    public init() {}

    /// Signed like `deltaY`: positive = older content (xterm button 64 / ↑). AppKit has already
    /// applied the Natural-scrolling preference. `pointsPerLine` is the cell height in points.
    public mutating func lines(
        deltaY: Double,
        precise: Bool,
        pointsPerLine: Double,
        linesPerNotch: Int
    ) -> Int {
        guard deltaY.isFinite, deltaY != 0 else { return 0 }
        if !precise {
            // Round away from zero so a fractional notch (some mice report 0.1 steps) still moves.
            let notches = deltaY.rounded(.toNearestOrAwayFromZero)
            let raw = notches * Double(max(1, linesPerNotch))
            return Int(min(Double(Int32.max), max(Double(Int32.min), raw)))
        }
        guard pointsPerLine.isFinite, pointsPerLine > 0 else { return 0 }
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
