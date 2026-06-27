import AppKit
import os

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
        stripView.onCloseWindow = { [weak self] w in
            // When closing the group's SELECTED (front) tab, pre-select its
            // VISUAL neighbour (TabOrderCoordinator order) before closing, so
            // focus lands on the strip-adjacent pill rather than whatever AppKit
            // auto-promotes in arrival order — which, after a drag-reorder, can
            // be a visually non-adjacent tab. Non-selected closes don't move
            // selection, so they're left to AppKit untouched.
            if let group = self?.hostWindow?.tabGroup, group.selectedWindow === w {
                let order = TabOrderCoordinator.shared.orderedTabs(for: group)
                if let idx = order.firstIndex(where: { $0 === w }),
                   let nIdx = TabOrderCoordinator.neighborIndexAfterClose(
                       closingIndex: idx, count: order.count) {
                    group.selectedWindow = order[nIdx]
                }
            }
            w.performClose(nil)
        }
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
        // Pill index must come from the coordinator's VISUAL order
        // (what the strip painted), not `group.windows`'s arrival
        // order. After a drag-reorder the two diverge — using arrival
        // order here would route the edit field onto a sibling pill,
        // and the commit would `onCommitRename(wrongWindow, ...)`
        // silently. The two-orderings-must-agree-at-every-positional-
        // lookup invariant is the whole point of `TabOrderCoordinator`.
        let tabs = TabOrderCoordinator.shared.orderedTabs(for: group)
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
        // Visual order is owned by `TabOrderCoordinator`, not by AppKit's
        // `tabGroup.windows`. After a drag-reorder the two diverge; the
        // pill strip is the user's source of truth, so the strip — and
        // every position-based consumer (⌘1-9, ⌘⇧] / ⌘⇧[) — reads from
        // the coordinator. Selection stays identity-based.
        let tabs: [NSWindow]
        if let group = window.tabGroup {
            tabs = TabOrderCoordinator.shared.orderedTabs(for: group)
        } else {
            tabs = [window]
        }
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

    /// Hand-off for "drag a pill with the configured window-move modifier
    /// (default ⌘) to move the window". With the trailing drag gutter removed
    /// (pills + `+` now fill the titlebar), this is the primary way to move a
    /// multi-tab window; single-tab windows skip the strip and keep a bare,
    /// draggable titlebar. Default performs
    /// a native AppKit window drag; injectable so a headless test can spy on the hand-off without
    /// a live `NSWindow`/`performDrag(with:)`. Lazy because the default
    /// captures `self`. The no-window branch logs rather than dropping the
    /// gesture silently — the strip is a permanently-attached titlebar
    /// accessory, so a nil window here means a future refactor broke that
    /// invariant (review S-2; matches the `dragLogger` discipline below).
    lazy var requestWindowDrag: (NSEvent) -> Void = { [weak self] event in
        guard let window = self?.window else {
            Self.dragLogger.notice("windowMove hand-off skipped: tab strip has no window — gesture dropped")
            return
        }
        window.performDrag(with: event)
    }

    // `tabs` / `pillFrames` are `fileprivate` (not `private`) so the hoisted
    // `TabDragController` + `TabRenameController` in this file can read the
    // strip's live layout without a parallel copy. The strip remains the
    // single writer (`update` / `layoutPills`).
    fileprivate var tabs: [NSWindow] = []
    private weak var selectedTab: NSWindow?
    private var totalWidth: CGFloat = 0
    fileprivate var pillFrames: [CGRect] = []
    private var addButtonFrame: CGRect = .zero

    /// Snapshot of the pill TITLE strings applied on the previous `update()`.
    /// VoiceOver value-changed posts diff against THIS (not the live window
    /// refs, which always equal the current title). Audit titlebar-tabs F5.
    private var lastAppliedTitles: [String] = []
    /// Cached per-pill accessibility elements. Rebuilt lazily and invalidated
    /// whenever the layout changes (`layoutPills`), so VoiceOver tracks stable
    /// element identities AND a value-changed post targets the very element
    /// `accessibilityChildren()` handed VO (rather than a throwaway).
    private var cachedPillElements: [NSAccessibilityElement]?

    // MARK: - Hoisted collaborators
    //
    // The drag-to-reorder state machine and the inline-rename engine are
    // hoisted into dedicated collaborators (REFACTOR.md Area 5: "eight
    // concerns become named collaborators"). Each holds an `unowned` back-
    // reference to the strip and reaches into its `fileprivate` layout /
    // hover / callback surface; the strip strong-references the controller,
    // so the back-ref is valid for the controller's whole life. The strip's
    // NSResponder overrides (`mouseDragged` / `mouseUp`) FORWARD to the drag
    // controller — neither collaborator is itself an NSResponder. `lazy`
    // because each initializer captures `self`.
    private lazy var tabDragController = TabDragController(view: self)
    private lazy var tabRenameController = TabRenameController(view: self)

    /// The intent of a pill drag once it has moved far enough to commit.
    /// Kept as a three-case enum (not a `Bool`) because `.pending` — the
    /// below-threshold / non-finite "not yet" state — is a real third outcome
    /// the move-vs-reorder distinction can't express; don't flatten it away
    /// even though `.reorder`/`.windowMove` now track `hasMoveModifier` 1:1.
    enum DragIntent: Equatable {
        /// Hasn't moved past `threshold` yet — keep waiting.
        case pending
        /// Plain drag — reorder the tabs.
        case reorder
        /// Modifier-bearing drag — move the window instead.
        case windowMove
    }

    /// Classify a pill drag once it has moved past `threshold`. Direction no
    /// longer selects the outcome: a plain drag reorders; a drag carrying the
    /// configured window-move modifier moves the window, in EITHER axis (the
    /// same gesture grammar as the terminal body — see `TerminalView.mouseDown`).
    ///
    /// This replaces the old direction heuristic (`classifyDrag`), which moved
    /// the window on an un-modified steep-vertical pull. That overloaded the
    /// pill with a sixth, unaffordanced meaning, made a horizontal window move
    /// impossible without a modifier, let a brisk reorder escalate into an
    /// irreversible window grab, and collided with the cross-app "drag a tab
    /// down to tear it off" idiom (critique 2026-06-07, issues 1–7).
    ///
    /// - non-finite `dx`/`dy` → `.pending` (ignore a degenerate AppKit sample,
    ///   regardless of the modifier — the guard precedes it)
    /// - `max(|dx|,|dy|) < threshold` → `.pending` (hasn't committed yet)
    /// - `hasMoveModifier` → `.windowMove`
    /// - otherwise → `.reorder`
    ///
    /// Pure + static so the whole decision is unit-testable without AppKit.
    static func classifyPillDrag(dx: CGFloat, dy: CGFloat,
                                 threshold: CGFloat,
                                 hasMoveModifier: Bool) -> DragIntent {
        guard dx.isFinite, dy.isFinite else { return .pending }
        guard max(abs(dx), abs(dy)) >= threshold else { return .pending }
        return hasMoveModifier ? .windowMove : .reorder
    }

    // Inline-edit state (`editingPill` / `editField`) lives on
    // `TabRenameController`; the strip queries it through that collaborator.

    // Hover state is `fileprivate` so `TabDragController` can snap it off when
    // a reorder drag starts (stale hover indices would linger under the moving
    // pill). The strip stays the only reader for paint.
    /// Which pill is the cursor over, if any.
    fileprivate var hoveredPill: Int? = nil
    /// Is the cursor specifically over the close target inside the hovered
    /// pill (i.e. the small `×` hotspot at the pill's leading edge).
    fileprivate var hoveredClose = false
    /// Cursor over the trailing `+` button.
    fileprivate var hoveredAdd = false
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
        // Suppress AppKit's default blue system focus ring around the whole
        // strip when a pill is clicked. The keyboard-driven focus
        // indicator (titlebar-tabs F4) is custom-drawn in `draw(_:)`
        // gated on `focusedPill`, which is only set by the arrow-key
        // handlers below — click routes through `mouseDown` and doesn't
        // touch `focusedPill`, so there's no legitimate focus to signal
        // via the system ring when the user mouse-clicks a pill. Keeping
        // the system ring off at all times means clicks are clean and
        // keyboard users still see the explicit pill ring drawn in
        // draw(_:). User-reported 2026-04-23.
        focusRingType = .none
        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    /// Pass-through hit testing: only claim mouse events that fall on a pill,
    /// the `+` button, or an active inline-rename field. Any remaining empty
    /// region of the strip (the thin trailing inset, sub-pixel gaps between
    /// pills) belongs to AppKit's titlebar so standard titlebar gestures still
    /// pass through. The strip now fills the bar with pills + `+`, so little
    /// bare region is left and a window move uses a modifier-drag on a pill;
    /// the pass-through still matters because without it the strip's full frame
    /// would swallow clicks landing in that empty area — `mouseDown` would
    /// return silently and nothing else got a chance to handle the event.
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
        if tabRenameController.isEditing, listShapeChanged {
            tabRenameController.commitEdit()
        }
        // If a gesture is in flight — an armed press OR an active reorder —
        // and the underlying tab list shape changed beneath it (sibling
        // closed, new tab opened, post-commit reorder), the captured index no
        // longer matches the strip. Cancel cleanly rather than trying to
        // reconcile: a stale `.dragging` would commit a reorder against the
        // wrong slot, and a stale `.armed` would fire a wrong selection on the
        // trailing mouseUp (selection is deferred to mouseUp now). Skipped on
        // the post-commit refresh because the commit path returned
        // `dragPhase = .idle` in `mouseUp` before the notification fired.
        if listShapeChanged {
            tabDragController.cancelForListShapeChange()
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
            // Diff against lastAppliedTitles — a STORED snapshot of the title
            // STRINGS from the previous update(). The old code diffed
            // self.tabs.map { $0.title } captured at the top of this call, but
            // self.tabs and the incoming tabs hold the SAME NSWindow refs and
            // window.title was already mutated before update() ran, so the
            // diff was always false and the notification never fired. Post
            // against the cached pill elements so VO tracks a stable identity.
            // Audit titlebar-tabs F5 / KNOWN_ISSUES.
            let current = tabs.map { $0.title }
            let changed = Self.changedTitleIndices(previous: lastAppliedTitles, current: current)
            if !changed.isEmpty {
                let pills = pillAccessibilityElements()
                for i in changed where i < pills.count {
                    NSAccessibility.post(element: pills[i], notification: .valueChanged)
                }
            }
        }
        lastAppliedTitles = tabs.map { $0.title }
        // Width-only update: move the edit field to track the pill's new
        // x/width so the caret doesn't drift off-pill (no-op when no edit is
        // in flight). Geometry mirrors `beginEditing`'s field-rect computation.
        tabRenameController.repositionFieldForWidthChange()
        needsDisplay = true
    }

    /// Commit the in-flight edit if one is active. No-op otherwise. Used
    /// by `MainWindowController.refreshTabBar` on the multi-tab →
    /// single-tab transition so the field doesn't survive as a subview
    /// of a hidden strip and re-appear on the next grow-back.
    /// (main-window F8)
    func commitEditIfNeeded() {
        tabRenameController.commitIfNeeded()
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
        var out: [NSAccessibilityElement] = pillAccessibilityElements()
        out.append(makeAddButtonElement())
        return out
    }

    /// The per-pill accessibility elements, cached so `accessibilityChildren()`
    /// and the value-changed posts in `update()` share identical instances
    /// (VoiceOver tracks element identity). Invalidated by `layoutPills()`.
    private func pillAccessibilityElements() -> [NSAccessibilityElement] {
        if let cached = cachedPillElements { return cached }
        var built: [NSAccessibilityElement] = []
        for (i, window) in tabs.enumerated() where i < pillFrames.count {
            built.append(makePillElement(pillIndex: i, window: window))
        }
        cachedPillElements = built
        return built
    }

    /// Indices whose title changed between two title snapshots (positionally).
    /// Pure + static so the VoiceOver value-changed diff is unit-testable.
    static func changedTitleIndices(previous: [String], current: [String]) -> [Int] {
        (0 ..< min(previous.count, current.count)).filter { previous[$0] != current[$0] }
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
    fileprivate static let titleFont = NSFont.systemFont(ofSize: 12, weight: .regular)

    private func layoutPills() {
        // Pill frames are about to change → any cached accessibility elements
        // (which embed a frame) are stale; rebuild lazily on next access.
        cachedPillElements = nil
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
        // Pills + `+` button divide the full strip width (less the trailing
        // inset). No window-draggable gutter is reserved: filling the bar to
        // the trailing edge is a deliberate product choice, accepting the loss
        // of the no-modifier "drag empty titlebar to move the window"
        // affordance. The window still moves via a modifier-drag on a pill
        // (see `classifyPillDrag` → `.windowMove`), and single-tab windows skip
        // the strip entirely so their titlebar stays bare and draggable.
        let available = max(0, totalWidth - trail - addW - gap)
        let pillW = available / CGFloat(n)
        var x: CGFloat = 0
        for _ in 0..<n {
            pillFrames.append(NSRect(x: x, y: y, width: max(0, pillW - gap / 2), height: h))
            x += pillW
        }
        addButtonFrame = NSRect(x: x + gap, y: y, width: addW, height: h)
    }

    // MARK: - Inline editing (delegated to TabRenameController)

    /// Enter rename mode for the pill at `pillIndex`. The rename engine
    /// (field install, commit/cancel/teardown, NSTextFieldDelegate) lives on
    /// `TabRenameController`; this thin forwarder preserves the entry point
    /// for external callers (`TitlebarTabBarViewController.beginInlineRename`).
    func beginEditing(pillIndex: Int) {
        tabRenameController.beginEditing(pillIndex: pillIndex)
    }

    /// `true` while any pill is in inline-edit mode. Hover / close
    /// rendering short-circuits on this so the editing pill doesn't
    /// paint an `×` hotspot over its own text field.
    private var isEditing: Bool { tabRenameController.isEditing }

    #if DEBUG
    /// Test hook — sets the editing field's value without going through
    /// a real NSTextField + field-editor dance. Only meaningful while an
    /// edit is in progress; no-op otherwise.
    @objc func setEditTextForTesting(_ text: String) {
        tabRenameController.editField?.stringValue = text
    }
    /// Test hook — explicitly commits the in-flight edit.
    @objc func commitEditForTesting() { tabRenameController.commitEdit() }
    /// Test hook — explicitly cancels the in-flight edit.
    @objc func cancelEditForTesting() { tabRenameController.cancelEdit() }
    /// Test hook — current pill count. Lets stress tests assert pill
    /// geometry tracks the tab list without exposing the internal
    /// `pillFrames` array publicly.
    var pillCountForTesting: Int { pillFrames.count }
    /// Test hook — read/write `focusedPill` so the keyboard-close path
    /// (`deleteBackward`) can be exercised without driving the AppKit
    /// responder chain.
    var focusedPillForTesting: Int? {
        get { focusedPill }
        set { focusedPill = newValue }
    }
    /// Test hook — invoke the keyboard-close path directly. AppKit's
    /// `interpretKeyEvents` plumbing isn't available to a headless XCTest.
    @objc func deleteBackwardForTesting() { deleteBackward(nil) }

    /// Test hook — pill index armed for a potential reorder drag, or
    /// `nil` when phase is `.idle` (no pill grabbed) or `.dragging`
    /// (already promoted past `pendingDrag`).
    var pendingDragPillIndexForTesting: Int? {
        tabDragController.armedPillIndex
    }

    /// Test hook — active drag state, or `nil` when phase is not
    /// `.dragging`. Tuple shape lets tests assert origin/target slot
    /// transitions without reaching into the private `DragState`
    /// struct. `cursorX` is the live mouse X used to anchor the
    /// dragged-pill render.
    var dragStateForTesting: (originalIndex: Int, currentIndex: Int, cursorX: CGFloat)? {
        tabDragController.activeDragState.map {
            ($0.originalIndex, $0.currentIndex, $0.cursorX)
        }
    }

    /// Test hook — pill frames laid out for the current `tabs`/`width`.
    /// Lets a test pass realistic geometry into the static
    /// `computeIntermediateIndex` helper without re-deriving it.
    var pillFramesForTesting: [CGRect] { pillFrames }
    /// Test hook — the trailing `+` button frame, so the strip's trailing
    /// layout (the `+` sits flush after the last pill, with no reserved drag
    /// gutter) is assertable without exposing the private `addButtonFrame`.
    var addButtonFrameForTesting: CGRect { addButtonFrame }
    #endif

    // MARK: - Drawing

    /// One paint pass' worth of pill colors, computed once per `draw(_:)`.
    /// Value type — no heap allocation beyond the `CGColor`s the previous
    /// inline path already built once per frame.
    ///
    /// Tint the pill bodies with `labelColor` (dark on light, light on dark)
    /// so they stay visible regardless of whether the theme has a light or
    /// dark titlebar. Hard-coding white meant the entire pill strip
    /// disappeared on Gruvbox-light / Solarized-light / Catppuccin-latte /
    /// Default-light. The dragged fill (`draggedBg`) is a touch brighter than
    /// `selectedBg` — visible enough to read as "this is the one I'm holding",
    /// subtle enough to avoid the heavy "lifted card" look of a shadow.
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
        // Snapshot of the drag (if any) — captured once so every pill index in
        // the loop sees a consistent state, and so the dragged pill draws LAST
        // (it's moved to the tail of the draw order) on top of the siblings it
        // visually overlaps.
        let activeDrag = tabDragController.activeDragState
        let drawOrder = Self.pillDrawOrder(count: tabs.count,
                                           draggedOriginalIndex: activeDrag?.originalIndex)

        for i in drawOrder where i < tabs.count && i < pillFrames.count {
            let (rect, isDraggedPill) = pillRect(for: i, activeDrag: activeDrag)
            let w = tabs[i]
            let isSelected = w === selectedTab
            // Hover state is meaningless during a drag — both the close
            // hotspot and the lighter "hovered" fill would compete with
            // the dragged-pill highlight for the user's eye.
            let isHovered = hoveredPill == i && !isEditing && activeDrag == nil
            let isBeingEdited = tabRenameController.editingPill == i
            drawPill(ctx: ctx, window: w, index: i, rect: rect,
                     isDraggedPill: isDraggedPill, isSelected: isSelected,
                     isHovered: isHovered, isBeingEdited: isBeingEdited,
                     palette: palette)
        }

        drawAddButton(ctx: ctx, palette: palette)
    }

    /// Two-pass draw order: the dragged pill (if any) is moved to the tail so
    /// it paints LAST, on top of the siblings it overlaps. Pure.
    private static func pillDrawOrder(count: Int, draggedOriginalIndex: Int?) -> [Int] {
        if let d = draggedOriginalIndex {
            return (0..<count).filter { $0 != d } + [d]
        }
        return Array(0..<count)
    }

    /// The rect (and dragged-flag) at which pill `i` paints this frame. With a
    /// drag in flight the grabbed pill is anchored under the cursor — geometry
    /// delegated to `TabDragController.draggedPillRect`, the drag-controller's
    /// concern — and its siblings shift one slot to "make space".
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
        // Siblings render at their intermediate slot — they appear to "make
        // space" by shifting one slot toward the dragged pill's origin.
        let slot = Self.intermediateSlot(originalIdx: i,
                                         draggedFrom: d.originalIndex,
                                         draggedTo: d.currentIndex)
        let rect = slot < pillFrames.count ? pillFrames[slot] : pillFrames[i]
        return (rect, false)
    }

    /// Fill + (hover) close glyph + title + keyboard focus ring for one pill.
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

        // Pill being renamed — skip the title + close-hotspot drawing.
        // The NSTextField subview covers the title area; drawing a
        // label underneath would bleed through around the field's
        // corners and confuse the eye about what's editable.
        if isBeingEdited { return }

        // Close `×` shown only when the pill is hovered. Drawn at
        // leading edge so text center stays stable. Tint with
        // labelColor so the × circle stays visible on both light and
        // dark themes (see pill body tinting rationale above).
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

        // Title: centered, truncated if pill is narrow. Leave room
        // for the close button's width on the left so titles don't
        // jump when hover reveals it. Same horizontal math as the
        // inline-rename field, via TabStripLayout.
        let area = TabStripLayout.titleArea(in: rect, closeWidth: closeRect.width)
        let titleArea = NSRect(
            x: area.x,
            y: rect.minY,
            width: area.width,
            height: rect.height
        )
        let title = w.title.isEmpty ? "Untitled" : w.title
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

    /// Trailing `+` button. Same label-tint so it stays visible on light
    /// themes too.
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

    /// Binary-search the longest prefix that fits. The previous per-pill
    /// per-frame loop dropped one character at a time and re-measured —
    /// O(N) measurements for an N-character title. A 2 KB hostile OSC 0/2
    /// title froze the strip on every redraw. Halving the search space
    /// per probe is O(log N) measurements, capped further upstream by
    /// `TerminalSession`'s 256-grapheme OSC title cap.
    ///
    /// Preserves the original "at least one character before the ellipsis
    /// when the string itself doesn't fit" floor — if even one-char-plus-
    /// ellipsis is wider than the pill, we still return that rather than
    /// a bare ellipsis (matches the pre-fix visual).
    static func truncatedString(_ s: String,
                                fitting width: CGFloat,
                                measure: (String) -> CGFloat) -> String {
        guard width > 20 else { return "" }
        let chars = Array(s)
        if chars.isEmpty { return s }
        if measure(s) <= width { return s }

        // Search inclusive range [1, chars.count - 1] for the largest k
        // such that prefix(k) + "…" fits. Floor at 1 preserves the
        // original's "always at least one character + ellipsis" output
        // even when the pill is too narrow to fit even that.
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

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // Mouse interaction retires the keyboard focus-ring state — a
        // stale ring from a prior arrow-key session shouldn't linger on
        // a different pill after the user mouse-clicks. The next arrow
        // key press will re-establish `focusedPill` from scratch.
        if focusedPill != nil {
            focusedPill = nil
            needsDisplay = true
        }

        // Every exit point below must either yield the strip's first-
        // responder status back to the host TerminalView or hand it to
        // the inline rename field. AppKit's NSWindow.sendEvent auto-
        // promotes the hit-tested view to first responder when its
        // `acceptsFirstResponder` returns true (see this view's
        // `becomeFirstResponder` comment block) — which is us during a
        // pill / + click. If we exit without yielding, subsequent
        // keystrokes route to TabStripView.keyDown → interpretKeyEvents
        // → insertText, and insertText only honours space (FKA pill
        // activation). Anything else falls through to AppKit's
        // `noResponderFor:` path and rings NSBeep. The
        // `selectedWindow` KVO restore in MainWindowController only
        // covers the DESTINATION window AND only fires on actual value
        // changes — clicking the already-selected pill ((self-)select
        // is a no-op) leaves the strip parked. Restoring here unifies
        // every mouse exit through one spot. Because it's a `defer`, it
        // also fires after each of the dispatch helpers below returns.
        defer { yieldFirstResponderToTerminalIfParked() }

        if commitEditOnOutsideClick(p) { return }
        if NSPointInRect(p, addButtonFrame) {
            onAddTab?()
            return
        }
        if beginRenameOnDoubleClick(p, event: event) { return }
        handlePillClick(p, event: event)
    }

    /// While a pill is being renamed, a click inside the edit field belongs to
    /// the field editor — we shouldn't see it here (subviews hit-test first),
    /// but the containing pill bounds still route here when the click lands on
    /// the pill body outside the field (e.g. the close hotspot area). Commit
    /// the in-flight edit on any outside click so the click doesn't silently
    /// drop the edit. Returns `true` (commit-and-stay-put) when the click was
    /// inside the editing pill but outside the field; `false` when it was
    /// outside the editing pill entirely (the caller then treats it as a normal
    /// click on whatever it landed on) or when nothing is being edited.
    private func commitEditOnOutsideClick(_ p: CGPoint) -> Bool {
        guard let idx = tabRenameController.editingPill, idx < pillFrames.count else { return false }
        let editingRect = pillFrames[idx]
        if !NSPointInRect(p, editingRect) {
            tabRenameController.commitEdit()
            return false
        } else {
            tabRenameController.commitEdit()
            return true
        }
    }

    /// Double-click on a pill body (outside the close hotspot) → enter inline
    /// rename mode. Matches Safari / Chrome / iTerm2 tab rename — no modal, no
    /// menu trip. `beginEditing` makes the edit field first responder; the
    /// `defer` in `mouseDown` sees that and skips the terminal-focus restore so
    /// the rename field keeps focus. Returns `true` when rename began.
    private func beginRenameOnDoubleClick(_ p: CGPoint, event: NSEvent) -> Bool {
        guard event.clickCount == 2 else { return false }
        for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
            let closeRect = closeHotspot(in: rect)
            if !NSPointInRect(p, closeRect), i < tabs.count {
                beginEditing(pillIndex: i)
                return true
            }
        }
        return false
    }

    /// A single click that landed on a pill: close it (only when the × is
    /// actually hovered), or arm a potential drag, or select. Selection is
    /// DEFERRED to mouseUp-as-click (see `mouseUp`'s `.armed` case) so a drag —
    /// reorder OR window move — never switches tabs. Grabbing a background pill
    /// to move the window used to eagerly select it here, yanking the
    /// foreground session onto that tab before the gesture was classified (user
    /// report 2026-06-07; critique complaint C). Arming lets `mouseDragged`
    /// promote it; the tab only switches if the press is released without a
    /// drag. Arming is suppressed for single-tab windows (no peer to reorder
    /// against), a click that also begins rename (clickCount ≥ 2), and any
    /// pill being renamed elsewhere — there we select now to keep the
    /// click-to-switch contract.
    private func handlePillClick(_ p: CGPoint, event: NSEvent) {
        for (i, rect) in pillFrames.enumerated() where NSPointInRect(p, rect) {
            guard i < tabs.count else { return }
            // Only honour a close click when the user is actually hovered on
            // the × — otherwise a stationary click near the leading edge of a
            // pill would quietly close it even though the × wasn't visible to
            // the user yet. Selecting is the safe default.
            if hoveredPill == i, hoveredClose, NSPointInRect(p, closeHotspot(in: rect)) {
                onCloseWindow?(tabs[i])
                return
            }
            let canReorder = tabs.count > 1
                && event.clickCount == 1
                && !isEditing
            if canReorder {
                tabDragController.arm(
                    pillIndex: i,
                    startPoint: p,
                    downOffsetX: p.x - rect.minX
                )
            } else {
                onSelectWindow?(tabs[i])
            }
            return
        }
    }

    // MARK: - Drag-to-reorder (delegated to TabDragController)
    //
    // The strip's NSResponder overrides forward the gesture to the drag
    // controller; the three-phase state machine, the `dragThreshold`, the
    // dropped-click-vs-reorder arbitration, and the `os.Logger` canaries all
    // live there. `mouseDown`'s arm branch (`handlePillClick`) and
    // `update(tabs:)`'s list-shape cancellation route through it too.

    override func mouseDragged(with event: NSEvent) {
        tabDragController.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        tabDragController.mouseUp(with: event)
    }

    /// Compute which slot the dragged pill is currently over, given the
    /// live cursor X and the offset within the pill where the user
    /// grabbed it. The dragged pill's anchor X is `cursorX - downOffsetX`;
    /// the slot is the one whose CENTER is closest to the pill's center
    /// (anchor + pillW/2). Clamped to `[0, count-1]`.
    ///
    /// Static + pure so unit tests can drive every transition with a
    /// synthetic `pillFrames` array — no NSWindows, no NSEvents, no
    /// strip instance needed.
    internal static func computeIntermediateIndex(cursorX: CGFloat,
                                                  downOffsetX: CGFloat,
                                                  count: Int,
                                                  pillFrames: [CGRect],
                                                  fallback: Int = 0) -> Int {
        guard count > 0, !pillFrames.isEmpty else { return fallback }
        let pillW = pillFrames[0].width
        let pillCenter = (cursorX - downOffsetX) + pillW / 2
        // Slot i's center = pillFrames[i].midX. Find the slot whose
        // center is nearest to pillCenter. Equal-width pills means we
        // can compute directly from the first slot's origin.
        let firstOriginX = pillFrames[0].minX
        let slotPitch: CGFloat = (count > 1 && pillFrames.count > 1)
            ? (pillFrames[1].minX - pillFrames[0].minX)
            : pillW
        // Degenerate input: zero-width strip (window collapsed mid-
        // drag) or two pills at the same origin. Return the caller's
        // fallback (typically `state.originalIndex`) so the dragged
        // pill holds its slot — silently snapping to slot 0, the old
        // behaviour, would commit a reorder the user didn't intend on
        // the next mouseUp.
        guard slotPitch > 0 else { return fallback }
        let rawIndex = (pillCenter - (firstOriginX + pillW / 2)) / slotPitch
        let rounded = Int(rawIndex.rounded())
        return max(0, min(count - 1, rounded))
    }

    /// Where pill `originalIdx` renders during a drag, given the dragged
    /// pill moved from `draggedFrom` to `draggedTo`. The dragged pill
    /// itself is returned as `draggedTo`; the displaced siblings shift
    /// by one slot toward the source. Pure helper; tests reach it via
    /// `@testable import Blackbird`.
    internal static func intermediateSlot(originalIdx: Int,
                                          draggedFrom: Int,
                                          draggedTo: Int) -> Int {
        if originalIdx == draggedFrom { return draggedTo }
        if draggedFrom == draggedTo { return originalIdx }
        if draggedFrom < draggedTo {
            // Dragged moved right: siblings in (draggedFrom, draggedTo]
            // shift one slot left.
            if originalIdx > draggedFrom, originalIdx <= draggedTo {
                return originalIdx - 1
            }
        } else {
            // Dragged moved left: siblings in [draggedTo, draggedFrom)
            // shift one slot right.
            if originalIdx >= draggedTo, originalIdx < draggedFrom {
                return originalIdx + 1
            }
        }
        return originalIdx
    }

    /// Right-click also auto-promotes the strip via AppKit's NSWindow
    /// event dispatch (same path as `mouseDown` — `acceptsFirstResponder`
    /// is gate-keeper, regardless of mouse button). `super` calls
    /// `menuForEvent:` which routes to our `menu(for:)` override; that
    /// shows the contextual menu and runs the chosen item's action
    /// synchronously, then returns. Whether the user picks an item or
    /// dismisses, first responder ends up parked on the strip — so we
    /// yield in the same shape as `mouseDown`.
    override func rightMouseDown(with event: NSEvent) {
        defer { yieldFirstResponderToTerminalIfParked() }
        super.rightMouseDown(with: event)
    }

    /// `os.Logger` (not `NSLog`) so `privacy: .public` markers actually
    /// take effect. Same pattern as `MainWindowController.tabsLogger`.
    /// Used as a canary for the rare case where
    /// `window.makeFirstResponder(cv)` returns `false` — that would
    /// silently re-open the NSBeep regression this fix targets.
    ///
    /// NOT gated on `#if DEBUG`: the failure mode (NSBeep on every
    /// keystroke until the user clicks away) is exactly the kind of
    /// regression that only shows up in production, and the log line
    /// is the only evidence we'd have to act on a user report.
    /// (audit M-5, sibling pattern of M-4)
    private static let focusLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "tabFocus")

    /// `os.Logger` for drag diagnostics — kept separate from `focusLogger`
    /// so the categories don't bleed into each other in the unified log.
    /// `fileprivate` so it is the single source of truth shared by the
    /// strip's `requestWindowDrag` no-window canary AND `TabDragController`'s
    /// `mouseUp` "should-never-happen but did" branches (which would
    /// otherwise discard a reorder gesture silently).
    fileprivate static let dragLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                               category: "tabDrag")

    /// Yield first-responder status from the strip back to the host
    /// window's contentView (the TerminalView in production) when the
    /// strip — or one of its non-edit-field descendants — is currently
    /// parked there. See the multi-paragraph rationale in `mouseDown`
    /// for *why*. Idempotent: when the strip isn't first responder, or
    /// when one of the protected roots (the inline rename text field)
    /// legitimately holds it, this is a no-op. Tolerant of a nil
    /// window / contentView (the strip outliving its host briefly
    /// during teardown).
    ///
    /// Called from `mouseDown`'s defer, `rightMouseDown`'s defer, and
    /// `teardownEdit` — every path the strip can be silently parked on
    /// after a user gesture.
    fileprivate func yieldFirstResponderToTerminalIfParked() {
        guard let win = window, let cv = win.contentView else { return }
        // When the rename controller's `editField` is non-nil we expect it to
        // be a subview of the strip (the inline rename text field is added in
        // `beginEditing` via `addSubview`). DEBUG-assert the invariant
        // so a future refactor that breaks the parentage trips loudly
        // instead of producing plausible-looking but wrong yield
        // decisions (an editField from a different strip would
        // short-circuit the protection branch and allow real keystroke
        // theft).
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
            // Logs in Release too — the NSBeep-on-every-keystroke
            // regression this canary covers is field-only by nature.
            // (audit M-5)
            Self.focusLogger.error("yieldFirstResponderToTerminalIfParked: makeFirstResponder(contentView) returned false — strip remains parked, keystrokes will ring NSBeep until the user clicks away. Investigate why TerminalView refused to become first responder.")
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
        // Only auto-set `focusedPill` (which drives the custom keyboard
        // focus ring) when the promotion to first responder came from a
        // keyboard event — Tab / Shift-Tab. A mouse-click promotion
        // leaves `focusedPill = nil` so the user just sees their tab
        // selected with no extra focus-ring decoration. Arrow keys and
        // Space still work afterward: the first arrow press sets
        // `focusedPill` via `moveLeft` / `moveRight` and the ring then
        // paints from that point forward.
        //
        // Why this matters: before this gate, clicking a pill would
        // become first responder → `focusedPill` defaulted to the
        // selected tab → the custom ring painted around that pill. User
        // feedback: looked like a stuck blue outline. Mouse clicks are
        // already a clear focus cue (the tab highlights); the ring is
        // keyboard-only affordance.
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
        // `onCloseWindow?` routes through `performClose(nil)` which
        // synchronously fires `windowWillClose` → `terminateSessions` →
        // `refreshAllTabBars`, mutating `self.tabs` (and `focusedPill`
        // via that refresh) before we return. Snapshot the pre-close
        // state so the post-close clamp lands on the right pill — reading
        // `focusedPill` / `tabs.count` after the close would clamp
        // against already-mutated state.
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
        // Hover state freezes during a drag: the dragged-pill highlight
        // is the user's focus point, and a stale `×` hotspot appearing
        // on a sibling pill mid-drag would compete with it. `mouseDragged`
        // is the only event we care about while a drag is live.
        if tabDragController.isDragging { return }
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
                hoveredClose = tabRenameController.editingPill != i
                    && NSPointInRect(p, closeHotspot(in: rect))
                break
            }
        }
        if prevPill != hoveredPill || prevClose != hoveredClose || prevAdd != hoveredAdd {
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        // Cursor leaving the strip's tracking area while a drag is in
        // flight is normal — AppKit still routes mouseDragged events to
        // us no matter where the cursor lives. Don't clobber hover
        // state (already cleared at drag start anyway) and don't trigger
        // a redraw.
        if tabDragController.isDragging { return }
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
        // `+` button or the empty trailing region) yields no contextual menu —
        // there's no tab to target.
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

        // Audit L9. NSMenu does NOT call `validateMenuItem` for context
        // menus built via `menu(for:)` — only for menu-bar menus reached
        // through the responder chain. Without filtering at build time,
        // "Rename…" and "Reset to Auto" appear enabled even when the
        // window's session has been torn down (shell exited mid-close)
        // or when no override is currently active. Both selectors then
        // hit `guard let session` / `guard … != nil` and silently no-op,
        // misleading the user. Mirror MainWindowController.validateMenuItem
        // logic at the build site so the items are simply absent when
        // they wouldn't fire usefully.
        let session = controller?.session
        if session != nil {
            let rename = NSMenuItem(
                title: "Rename…",
                action: #selector(MainWindowController.renameActiveTab(_:)),
                keyEquivalent: ""
            )
            rename.target = controller
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

        // Only emit the separator if at least one item was added above —
        // a leading separator on a context menu looks broken.
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

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

// MARK: - Strip first-responder yield decision

/// Pure decision function for `TabStripView.yieldFirstResponderToTerminalIfParked`.
/// Returns `true` when the caller SHOULD push first-responder back to
/// the host window's contentView, `false` when the current responder
/// is somewhere we must not clobber.
///
/// `claimant` is the view AppKit may have auto-promoted on a mouse
/// gesture (the `TabStripView` in production). `protectedRoots` is the
/// list of subtrees that legitimately own first responder while
/// non-empty — for the strip that's the inline rename text field while
/// rename is active, and only that. Empty at all other times.
///
/// Mirrors the shape of `shouldRestoreFirstResponder(currentFirstResponder:preserveDescendantsOf:)`
/// in `MainWindowController` so a future "another view that
/// legitimately holds FR" case is a 1-line append to `protectedRoots`
/// rather than another parameter.
///
/// Decision order (first match wins):
///   1. nil current responder — auto-promotion failed in some odd way
///      OR a `makeFirstResponder(nil)` left the window without one.
///      Restore so subsequent keystrokes have a definite home.
///   2. Non-NSView responder (typically the host NSWindow itself,
///      which is an NSResponder but NOT an NSView subclass — the
///      state a window briefly enters when a `becomeFirstResponder`
///      call returns false). Anything else hitting this branch
///      (NSWindowController, NSApplication, custom global responders)
///      is treated as "unintended" — restore. Production today has
///      no such responder; a comment in the call site flags the
///      assumption for any future addition.
///   3. Inside any protected root — leave alone.
///   4. The claimant itself or any of its non-protected descendants —
///      AppKit auto-promoted us, restore.
///   5. Anything else (typically TerminalView or a TerminalView
///      descendant such as the FindBar's text field) — first responder
///      already lives where keystrokes belong. Leave alone.
///
/// Pure (no AppKit reach-in) so unit tests can drive every case
/// without instantiating an NSWindow. Internal so tests can reach it
/// via `@testable import Blackbird`.
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

/// The pill drag-to-reorder state machine, hoisted out of `TabStripView`
/// (REFACTOR.md Area 5). Owns the three-phase gesture state; the strip's
/// `mouseDragged` / `mouseUp` overrides forward here, `mouseDown`'s arm branch
/// calls `arm(...)`, and `update(tabs:)` / `draw(_:)` query it. Holds an
/// `unowned` back-reference to the strip for its layout (`tabs` / `pillFrames`),
/// hover paint, and callbacks; the strip strong-references the controller, so
/// the back-ref is valid for the controller's whole life. Not an NSResponder —
/// the strip keeps the overrides and forwards.
private final class TabDragController {
    unowned let view: TabStripView

    init(view: TabStripView) { self.view = view }

    /// Captured on `mouseDown` over a pill body when reorder is feasible
    /// (≥ 2 tabs, not on the close hotspot, not entering inline-rename).
    /// `mouseDragged` checks the threshold against `startPoint.x` to
    /// decide whether to promote to a real reorder gesture.
    struct PendingDrag {
        let pillIndex: Int
        let startPoint: NSPoint
        /// Horizontal offset inside the pill at mousedown — preserved so
        /// the dragged pill stays anchored to where the user grabbed it
        /// rather than snapping its left edge to the cursor.
        let downOffsetX: CGFloat
    }

    /// Active drag — promoted from the `.armed` phase once the user
    /// moves the cursor past `dragThreshold`. `currentIndex` is the
    /// intermediate slot the dragged pill currently occupies; siblings
    /// render shifted around that slot. `cursorX` is the live mouse X
    /// used to draw the dragged pill under the cursor (clamped to
    /// strip bounds).
    struct DragState {
        let originalIndex: Int
        let downOffsetX: CGFloat
        var cursorX: CGFloat
        var currentIndex: Int
    }

    /// Three-phase state machine for reorder gestures. The enum makes
    /// the "armed but not yet dragging" vs "actively dragging" vs
    /// "neither" distinction representable in the type system — the
    /// previous two-optional encoding (`pendingDrag: ?`, `dragState: ?`)
    /// admitted a representable-but-illegal `(nil, set)` fourth state.
    /// `mouseDragged` reads + transitions; `mouseUp` always returns to
    /// `.idle`.
    enum DragPhase {
        case idle
        case armed(PendingDrag)
        case dragging(DragState)
    }
    private var phase: DragPhase = .idle

    /// Pixels of horizontal motion required before a mousedown is
    /// promoted to a reorder drag. Anything smaller is treated as a
    /// click and falls through to the existing select / close path. 5pt
    /// matches the macOS-wide drag-recognition tolerance for AppKit
    /// controls and is high enough to absorb hand-tremor without making
    /// the gesture feel laggy.
    private static let dragThreshold: CGFloat = 5

    /// `os.Logger` for the `mouseUp` "should-never-happen but did" canaries.
    /// Shared single source of truth with the strip's `requestWindowDrag`
    /// no-window log — lives on `TabStripView` (`tabDrag` category).
    private static var dragLogger: Logger { TabStripView.dragLogger }

    // MARK: Queries (consumed by the strip's draw / hover / test hooks)

    /// True while an active reorder drag is in flight. The strip freezes
    /// hover paint and short-circuits `mouseMoved` / `mouseExited` on this.
    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    /// The live drag state while `.dragging`, else `nil`. Drives the
    /// dragged-pill render in `draw(_:)`.
    var activeDragState: DragState? {
        if case .dragging(let s) = phase { return s }
        return nil
    }

    /// The armed pill index while `.armed` (pressed, not yet promoted past
    /// the threshold), else `nil`. Test-hook surface.
    var armedPillIndex: Int? {
        if case .armed(let p) = phase { return p.pillIndex }
        return nil
    }

    // MARK: Transitions

    /// Arm a potential reorder from a pill mousedown. Called by the strip's
    /// `handlePillClick` arm branch; selection stays DEFERRED to `mouseUp`
    /// so a drag — reorder OR window move — never switches tabs.
    func arm(pillIndex: Int, startPoint: NSPoint, downOffsetX: CGFloat) {
        phase = .armed(PendingDrag(pillIndex: pillIndex,
                                   startPoint: startPoint,
                                   downOffsetX: downOffsetX))
    }

    /// Hard-cancel an in-flight drag without committing. Used when the
    /// list shape changes underneath the gesture so we don't try to
    /// reorder against a stale index.
    func cancelInProgress() {
        phase = .idle
        view.needsDisplay = true
    }

    /// Cancel an armed-or-active gesture when the tab list changed shape
    /// beneath it (sibling closed, new tab opened, post-commit reorder). A
    /// stale `.dragging` would commit a reorder against the wrong slot, and a
    /// stale `.armed` would fire a wrong selection on the trailing mouseUp.
    /// `.idle` is left untouched — the post-commit refresh path already
    /// returned `.idle` in `mouseUp` before the notification fired.
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
            // A plain drag reorders; a drag carrying the configured
            // window-move modifier (default ⌘) moves the window, in EITHER
            // axis — the same gesture grammar as the terminal body
            // (`TerminalView.mouseDown`). Direction no longer decides the
            // outcome: the old steep-vertical-pull-moves-window heuristic was
            // removed (critique 2026-06-07, audit titlebar-tabs F10 lives on
            // as this modifier path).
            let dragMask = Preferences.shared.windowDragModifier.modifierMask
            let hasMoveModifier = !dragMask.isEmpty
                && event.modifierFlags.contains(dragMask)
            switch TabStripView.classifyPillDrag(dx: dx, dy: dy,
                                                 threshold: Self.dragThreshold,
                                                 hasMoveModifier: hasMoveModifier) {
            case .pending:
                // Hasn't moved far enough — still potentially a click.
                return
            case .reorder:
                // Plain drag — promote to an active reorder drag. Snap the
                // hover state off: we're not painting close hotspots or hover
                // backgrounds while a drag is in flight, and stale hover
                // indices would visibly linger under the moving pill.
                view.hoveredPill = nil
                view.hoveredClose = false
                view.hoveredAdd = false
                phase = .dragging(DragState(
                    originalIndex: pending.pillIndex,
                    downOffsetX: pending.downOffsetX,
                    cursorX: p.x,
                    currentIndex: pending.pillIndex
                ))
                view.needsDisplay = true
            case .windowMove:
                // Modifier held — the user is moving the window, not
                // reordering. Drop the armed reorder, clear hover paint,
                // and hand off to a native AppKit window drag. The
                // hand-off consumes the rest of the gesture (the default
                // `performDrag(with:)` blocks until mouse-up), so reset
                // to `.idle` *before* the hand-off — no `mouseUp` will
                // arrive to clear it for us.
                view.hoveredPill = nil
                view.hoveredClose = false
                view.hoveredAdd = false
                phase = .idle
                view.needsDisplay = true
                view.requestWindowDrag(event)
            }
        case .dragging(var state):
            // Bail out cleanly if the underlying tab list changed
            // shape mid-gesture (a sibling closed, a new tab opened) —
            // the original index no longer matches the strip.
            guard state.originalIndex < view.tabs.count else {
                cancelInProgress()
                return
            }
            // Degenerate strip width (mid-gesture window collapse to ~0):
            // `computeIntermediateIndex` can't compute a meaningful slot
            // without a positive pill pitch. Hold the dragged pill at
            // its original slot rather than yanking it to slot 0.
            let newIndex = TabStripView.computeIntermediateIndex(
                cursorX: p.x,
                downOffsetX: state.downOffsetX,
                count: view.tabs.count,
                pillFrames: view.pillFrames,
                fallback: state.originalIndex
            )
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
        // A press that armed a drag but never crossed the threshold is a
        // click: NOW switch tabs (selection was deferred from `mouseDown` so a
        // drag never selects — critique complaint C). Guard the index against
        // a list-shape change between mouseDown and mouseUp.
        if case .armed(let pending) = phase {
            // `.armed` is cancelled in `update(tabs:)` on any list-shape
            // change, so a surviving armed index should always be valid here.
            // If it isn't, the armed phase outlived a refresh that should have
            // reconciled it — log (matching the `.dragging` canary below)
            // rather than dropping the click silently.
            guard pending.pillIndex < view.tabs.count else {
                Self.dragLogger.notice("mouseUp: armed pillIndex \(pending.pillIndex, privacy: .public) >= tabs.count \(self.view.tabs.count, privacy: .public); armed phase outlived a list-shape change without being cancelled in update(tabs:) — click-to-select dropped, investigate.")
                return
            }
            // Only an index guard is needed here (unlike the reorder-commit
            // path below, which re-checks `tabGroup`): selecting a window whose
            // group changed mid-press is benign, whereas committing a reorder
            // against a detached window is not.
            view.onSelectWindow?(view.tabs[pending.pillIndex])
            return
        }
        // Only the actively-dragging phase has a reorder commit to consider;
        // `.idle` (no pill grabbed) falls straight through the guard.
        guard case .dragging(let state) = phase else { return }
        // No-op when the user lifted on the original slot.
        guard state.currentIndex != state.originalIndex else {
            view.needsDisplay = true
            return
        }
        // Defensive: tabs could have shrunk between the last
        // `mouseDragged` (where we already checked) and `mouseUp`. The
        // `update(tabs:)` cancellation path should have nilled the
        // drag, but the gesture is on the same main thread as the KVO
        // refresh so a synchronous interleave is theoretically possible
        // on AppKit's part. Log so a regression is visible.
        guard state.originalIndex < view.tabs.count else {
            Self.dragLogger.notice("mouseUp: dragState.originalIndex \(state.originalIndex, privacy: .public) >= tabs.count \(self.view.tabs.count, privacy: .public); list shape changed between mouseDragged and mouseUp without an update(tabs:) refresh — investigate.")
            view.needsDisplay = true
            return
        }
        let target = view.tabs[state.originalIndex]
        // Tab must still be in a group for the coordinator's
        // group-keyed storage to accept the move. Drag-out (the user
        // detaching the window) is the documented way `tabGroup` goes
        // nil mid-drag; treat the reorder as discarded rather than
        // trying to commit against the now-standalone window.
        guard let group = target.tabGroup else {
            Self.dragLogger.notice("mouseUp: dragged window's tabGroup went nil mid-drag (detached?); discarding reorder")
            view.needsDisplay = true
            return
        }
        TabOrderCoordinator.shared.move(window: target,
                                        to: state.currentIndex,
                                        in: group)
        // The coordinator's `orderDidChange` notification drives
        // `refreshAllTabBars()` — every sibling strip in the group
        // repaints with the new permutation. Setting `needsDisplay` here
        // covers the (rare) case where notification delivery is delayed
        // past the next paint pass: we want the dragged pill to settle
        // into its new slot immediately even if the refresh hasn't
        // landed yet.
        view.needsDisplay = true
    }

    /// Where the dragged pill renders this frame: anchored to the cursor by
    /// the grab offset (`downOffsetX`, so it doesn't snap-left on grab),
    /// clamped against the laid-out `+` button frame (the single source of
    /// truth for the trailing boundary) so it can never slide under the
    /// button and this can't drift from `layoutPills()`'s math. Pure so the
    /// strip's draw path delegates the geometry here.
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

/// The inline-rename engine, hoisted out of `TabStripView` (REFACTOR.md
/// Area 5). Owns the editing pill index + field editor and IS the field's
/// `NSTextFieldDelegate` + action target. The strip exposes thin
/// `beginEditing` / `commitEditIfNeeded` forwarders for its external callers
/// (`TitlebarTabBarViewController`) and queries `editingPill` / `isEditing`
/// from its draw + hit-test + hover paths. `unowned view`; the strip
/// strong-references this, so the back-ref is valid for the controller's
/// whole life. NSObject base is required for the `@objc` action + the
/// Cocoa text-field delegate protocol.
private final class TabRenameController: NSObject, NSTextFieldDelegate {
    unowned let view: TabStripView

    init(view: TabStripView) {
        self.view = view
        super.init()
    }

    /// Index of the pill currently in inline-edit mode, or `nil`. Only one
    /// pill edits at a time; opening a second commits the first so the
    /// user never silently loses an in-flight title edit.
    private(set) var editingPill: Int? = nil
    /// Field editor used while a pill is being renamed. Lifetime matches
    /// `editingPill` — nil'd together by `teardownEdit`.
    private(set) var editField: NSTextField? = nil

    /// `true` while any pill is in inline-edit mode. The strip's hover /
    /// close / draw paths short-circuit on this so the editing pill doesn't
    /// paint an `×` hotspot over its own text field.
    var isEditing: Bool { editingPill != nil }

    /// Swap the pill at `pillIndex` into rename mode. Installs an
    /// `NSTextField` over the pill's title area, pre-fills with the window
    /// title, selects all. Commits any in-flight edit first so two
    /// double-clicks in a row don't drop the first edit silently.
    func beginEditing(pillIndex: Int) {
        guard pillIndex >= 0,
              pillIndex < view.tabs.count,
              pillIndex < view.pillFrames.count
        else { return }
        if let existing = editingPill, existing != pillIndex {
            commitEdit()
        }
        // If the field already exists for the same pill (e.g., user hit
        // ⌥⌘R a second time on the same pill), just refocus it.
        if editingPill == pillIndex, let existing = editField {
            view.window?.makeFirstResponder(existing)
            existing.currentEditor()?.selectAll(nil)
            return
        }
        editingPill = pillIndex
        let pill = view.pillFrames[pillIndex]
        let closeRect = view.closeHotspot(in: pill)
        // Size the field to the pill's title area (the SAME horizontal math
        // the drawing path uses, via TabStripLayout). 2 pt top/bottom inset
        // keeps the field slightly inside the pill body so its focus-ring-free
        // border is visible.
        let title = TabStripLayout.titleArea(in: pill, closeWidth: closeRect.width)
        let fieldRect = NSRect(
            x: title.x,
            y: pill.minY + 2,
            width: title.width,
            height: pill.height - 4
        )
        let field = NSTextField(frame: fieldRect)
        field.font = TabStripView.titleFont
        field.alignment = .center
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.textBackgroundColor
        field.textColor = NSColor.labelColor
        field.focusRingType = .none
        field.stringValue = view.tabs[pillIndex].title.isEmpty ? "Untitled" : view.tabs[pillIndex].title
        field.delegate = self
        // Enter fires the action; action selector + target here is a
        // defense-in-depth for environments where the field-editor
        // `insertNewline:` command path doesn't route through the
        // delegate. Both paths funnel through `commitEdit`.
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
    func commitEdit() {
        guard let idx = editingPill,
              let field = editField,
              idx < view.tabs.count
        else {
            cancelEdit()
            return
        }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = view.tabs[idx]
        teardownEdit()
        // Call through AFTER teardown so the consumer's side-effects
        // (title publication → KVO → refreshTabBar) don't land while
        // the field subview is still alive. Note that `teardownEdit`
        // now also yields first-responder back to the terminal view
        // synchronously (see `yieldFirstResponderToTerminalIfParked`),
        // so by the time `onCommitRename` runs the FR slot is settled
        // — the older comment about "racing for the first-responder
        // slot" no longer applies, but the teardown-then-publish
        // ordering still does.
        view.onCommitRename?(target, trimmed)
    }

    /// Dismiss the edit without publishing. Used for Escape and for any
    /// path that takes the field down without consumer notification.
    func cancelEdit() {
        teardownEdit()
    }

    /// Commit the in-flight edit if one is active. No-op otherwise. Used
    /// by `TabStripView.commitEditIfNeeded` (→
    /// `MainWindowController.refreshTabBar`) on the multi-tab → single-tab
    /// transition so the field doesn't survive as a subview of a hidden
    /// strip. (main-window F8)
    func commitIfNeeded() {
        if editingPill != nil {
            commitEdit()
        }
    }

    /// Move the field to track the pill's new x/width on a width-only
    /// `update` (the path `windowDidResize` takes every tick at 120 Hz on
    /// ProMotion) so the caret doesn't drift off-pill. No-op when no edit is
    /// in flight. Geometry mirrors `beginEditing`'s field-rect computation.
    func repositionFieldForWidthChange() {
        guard let idx = editingPill,
              idx < view.pillFrames.count,
              let field = editField
        else { return }
        let pill = view.pillFrames[idx]
        let closeRect = view.closeHotspot(in: pill)
        let title = TabStripLayout.titleArea(in: pill, closeWidth: closeRect.width)
        field.frame = NSRect(
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
        editingPill = nil
        view.needsDisplay = true
        // Removing the field as a subview triggers AppKit's
        // `makeFirstResponder(nil)`, which lands first responder on the
        // host NSWindow itself — an NSResponder but not an NSView, so
        // typed characters fall to `noResponderFor:` and ring NSBeep.
        // Push first responder back to the terminal in the same
        // synchronous step so no keystrokes can squeak through the
        // window-as-FR window. The `onCommitRename` side-effects fired
        // by `commitEdit` (KVO → refreshTabBar) don't touch first
        // responder, so doing this here (vs. at every call site) is
        // safe and keeps the contract local.
        view.yieldFirstResponderToTerminalIfParked()
    }

    // MARK: NSTextFieldDelegate

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
