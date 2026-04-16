import AppKit

/// Custom tab bar that sits inside the titlebar row — same row as the
/// traffic-light buttons, iTerm2 / Safari style. Built on top of AppKit's
/// native `NSWindowTabGroup` so the windows are still real tabs (AppKit
/// manages merging, selection, keyboard-shortcut routing); we just hide
/// the default strip-below-titlebar with `tabGroup.isTabBarVisible =
/// false` and draw our own pills in a titlebar accessory.
final class TitlebarTabBarViewController: NSTitlebarAccessoryViewController {

    private let stripView = TabStripView(frame: .zero)
    private weak var hostWindow: NSWindow?
    private var observer: NSObjectProtocol?

    init(window: NSWindow) {
        self.hostWindow = window
        super.init(nibName: nil, bundle: nil)
        // `.right` anchors the accessory to the right side of the titlebar
        // and lets its view fill available space up to the traffic lights.
        // `.bottom` would place it below the titlebar, which is exactly
        // what we're trying to avoid.
        layoutAttribute = .right
        view = stripView
        stripView.onSelectWindow = { [weak self] w in
            self?.hostWindow?.tabGroup?.selectedWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        stripView.onCloseWindow = { w in
            w.performClose(nil)
        }
        stripView.onAddTab = { [weak self] in
            guard let _ = self?.hostWindow else { return }
            NSApp.sendAction(
                Selector(("newWindowForTab:")),
                to: nil,
                from: nil
            )
        }
        // Refresh when any window's title changes (tabs display titles) or
        // when the tab group membership / selection changes.
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let o = observer { NotificationCenter.default.removeObserver(o) }
    }

    /// Re-read the tab group and rebuild the strip. Called on visibility
    /// change, tab add/remove, and title updates.
    func refresh() {
        guard let window = hostWindow else { return }
        let tabs = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window
        stripView.update(tabs: tabs, selected: selected)
        // Keep the accessory visible even with one tab — otherwise the
        // first ⌘T is jarring because the titlebar layout suddenly gains
        // pills. One tab just shows one (unclickable-to-close) label.
        let preferredWidth = stripView.preferredWidth()
        view.frame = NSRect(x: 0, y: 0, width: preferredWidth, height: TabStripView.height)
    }
}

/// The pill strip itself. Draws each tab as a rounded background + title,
/// with a `+` button at the trailing edge that calls `onAddTab`. Click a
/// tab to select it; a small `×` on hover closes it.
final class TabStripView: NSView {

    static let height: CGFloat = 28

    var onSelectWindow: ((NSWindow) -> Void)?
    var onCloseWindow:  ((NSWindow) -> Void)?
    var onAddTab:       (() -> Void)?

    private var tabs: [NSWindow] = []
    private weak var selectedTab: NSWindow?
    /// Per-pill frames (in this view's coords), recomputed on every update.
    private var pillFrames: [CGRect] = []
    private var addButtonFrame: CGRect = .zero
    /// Tracks the hovered pill index so we can draw a light highlight.
    private var hoveredIndex: Int? = nil
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    func update(tabs: [NSWindow], selected: NSWindow) {
        self.tabs = tabs
        self.selectedTab = selected
        layoutPills()
        needsDisplay = true
    }

    /// Sum of preferred pill widths + `+` button + spacing. The accessory
    /// controller uses this to size its frame so the titlebar allocates
    /// enough room.
    func preferredWidth() -> CGFloat {
        var total: CGFloat = 6 // leading inset
        for w in tabs {
            total += pillWidth(for: w) + 4
        }
        total += 28 // + button
        total += 12 // trailing inset
        return max(120, total)
    }

    private func pillWidth(for w: NSWindow) -> CGFloat {
        let title = w.title.isEmpty ? "Untitled" : w.title
        let attr: [NSAttributedString.Key: Any] = [.font: Self.titleFont]
        let size = (title as NSString).size(withAttributes: attr)
        return min(200, max(72, size.width + 28)) // padding for text
    }

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private func layoutPills() {
        pillFrames.removeAll(keepingCapacity: true)
        var x: CGFloat = 6
        let y: CGFloat = 2
        let h = Self.height - 4
        for w in tabs {
            let pw = pillWidth(for: w)
            pillFrames.append(NSRect(x: x, y: y, width: pw, height: h))
            x += pw + 4
        }
        addButtonFrame = NSRect(x: x + 4, y: y, width: 22, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bgActive = NSColor(white: 1.0, alpha: 0.10).cgColor
        let bgHover  = NSColor(white: 1.0, alpha: 0.04).cgColor
        let textColor = NSColor.labelColor

        for (i, w) in tabs.enumerated() where i < pillFrames.count {
            let rect = pillFrames[i]
            let isActive = w === selectedTab
            let isHovered = hoveredIndex == i
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).cgPath
            ctx.addPath(path)
            if isActive {
                ctx.setFillColor(bgActive)
                ctx.fillPath()
            } else if isHovered {
                ctx.setFillColor(bgHover)
                ctx.fillPath()
            } else {
                ctx.setFillColor(CGColor.clear)
                ctx.fillPath()
            }
            let title = w.title.isEmpty ? "Untitled" : w.title
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.titleFont,
                .foregroundColor: textColor,
            ]
            let s = NSAttributedString(string: title, attributes: attrs)
            let tsize = s.size()
            let tx = rect.midX - tsize.width / 2
            let ty = rect.midY - tsize.height / 2
            s.draw(at: NSPoint(x: tx, y: ty))
        }

        // Plus button
        ctx.setFillColor(NSColor(white: 1.0, alpha: hoveredIndex == -1 ? 0.12 : 0.06).cgColor)
        let plusPath = NSBezierPath(ovalIn: addButtonFrame).cgPath
        ctx.addPath(plusPath)
        ctx.fillPath()
        let plusAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: textColor,
        ]
        let plusStr = NSAttributedString(string: "+", attributes: plusAttr)
        let psize = plusStr.size()
        plusStr.draw(at: NSPoint(
            x: addButtonFrame.midX - psize.width / 2,
            y: addButtonFrame.midY - psize.height / 2 - 1
        ))
    }

    // MARK: - Hit testing

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if NSPointInRect(p, addButtonFrame) {
            onAddTab?()
            return
        }
        for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
            if i < tabs.count { onSelectWindow?(tabs[i]) }
            return
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let prev = hoveredIndex
        hoveredIndex = nil
        if NSPointInRect(p, addButtonFrame) {
            hoveredIndex = -1
        } else {
            for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
                hoveredIndex = i
                break
            }
        }
        if prev != hoveredIndex { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil {
            hoveredIndex = nil
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
            case .curveTo:   path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath: path.closeSubpath()
            default: break
            }
        }
        return path
    }
}
