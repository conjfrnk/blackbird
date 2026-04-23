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

    /// Publish and tear down any in-flight inline rename. Safe to call
    /// when no edit is in progress (the strip short-circuits internally).
    /// `MainWindowController.refreshTabBar` invokes this before hiding
    /// the accessory on the multi-tab → single-tab transition so the
    /// editing field doesn't survive as a stale subview of the hidden
    /// strip. (main-window F8)
    func commitAnyInFlightEdit() {
        stripView.commitEditIfNeeded()
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

    /// Pill index currently holding keyboard focus, or `nil` when the
    /// strip itself is first responder with no specific pill focused.
    /// Drives the focus ring rendered in `draw(_:)` and the
    /// `moveLeft:`/`moveRight:`/`performClick:` key handlers. Audit
    /// titlebar-tabs F4.
    private var focusedPill: Int? = nil

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
        // list. Commit only when the LIST SHAPE changes (count or identity),
        // not on a bare width change — otherwise every live-resize tick at
        // 120 Hz discards the user's mid-type rename silently. Width-only
        // updates just re-lay the pill frames and reposition the existing
        // field below. (main-window F6)
        let listShapeChanged = self.tabs.count != tabs.count
            || !zip(self.tabs, tabs).allSatisfy { $0 === $1 }
        // Collect titles BEFORE updating so VoiceOver value-changed
        // notifications can be posted against the correct pill after
        // the tab array refreshes. Audit titlebar-tabs F5.
        let oldTitles: [String] = self.tabs.map { $0.title }
        if editingPill != nil, listShapeChanged {
            commitEdit()
        }
        self.tabs = tabs
        self.selectedTab = selected
        self.totalWidth = width
        self.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        layoutPills()
        // Post VO value-changed notifications when a title changed but
        // the list shape didn't. The per-pill accessibility element
        // exposes the title via `accessibilityLabel`, so a bare
        // repaint + `NSAccessibility.post(..., valueChanged)` is
        // enough for VO to re-read the pill. Skip on list-shape
        // changes — AppKit's container-children invalidation will
        // handle those more comprehensively. Audit titlebar-tabs F5.
        if !listShapeChanged {
            for (i, window) in tabs.enumerated() where i < oldTitles.count {
                if window.title != oldTitles[i], i < pillFrames.count {
                    let element = makePillElement(pillIndex: i, window: window)
                    NSAccessibility.post(
                        element: element,
                        notification: .valueChanged
                    )
                }
            }
        }
        // Width-only update: move the edit field to track the pill's new
        // x/width so the caret doesn't drift off-pill. Geometry mirrors
        // `beginEditing`'s field-rect computation.
        if let idx = editingPill,
           idx < pillFrames.count,
           let field = editField {
            let pill = pillFrames[idx]
            let closeRect = closeHotspot(in: pill)
            field.frame = NSRect(
                x: pill.minX + closeRect.width + 6,
                y: pill.minY + 2,
                width: max(0, pill.width - (closeRect.width + 12)),
                height: pill.height - 4
            )
        }
        needsDisplay = true
    }

    /// Commit the in-flight edit if one is active. No-op otherwise. Used
    /// by `MainWindowController.refreshTabBar` on the multi-tab →
    /// single-tab transition so the field doesn't survive as a subview
    /// of a hidden strip and re-appear on the next grow-back.
    /// (main-window F8)
    func commitEditIfNeeded() {
        if editingPill != nil {
            commitEdit()
        }
    }

    // MARK: - Accessibility
    //
    // Each pill + the `+` button are drawn shapes, not real views, so
    // NSAccessibility sees nothing by default. VoiceOver skips over the
    // tab strip entirely. Expose per-pill NSAccessibilityElement buttons
    // keyed to window titles, plus a "New Tab" button, so rotor and VO
    // navigation reach them. Audit titlebar-tabs F3.

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Tabs" }

    override func accessibilityChildren() -> [Any]? {
        var out: [NSAccessibilityElement] = []
        for (i, window) in tabs.enumerated() where i < pillFrames.count {
            out.append(makePillElement(pillIndex: i, window: window))
        }
        out.append(makeAddButtonElement())
        return out
    }

    private func makePillElement(pillIndex: Int, window: NSWindow) -> NSAccessibilityElement {
        let frame = pillFrames[pillIndex]
        let element = BBTabPillAccessibilityElement(
            parent: self,
            frame: frame,
            title: window.title.isEmpty ? "Untitled" : window.title,
            isSelected: window === selectedTab,
            onSelect: { [weak self] in self?.onSelectWindow?(window) },
            onClose: { [weak self] in self?.onCloseWindow?(window) }
        )
        return element
    }

    private func makeAddButtonElement() -> NSAccessibilityElement {
        let element = BBAddTabAccessibilityElement(
            parent: self,
            frame: addButtonFrame,
            onAdd: { [weak self] in self?.onAddTab?() }
        )
        return element
    }

    private static let addButtonWidth: CGFloat = 22
    private static let pillSpacing: CGFloat = 2
    private static let trailingInset: CGFloat = 4
    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private func layoutPills() {
        pillFrames.removeAll(keepingCapacity: true)
        // Pill geometry: the stripView is 28 pt tall (standard titlebar);
        // pills are 24 pt at y=4 → center=16, which matches the traffic-
        // light vertical midline. Traffic lights aren't exactly centered
        // in the titlebar — their origin sits ~2pt below center on
        // modern macOS — so strict mathematical centering (y=2, center=14)
        // reads visibly high; y=4 restores the offset.
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
    ///
    /// Note: titlebar-tabs F8 flagged pure-whitespace input over a
    /// non-empty existing title as an "accidental override clear".
    /// The current contract — and the existing
    /// `InlineRenameTests.test_commit_empty_forwards_empty_string`
    /// pinning — is that whitespace-only commits still forward as the
    /// empty string so the consumer can map it to "revert to OSC".
    /// Modifying that behaviour would be a test-owner change; deferred
    /// here.
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

            // Keyboard focus ring. Full-Keyboard-Access users can't
            // reach the pills without one. Drawn on TOP of the fill +
            // title so it's visible regardless of selected/hovered
            // state. Accent-coloured for consistency with the rest of
            // AppKit's focus indicators. Audit titlebar-tabs F4.
            if focusedPill == i && isStripFirstResponder() {
                let focusPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                             xRadius: 4, yRadius: 4).cgPath
                ctx.addPath(focusPath)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(2)
                ctx.strokePath()
            }
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

    // MARK: - Keyboard focus (titlebar-tabs F4)

    /// Accept first responder so Full-Keyboard-Access users (Tab /
    /// Shift-Tab key path) can reach the strip. While focused, arrow
    /// keys move the focus between pills, Space/Return activates the
    /// focused pill, and Delete closes it.
    override var acceptsFirstResponder: Bool { !tabs.isEmpty }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        // Default focus to the currently-selected pill so Tab->strip
        // lands on the user's active tab rather than always column 0.
        if focusedPill == nil, !tabs.isEmpty {
            if let sel = selectedTab,
               let idx = tabs.firstIndex(where: { $0 === sel }) {
                focusedPill = idx
            } else {
                focusedPill = 0
            }
        }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            // Keep `focusedPill` set so Tab->back restores the last
            // focused pill. Just repaint so the ring disappears while
            // another responder is active.
            needsDisplay = true
        }
        return ok
    }

    /// True while the window's first responder is this strip. The focus
    /// ring only renders when true so the ring isn't painted after a
    /// responder swap leaves `focusedPill` valid but the strip
    /// inactive. Audit titlebar-tabs F4.
    private func isStripFirstResponder() -> Bool {
        window?.firstResponder === self
    }

    override func keyDown(with event: NSEvent) {
        // Let interpretKeyEvents route arrow/Space/Return/Delete through
        // the standard NSResponder selector dispatch so our
        // `moveLeft:`/`moveRight:`/`insertNewline:`/`deleteBackward:`
        // overrides below fire. Unrecognised selectors fall back to
        // super (menu bar bindings, etc.).
        self.interpretKeyEvents([event])
    }

    override func moveLeft(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let current = focusedPill ?? 0
        focusedPill = max(0, current - 1)
        needsDisplay = true
    }

    override func moveRight(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let current = focusedPill ?? 0
        focusedPill = min(tabs.count - 1, current + 1)
        needsDisplay = true
    }

    override func insertNewline(_ sender: Any?) {
        activateFocusedPill()
    }

    /// Space (via `insertText` under FKA) also selects — matches
    /// AppKit's standard "button"-ish activation. NSTextField-style
    /// `performKeyEquivalent` isn't used here because we want the
    /// Space to activate even without a Cmd modifier.
    override func insertText(_ insertString: Any) {
        if let str = insertString as? String, str == " " {
            activateFocusedPill()
            return
        }
        super.insertText(insertString)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let idx = focusedPill, idx < tabs.count else { return }
        // Close the focused tab; keep focus on the same index (which
        // now points at the next-over tab after the close).
        let closing = tabs[idx]
        onCloseWindow?(closing)
        // Don't mutate `focusedPill` here — the close triggers a tab
        // group refresh that calls `update(tabs:selected:width:)`, and
        // we want the focus to land on the closest surviving pill.
        // Clamp in a follow-up so out-of-bounds reads don't crash.
        if let idx = focusedPill, idx >= tabs.count {
            focusedPill = max(0, tabs.count - 1)
        }
        needsDisplay = true
    }

    private func activateFocusedPill() {
        guard let idx = focusedPill, idx < tabs.count else { return }
        onSelectWindow?(tabs[idx])
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

    /// Build a per-pill context menu on right-click. Rename / Reset items
    /// target the right-clicked window's `MainWindowController`
    /// explicitly so the responder chain's state at the moment the menu
    /// fires (which may lag key-window transitions on slow machines or
    /// under tests) can't mis-route the action to a different window's
    /// controller. Audit titlebar-tabs F15.
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
        // This is still the correct UX (the menu visually corresponds to
        // the selected pill), even though the explicit menu targets below
        // no longer depend on responder chain state.
        onSelectWindow?(targetWindow)

        let menu = NSMenu()

        // Explicit targets, not responder-chain dispatch. Audit
        // titlebar-tabs F15.
        let controller = targetWindow.windowController as? MainWindowController

        let rename = NSMenuItem(
            title: "Rename…",
            action: #selector(MainWindowController.renameActiveTab(_:)),
            keyEquivalent: ""
        )
        rename.target = controller
        menu.addItem(rename)

        let reset = NSMenuItem(
            title: "Reset to Auto",
            action: #selector(MainWindowController.resetActiveTabTitle(_:)),
            keyEquivalent: ""
        )
        reset.target = controller
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

/// Accessibility proxy for a single tab pill. Maps its `activate` to
/// `onSelect` (equivalent to clicking the pill) and exposes a custom
/// "Close Tab" action that routes to `onClose`. Frame in parent-view
/// coordinates; NSAccessibility transforms to screen space for VO.
final class BBTabPillAccessibilityElement: NSAccessibilityElement {
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let _title: String
    private let _isSelected: Bool
    private weak var parentView: NSView?

    init(parent: NSView, frame: NSRect, title: String, isSelected: Bool,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._title = title
        self._isSelected = isSelected
        self.onSelect = onSelect
        self.onClose = onClose
        self.parentView = parent
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.button)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityLabel() -> String? {
        _isSelected ? "Tab, \(_title), selected" : "Tab, \(_title)"
    }

    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
            self?.onClose()
            return true
        }]
    }
}

/// Accessibility proxy for the trailing `+` button. Role=.button with
/// a single press action that fires `onAddTab`.
final class BBAddTabAccessibilityElement: NSAccessibilityElement {
    private let onAdd: () -> Void

    init(parent: NSView, frame: NSRect, onAdd: @escaping () -> Void) {
        self.onAdd = onAdd
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.button)
        setAccessibilityFrameInParentSpace(frame)
    }

    override func accessibilityLabel() -> String? { "New Tab" }

    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onAdd()
        return true
    }
}
