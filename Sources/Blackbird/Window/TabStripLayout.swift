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
}
