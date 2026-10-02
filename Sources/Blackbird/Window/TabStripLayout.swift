import CoreGraphics

/// Pure pill geometry for the titlebar tab strip — one source of truth for the
/// layout math `TabStripView` used to hand-inline at several sites (REFACTOR.md
/// Area 5: "pill geometry hand-duplicated 3× with magic 6/12 offsets"). Kept
/// free of any `NSView` state so it's unit-testable without a real window.
enum TabStripLayout {
    /// Horizontal gap between a pill's left edge (where the close button sits)
    /// and the start of its title region.
    static let titleLeadingGap: CGFloat = 6
    /// Total horizontal inset removed from a pill's width to size its title
    /// region — `titleLeadingGap` on the left plus a matching trailing gap, so
    /// the title can't collide with the close hotspot or run to the pill edge.
    static let titleHorizontalInset: CGFloat = 12

    /// The title region inside `pill`, to the right of the close button.
    /// Shared by the draw path (which uses the full pill height) and the
    /// inline-rename field (which further insets y/height for its border), so
    /// the title never jumps between drawing and editing. Returns only the
    /// horizontal extent; callers supply their own y/height.
    static func titleArea(in pill: CGRect, closeWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        (x: pill.minX + closeWidth + titleLeadingGap,
         width: max(0, pill.width - (closeWidth + titleHorizontalInset)))
    }

    /// Vertical origin of the pills inside a strip of `stripHeight`.
    ///
    /// The pills' midline should sit on the traffic lights' midline, and where
    /// that is relative to the strip is decided by AppKit, not by us: the
    /// accessory is centred in a titlebar band whose height differs by OS
    /// (on macOS 27 the strip starts 4 pt below the window top while the
    /// lights stay put, which left a fixed `y = 4` four points too low). So
    /// callers pass the lights' midline in the strip's own coordinates.
    ///
    /// `trafficLightMidY` is `nil` when there is nothing to align to (no
    /// window yet, buttons hidden, full screen); `fallback` is then used. The
    /// result is clamped so the pills never leave the strip, and a non-finite
    /// midline is treated as `nil`.
    static func pillOriginY(stripHeight: CGFloat,
                            pillHeight: CGFloat,
                            trafficLightMidY: CGFloat?,
                            fallback: CGFloat) -> CGFloat {
        guard let mid = trafficLightMidY, mid.isFinite else { return fallback }
        let maxY = max(0, stripHeight - pillHeight)
        return min(max(mid - pillHeight / 2, 0), maxY)
    }
}
