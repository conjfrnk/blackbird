import AppKit
import Foundation
import BBCore

/// The mouse-driven text-selection gesture machine for `TerminalView`, split
/// out of `TerminalView+Mouse.swift` so that file becomes thin overrides that
/// classify the gesture and delegate (selection here, reporting to
/// `sendMouseEvent`/`MouseReportEncoder`, window move/resize to
/// `WindowResizeController`).
///
/// Owns the drag state — `isDragging` and the resolved double-click word
/// (`wordDragAnchorWord`) — and the click/drag/extend logic. The `selection`
/// PROPERTY stays on the view: it's `public internal(set)`, drawn by the
/// renderer, taken by `renderer.render(...:selection:)`, and read at ~100
/// sites; this controller mutates it as `view.selection`. The edge-autoscroll
/// timer likewise stays in the view-owned `SelectionAutoscroller`; this
/// controller drives it with a per-tick closure.
///
/// `unowned let view`: the view owns this controller (`lazy var`), so its
/// lifetime is a strict subset of the view's. The view's teardown
/// (`deinit`/`viewWillMove`) stops the autoscroll via `selectionAutoscroller`
/// DIRECTLY — it never calls a method here — so the `unowned view` back-ref is
/// never read during the view's own deinit (which would trap). The autoscroll
/// tick closure captures `[weak self]` (self = this controller) and no-ops once
/// the view/controller are gone.
final class SelectionController {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    /// True while a left-drag selection is in progress (set on `mouseDown`'s
    /// select branch, cleared on `mouseUp`). No external readers.
    var isDragging = false

    /// The resolved double-click word — captured on-screen at `mouseDown` while
    /// the anchor is on-viewport — so a `.word` drag unions it with the cursor
    /// word even after an autoscroll pushes the anchor off-viewport. Reconciled
    /// against snapshot moves/deletes by `SelectionReconciler` (the view's
    /// snapshot path reads/writes it as `selectionController.wordDragAnchorWord`).
    var wordDragAnchorWord: (BufferPoint, BufferPoint)?

    // MARK: - Entry points (called by the view's mouse overrides)

    /// `mouseDown`'s selection branch — reached only after the URL-open,
    /// window-drag, and mouse-reporting early-returns in the override.
    ///
    /// `clickCount` is the view's RENUMBERED count
    /// (`TerminalView.effectiveClickCount`), not `event.clickCount`. The raw
    /// system count keeps rising across an activation click AppKit never
    /// delivered, which made a single delivered click select a word and a
    /// genuine double-click select a whole line. Every branch below reads the
    /// parameter; reaching for `event.clickCount` here reintroduces the bug.
    func beginSelection(with event: NSEvent, clickCount: Int) {
        let point = view.bufferPointFromEvent(event)
        // Shift-click extends the current selection from its ANCHOR to the
        // click point — the standard macOS / iTerm2 gesture for precise
        // selection adjustment. Without it, shift-click would start a new
        // zero-width selection, discarding whatever the user just carefully
        // selected. Audit findbar-selection F17.
        if clickCount == 1,
           event.modifierFlags.contains(.shift),
           let existing = view.selection {
            view.selection = Selection(anchor: existing.anchor, cursor: point, mode: existing.mode)
            // Re-capture the word-drag anchor so a subsequent drag extends by
            // word from the existing selection's anchor. Resolve the word now
            // (anchor is on-screen); fall back to the bare anchor if it lands
            // on a non-word cell.
            if existing.mode == .word, let snap = view.currentSnapshot {
                wordDragAnchorWord = wordRange(around: existing.anchor, in: snap, displayOffset: snap.displayOffset)
                    ?? (existing.anchor, existing.anchor)
            } else {
                wordDragAnchorWord = nil
            }
            isDragging = true
            return
        }
        let mode: Selection.Mode
        switch clickCount {
        case 3: mode = .line
        case 2: mode = .word
        default:
            // ⌥-drag for rectangular (column-block) selection — iTerm2 /
            // Terminal.app default. ⌘-click is reserved for URL-open and, when
            // ⌘ is the configured window-drag modifier (the default), window
            // drag — both of which return in the override before reaching here.
            // If the drag modifier is remapped (e.g. ⌥⌘), a bare ⌘-drag with no
            // URL intentionally falls through to character selection here.
            mode = event.modifierFlags.contains(.option) ? .rectangular : .character
        }
        view.selection = Selection(anchor: point, cursor: point, mode: mode)
        isDragging = true
        if mode == .word || mode == .line {
            expandSelectionUnderAnchor()
        }
        // Capture the resolved anchor word ONCE, now, while the anchor is
        // on-screen — `expandSelectionUnderAnchor` just set the selection's
        // endpoints to the word edges for `.word`. A subsequent drag unions
        // this fixed range with the word under the cursor; storing the resolved
        // range (not the point) means an autoscroll that pushes the anchor
        // off-viewport can't lose it. nil for non-word modes.
        if mode == .word, let s = view.selection {
            wordDragAnchorWord = (s.anchor, s.cursor)
        } else {
            wordDragAnchorWord = nil
        }
    }

