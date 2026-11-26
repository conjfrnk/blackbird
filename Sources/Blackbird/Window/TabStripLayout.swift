import CoreGraphics

/// Pure pill geometry for the titlebar tab strip.
enum TabStripLayout {
    static let titleLeadingGap: CGFloat = 6
    static let titleHorizontalInset: CGFloat = 12

    static func titleArea(in pill: CGRect, closeWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        (x: pill.minX + closeWidth + titleLeadingGap,
         width: max(0, pill.width - (closeWidth + titleHorizontalInset)))
    }

    struct PillRow: Equatable {
        /// Pill width plus the inter-pill spacing.
        let slotWidth: CGFloat
        let firstVisible: Int
        let visibleCount: Int
        let edgeSlotWidth: CGFloat

        var visibleRange: Range<Int> { firstVisible ..< firstVisible + visibleCount }
        var isPaged: Bool { edgeSlotWidth > 0 }
    }

    /// Pages rather than scrolls: the page is a pure function of the selection, so every strip in a
    /// tab group agrees, and selecting a visible pill never moves the row under the cursor.
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
        // The `n` bound never binds here; it only keeps an absurd width from overflowing `Int`.
        let perPage = max(1, Int(min(pagedSpan / minPillWidth, CGFloat(n))))
        let selected = min(max(selectedIndex ?? 0, 0), n - 1)
        let first = selected / perPage * perPage
        return PillRow(slotWidth: pagedSpan / CGFloat(perPage),
                       firstVisible: first,
                       visibleCount: min(perPage, n - first),
                       edgeSlotWidth: edgeSlotWidth)
    }

    /// `trafficLightMidY` is in the strip's own coordinates; where the strip sits relative to the lights differs by OS.
    static func pillOriginY(stripHeight: CGFloat,
                            pillHeight: CGFloat,
                            trafficLightMidY: CGFloat?,
                            fallback: CGFloat) -> CGFloat {
        guard let mid = trafficLightMidY, mid.isFinite else { return fallback }
        let maxY = max(0, stripHeight - pillHeight)
        return min(max(mid - pillHeight / 2, 0), maxY)
    }
}
