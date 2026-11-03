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

    /// How the pill row is laid out in a given width.
    struct PillRow: Equatable {
        /// Distance between the leading edges of adjacent pills (the pill's
        /// width plus the inter-pill spacing).
        let slotWidth: CGFloat
        /// Index of the first pill that is on screen.
        let firstVisible: Int
        /// How many pills are on screen.
        let visibleCount: Int
        /// Width of each of the two page-button slots that flank the visible
        /// pills while the row pages; 0 when the whole row fits.
        let edgeSlotWidth: CGFloat

        var visibleRange: Range<Int> { firstVisible ..< firstVisible + visibleCount }
        var isPaged: Bool { edgeSlotWidth > 0 }
    }

    /// Lay `count` pills into `available` points.
    ///
    /// The pills split the width equally while each keeps at least
    /// `minPillWidth`. Past that the row PAGES instead of shrinking the pills
    /// into blank stubs: whole pills fill the space between two
    /// `edgeSlotWidth` page-button slots, and the page shown is the one that
    /// holds `selectedIndex`.
    ///
    /// Paging, not scrolling, is deliberate. The page is a pure function of the
    /// selection, so every window's strip in a tab group agrees without any
    /// shared scroll state. And because the pages are disjoint with no partly
    /// visible pills, selecting a pill that is on screen can never change the
    /// page: the row stays put under a stationary cursor, so the second click
    /// of a double-click lands on the same pill as the first.
    ///
    /// A strip too narrow for two such pages' worth of pills skips the floor
    /// (paging one legible pill at a time is worse than a cramped equal split).
    static func pillRow(available: CGFloat,
                        count: Int,
                        selectedIndex: Int?,
                        minPillWidth: CGFloat,
                        edgeSlotWidth: CGFloat) -> PillRow {
        let n = max(1, count)
        let equal = available / CGFloat(n)
        let pagedSpan = available - 2 * edgeSlotWidth
        guard equal < minPillWidth, pagedSpan >= 2 * minPillWidth else {
            return PillRow(slotWidth: equal, firstVisible: 0, visibleCount: n, edgeSlotWidth: 0)
        }
        // `equal < minPillWidth` means `n` exceeds `available / minPillWidth`,
        // so the `n` bound never binds; it only keeps an absurd width from
        // overflowing `Int`.
        let perPage = max(1, Int(min(pagedSpan / minPillWidth, CGFloat(n))))
        let selected = min(max(selectedIndex ?? 0, 0), n - 1)
        let first = selected / perPage * perPage
        return PillRow(slotWidth: pagedSpan / CGFloat(perPage),
                       firstVisible: first,
                       visibleCount: min(perPage, n - first),
                       edgeSlotWidth: edgeSlotWidth)
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