    /// `mouseUp`'s selection branch. Returns `true` when a drag was in progress
    /// (the override then returns without falling through to reporting).
    func endDrag() -> Bool {
        guard isDragging else { return false }
        isDragging = false
        // Tear down the edge-autoscroll timer armed during the drag. If the
        // release happened while still inside the edge band the timer may still
        // be ticking; stopping it here prevents a stray scroll after `mouseUp`
        // returns. Audit terminal-view-2 F2.
        stopSelectionAutoscroll()
        // A zero-width selection means the user clicked without dragging — no
        // content to show, so clear. Applies to every mode: .character clicks
        // leave anchor == cursor directly; .word / .line clicks that landed on
        // non-word cells also leave anchor == cursor (expandSelectionUnderAnchor
        // is a no-op there); .rectangular clicks start at anchor == cursor and
        // only grow during the drag.
        if let s = view.selection, s.anchor == s.cursor {
            view.selection = nil
        }
        return true
    }

    /// `mouseDragged`'s selection branch. Returns `true` when a selection drag
    /// is being handled (the override then returns without falling through to
    /// motion reporting).
    func handleDrag(with event: NSEvent) -> Bool {
        guard isDragging, var sel = view.selection else { return false }
        // Autoscroll when dragging past the viewport edges so the user can
        // select into scrollback / future output.
        //
        // scroll(delta:) follows alacritty's convention:
        //   positive → show older (scrollback), negative → show newer.
        // AppKit coords place y=0 at the visual bottom, so:
        //   - cursor near the TOP (high y)    → reveal older content → +1
        //   - cursor near the BOTTOM (low y) → reveal newer content → -1
        let local = view.convert(event.locationInWindow, from: nil)
        // Audit terminal-view-2 F2. AppKit stops delivering `mouseDragged` the
        // moment the pointer stops moving, so a user who drags to the edge and
        // holds still would see autoscroll stop until they wiggled the pointer.
        // Arm a repeating timer while inside an edge band; the timer drives the
        // actual `session.scroll` so selection extension continues even on a
        // stationary hold. `endDrag` (mouseUp) and the view's teardown
        // (viewWillMove / deinit) tear the timer down.
        let direction: Int32
        if local.y > view.bounds.height - view.titlebarOnlyTopInset - view.metrics.cellHeight {
            direction = 1
        } else if local.y < view.metrics.cellHeight {
            direction = -1
        } else {
            direction = 0
        }
        updateSelectionAutoscroll(direction: direction)
        sel.cursor = view.bufferPointFromEvent(event)
        view.selection = sel
        // F15 (findbar-selection): .word and .line modes must re-snap their
        // endpoints on every drag so the visual highlight (renderer uses
        // `selection.normalized`) agrees with the copy range (which extends to
        // full-row/full-word boundaries via `copyRange(for:cols:)`) — otherwise
        // a triple-click-and-drag highlights a ragged prose rectangle while ⌘C
        // grabs clean whole rows. Unlike the initiating click, the drag must
        // EXTEND to the word/line under the cursor, not re-select the anchor.
        if sel.mode == .word || sel.mode == .line {
            extendSelectionToCursor()
        }
        return true
    }

    // MARK: - Autoscroll

    /// Arm, re-arm, or tear down the selection-drag autoscroll timer based on
    /// the cursor's current edge-band status. `direction`: +1 = top edge
    /// (reveal older rows), -1 = bottom edge (reveal newer rows), 0 = inside the
    /// viewport (stop). Audit terminal-view-2 F2.
    private func updateSelectionAutoscroll(direction: Int32) {
        // The timer + direction live on `view.selectionAutoscroller`; this
        // drives it with a per-tick closure. The closure returns `false` (→
        // stop) when the drag has ended; otherwise it re-derives the selection
        // cursor from the CURRENT mouse location so the selection keeps growing
        // as the viewport scrolls under a stationary pointer (else it would
        // freeze to whatever bufferPoint the last `mouseDragged` recorded). One
        // `session.scroll` per tick; the new snapshot propagates through the
        // normal Combine→render path.
        view.selectionAutoscroller.update(direction: direction) { [weak self] in
            guard let self, self.isDragging else { return false }
            self.view.session?.scroll(delta: self.view.selectionAutoscroller.direction)
            if var sel = self.view.selection,
               let mouseWindow = self.view.window?.mouseLocationOutsideOfEventStream {
                let local = self.view.convert(mouseWindow, from: nil)
                let fakePoint = self.view.bufferPointFromLocalPoint(local)
                sel.cursor = fakePoint
                self.view.selection = sel
                if sel.mode == .word || sel.mode == .line {
                    self.extendSelectionToCursor()
                }
            }
            return true
        }
    }

