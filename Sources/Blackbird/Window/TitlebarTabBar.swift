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
        // Inline-rename commit: the strip has already trimmed the input
        // and converted "" → nil; just hand the value to the window's
        // MainWindowController (which owns the session + override
        // policy). This bypasses the responder chain — we already know
        // the exact window being renamed.
        stripView.onCommitRename = { window, newOverride in
            guard let controller = window.windowController as? MainWindowController else { return }
            controller.applyInlineRename(newOverride)
        }
    }

    /// Enter inline rename mode for `window`'s pill, if any. Called by
    /// `MainWindowController.beginRenameActiveTab` and the `Rename…`
    /// context menu item when the window is part of a multi-tab group.
    /// Single-tab windows fall back to the modal path on the controller.
    func beginInlineRename(for window: NSWindow) {
        guard let group = window.tabGroup else { return }
        let tabs = group.windows
        guard let idx = tabs.firstIndex(of: window) else { return }
        stripView.beginEditing(pillIndex: idx)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Re-read the tab group and re-lay pills. Caller is responsible for
    /// toggling `view.isHidden` based on tab count before calling this —
    /// single-tab windows skip the custom strip entirely.
    ///
    /// `availableWidth` is the caller's pre-computed titlebar budget for
    /// this accessory: total window width minus the trailing space for
    /// the traffic lights. The strip owns zero layout math of its own —
    /// `MainWindowController` is the single authority for reservation
    /// arithmetic.
    func refresh(availableWidth: CGFloat) {
        guard let window = hostWindow else { return }
        let tabs = window.tabGroup?.windows ?? [window]
        let selected = window.tabGroup?.selectedWindow ?? window
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
    /// Called when the user commits an inline rename. `newOverride` is the
    /// trimmed value; `""` means "clear the override and revert to auto".
    /// The strip does not call this on cancel (Escape or external
    /// teardown).
    var onCommitRename: ((NSWindow, String) -> Void)?

    private var tabs: [NSWindow] = []
    private weak var selectedTab: NSWindow?
    private var totalWidth: CGFloat = 0
    private var pillFrames: [CGRect] = []
    private var addButtonFrame: CGRect = .zero

    // MARK: - Inline-edit state

    /// Index of the pill currently in inline-edit mode, or `nil`. Only one
    /// pill edits at a time; opening a second commits the first so the
    /// user never silently loses an in-flight title edit.
    private var editingPill: Int? = nil
    /// Field editor used while a pill is being renamed. Lifetime matches
    /// `editingPill` — nil'd together by `teardownEdit`.
    private var editField: NSTextField? = nil

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

    /// Pass-through hit testing: only claim mouse events that fall on a pill,
    /// the `+` button, or an active inline-rename field. Empty regions of the
    /// strip belong to AppKit's titlebar so the user can still ⌘-drag the
    /// window or invoke standard titlebar gestures from the gaps. Without this
    /// the strip's full frame swallowed clicks that landed in the empty area
    /// between pills and the right edge — `mouseDown` returned silently and
    /// nothing else got a chance to handle the event.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Subviews (the inline-edit text field) get first crack — defer to the
        // default chain so the field editor still receives clicks routed at it.
        if let sub = super.hitTest(point), sub !== self { return sub }
        let local = convert(point, from: superview)
        if NSPointInRect(local, addButtonFrame) { return self }
        for rect in pillFrames where NSPointInRect(local, rect) { return self }
        return nil
    }

    func update(tabs: [NSWindow], selected: NSWindow, width: CGFloat) {
        // An in-flight edit targets a specific pill index in the OLD tab
        // list. If the list shape changes under us (tab closed, window
        // dragged in, reorder), the field can end up floating over the
        // wrong pill or off-strip entirely. Safest policy: commit on any
        // layout-affecting update — preserves the user's work and drops
        // the field before it becomes confusing. Cancels when there's no
        // text field (e.g., first call before any edit).
        if editingPill != nil {
            commitEdit()
        }
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
        // Pill geometry: the stripView is 28 pt tall (standard titlebar);
        // pills are 24 pt, anchored at y=4 so their bottom edge sits flush
        // with the titlebar/content seam (Safari / Chrome style) and their
        // top sits visually BELOW the traffic-light centers — matching how
        // the lights read as a unit at the titlebar top rather than
        // centered in it. Previously h=22 at y=3 made pills look floating-
        // high; the 2 pt taller body + 1 pt drop lines them up against the
        // traffic lights on eye-test.
        let h: CGFloat = 24
        let y: CGFloat = 4
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

    // MARK: - Inline editing

    /// Swap the pill at `pillIndex` into rename mode. Installs an
    /// `NSTextField` over the pill's title area, pre-fills with the window
    /// title, selects all. Commits any in-flight edit first so two
    /// double-clicks in a row don't drop the first edit silently.
    func beginEditing(pillIndex: Int) {
        guard pillIndex >= 0,
              pillIndex < tabs.count,
              pillIndex < pillFrames.count
        else { return }
        if let existing = editingPill, existing != pillIndex {
            commitEdit()
        }
        // If the field already exists for the same pill (e.g., user hit
        // ⌥⌘R a second time on the same pill), just refocus it.
        if editingPill == pillIndex, let existing = editField {
            window?.makeFirstResponder(existing)
            existing.currentEditor()?.selectAll(nil)
            return
        }
        editingPill = pillIndex
        let pill = pillFrames[pillIndex]
        let closeRect = closeHotspot(in: pill)
        // Size the field to the pill's title area (same math as the
        // drawing path). 2 pt top/bottom inset keeps the field slightly
        // inside the pill body so its focus-ring-free border is visible.
        let fieldRect = NSRect(
            x: pill.minX + closeRect.width + 6,
            y: pill.minY + 2,
            width: max(0, pill.width - (closeRect.width + 12)),
            height: pill.height - 4
        )
        let field = NSTextField(frame: fieldRect)
        field.font = Self.titleFont
        field.alignment = .center
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor
        field.textColor = NSColor.labelColor
        field.focusRingType = .none
        field.stringValue = tabs[pillIndex].title.isEmpty ? "Untitled" : tabs[pillIndex].title
        field.delegate = self
        // Enter fires the action; action selector + target here is a
        // defense-in-depth for environments where the field-editor
        // `insertNewline:` command path doesn't route through the
        // delegate. Both paths funnel through `commitEdit`.
        field.target = self
        field.action = #selector(editFieldCommitAction(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        editField = field
        needsDisplay = true
    }

    @objc private func editFieldCommitAction(_ sender: Any?) {
        commitEdit()
    }

    /// Publish the current edit-field value through `onCommitRename` and
    /// tear down the field. Trims whitespace; empty → `""` which the
    /// caller (MainWindowController.applyInlineRename) treats as
    /// "clear override, revert to auto title".
    private func commitEdit() {
        guard let idx = editingPill,
              let field = editField,
              idx < tabs.count
        else {
            cancelEdit()
            return
        }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = tabs[idx]
        teardownEdit()
        // Call through AFTER teardown so the consumer's side-effects
        // (title publication → KVO → refreshTabBar) don't land while the
        // subview is still alive and racing for the first-responder slot.
        onCommitRename?(target, trimmed)
    }

    /// Dismiss the edit without publishing. Used for Escape and for any
    /// path that takes the field down without consumer notification.
    private func cancelEdit() {
        teardownEdit()
    }

    private func teardownEdit() {
        editField?.delegate = nil
        editField?.removeFromSuperview()
        editField = nil
        editingPill = nil
        needsDisplay = true
    }

    /// `true` while any pill is in inline-edit mode. Hover / close
    /// rendering short-circuits on this so the editing pill doesn't
    /// paint an `×` hotspot over its own text field.
    private var isEditing: Bool { editingPill != nil }

    #if DEBUG
    /// Test hook — sets the editing field's value without going through
    /// a real NSTextField + field-editor dance. Only meaningful while an
    /// edit is in progress; no-op otherwise.
    @objc func setEditTextForTesting(_ text: String) {
        editField?.stringValue = text
    }
    /// Test hook — explicitly commits the in-flight edit.
    @objc func commitEditForTesting() { commitEdit() }
    /// Test hook — explicitly cancels the in-flight edit.
    @objc func cancelEditForTesting() { cancelEdit() }
    #endif

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
            let isHovered = hoveredPill == i && !isEditing
            let isBeingEdited = editingPill == i

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

            // Pill being renamed — skip the title + close-hotspot drawing.
            // The NSTextField subview covers the title area; drawing a
            // label underneath would bleed through around the field's
            // corners and confuse the eye about what's editable.
            if isBeingEdited { continue }

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

        // While a pill is being renamed, a click inside the edit field
        // belongs to the field editor — we shouldn't see it here at all
        // (subviews hit-test first), but the containing pill bounds still
        // route through this method when the click lands on the pill body
        // outside the field (e.g., the close hotspot area). Commit the
        // in-flight edit on any outside click before processing so the
        // click doesn't silently drop the edit.
        if let idx = editingPill, idx < pillFrames.count {
            let editingRect = pillFrames[idx]
            if !NSPointInRect(p, editingRect) {
                commitEdit()
                // Fall through — the click was outside the editing pill,
                // treat it as a normal click on whatever it landed on.
            } else {
                // Click inside the editing pill but outside the field
                // (close hotspot area). Treat as commit-and-stay-put.
                commitEdit()
                return
            }
        }

        if NSPointInRect(p, addButtonFrame) {
            onAddTab?()
            return
        }

        // Double-click on a pill body (outside the close hotspot) → enter
        // inline rename mode. Matches Safari / Chrome / iTerm2 tab rename
        // idiom — no modal alert, no menu trip.
        if event.clickCount == 2 {
            for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
                let closeRect = closeHotspot(in: rect)
                if !NSPointInRect(p, closeRect), i < tabs.count {
                    beginEditing(pillIndex: i)
                    return
                }
            }
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
                // Don't arm the close hotspot for the pill under edit —
                // the `×` isn't drawn there and honouring a close click
                // would toss the field and kill the session.
                hoveredClose = editingPill != i
                    && NSPointInRect(p, closeHotspot(in: rect))
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

    // MARK: - Context menu (right-click to rename)

    /// Build a per-pill context menu on right-click. The Rename / Reset
    /// items dispatch via the responder chain (nil target) — AppKit routes
    /// them to the key window's `MainWindowController`. To ensure the
    /// controller that receives the action is the one for the right-clicked
    /// pill (not whichever pill happens to currently be selected), we
    /// pre-select the pill's window before returning the menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        // Hit-test against pillFrames. Falling outside a pill (e.g. over the
        // `+` button or the gutter) yields no contextual menu — there's no
        // tab to target.
        guard
            let idx = pillFrames.firstIndex(where: { NSPointInRect(p, $0) }),
            idx < tabs.count
        else { return nil }

        let targetWindow = tabs[idx]
        // Bring the right-clicked tab to the front before showing the menu.
        // Without this, ⌘/responder-chain dispatch on the resulting items
        // would go to the previously-selected pill's controller, which
        // isn't what the user clicked on. Selecting also flips window.key
        // in the same runloop tick so by the time the user picks Rename…,
        // the correct controller is in the responder chain.
        onSelectWindow?(targetWindow)

        let menu = NSMenu()

        let rename = NSMenuItem(
            title: "Rename…",
            action: #selector(MainWindowController.renameActiveTab(_:)),
            keyEquivalent: ""
        )
        menu.addItem(rename)

        let reset = NSMenuItem(
            title: "Reset to Auto",
            action: #selector(MainWindowController.resetActiveTabTitle(_:)),
            keyEquivalent: ""
        )
        menu.addItem(reset)

        menu.addItem(.separator())

        // Close — dupes what the hover `×` does, but is useful on a
        // context menu for discoverability and for users who never hover.
        let close = NSMenuItem(
            title: "Close Tab",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: ""
        )
        // performClose: must target the window directly; it isn't a
        // responder-chain action like rename.
        close.target = targetWindow
        menu.addItem(close)

        return menu
    }
}

extension TabStripView: NSTextFieldDelegate {
    /// Enter → commit, Escape → cancel. Routed through the field editor's
    /// command dispatch so we get both Return on a physical keyboard and
    /// Enter on the numeric keypad.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) {
            cancelEdit()
            return true
        }
        if sel == #selector(NSResponder.insertNewline(_:)) {
            commitEdit()
            return true
        }
        return false
    }

    /// Focus loss that isn't routed through Enter / Escape — clicked
    /// elsewhere in the app, ⌘-Tab to another app, etc. Commit so the
    /// user's typed value survives. `cancelEdit` paths have already
    /// nil'd `editField`, so this is a no-op in that case.
    func controlTextDidEndEditing(_ obj: Notification) {
        if editField != nil { commitEdit() }
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
