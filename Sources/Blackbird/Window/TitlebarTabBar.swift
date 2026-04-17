import AppKit

/// Custom tab bar that sits inside the titlebar row — same row as the
/// traffic-light buttons, Safari / iTerm2 style. Built on top of AppKit's
/// native `NSWindowTabGroup` so windows are still real tabs (AppKit
/// handles merging, selection, keyboard routing); we just hide the default
/// strip-below-titlebar via view-walk and draw our own pills.
///
/// Single-tab windows hide the accessory entirely and show the normal
/// window title. The custom pill strip only appears when ≥2 tabs exist,
/// and then splits the titlebar width equally across the open tabs so
/// 2 tabs = halves, 3 tabs = thirds, etc.
final class TitlebarTabBarViewController: NSTitlebarAccessoryViewController {

    private let stripView = TabStripView(frame: .zero)
    private weak var hostWindow: NSWindow?

    init(window: NSWindow) {
        self.hostWindow = window
        super.init(nibName: nil, bundle: nil)
        // `.right` anchors the accessory to the right side of the
        // titlebar; we size its view wide enough to eat the full space
        // left of the edge (minus room for the traffic lights). `.bottom`
        // would put it below the titlebar — exactly what we're avoiding.
        layoutAttribute = .right
        view = stripView
        stripView.onSelectWindow = { [weak self] w in
            self?.hostWindow?.tabGroup?.selectedWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        stripView.onCloseWindow = { w in w.performClose(nil) }
        stripView.onAddTab = {
            NSApp.sendAction(Selector(("newWindowForTab:")), to: nil, from: nil)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Re-read the tab group and re-lay pills. Caller is responsible for
    /// toggling `view.isHidden` based on tab count before calling this —
    /// single-tab windows skip the custom strip entirely.
    func refresh() {
        guard let window = hostWindow else { return }
        let tabs = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window
        // Reserve room for the traffic lights (~78pt on standard macOS
        // with all three visible). The rest of the titlebar belongs to
        // us.
        let trafficLightsReservation: CGFloat = 78
        let totalTitlebarWidth = window.frame.width
        let availableWidth = max(200, totalTitlebarWidth - trafficLightsReservation)
        stripView.update(tabs: tabs, selected: selected, width: availableWidth)
        view.frame = NSRect(x: 0, y: 0, width: availableWidth, height: TabStripView.height)
    }
}

/// Equal-width pill strip with a trailing `+` button. Each pill shows its
/// window title; hovering reveals an `×` close button on the left of the
/// pill. Designed to live inside an `NSTitlebarAccessoryViewController`.
final class TabStripView: NSView {

    /// Full titlebar-row height. The grid's top inset is computed from
    /// the style-mask-derived titlebar height (not `safeAreaInsets`), so
    /// making the pills tall to fill the titlebar doesn't push the prompt
    /// down on multi-tab windows.
    static let height: CGFloat = 28

    var onSelectWindow: ((NSWindow) -> Void)?
    var onCloseWindow:  ((NSWindow) -> Void)?
    var onAddTab:       (() -> Void)?

    private var tabs: [NSWindow] = []
    private weak var selectedTab: NSWindow?
    private var totalWidth: CGFloat = 0
    private var pillFrames: [CGRect] = []
    private var addButtonFrame: CGRect = .zero

    /// Which pill is the cursor over, if any.
    private var hoveredPill: Int? = nil
    /// Is the cursor specifically over the close target inside the hovered
    /// pill (i.e. the small `×` hotspot at the pill's leading edge).
    private var hoveredClose = false
    /// Cursor over the trailing `+` button.
    private var hoveredAdd = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    func update(tabs: [NSWindow], selected: NSWindow, width: CGFloat) {
        self.tabs = tabs
        self.selectedTab = selected
        self.totalWidth = width
        self.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        layoutPills()
        needsDisplay = true
    }

    private static let addButtonWidth: CGFloat = 22
    private static let pillSpacing: CGFloat = 2
    private static let trailingInset: CGFloat = 8
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private func layoutPills() {
        pillFrames.removeAll(keepingCapacity: true)
        let y: CGFloat = 3
        let h = Self.height - 6
        let addW = Self.addButtonWidth
        let gap = Self.pillSpacing
        let trail = Self.trailingInset
        let n = max(1, tabs.count)
        let available = max(0, totalWidth - trail - addW - gap)
        let pillW = available / CGFloat(n)
        var x: CGFloat = 0
        for _ in 0..<n {
            pillFrames.append(NSRect(x: x, y: y, width: max(0, pillW - gap / 2), height: h))
            x += pillW
        }
        addButtonFrame = NSRect(x: x + gap, y: y, width: addW, height: h)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Tint the pill bodies with labelColor (dark on light, light on
        // dark) so they stay visible regardless of whether the theme has
        // a light or dark titlebar. Hard-coding white meant the entire
        // pill strip disappeared on Gruvbox-light / Solarized-light /
        // Catppuccin-latte / Default-light.
        let tint = NSColor.labelColor
        let selectedBg = tint.withAlphaComponent(0.18).cgColor
        let hoverBg    = tint.withAlphaComponent(0.10).cgColor
        let inactiveBg = tint.withAlphaComponent(0.04).cgColor
        let textColor  = NSColor.labelColor
        let inactiveText = NSColor.secondaryLabelColor

        for (i, w) in tabs.enumerated() where i < pillFrames.count {
            let rect = pillFrames[i]
            let isSelected = w === selectedTab
            let isHovered = hoveredPill == i

            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).cgPath
            ctx.addPath(path)
            if isSelected {
                ctx.setFillColor(selectedBg)
            } else if isHovered {
                ctx.setFillColor(hoverBg)
            } else {
                ctx.setFillColor(inactiveBg)
            }
            ctx.fillPath()

            // Close `×` shown only when the pill is hovered. Drawn at
            // leading edge so text center stays stable. Tint with
            // labelColor so the × circle stays visible on both light and
            // dark themes (see pill body tinting rationale above).
            let closeRect = closeHotspot(in: rect)
            if isHovered {
                let xFillColor: CGColor
                if hoveredClose {
                    xFillColor = tint.withAlphaComponent(0.20).cgColor
                } else {
                    xFillColor = tint.withAlphaComponent(0.08).cgColor
                }
                ctx.addPath(NSBezierPath(ovalIn: closeRect).cgPath)
                ctx.setFillColor(xFillColor)
                ctx.fillPath()
                let xAttr: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: textColor,
                ]
                let xs = NSAttributedString(string: "×", attributes: xAttr)
                let xsize = xs.size()
                xs.draw(at: NSPoint(
                    x: closeRect.midX - xsize.width / 2,
                    y: closeRect.midY - xsize.height / 2 - 1
                ))
            }

            // Title: centered, truncated if pill is narrow. Leave room
            // for the close button's width on the left so titles don't
            // jump when hover reveals it.
            let titleArea = NSRect(
                x: rect.minX + closeRect.width + 6,
                y: rect.minY,
                width: max(0, rect.width - (closeRect.width + 12)),
                height: rect.height
            )
            let title = w.title.isEmpty ? "Untitled" : w.title
            let truncated = truncatedString(title, fitting: titleArea.width)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.titleFont,
                .foregroundColor: isSelected ? textColor : inactiveText,
            ]
            let s = NSAttributedString(string: truncated, attributes: attrs)
            let tsize = s.size()
            s.draw(at: NSPoint(
                x: titleArea.midX - tsize.width / 2,
                y: titleArea.midY - tsize.height / 2
            ))
        }

        // Trailing `+` button. Same label-tint so it stays visible on
        // light themes too.
        let addPath = NSBezierPath(ovalIn: addButtonFrame).cgPath
        ctx.addPath(addPath)
        ctx.setFillColor(tint.withAlphaComponent(hoveredAdd ? 0.16 : 0.08).cgColor)
        ctx.fillPath()
        let plusAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: textColor,
        ]
        let plusStr = NSAttributedString(string: "+", attributes: plusAttr)
        let psize = plusStr.size()
        plusStr.draw(at: NSPoint(
            x: addButtonFrame.midX - psize.width / 2,
            y: addButtonFrame.midY - psize.height / 2 - 1
        ))
    }

