import AppKit
import os

/// Custom tab bar inside the titlebar row, built on the native `NSWindowTabGroup`; the native strip is hidden.
final class TitlebarTabBarViewController: NSTitlebarAccessoryViewController {

    private let stripView = TabStripView(frame: .zero)
    private weak var hostWindow: NSWindow?

    init(window: NSWindow) {
        self.hostWindow = window
        super.init(nibName: nil, bundle: nil)
        // `.bottom` would put the accessory below the titlebar.
        layoutAttribute = .right
        view = stripView
        stripView.onSelectWindow = { [weak self] w in
            self?.hostWindow?.tabGroup?.selectedWindow = w
            w.makeKeyAndOrderFront(nil)
        }
        stripView.onCloseWindow = { w in
            // Neighbour selection for a closing SELECTED tab lives in
            // `MainWindowController.windowShouldClose`, after the confirm, not here.
            w.performClose(nil)
        }
        stripView.onAddTab = {
            if !NSApp.sendAction(#selector(AppDelegate.newWindowForTab(_:)), to: nil, from: nil) {
                TitlebarTabBarViewController.tabBarLogger.error("newWindowForTab: found no responder; the + button did nothing")
            }
        }
        stripView.onCommitRename = { window, newOverride in
            guard let controller = window.windowController as? MainWindowController else { return }
            controller.applyInlineRename(newOverride)
        }
    }

    func beginInlineRename(for window: NSWindow) {
        guard let group = window.tabGroup else { return }
        // Pill index comes from the coordinator's VISUAL order, not `group.windows`' arrival
        // order: the two diverge after a drag-reorder.
        let tabs = TabOrderCoordinator.shared.orderedTabs(for: group)
        guard let idx = tabs.firstIndex(of: window) else { return }
        stripView.beginEditing(pillIndex: idx)
    }

    func commitAnyInFlightEdit() {
        stripView.commitEditIfNeeded()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    static let tabBarLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "tabs")

    func clearTabs() {
        stripView.detachTabs()
    }

    /// The caller toggles `view.isHidden` by tab count before calling this.
    func refresh(availableWidth: CGFloat) {
        guard let window = hostWindow else { return }
        // Visual order is owned by `TabOrderCoordinator`, not AppKit's `tabGroup.windows`.
        let tabs = TabOrderCoordinator.shared.orderedTabs(of: window)
        let selected = window.tabGroup?.selectedWindow ?? window
        // `update` sizes the strip (size only: its origin belongs to AppKit).
        stripView.update(tabs: tabs, selected: selected, width: availableWidth)
    }
}

/// Pill strip with a trailing `+` button, living inside an `NSTitlebarAccessoryViewController`.
final class TabStripView: NSView, NSViewToolTipOwner {

    static let height: CGFloat = 28

    var onSelectWindow: ((NSWindow) -> Void)?
    var onCloseWindow:  ((NSWindow) -> Void)?
    var onAddTab:       (() -> Void)?
    /// `""` means "clear the override". Not called on cancel.
    var onCommitRename: ((NSWindow, String) -> Void)?

    lazy var requestWindowDrag: (NSEvent) -> Void = { [weak self] event in
        guard let window = self?.window else {
            Self.dragLogger.notice("windowMove hand-off skipped: tab strip has no window — gesture dropped")
            return
        }
        window.performDrag(with: event)
    }

    // The strip is the single writer of its layout state (`update` / `layoutPills`).
    fileprivate var tabs: [NSWindow] = []
    fileprivate weak var selectedTab: NSWindow?
    private var totalWidth: CGFloat = 0
    /// While the row pages, frames of tabs outside `visiblePillRange` sit at virtual positions off
    /// the page; only a visible pill is ever painted, hit-tested, or exposed to accessibility.
    fileprivate var pillFrames: [CGRect] = []
    fileprivate var addButtonFrame: CGRect = .zero
    fileprivate var visiblePillRange: Range<Int> = 0 ..< 0
    /// `.zero` when the whole row fits. A slot is reserved on both sides of every page, drawn or not.
    fileprivate var leadingPageFrame: CGRect = .zero
    fileprivate var trailingPageFrame: CGRect = .zero

    enum PageDirection: Equatable {
        case earlier
        case later
    }

    // MARK: - Hoisted collaborators
    // Each holds an `unowned` back-reference to the strip, which strong-references it.
    private lazy var tabDragController = TabDragController(view: self)
    private lazy var tabRenameController = TabRenameController(view: self)
    private lazy var tabAccessibility = TabStripAccessibility(view: self)

    /// `.pending` is a real third outcome; do not flatten this to a `Bool`.
    enum DragIntent: Equatable {
        case pending
        case reorder
        case windowMove
    }

    static func classifyPillDrag(dx: CGFloat, dy: CGFloat,
                                 threshold: CGFloat,
                                 hasMoveModifier: Bool) -> DragIntent {
        guard dx.isFinite, dy.isFinite else { return .pending }
        guard max(abs(dx), abs(dy)) >= threshold else { return .pending }
        return hasMoveModifier ? .windowMove : .reorder
    }

    fileprivate var hoveredPill: Int? = nil
    fileprivate var hoveredClose = false
    fileprivate var hoveredAdd = false
    private var trackingArea: NSTrackingArea?
    private var toolTipRects: [CGRect] = []