    /// Stop any in-flight selection autoscroll. Safe to call when none is
    /// running. Audit terminal-view-2 F2.
    private func stopSelectionAutoscroll() {
        view.selectionAutoscroller.stop()
    }

    // MARK: - Word / line expansion

    /// Select the `.word` or `.line` UNDER THE ANCHOR — the initiating
    /// double/triple-click gesture. `.word` uses the shared `wordRange` helper;
    /// `.line` selects the entire grid line. Drag/autoscroll use
    /// `extendSelectionToCursor` instead, so this is only the mouseDown entry.
    private func expandSelectionUnderAnchor() {
        guard var sel = view.selection, let snap = view.currentSnapshot else { return }
        switch sel.mode {
        case .word:
            if let (a, b) = wordRange(around: sel.anchor, in: snap, displayOffset: snap.displayOffset) {
                sel.anchor = a
                sel.cursor = b
                view.selection = sel
            }
        case .line:
            sel.anchor = BufferPoint(line: sel.anchor.line, col: 0)
            sel.cursor = BufferPoint(line: sel.cursor.line, col: snap.cols - 1)
            view.selection = sel
        default:
            break
        }
    }

    /// Extend a `.word` or `.line` selection to the live drag cursor. Used by
    /// `handleDrag` and the autoscroll tick — distinct from
    /// `expandSelectionUnderAnchor`, which only ever selects the word/line at
    /// the anchor (the initiating click). A drag must span from the anchor's
    /// word/line to whatever the cursor is now over, the way Terminal.app /
    /// iTerm2 extend a double-click-drag word by word. Audit
    /// double-click-drag word-extend.
    private func extendSelectionToCursor() {
        guard var sel = view.selection, let snap = view.currentSnapshot else { return }
        let off = snap.displayOffset
        switch sel.mode {
        case .word:
            // Union the FIXED anchor word (resolved once at mouseDown) with the
            // word under the live cursor. Using the stored resolved range — not
            // `sel.anchor`, and not a re-resolved point — keeps the anchor word
            // both stable across a backward drag (where `sel.anchor` moves to
            // the cursor side) AND intact when an autoscroll drag pushes the
            // anchor off-viewport (where a re-resolve would return nil and
            // collapse it).
            let anchorWord = wordDragAnchorWord ?? (sel.anchor, sel.cursor)
            let ends = Self.wordDragSelectionEndpoints(
                anchorWord: anchorWord,
                cursorPoint: sel.cursor,
                in: snap,
                displayOffset: off
            )
            sel.anchor = ends.anchor
            sel.cursor = ends.cursor
            view.selection = sel
        case .line:
            sel.anchor = BufferPoint(line: sel.anchor.line, col: 0)
            sel.cursor = BufferPoint(line: sel.cursor.line, col: snap.cols - 1)
            view.selection = sel
        default:
            break
        }
    }

    /// Word-mode drag endpoints: union the already-resolved `anchorWord` (start,
    /// end — the double-click word, captured on-screen at mouseDown) with the
    /// word under the live `cursorPoint`, returning the `(anchor, cursor)`
    /// endpoints for the resulting selection. The stable end is placed at
    /// `anchor` and the moving end at `cursor` following the drag direction;
    /// `Selection.normalized` re-sorts, so the union is covered either way. When
    /// the cursor falls on a non-word cell (blank), `wordRange` returns nil and
    /// that endpoint degrades to the bare cursor cell — matching character-
    /// grained drag over whitespace. `anchorWord` is taken pre-resolved (not a
    /// point re-resolved here) so it survives an autoscroll that scrolls the
    /// anchor off-viewport. Pure + `static` so it is unit-testable without a
    /// live view or synthesized `NSEvent`. Audit double-click-drag word-extend.
    static func wordDragSelectionEndpoints(
        anchorWord: (BufferPoint, BufferPoint),
        cursorPoint: BufferPoint,
        in snapshot: BBSnapshot,
        displayOffset: Int
    ) -> (anchor: BufferPoint, cursor: BufferPoint) {
        // Defensive: tolerate an unnormalized anchorWord (the mouseDown capture
        // is already start<=end, but a fallback span may not be).
        let aLo = min(anchorWord.0, anchorWord.1)
        let aHi = max(anchorWord.0, anchorWord.1)
        let cWord = wordRange(around: cursorPoint, in: snapshot, displayOffset: displayOffset)
            ?? (cursorPoint, cursorPoint)
        if cursorPoint < aLo {
            // Backward drag: stable end is the anchor word's trailing edge,
            // moving end is the cursor word's leading edge.
            return (anchor: aHi, cursor: cWord.0)
        } else {
            // Forward drag (cursor at/after the anchor word's start, including
            // inside it): stable end is the anchor word's leading edge, moving
            // end is the cursor word's trailing edge.
            return (anchor: aLo, cursor: cWord.1)
        }
    }
}