    private func truncatedString(_ s: String, fitting width: CGFloat) -> String {
        guard width > 20 else { return "" }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.titleFont]
        var current = s
        if (current as NSString).size(withAttributes: attrs).width <= width { return current }
        // Reserve room for the ellipsis.
        while current.count > 1,
              ((current + "…") as NSString).size(withAttributes: attrs).width > width {
            current.removeLast()
        }
        return current + "…"
    }

    private func closeHotspot(in pillRect: NSRect) -> NSRect {
        let side: CGFloat = 14
        return NSRect(
            x: pillRect.minX + 6,
            y: pillRect.midY - side / 2,
            width: side,
            height: side
        )
    }

    // MARK: - Hit testing & hover

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if NSPointInRect(p, addButtonFrame) {
            onAddTab?()
            return
        }
        for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
            guard i < tabs.count else { return }
            // Only honour a close click when the user is actually hovered
            // on the × — otherwise a stationary click near the leading edge
            // of a pill would quietly close it even though the × wasn't
            // visible to the user yet. Selecting is the safe default; to
            // close, the user has to hover the pill first (which paints
            // the ×) and then click.
            if hoveredPill == i, hoveredClose, NSPointInRect(p, closeHotspot(in: rect)) {
                onCloseWindow?(tabs[i])
            } else {
                onSelectWindow?(tabs[i])
            }
            return
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let prevPill = hoveredPill
        let prevClose = hoveredClose
        let prevAdd = hoveredAdd
        hoveredPill = nil
        hoveredClose = false
        hoveredAdd = false
        if NSPointInRect(p, addButtonFrame) {
            hoveredAdd = true
        } else {
            for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
                hoveredPill = i
                hoveredClose = NSPointInRect(p, closeHotspot(in: rect))
                break
            }
        }
        if prevPill != hoveredPill || prevClose != hoveredClose || prevAdd != hoveredAdd {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredPill != nil || hoveredAdd || hoveredClose {
            hoveredPill = nil
            hoveredAdd = false
            hoveredClose = false
            needsDisplay = true
        }
    }
}

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:    path.move(to: points[0])
            case .lineTo:    path.addLine(to: points[0])
            // `.curveTo` and `.cubicCurveTo` share the same raw value in
            // macOS 14+; either name reaches this case. Swift's Element
            // import keeps both names distinct, so we can only list one —
            // `.curveTo` is the deprecated alias that still matches.
            case .curveTo:   path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                // New in macOS 14. Our current paths (roundedRect, ovalIn)
                // don't emit quadratics, but if a future path source does
                // we want to draw it rather than silently skip the segment.
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}