    private var focusedPill: Int? = nil

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        // The system focus ring stays off; the keyboard focus indicator is drawn in `draw(_:)`, gated on `focusedPill`.
        focusRingType = .none
        updateTrackingAreas()
        // AppKit places and moves the accessory by setting this view's frame; a pure move dirties
        // nothing, so ask for a redraw and let `viewWillDraw` re-align the pills.
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(frameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func frameDidChange(_ note: Notification) { needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    /// Pass-through: any region not claimed here belongs to AppKit's titlebar.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let sub = super.hitTest(point), sub !== self { return sub }
        let local = convert(point, from: superview)
        if NSPointInRect(local, addButtonFrame) { return self }
        // Both page-button slots are claimed even when undrawn: the second click of a double-click
        // must not fall through to the titlebar and zoom the window.
        if pageDirection(at: local) != nil { return self }
        return pillIndex(at: local) != nil ? self : nil
    }

    /// `tabs` is a STRONG `[NSWindow]` that includes the strip's own host; uncleared, it closes the cycle
    /// `NSWindow → titlebarAccessoryViewControllers → view → tabs → NSWindow`.
    func detachTabs() {
        commitEditIfNeeded()
        tabs = []
        selectedTab = nil
        pillFrames = []
        visiblePillRange = 0 ..< 0
        leadingPageFrame = .zero
        trailingPageFrame = .zero
        focusedPill = nil
        clearHover()
        tabAccessibility.invalidateCache()
        needsDisplay = true
    }

    func update(tabs: [NSWindow], selected: NSWindow, width: CGFloat) {
        // Commit an in-flight edit only when the list SHAPE changes, not on a bare width change:
        // live resize would otherwise discard a mid-type rename.
        let listShapeChanged = self.tabs.count != tabs.count
            || !zip(self.tabs, tabs).allSatisfy { $0 === $1 }
        if tabRenameController.isEditing, listShapeChanged {
            tabRenameController.commitEdit()
        }
        if listShapeChanged {
            // The gesture's captured index no longer matches the strip.
            tabDragController.cancelForListShapeChange()
            // A pill-targeted mark refers to the OLD pill list. A `+`-targeted mark must survive: clicking `+`
            // always changes the list shape, and dropping it would let a `+` double-click open two tabs.
            if case .pill = Self.lastMouseDown?.target {
                Self.lastMouseDown = nil
            }
        }
        self.tabs = tabs
        self.selectedTab = selected
        self.totalWidth = width
        setFrameSize(NSSize(width: width, height: Self.height))
        layoutPills()
        // Pill frames changed, possibly under a stationary cursor.
        applyHoverAtCurrentCursorLocation()
        tabAccessibility.refreshTitlesAndPost(tabs: tabs, listShapeChanged: listShapeChanged)
        tabRenameController.repositionFieldForWidthChange()
        needsDisplay = true
    }

    func commitEditIfNeeded() {
        tabRenameController.commitIfNeeded()
    }

    // MARK: - Accessibility
    // Pills and the `+` button are drawn shapes, not views, so they are exposed as NSAccessibilityElements.

    override func isAccessibilityElement() -> Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? { "Tabs" }

    override func accessibilityChildren() -> [Any]? {
        tabAccessibility.children()
    }

    static func changedTitleIndices(previous: [String], current: [String]) -> [Int] {
        (0 ..< min(previous.count, current.count)).filter { previous[$0] != current[$0] }
    }

    private static let addButtonWidth: CGFloat = 22
    private static let pillSpacing: CGFloat = 2
    private static let trailingInset: CGFloat = 4
    /// Narrowest a pill may get before the row pages instead.
    private static let minPillWidth: CGFloat = 80
    private static let pageSlotWidth: CGFloat = 14
    fileprivate static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private static let pillHeight: CGFloat = 24

    /// Used when there is no traffic light to align to (no window, full screen).
    private static let fallbackPillY: CGFloat = TabStripView.height - TabStripView.pillHeight

    private func trafficLightMidY() -> CGFloat? {
        guard let window,
              !window.styleMask.contains(.fullScreen),
              let button = window.standardWindowButton(.closeButton),
              !button.isHidden,
              button.window === window else { return nil }
        return convert(button.bounds, from: button).midY
    }

    private func currentPillY() -> CGFloat {
        TabStripLayout.pillOriginY(stripHeight: Self.height,
                                   pillHeight: Self.pillHeight,
                                   trafficLightMidY: trafficLightMidY(),
                                   fallback: Self.fallbackPillY)
    }

    /// AppKit positions the accessory after `update(tabs:)` has run, so the traffic-light midline is
    /// knowable only once the strip is placed; re-place the pills when their row no longer matches it.
    override func viewWillDraw() {
        super.viewWillDraw()
        guard let placed = pillFrames.first?.minY,
              abs(currentPillY() - placed) > 0.01 else { return }
        layoutPills()
        tabRenameController.repositionFieldForWidthChange()
        applyHoverAtCurrentCursorLocation()
        needsDisplay = true
    }

    private func layoutPills() {
        tabAccessibility.invalidateCache()
        pillFrames.removeAll(keepingCapacity: true)
        // The pill midline follows the live traffic-light midline, not a fixed offset: AppKit centres the
        // accessory in a titlebar band whose height varies by OS, and the lights do not move with it.
        let h = Self.pillHeight
        let y = currentPillY()
        let addW = Self.addButtonWidth
        let gap = Self.pillSpacing
        let trail = Self.trailingInset
        let n = max(1, tabs.count)
        let available = max(0, totalWidth - trail - addW - gap)
        let selectedIndex = tabs.firstIndex(where: { (t: NSWindow) -> Bool in t === selectedTab })
        let row = TabStripLayout.pillRow(available: available,
                                         count: n,
                                         selectedIndex: selectedIndex,
                                         minPillWidth: Self.minPillWidth,
                                         edgeSlotWidth: Self.pageSlotWidth)
        // Pills outside the page keep virtual frames at the same pitch; the later ones are parked at or beyond
        // the strip's trailing edge so none can sit over the trailing page slot or the `+`.
        var x = row.edgeSlotWidth - CGFloat(row.firstVisible) * row.slotWidth
        for i in 0..<n {
            if row.isPaged, i == row.visibleRange.upperBound { x = max(x, totalWidth) }
            pillFrames.append(NSRect(x: x, y: y, width: max(0, row.slotWidth - gap / 2), height: h))
            x += row.slotWidth
        }
        visiblePillRange = row.visibleRange
        if row.isPaged {
            leadingPageFrame = NSRect(x: 0, y: y, width: row.edgeSlotWidth, height: h)
            trailingPageFrame = NSRect(x: available - row.edgeSlotWidth, y: y,
                                       width: row.edgeSlotWidth, height: h)
        } else {
            leadingPageFrame = .zero
            trailingPageFrame = .zero
        }
        addButtonFrame = NSRect(x: (row.isPaged ? available : x) + gap, y: y, width: addW, height: h)
        refreshToolTips()
    }

    // MARK: - Tooltips

    private func refreshToolTips() {
        var rects: [CGRect] = visiblePillRange.compactMap { (i: Int) -> CGRect? in
            i < pillFrames.count ? pillFrames[i] : nil
        }
        if canPage(.earlier) { rects.append(leadingPageFrame) }
        if canPage(.later) { rects.append(trailingPageFrame) }
        guard rects != toolTipRects else { return }
        removeAllToolTips()
        for r in rects {
            addToolTip(r, owner: self, userData: nil)
        }
        toolTipRects = rects
    }

    /// Resolved lazily from the point, so a title change needs no re-registration.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if let direction = pageDirection(at: point), canPage(direction) {
            return pageButtonLabel(direction)
        }
        guard let i = pillIndex(at: point), i < tabs.count else { return "" }
        return Self.displayTitle(tabs[i].title)
    }

    // MARK: - Inline editing

    func beginEditing(pillIndex: Int) {
        tabRenameController.beginEditing(pillIndex: pillIndex)
    }

    private var isEditing: Bool { tabRenameController.isEditing }

    #if DEBUG
    @objc func setEditTextForTesting(_ text: String) {
        tabRenameController.editField?.stringValue = text
    }
    @objc func commitEditForTesting() { tabRenameController.commitEdit() }
    @objc func cancelEditForTesting() { tabRenameController.cancelEdit() }
    @objc var isEditingForTesting: Bool { isEditing }

    var pillCountForTesting: Int { pillFrames.count }
    var focusedPillForTesting: Int? {
        get { focusedPill }
        set { focusedPill = newValue }
    }
    @objc func deleteBackwardForTesting() { deleteBackward(nil) }

    var pendingDragPillIndexForTesting: Int? {
        tabDragController.armedPillIndex
    }

    var dragStateForTesting: (originalIndex: Int, currentIndex: Int, cursorX: CGFloat)? {
        tabDragController.activeDragState.map {
            ($0.originalIndex, $0.currentIndex, $0.cursorX)
        }
    }

    var pillFramesForTesting: [CGRect] { pillFrames }
    var visiblePillRangeForTesting: Range<Int> { visiblePillRange }
    var pageButtonFramesForTesting: (earlier: CGRect, later: CGRect) {
        (leadingPageFrame, trailingPageFrame)
    }
    func toolTipForTesting(at point: NSPoint) -> String? {
        guard toolTipRects.contains(where: { (r: CGRect) -> Bool in NSPointInRect(point, r) }) else {
            return nil
        }
        return view(self, stringForToolTip: 0, point: point, userData: nil)
    }
    var addButtonFrameForTesting: CGRect { addButtonFrame }
    #endif

    // MARK: - Drawing

    /// Tinted with `labelColor` so the pills stay visible on both light and dark titlebars.
    private struct PillPalette {
        let tint = NSColor.labelColor
        let selectedBg = NSColor.labelColor.withAlphaComponent(0.18).cgColor
        let draggedBg = NSColor.labelColor.withAlphaComponent(0.24).cgColor
        let hoverBg = NSColor.labelColor.withAlphaComponent(0.10).cgColor
        let inactiveBg = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        let textColor = NSColor.labelColor
        let inactiveText = NSColor.secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let palette = PillPalette()
        let activeDrag = tabDragController.activeDragState
        let drawOrder = Self.pillDrawOrder(count: tabs.count,
                                           draggedOriginalIndex: activeDrag?.originalIndex)

        for i in drawOrder where visiblePillRange.contains(i) && i < tabs.count && i < pillFrames.count {
            let (rect, isDraggedPill) = pillRect(for: i, activeDrag: activeDrag)
            let w = tabs[i]
            let isSelected = w === selectedTab
            let isHovered = hoveredPill == i && !isEditing && activeDrag == nil
            let isBeingEdited = tabRenameController.editingPill == i
            drawPill(ctx: ctx, window: w, index: i, rect: rect,
                     isDraggedPill: isDraggedPill, isSelected: isSelected,
                     isHovered: isHovered, isBeingEdited: isBeingEdited,
                     palette: palette)
        }

        drawPageButtons(ctx: ctx, palette: palette)
        drawAddButton(ctx: ctx, palette: palette)
    }

    /// The dragged pill paints LAST, on top of the siblings it overlaps.
    private static func pillDrawOrder(count: Int, draggedOriginalIndex: Int?) -> [Int] {
        if let d = draggedOriginalIndex {
            return (0..<count).filter { $0 != d } + [d]
        }
        return Array(0..<count)
    }

    private func pillRect(for i: Int,
                          activeDrag: TabDragController.DragState?) -> (NSRect, Bool) {
        guard let d = activeDrag else { return (pillFrames[i], false) }
        if i == d.originalIndex {
            let rect = TabDragController.draggedPillRect(
                base: pillFrames[d.originalIndex],
                cursorX: d.cursorX,
                downOffsetX: d.downOffsetX,
                addButtonMinX: addButtonFrame.minX,
                spacing: Self.pillSpacing
            )
            return (rect, true)
        }
        let slot = Self.intermediateSlot(originalIdx: i,
                                         draggedFrom: d.originalIndex,
                                         draggedTo: d.currentIndex)
        let rect = slot < pillFrames.count ? pillFrames[slot] : pillFrames[i]
        return (rect, false)
    }

    private func drawPill(ctx: CGContext, window w: NSWindow, index i: Int,
                          rect: NSRect, isDraggedPill: Bool, isSelected: Bool,
                          isHovered: Bool, isBeingEdited: Bool,
                          palette: PillPalette) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).cgPath
        ctx.addPath(path)
        if isDraggedPill {
            ctx.setFillColor(palette.draggedBg)
        } else if isSelected {
            ctx.setFillColor(palette.selectedBg)
        } else if isHovered {
            ctx.setFillColor(palette.hoverBg)
        } else {
            ctx.setFillColor(palette.inactiveBg)
        }
        ctx.fillPath()

        // The rename field covers the title area; a label drawn underneath bleeds through around its corners.
        if isBeingEdited { return }

        let closeRect = closeHotspot(in: rect)
        if isHovered {
            let xFillColor: CGColor
            if hoveredClose {
                xFillColor = palette.tint.withAlphaComponent(0.20).cgColor
            } else {
                xFillColor = palette.tint.withAlphaComponent(0.08).cgColor
            }
            ctx.addPath(NSBezierPath(ovalIn: closeRect).cgPath)
            ctx.setFillColor(xFillColor)
            ctx.fillPath()
            let xAttr: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                .foregroundColor: palette.textColor,
            ]
            let xs = NSAttributedString(string: "×", attributes: xAttr)
            let xsize = xs.size()
            xs.draw(at: NSPoint(
                x: closeRect.midX - xsize.width / 2,
                y: closeRect.midY - xsize.height / 2 - 1
            ))
        }

        // Room for the close button is always reserved so titles don't jump on hover; same
        // horizontal math as the inline-rename field, via TabStripLayout.
        let area = TabStripLayout.titleArea(in: rect, closeWidth: closeRect.width)
        let titleArea = NSRect(
            x: area.x,
            y: rect.minY,
            width: area.width,
            height: rect.height
        )
        let title = Self.displayTitle(w.title)
        let truncated = truncatedString(title, fitting: titleArea.width)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.titleFont,
            .foregroundColor: isSelected ? palette.textColor : palette.inactiveText,
        ]
        let s = NSAttributedString(string: truncated, attributes: attrs)
        let tsize = s.size()
        s.draw(at: NSPoint(
            x: titleArea.midX - tsize.width / 2,
            y: titleArea.midY - tsize.height / 2
        ))

        if showsUnseenAttention(w) {
            let d: CGFloat = 6
            let dot = NSRect(x: rect.maxX - d - 6, y: rect.midY - d / 2, width: d, height: d)
            ctx.addPath(NSBezierPath(ovalIn: dot).cgPath)
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillPath()
        }

        if focusedPill == i && isStripFirstResponder() {
            let focusPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                         xRadius: 4, yRadius: 4).cgPath
            ctx.addPath(focusPath)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.strokePath()
        }
    }

    private func showsUnseenAttention(_ w: NSWindow) -> Bool {
        w !== selectedTab
            && (w.windowController as? MainWindowController)?.hasUnseenAttention == true
    }

    private func drawPageButtons(ctx: CGContext, palette: PillPalette) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: palette.textColor,
        ]
        let buttons: [(PageDirection, CGRect, String)] = [
            (.earlier, leadingPageFrame, "\u{2039}"),
            (.later, trailingPageFrame, "\u{203A}"),
        ]
        for (direction, frame, glyph) in buttons where canPage(direction) {
            let s = NSAttributedString(string: glyph, attributes: attrs)
            let size = s.size()
            s.draw(at: NSPoint(x: frame.midX - size.width / 2,
                               y: frame.midY - size.height / 2 + 1))
            if hasHiddenAttention(direction) {
                let d: CGFloat = 5
                let dot = NSRect(x: frame.midX - d / 2, y: frame.minY + 2, width: d, height: d)
                ctx.addPath(NSBezierPath(ovalIn: dot).cgPath)
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.fillPath()
            }
        }
    }

    private func drawAddButton(ctx: CGContext, palette: PillPalette) {
        let addPath = NSBezierPath(ovalIn: addButtonFrame).cgPath
        ctx.addPath(addPath)
        ctx.setFillColor(palette.tint.withAlphaComponent(hoveredAdd ? 0.16 : 0.08).cgColor)
        ctx.fillPath()
        let plusAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: palette.textColor,
        ]
        let plusStr = NSAttributedString(string: "+", attributes: plusAttr)
        let psize = plusStr.size()
        plusStr.draw(at: NSPoint(
            x: addButtonFrame.midX - psize.width / 2,
            y: addButtonFrame.midY - psize.height / 2 - 1
        ))
    }

    private func truncatedString(_ s: String, fitting width: CGFloat) -> String {
        Self.truncatedString(s, fitting: width, measure: Self.measureWidth)
    }

    /// Binary search, O(log N) measurements: a long hostile title must not freeze the redraw.
    /// Always keeps at least one character before the ellipsis.
    static func truncatedString(_ s: String,
                                fitting width: CGFloat,
                                measure: (String) -> CGFloat) -> String {
        guard width > 20 else { return "" }
        let chars = Array(s)
        if chars.isEmpty { return s }
        if measure(s) <= width { return s }

        var lo = 1
        var hi = max(1, chars.count - 1)
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = String(chars[..<mid]) + "…"
            if measure(candidate) <= width {
                lo = mid
            } else {
                hi = mid - 1
            }
        }
        return String(chars[..<lo]) + "…"
    }

    private static func measureWidth(_ s: String) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.titleFont]
        return (s as NSString).size(withAttributes: attrs).width
    }

    fileprivate func closeHotspot(in pillRect: NSRect) -> NSRect {
        let side: CGFloat = 14
        return NSRect(
            x: pillRect.minX + 6,
            y: pillRect.midY - side / 2,
            width: side,
            height: side
        )
    }

    // MARK: - Hit testing & hover

    enum ClickTarget: Equatable {
        case pill(Int)
        case addButton
        case pageButton(PageDirection)
    }

    /// `NSEvent.clickCount` counts the SYSTEM's click sequence, across activation boundaries and including clicks no
    /// strip received: the activating click is swallowed, so the next click arrives with `clickCount == 2`.
    struct ClickSequenceMark: Equatable {
        let target: ClickTarget
        /// `ClickTarget.pill` compares a bare index, so the mark must not license a click run across
        /// unrelated tab groups. `nil` for a strip with no group.
        let groupID: ObjectIdentifier?
        let systemClickCount: Int
        let effectiveClickCount: Int
        /// Whether the clicked pill was already selected when this run STARTED. Carried forward, not
        /// re-read: by the second click the first has selected the tab. Inline rename requires it.
        let targetWasSelected: Bool
        let timestamp: TimeInterval

        init(target: ClickTarget,
             groupID: ObjectIdentifier? = nil,
             systemClickCount: Int,
             effectiveClickCount: Int,
             targetWasSelected: Bool = false,
             timestamp: TimeInterval) {
            self.target = target
            self.groupID = groupID
            self.systemClickCount = systemClickCount
            self.effectiveClickCount = effectiveClickCount
            self.targetWasSelected = targetWasSelected
            self.timestamp = timestamp
        }
    }

    /// Deliberately SHARED across every strip: each tab is its own `NSWindow` with its own strip, so the two
    /// halves of one gesture are routinely delivered to different strips. Main thread only.
    private(set) static var lastMouseDown: ClickSequenceMark?

    /// The ordinal of this mousedown within the run the STRIPS received, not the window server's sequence.
    static func effectiveClickCount(previous: ClickSequenceMark?,
                                    target: ClickTarget,
                                    groupID: ObjectIdentifier? = nil,
                                    clickCount: Int,
                                    timestamp: TimeInterval,
                                    doubleClickInterval: TimeInterval) -> Int {
        guard clickCount > 1 else { return clickCount }
        guard let previous,
              previous.target == target,
              previous.groupID == groupID,
              previous.systemClickCount == clickCount - 1
        else { return 1 }
        let elapsed = timestamp - previous.timestamp
        guard elapsed >= 0, elapsed <= doubleClickInterval else { return 1 }
        return previous.effectiveClickCount + 1
    }

    #if DEBUG
    static func resetClickSequenceForTesting() { lastMouseDown = nil }
    static var lastMouseDownForTesting: ClickSequenceMark? { lastMouseDown }
    #endif

    /// Pills on other pages have frames too, but are never hit.
    private func pillIndex(at p: CGPoint) -> Int? {
        visiblePillRange.first(where: { (i: Int) -> Bool in
            i < pillFrames.count && NSPointInRect(p, pillFrames[i])
        })
    }

    private func pageDirection(at p: CGPoint) -> PageDirection? {
        if NSPointInRect(p, leadingPageFrame) { return .earlier }
        if NSPointInRect(p, trailingPageFrame) { return .later }
        return nil
    }

    fileprivate func canPage(_ direction: PageDirection) -> Bool {
        switch direction {
        case .earlier: return visiblePillRange.lowerBound > 0
        case .later: return visiblePillRange.upperBound < tabs.count
        }
    }

    private func hiddenPillRange(_ direction: PageDirection) -> Range<Int> {
        switch direction {
        case .earlier: return 0 ..< min(visiblePillRange.lowerBound, tabs.count)
        case .later: return min(visiblePillRange.upperBound, tabs.count) ..< tabs.count
        }
    }

    private func hasHiddenAttention(_ direction: PageDirection) -> Bool {
        hiddenPillRange(direction).contains(where: { (i: Int) -> Bool in
            showsUnseenAttention(tabs[i])
        })
    }

    fileprivate func pageButtonLabel(_ direction: PageDirection) -> String {
        let base = direction == .earlier ? "Show earlier tabs" : "Show later tabs"
        return hasHiddenAttention(direction) ? base + " (a tab needs attention)" : base
    }

    /// The page is a function of the selection, so selecting the tab next to the visible page is how it turns.
    fileprivate func page(_ direction: PageDirection) {
        guard canPage(direction) else { return }
        let target = direction == .earlier ? visiblePillRange.lowerBound - 1 : visiblePillRange.upperBound
        guard target >= 0, target < tabs.count else { return }
        onSelectWindow?(tabs[target])
    }

    private func clickTarget(at p: CGPoint) -> ClickTarget? {
        if let i = pillIndex(at: p) { return .pill(i) }
        if NSPointInRect(p, addButtonFrame) { return .addButton }
        if let direction = pageDirection(at: p) { return .pageButton(direction) }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Renumber and record this click BEFORE any dispatch below can return early.
        let target = clickTarget(at: p)
        let clicks: Int
        // Hoisted so the rename gate reads THIS click's value, not `Self.lastMouseDown` after it is overwritten.
        let wasSelected: Bool
        if let target {
            let groupID = window?.tabGroup.map(ObjectIdentifier.init)
            clicks = Self.effectiveClickCount(previous: Self.lastMouseDown,
                                              target: target,
                                              groupID: groupID,
                                              clickCount: event.clickCount,
                                              timestamp: event.timestamp,
                                              doubleClickInterval: NSEvent.doubleClickInterval)
            // A continued run inherits its original selectedness: by now the first click has selected the tab.
            if clicks > 1, let previous = Self.lastMouseDown {
                wasSelected = previous.targetWasSelected
            } else if case .pill(let i) = target, i < tabs.count {
                wasSelected = tabs[i] === selectedTab
            } else {
                wasSelected = false
            }
            Self.lastMouseDown = ClickSequenceMark(target: target,
                                                   groupID: groupID,
                                                   systemClickCount: event.clickCount,
                                                   effectiveClickCount: clicks,
                                                   targetWasSelected: wasSelected,
                                                   timestamp: event.timestamp)
        } else {
            clicks = event.clickCount
            wasSelected = false
            Self.lastMouseDown = nil
        }
        if focusedPill != nil {
            focusedPill = nil
            needsDisplay = true
        }

        // Every exit must yield first responder to the terminal or hand it to the rename field: `NSWindow.sendEvent`
        // auto-promotes the hit-tested view, and keystrokes left on the strip ring NSBeep.
        defer { yieldFirstResponderToTerminalIfParked() }

        if commitEditOnOutsideClick(p) { return }
        if NSPointInRect(p, addButtonFrame) {
            // Fire only on the first click the STRIPS saw; later clicks are still swallowed here so
            // they don't fall through to pill hit-testing.
            if clicks == 1 {
                onAddTab?()
            }
            return
        }
        if let direction = pageDirection(at: p) {
            // Same first-click-only rule; a second click falling through to the titlebar would zoom the window.
            if clicks == 1 {
                page(direction)
            }
            return
        }
        if beginRenameOnDoubleClick(p, clicks: clicks, wasSelected: wasSelected) { return }
        handlePillClick(p, event: event, clicks: clicks)
    }

    /// Returns `true` when the click was inside the editing pill but outside the field.
    private func commitEditOnOutsideClick(_ p: CGPoint) -> Bool {
        guard let idx = tabRenameController.editingPill, idx < pillFrames.count else { return false }
        let editingRect = pillFrames[idx]
        tabRenameController.commitEdit()
        return NSPointInRect(p, editingRect)
    }

    /// `clicks` is the renumbered count and `wasSelected` the run's ORIGINAL selectedness: rename is only for
    /// the tab already selected, so double-clicking a background pill switches to it and stops there.
    private func beginRenameOnDoubleClick(_ p: CGPoint, clicks: Int, wasSelected: Bool) -> Bool {
        guard clicks == 2, wasSelected, let i = pillIndex(at: p), i < tabs.count else { return false }
        guard !NSPointInRect(p, closeHotspot(in: pillFrames[i])) else { return false }
        beginEditing(pillIndex: i)
        return true
    }

    /// Selection is DEFERRED to mouseUp-as-click so a drag, reorder or window move, never switches tabs.
    private func handlePillClick(_ p: CGPoint, event: NSEvent, clicks: Int) {
        if let i = pillIndex(at: p) {
            guard i < tabs.count else { return }
            let rect = pillFrames[i]
            // Honour a close click only when the × is actually hovered, i.e. visible to the user.
            if hoveredPill == i, hoveredClose, NSPointInRect(p, closeHotspot(in: rect)) {
                onCloseWindow?(tabs[i])
                return
            }
            // `clicks`, not `event.clickCount`: after an activating click no strip received, the raw
            // count is already 2 and arming would be skipped.
            let canReorder = tabs.count > 1
                && clicks == 1
                && !isEditing
            if canReorder {
                tabDragController.arm(
                    pillIndex: i,
                    startPoint: p,
                    downOffsetX: p.x - rect.minX,
                    mouseDownEvent: event
                )
            } else {
                onSelectWindow?(tabs[i])
            }
            return
        }
    }

    // MARK: - Drag-to-reorder

    override func mouseDragged(with event: NSEvent) {
        tabDragController.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        tabDragController.mouseUp(with: event)
    }

    /// The slot whose centre is nearest the dragged pill's centre. Assumes equal-width pills.
    internal static func computeIntermediateIndex(cursorX: CGFloat,
                                                  downOffsetX: CGFloat,
                                                  count: Int,
                                                  pillFrames: [CGRect],
                                                  fallback: Int = 0) -> Int {
        guard count > 0, !pillFrames.isEmpty else { return fallback }
        let pillW = pillFrames[0].width
        let pillCenter = (cursorX - downOffsetX) + pillW / 2
        let firstOriginX = pillFrames[0].minX
        let slotPitch: CGFloat = (count > 1 && pillFrames.count > 1)
            ? (pillFrames[1].minX - pillFrames[0].minX)
            : pillW
        // Zero pitch (strip collapsed mid-drag): return the fallback so the dragged pill holds its
        // slot instead of snapping to slot 0 and committing an unintended reorder.
        guard slotPitch > 0 else { return fallback }
        let rawIndex = (pillCenter - (firstOriginX + pillW / 2)) / slotPitch
        let rounded = Int(rawIndex.rounded())
        return max(0, min(count - 1, rounded))
    }

    /// Where pill `originalIdx` renders during a drag: displaced siblings shift one slot toward the source.
    internal static func intermediateSlot(originalIdx: Int,
                                          draggedFrom: Int,
                                          draggedTo: Int) -> Int {
        if originalIdx == draggedFrom { return draggedTo }
        if draggedFrom == draggedTo { return originalIdx }
        if draggedFrom < draggedTo {
            if originalIdx > draggedFrom, originalIdx <= draggedTo {
                return originalIdx - 1
            }
        } else {
            if originalIdx >= draggedTo, originalIdx < draggedFrom {
                return originalIdx + 1
            }
        }
        return originalIdx
    }

    /// Right-click auto-promotes the strip to first responder exactly like `mouseDown`, so yield the same way.
    override func rightMouseDown(with event: NSEvent) {
        // A stale `.armed`/`.dragging` phase would misfire on a later, unrelated left mouseUp.
        tabDragController.cancelInProgress()
        defer { yieldFirstResponderToTerminalIfParked() }
        super.rightMouseDown(with: event)
    }

    private static let focusLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "tabFocus")

    fileprivate static let dragLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                               category: "tabDrag")

    /// Idempotent: a no-op when the strip is not first responder or the inline rename field holds it.
    fileprivate func yieldFirstResponderToTerminalIfParked() {
        guard let win = window, let cv = win.contentView else { return }
        let editField = tabRenameController.editField
        #if DEBUG
        if let field = editField {
            assert(field.isDescendant(of: self),
                   "editField must be a subview of its TabStripView")
        }
        #endif
        let protectedRoots: [NSView] = [editField].compactMap { $0 }
        guard shouldYieldFirstResponderToTerminal(
            currentFirstResponder: win.firstResponder,
            claimedBy: self,
            preserveDescendantsOf: protectedRoots
        ) else { return }
        let ok = win.makeFirstResponder(cv)
        if !ok {
            Self.focusLogger.error("yieldFirstResponderToTerminalIfParked: makeFirstResponder(contentView) returned false — strip remains parked, keystrokes will ring NSBeep until the user clicks away. Investigate why TerminalView refused to become first responder.")
        }
    }

    // MARK: - Keyboard focus

    /// Lets Full-Keyboard-Access users reach the strip.
    override var acceptsFirstResponder: Bool { !tabs.isEmpty }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        // Set `focusedPill` only when a keyboard event promoted the strip: a mouse-click promotion
        // must not paint the focus ring.
        let viaKeyboard = NSApp.currentEvent?.type == .keyDown
        if viaKeyboard, focusedPill == nil, !tabs.isEmpty {
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
            // `focusedPill` stays set so tabbing back restores the last focused pill.
            needsDisplay = true
        }
        return ok
    }

    private func isStripFirstResponder() -> Bool {
        window?.firstResponder === self
    }

    override func keyDown(with event: NSEvent) {
        // Routes arrow/Space/Return/Delete/Escape through NSResponder selector dispatch to the overrides below.
        self.interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) {
        guard tabDragController.armedPillIndex != nil || tabDragController.isDragging else {
            super.cancelOperation(sender)
            return
        }
        tabDragController.cancelInProgress()
    }

    override func moveLeft(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        // Clamp the STARTING index first: `focusedPill` can be stale-high after the tab list shrank.
        // Clamped to the visible page so focus never rests on a pill that is not painted.
        let current = clampToVisiblePills(focusedPill ?? 0)
        focusedPill = clampToVisiblePills(current - 1)
        needsDisplay = true
    }

    override func moveRight(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let current = clampToVisiblePills(focusedPill ?? 0)
        focusedPill = clampToVisiblePills(current + 1)
        needsDisplay = true
    }

    fileprivate func clampToVisiblePills(_ i: Int) -> Int {
        let last = min(visiblePillRange.upperBound, tabs.count) - 1
        let first = min(visiblePillRange.lowerBound, max(0, last))
        return max(first, min(last, i))
    }

    /// The page can turn under a still-set `focusedPill`; Delete / Return must not act on a tab
    /// the user cannot see.
    private var focusedVisiblePill: Int? {
        guard let i = focusedPill, i < tabs.count, visiblePillRange.contains(i) else { return nil }
        return i
    }

    override func insertNewline(_ sender: Any?) {
        activateFocusedPill()
    }

    /// Space arrives via `insertText` under Full Keyboard Access.
    override func insertText(_ insertString: Any) {
        if let str = insertString as? String, str == " " {
            activateFocusedPill()
            return
        }
        super.insertText(insertString)
    }

    override func deleteBackward(_ sender: Any?) {
        guard let idx = focusedVisiblePill else { return }
        // `onCloseWindow` synchronously mutates `tabs` and `focusedPill` (performClose → windowWillClose →
        // refreshAllTabBars) before returning, so snapshot the pre-close state for the clamp below.
        let priorIndex = idx
        let closing = tabs[idx]
        onCloseWindow?(closing)
        if tabs.isEmpty {
            focusedPill = nil
        } else {
            focusedPill = min(priorIndex, tabs.count - 1)
        }
        needsDisplay = true
    }

    private func activateFocusedPill() {
        guard let idx = focusedVisiblePill else { return }
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
        // Hover state freezes during a drag.
        if tabDragController.isDragging { return }
        applyHover(at: convert(event.locationInWindow, from: nil))
    }

    /// Callers own the `needsDisplay`.
    fileprivate func clearHover() {
        hoveredPill = nil
        hoveredClose = false
        hoveredAdd = false
    }

    private func applyHover(at p: NSPoint) {
        let prevPill = hoveredPill
        let prevClose = hoveredClose
        let prevAdd = hoveredAdd
        clearHover()
        if NSPointInRect(p, addButtonFrame) {
            hoveredAdd = true
        } else if let i = pillIndex(at: p) {
            hoveredPill = i
            // Never arm the close hotspot for the pill under edit: a close click there would kill the session.
            hoveredClose = tabRenameController.editingPill != i
                && NSPointInRect(p, closeHotspot(in: pillFrames[i]))
        }
        if prevPill != hoveredPill || prevClose != hoveredClose || prevAdd != hoveredAdd {
            needsDisplay = true
        }
    }

    /// Uses the CURRENT cursor position: a relayout shifts geometry under a stationary cursor with no
    /// `mouseMoved`, which would leave the close-× painted on a pill other than the one a click hits.
    private func applyHoverAtCurrentCursorLocation() {
        guard !tabDragController.isDragging, let window else { return }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        applyHover(at: convert(windowPoint, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // AppKit keeps routing mouseDragged here during a drag, wherever the cursor is.
        if tabDragController.isDragging { return }
        if hoveredPill != nil || hoveredAdd || hoveredClose {
            clearHover()
            needsDisplay = true
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        guard
            let idx = pillIndex(at: p),
            idx < tabs.count
        else { return nil }

        // No selection side effect: every item below carries `targetWindow` explicitly.
        let targetWindow = tabs[idx]

        let menu = NSMenu()

        let controller = targetWindow.windowController as? MainWindowController

        // NSMenu does NOT call `validateMenuItem` for context menus built via `menu(for:)`, so items
        // that could not fire usefully are left out at build time.
        let session = controller?.session
        if session != nil {
            // Targets THIS strip, not the pill's controller: a background tab's own strip lives in an
            // ordered-out window, where the editor would be invisible.
            let rename = NSMenuItem(
                title: "Rename…",
                action: #selector(renamePillFromMenu(_:)),
                keyEquivalent: ""
            )
            rename.target = self
            rename.representedObject = targetWindow
            menu.addItem(rename)
        }

        if session?.titleState.titleOverride != nil {
            let reset = NSMenuItem(
                title: "Reset to Auto",
                action: #selector(MainWindowController.resetActiveTabTitle(_:)),
                keyEquivalent: ""
            )
            reset.target = controller
            menu.addItem(reset)
        }

        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        appendMoveItems(to: menu, for: targetWindow)

        let close = NSMenuItem(
            title: "Close Tab",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: ""
        )
        // `performClose:` must target the window directly.
        close.target = targetWindow
        menu.addItem(close)

        return menu
    }

    /// Resolves the index at fire time, so a list change while the menu was open drops the request.
    @objc private func renamePillFromMenu(_ sender: NSMenuItem) {
        guard let window = sender.representedObject as? NSWindow,
              let idx = tabs.firstIndex(where: { $0 === window })
        else { return }
        beginEditing(pillIndex: idx)
    }

    private func appendMoveItems(to menu: NSMenu, for targetWindow: NSWindow) {
        var addedAny = false

        if (targetWindow.tabGroup?.windows.count ?? 1) > 1 {
            let detach = NSMenuItem(
                title: "Move Tab to New Window",
                action: #selector(TabMover.moveTabAction(_:)),
                keyEquivalent: ""
            )
            detach.target = TabMover.shared
            detach.representedObject = TabMoveRequest(tab: targetWindow, destination: .newWindow)
            menu.addItem(detach)
            addedAny = true
        }

        // A fullscreen SOURCE sits out cross-window moves, mirroring `destinationEligible`.
        // `TabMover.moveTab` re-checks at fire time.
        let sourceIsFullscreen = targetWindow.styleMask.contains(.fullScreen)
        let destinations = sourceIsFullscreen
            ? []
            : TabMover.moveDestinations(for: targetWindow, among: NSApp.windows)
        if !destinations.isEmpty {
            let submenu = NSMenu(title: "Move Tab to Window")
            for destination in destinations {
                let item = NSMenuItem(
                    title: Self.moveDestinationTitle(
                        windowTitle: destination.title,
                        groupTabCount: destination.tabGroup?.windows.count ?? 1
                    ),
                    action: #selector(TabMover.moveTabAction(_:)),
                    keyEquivalent: ""
                )
                item.target = TabMover.shared
                item.representedObject = TabMoveRequest(
                    tab: targetWindow,
                    destination: .toWindow(TabMoveRequest.WeakWindow(destination))
                )
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: "Move Tab to Window", action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
            addedAny = true
        }

        if addedAny {
            menu.addItem(.separator())
        }
    }

    static func moveDestinationTitle(windowTitle: String, groupTabCount: Int) -> String {
        let base = displayTitle(windowTitle)
        return groupTabCount >= 2 ? "\(base) (\(groupTabCount) tabs)" : base
    }

    static func displayTitle(_ windowTitle: String) -> String {
        windowTitle.isEmpty ? "Untitled" : windowTitle
    }
}

// MARK: - Strip first-responder yield decision

/// True when first responder should go back to the contentView: it is nil, a non-NSView responder (the NSWindow
/// itself), or the claimant or one of its descendants outside every protected root.
internal func shouldYieldFirstResponderToTerminal(
    currentFirstResponder: NSResponder?,
    claimedBy claimant: NSView,
    preserveDescendantsOf protectedRoots: [NSView]
) -> Bool {
    guard let responder = currentFirstResponder else { return true }
    guard let view = responder as? NSView else { return true }
    if protectedRoots.contains(where: { view === $0 || view.isDescendant(of: $0) }) {
        return false
    }
    return view === claimant || view.isDescendant(of: claimant)
}

// MARK: - Tab drag-to-reorder controller

/// Not an NSResponder: the strip keeps the overrides and forwards here.
private final class TabDragController {
    unowned let view: TabStripView

    init(view: TabStripView) { self.view = view }

    struct PendingDrag {
        let pillIndex: Int
        let startPoint: NSPoint
        let downOffsetX: CGFloat
        /// `NSWindow.performDrag(with:)` expects the ORIGINAL mouseDown event, not a later mouseDragged sample.
        let mouseDownEvent: NSEvent
    }

    struct DragState {
        let originalIndex: Int
        let downOffsetX: CGFloat
        var cursorX: CGFloat
        var currentIndex: Int
    }

    enum DragPhase {
        case idle
        case armed(PendingDrag)
        case dragging(DragState)
    }
    private var phase: DragPhase = .idle

    private static let dragThreshold: CGFloat = 5

    private static var dragLogger: Logger { TabStripView.dragLogger }

    // MARK: Queries

    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    var activeDragState: DragState? {
        if case .dragging(let s) = phase { return s }
        return nil
    }

    var armedPillIndex: Int? {
        if case .armed(let p) = phase { return p.pillIndex }
        return nil
    }

    // MARK: Transitions

    func arm(pillIndex: Int, startPoint: NSPoint, downOffsetX: CGFloat, mouseDownEvent: NSEvent) {
        phase = .armed(PendingDrag(pillIndex: pillIndex,
                                   startPoint: startPoint,
                                   downOffsetX: downOffsetX,
                                   mouseDownEvent: mouseDownEvent))
    }

    func cancelInProgress() {
        phase = .idle
        view.needsDisplay = true
    }

    func cancelForListShapeChange() {
        switch phase {
        case .armed, .dragging: cancelInProgress()
        case .idle: break
        }
    }

    func mouseDragged(with event: NSEvent) {
        let p = view.convert(event.locationInWindow, from: nil)

        switch phase {
        case .idle:
            return
        case .armed(let pending):
            let dx = p.x - pending.startPoint.x
            let dy = p.y - pending.startPoint.y
            // A plain drag reorders; a drag carrying the window-move modifier moves the window, in either axis.
            let dragMask = Preferences.shared.windowDragModifier.modifierMask
            let hasMoveModifier = !dragMask.isEmpty
                && event.modifierFlags.contains(dragMask)
            switch TabStripView.classifyPillDrag(dx: dx, dy: dy,
                                                 threshold: Self.dragThreshold,
                                                 hasMoveModifier: hasMoveModifier) {
            case .pending:
                return
            case .reorder:
                view.clearHover()
                phase = .dragging(DragState(
                    originalIndex: pending.pillIndex,
                    downOffsetX: pending.downOffsetX,
                    cursorX: p.x,
                    currentIndex: pending.pillIndex
                ))
                view.needsDisplay = true
            case .windowMove:
                // `performDrag(with:)` blocks until mouse-up and no `mouseUp` arrives here afterwards,
                // so reset to `.idle` BEFORE the hand-off.
                view.clearHover()
                phase = .idle
                view.needsDisplay = true
                view.requestWindowDrag(pending.mouseDownEvent)
            }
        case .dragging(var state):
            guard state.originalIndex < view.tabs.count else {
                cancelInProgress()
                return
            }
            // Clamped to the page on screen: a reorder is never carried across pages.
            let newIndex = view.clampToVisiblePills(TabStripView.computeIntermediateIndex(
                cursorX: p.x,
                downOffsetX: state.downOffsetX,
                count: view.tabs.count,
                pillFrames: view.pillFrames,
                fallback: state.originalIndex
            ))
            state.cursorX = p.x
            state.currentIndex = newIndex
            phase = .dragging(state)
            view.needsDisplay = true
        }
    }

    func mouseUp(with event: NSEvent) {
        defer {
            phase = .idle
        }
        // An armed press that never crossed the threshold is a click: select now.
        if case .armed(let pending) = phase {
            guard pending.pillIndex < view.tabs.count else {
                Self.dragLogger.notice("mouseUp: armed pillIndex \(pending.pillIndex, privacy: .public) >= tabs.count \(self.view.tabs.count, privacy: .public); armed phase outlived a list-shape change without being cancelled in update(tabs:) — click-to-select dropped, investigate.")
                return
            }
            view.onSelectWindow?(view.tabs[pending.pillIndex])
            return
        }
        guard case .dragging(let state) = phase else { return }
        guard state.currentIndex != state.originalIndex else {
            view.needsDisplay = true
            return
        }
        guard state.originalIndex < view.tabs.count else {
            Self.dragLogger.notice("mouseUp: dragState.originalIndex \(state.originalIndex, privacy: .public) >= tabs.count \(self.view.tabs.count, privacy: .public); list shape changed between mouseDragged and mouseUp without an update(tabs:) refresh — investigate.")
            view.needsDisplay = true
            return
        }
        let target = view.tabs[state.originalIndex]
        // The tab must still be in a group for the coordinator to accept the move; `tabGroup` goes
        // nil when the window is detached mid-drag.
        guard let group = target.tabGroup else {
            Self.dragLogger.notice("mouseUp: dragged window's tabGroup went nil mid-drag (detached?); discarding reorder")
            view.needsDisplay = true
            return
        }
        TabOrderCoordinator.shared.move(window: target,
                                        to: state.currentIndex,
                                        in: group)
        // The coordinator's `orderDidChange` notification drives the full refresh; this covers a delayed delivery.
        view.needsDisplay = true
    }

    /// Clamped against the laid-out `+` button frame so the dragged pill can never slide under it.
    static func draggedPillRect(base: NSRect, cursorX: CGFloat,
                                downOffsetX: CGFloat, addButtonMinX: CGFloat,
                                spacing: CGFloat) -> NSRect {
        let maxX = max(0, addButtonMinX - spacing - base.width)
        let rawX = cursorX - downOffsetX
        let x = max(0, min(maxX, rawX))
        return NSRect(x: x, y: base.minY, width: base.width, height: base.height)
    }
}

// MARK: - Tab inline-rename controller

private final class TabRenameController: NSObject, NSTextFieldDelegate {
    unowned let view: TabStripView

    init(view: TabStripView) {
        self.view = view
        super.init()
    }

    private(set) var editingPill: Int? = nil
    /// Nil'd together with `editingPill` by `teardownEdit`.
    private(set) var editField: NSTextField? = nil
    /// The text the field was pre-filled with, so `commitEdit` can tell an untouched field from a typed name.
    private var seededText: String? = nil

    var isEditing: Bool { editingPill != nil }

    func beginEditing(pillIndex: Int) {
        guard pillIndex >= 0,
              pillIndex < view.tabs.count,
              pillIndex < view.pillFrames.count
        else { return }
        if let existing = editingPill, existing != pillIndex {
            commitEdit()
        }
        if editingPill == pillIndex, let existing = editField {
            view.window?.makeFirstResponder(existing)
            existing.currentEditor()?.selectAll(nil)
            return
        }
        editingPill = pillIndex
        let field = NSTextField(frame: fieldRect(for: view.pillFrames[pillIndex]))
        field.font = TabStripView.titleFont
        field.alignment = .center
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor
        field.textColor = NSColor.labelColor
        field.focusRingType = .none
        field.stringValue = TabStripView.displayTitle(view.tabs[pillIndex].title)
        seededText = field.stringValue
        field.delegate = self
        // Fallback for environments where `insertNewline:` does not route through the delegate;
        // both paths funnel through `commitEdit`.
        field.target = self
        field.action = #selector(editFieldCommitAction(_:))
        view.addSubview(field)
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        editField = field
        view.needsDisplay = true
    }

    @objc private func editFieldCommitAction(_ sender: Any?) {
        commitEdit()
    }

    /// Whitespace-only input forwards as `""` (clear the override). A field still holding exactly the raw, untrimmed
    /// pre-filled title is a cancel: forwarding it would pin the current auto title as a permanent override.
    func commitEdit() {
        guard let idx = editingPill,
              let field = editField,
              idx < view.tabs.count
        else {
            cancelEdit()
            return
        }
        if field.stringValue == seededText {
            cancelEdit()
            return
        }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = view.tabs[idx]
        teardownEdit()
        // Call through AFTER teardown so the consumer's side effects (title publication → KVO →
        // refreshTabBar) don't land while the field subview is still alive.
        view.onCommitRename?(target, trimmed)
    }

    func cancelEdit() {
        teardownEdit()
    }

    func commitIfNeeded() {
        if editingPill != nil {
            commitEdit()
        }
    }

    func repositionFieldForWidthChange() {
        guard let idx = editingPill,
              idx < view.pillFrames.count,
              let field = editField
        else { return }
        field.frame = fieldRect(for: view.pillFrames[idx])
    }

    /// The SAME horizontal math the drawing path uses, via TabStripLayout.
    private func fieldRect(for pill: NSRect) -> NSRect {
        let closeRect = view.closeHotspot(in: pill)
        let title = TabStripLayout.titleArea(in: pill, closeWidth: closeRect.width)
        return NSRect(
            x: title.x,
            y: pill.minY + 2,
            width: title.width,
            height: pill.height - 4
        )
    }

    private func teardownEdit() {
        editField?.delegate = nil
        editField?.removeFromSuperview()
        editField = nil
        seededText = nil
        editingPill = nil
        view.needsDisplay = true
        // Removing the field triggers AppKit's `makeFirstResponder(nil)`, leaving the NSWindow itself as first
        // responder, where typed characters ring NSBeep; yield to the terminal in the same synchronous step.
        view.yieldFirstResponderToTerminalIfParked()
    }

    // MARK: NSTextFieldDelegate

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

    /// Focus loss commits. `cancelEdit` paths have already nil'd `editField`, so this is a no-op for them.
    func controlTextDidEndEditing(_ obj: Notification) {
        if editField != nil { commitEdit() }
    }
}

private final class TabStripAccessibility {
    unowned let view: TabStripView
    init(view: TabStripView) { self.view = view }

    /// Cached because VoiceOver tracks element identity; invalidated by `layoutPills`.
    private var cachedPillElements: [NSAccessibilityElement]?
    /// Value-changed posts diff against this snapshot, not the live windows, which always hold the current title.
    private var lastAppliedTitles: [String] = []

    /// Pills on other pages are left out: their frames are virtual.
    func children() -> [NSAccessibilityElement] {
        let pills = pillElements()
        var earlier: [NSAccessibilityElement] = []
        var later: [NSAccessibilityElement] = []
        for (direction, element) in pageElements() {
            if direction == .earlier {
                earlier.append(element)
            } else {
                later.append(element)
            }
        }
        var visiblePills: [NSAccessibilityElement] = []
        for i in view.visiblePillRange where i < pills.count {
            visiblePills.append(pills[i])
        }
        var out: [NSAccessibilityElement] = earlier
        out.append(contentsOf: visiblePills)
        out.append(contentsOf: later)
        out.append(makeAddButtonElement())
        return out
    }

    /// Skipped on a list-shape change: AppKit's container-children invalidation covers those.
    func refreshTitlesAndPost(tabs: [NSWindow], listShapeChanged: Bool) {
        if !listShapeChanged {
            let current = tabs.map { $0.title }
            let changed = TabStripView.changedTitleIndices(previous: lastAppliedTitles, current: current)
            if !changed.isEmpty {
                let pills = pillElements()
                for i in changed where i < pills.count && view.visiblePillRange.contains(i) {
                    NSAccessibility.post(element: pills[i], notification: .valueChanged)
                }
            }
        }
        lastAppliedTitles = tabs.map { $0.title }
    }

    /// Cached elements embed a frame.
    func invalidateCache() {
        cachedPillElements = nil
        cachedPageElements = nil
    }

    private var cachedPageElements: [(TabStripView.PageDirection, NSAccessibilityElement)]?

    private func pageElements() -> [(TabStripView.PageDirection, NSAccessibilityElement)] {
        if let cached = cachedPageElements { return cached }
        var built: [(TabStripView.PageDirection, NSAccessibilityElement)] = []
        for direction in [TabStripView.PageDirection.earlier, TabStripView.PageDirection.later]
        where view.canPage(direction) {
            let element = BBPageButtonAccessibilityElement(
                parent: view,
                frame: direction == .earlier ? view.leadingPageFrame : view.trailingPageFrame,
                label: view.pageButtonLabel(direction),
                onPress: { [weak view] in view?.page(direction) }
            )
            built.append((direction, element))
        }
        cachedPageElements = built
        return built
    }

    private func pillElements() -> [NSAccessibilityElement] {
        if let cached = cachedPillElements { return cached }
        var built: [NSAccessibilityElement] = []
        for (i, window) in view.tabs.enumerated() where i < view.pillFrames.count {
            built.append(makePillElement(pillIndex: i, window: window))
        }
        cachedPillElements = built
        return built
    }

    private func makePillElement(pillIndex: Int, window: NSWindow) -> NSAccessibilityElement {
        let frame = view.pillFrames[pillIndex]
        let element = BBTabPillAccessibilityElement(
            parent: view,
            frame: frame,
            title: TabStripView.displayTitle(window.title),
            isSelected: window === view.selectedTab,
            onSelect: { [weak view] in view?.onSelectWindow?(window) },
            onClose: { [weak view] in view?.onCloseWindow?(window) }
        )
        return element
    }

    private func makeAddButtonElement() -> NSAccessibilityElement {
        let element = BBAddTabAccessibilityElement(
            parent: view,
            frame: view.addButtonFrame,
            onAdd: { [weak view] in view?.onAddTab?() }
        )
        return element
    }
}

class BBFrameTrackingAccessibilityElement: NSAccessibilityElement {
    private weak var parentView: NSView?
    private let localFrame: NSRect

    init(parent: NSView, frame: NSRect, role: NSAccessibility.Role) {
        self.parentView = parent
        self.localFrame = frame
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(role)
        // Fallback for AXAPI callers that read frameInParentSpace directly; VoiceOver queries `accessibilityFrame()`.
        setAccessibilityFrameInParentSpace(frame)
    }

    /// Computed here because AppKit's resolution of `accessibilityFrameInParentSpace` is off by the
    /// element's local y-offset when the parent view is flipped.
    override func accessibilityFrame() -> NSRect {
        guard let parentView, let window = parentView.window else {
            // Not `super.accessibilityFrame()`: that falls back to the buggy parent-space resolution.
            return .zero
        }
        let windowFrame = parentView.convert(localFrame, to: nil)
        return window.convertToScreen(windowFrame)
    }

    override func isAccessibilityEnabled() -> Bool { true }
}

final class BBTabPillAccessibilityElement: BBFrameTrackingAccessibilityElement {
    private let onSelect: () -> Void
    private let onClose: () -> Void
    private let _title: String
    private let _isSelected: Bool

    init(parent: NSView, frame: NSRect, title: String, isSelected: Bool,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self._title = title
        self._isSelected = isSelected
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(parent: parent, frame: frame, role: .button)
    }

    override func accessibilityLabel() -> String? {
        _isSelected ? "Tab, \(_title), selected" : "Tab, \(_title)"
    }

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

final class BBPageButtonAccessibilityElement: BBFrameTrackingAccessibilityElement {
    private let label: String
    private let onPress: () -> Void

    init(parent: NSView, frame: NSRect, label: String, onPress: @escaping () -> Void) {
        self.label = label
        self.onPress = onPress
        super.init(parent: parent, frame: frame, role: .button)
    }

    override func accessibilityLabel() -> String? { label }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }
}

final class BBAddTabAccessibilityElement: BBFrameTrackingAccessibilityElement {
    private let onAdd: () -> Void

    init(parent: NSView, frame: NSRect, onAdd: @escaping () -> Void) {
        self.onAdd = onAdd
        super.init(parent: parent, frame: frame, role: .button)
    }

    override func accessibilityLabel() -> String? { "New Tab" }

    override func accessibilityPerformPress() -> Bool {
        onAdd()
        return true
    }
}
