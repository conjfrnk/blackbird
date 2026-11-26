import AppKit
import Foundation
import BBCore

/// The view owns this controller, and its teardown stops the autoscroll through
/// `selectionAutoscroller` directly: `unowned view` must never be read during the view's deinit.
final class SelectionController {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    var isDragging = false

    /// The double-click word, resolved at `mouseDown` while the anchor is still on-viewport.
    var wordDragAnchorWord: (BufferPoint, BufferPoint)?

    /// A one-cell word and a blank cell both reach `endDrag` as `anchor == cursor`; this tells them apart.
    private(set) var anchorResolvedToUnit = false

    #if DEBUG
    var anchorResolvedToUnitForTesting: Bool { anchorResolvedToUnit }
    #endif

    // MARK: - Entry points

    /// `clickCount` is `TerminalView.effectiveClickCount`, not `event.clickCount`: the raw
    /// count keeps rising across an activation click AppKit never delivered.
    func beginSelection(with event: NSEvent, clickCount: Int) {
        let point = view.bufferPointFromEvent(event)
        if clickCount == 1,
           event.modifierFlags.contains(.shift),
           let existing = view.selection {
            view.selection = Selection(anchor: existing.anchor, cursor: point, mode: existing.mode)
            if existing.mode == .word, let snap = view.currentSnapshot {
                wordDragAnchorWord = wordRange(around: existing.anchor, in: snap, displayOffset: snap.displayOffset)
                    ?? (existing.anchor, existing.anchor)
            } else {
                wordDragAnchorWord = nil
            }
            isDragging = true
            anchorResolvedToUnit = false
            return
        }
        let mode: Selection.Mode
        switch clickCount {
        case 3: mode = .line
        case 2: mode = .word
        default:
            mode = event.modifierFlags.contains(.option) ? .rectangular : .character
        }
        view.selection = Selection(anchor: point, cursor: point, mode: mode)
        isDragging = true
        // Reset unconditionally: a stale `true` would leave a zero-width selection after every later click.
        anchorResolvedToUnit = false
        if mode == .word || mode == .line {
            anchorResolvedToUnit = expandSelectionUnderAnchor()
        }
        if mode == .word, let s = view.selection {
            wordDragAnchorWord = (s.anchor, s.cursor)
        } else {
            wordDragAnchorWord = nil
        }
    }

    func endDrag() -> Bool {
        guard isDragging else { return false }
        isDragging = false
        stopSelectionAutoscroll()
        // A zero-width selection is a click without a drag, unless the expansion resolved a one-cell unit.
        if let s = view.selection, s.anchor == s.cursor, !anchorResolvedToUnit {
            view.selection = nil
        }
        return true
    }

    func handleDrag(with event: NSEvent) -> Bool {
        guard isDragging, var sel = view.selection else { return false }
        let local = view.convert(event.locationInWindow, from: nil)
        // AppKit stops delivering `mouseDragged` when the pointer stops moving, so a timer
        // drives the scroll while the pointer sits in an edge band. y=0 is the visual bottom.
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
        // `.word` and `.line` re-snap on every drag so the highlight agrees with the copy range.
        if sel.mode == .word || sel.mode == .line {
            extendSelectionToCursor()
        }
        return true
    }

    // MARK: - Autoscroll

    private func updateSelectionAutoscroll(direction: Int32) {
        // The tick re-derives the cursor from the current mouse location so the selection
        // keeps growing as the viewport scrolls under a stationary pointer.
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

    private func stopSelectionAutoscroll() {
        view.selectionAutoscroller.stop()
    }

    // MARK: - Word / line expansion

    @discardableResult
    private func expandSelectionUnderAnchor() -> Bool {
        guard var sel = view.selection, let snap = view.currentSnapshot else { return false }
        switch sel.mode {
        case .word:
            guard let (a, b) = wordRange(around: sel.anchor, in: snap, displayOffset: snap.displayOffset)
            else { return false }
            sel.anchor = a
            sel.cursor = b
            view.selection = sel
            return true
        case .line:
            sel.anchor = BufferPoint(line: sel.anchor.line, col: 0)
            sel.cursor = BufferPoint(line: sel.cursor.line, col: snap.cols - 1)
            view.selection = sel
            return true
        default:
            return false
        }
    }

    private func extendSelectionToCursor() {
        guard var sel = view.selection, let snap = view.currentSnapshot else { return }
        let off = snap.displayOffset
        switch sel.mode {
        case .word:
            // Use the stored anchor word, not `sel.anchor` or a re-resolve: `sel.anchor` moves on
            // a backward drag, and a re-resolve returns nil once the anchor is off-viewport.
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

    /// Unions `anchorWord` with the word under `cursorPoint`. A cursor on a non-word cell
    /// degrades that endpoint to the bare cursor cell.
    static func wordDragSelectionEndpoints(
        anchorWord: (BufferPoint, BufferPoint),
        cursorPoint: BufferPoint,
        in snapshot: BBSnapshot,
        displayOffset: Int
    ) -> (anchor: BufferPoint, cursor: BufferPoint) {
        let aLo = min(anchorWord.0, anchorWord.1)
        let aHi = max(anchorWord.0, anchorWord.1)
        let cWord = wordRange(around: cursorPoint, in: snapshot, displayOffset: displayOffset)
            ?? (cursorPoint, cursorPoint)
        if cursorPoint < aLo {
            return (anchor: aHi, cursor: cWord.0)
        } else {
            return (anchor: aLo, cursor: cWord.1)
        }
    }
}
