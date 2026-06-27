import BBCore

/// Reconciles a live mouse selection (and its captured word-drag anchor) against
/// a freshly-arrived grid snapshot. Selection endpoints are `BufferPoint`s
/// pinned to the grid the user dragged on; certain snapshot transitions move or
/// delete the cells they address, so the selection must be dropped or rotated.
/// Extracted verbatim from the coordinate-reflow block buried in
/// `TerminalView.render(snapshot:)` (REFACTOR.md Part IV) into a pure,
/// snapshot-pair-testable seam.
///
/// The rules (all gated on a prior snapshot existing — the first render has no
/// live selection):
///   - #14 column reflow: cols changed → alacritty re-wraps scrollback, the
///     points name different cells, re-mapping is impossible → DROP.
///   - #15 alt-screen toggle: the visible grid was swapped → DROP.
///   - H-6 history collapse (⌘K / RIS): history went non-zero → zero, the
///     selected scrollback lines are gone → DROP.
///   - S5-005 output scroll (rows unchanged, linesScrolled advanced): rotate
///     both endpoints up by the lines-scrolled delta so the highlight stays
///     glued to its content; drop once an endpoint scrolls past retention. The
///     `.word` drag anchor is rotated in lockstep (or dropped if IT scrolls
///     past retention).
enum SelectionReconciler {
    /// Given a non-nil `selection` and its optional `wordDragAnchor`, return the
    /// values they should take under `next` (relative to `prev`). A nil
    /// `selection` in the result means "drop it".
    static func reconciled(
        selection: Selection,
        wordDragAnchor: (BufferPoint, BufferPoint)?,
        prev: BBSnapshot,
        next: BBSnapshot
    ) -> (selection: Selection?, wordDragAnchor: (BufferPoint, BufferPoint)?) {
        let colsChanged = prev.cols != next.cols
        let altScreenChanged = prev.termMode.contains(.altScreen)
            != next.termMode.contains(.altScreen)
        let historyCollapsed = prev.historySize > 0 && next.historySize == 0
        if colsChanged || altScreenChanged || historyCollapsed {
            // cols/altScreen/history gates fire: drop the selection. The word
            // drag anchor is left as-is (matches the original branch).
            return (nil, wordDragAnchor)
        }
        // rows-equal gate: a vertical resize also bumps linesScrolled (the
        // counter's any-resize caveat); rotating on that would shift a
        // selection the row-only-resize contract (#14) promises to preserve.
        // Only genuine output flow (rows unchanged) rotates.
        guard prev.rows == next.rows, next.linesScrolled > prev.linesScrolled else {
            return (selection, wordDragAnchor)
        }
        var sel = selection
        let delta = Int64(next.linesScrolled - prev.linesScrolled)
        let anchorLine = Int64(sel.anchor.line) - delta
        let cursorLine = Int64(sel.cursor.line) - delta
        let retentionFloor = -Int64(next.historySize)
        if min(anchorLine, cursorLine) < retentionFloor {
            // The selected content scrolled out of retention — drop both the
            // selection and the stored word-drag anchor so a resumed drag can't
            // re-pin to vacated coordinates.
            return (nil, nil)
        }
        sel.anchor.line = Int32(clamping: anchorLine)
        sel.cursor.line = Int32(clamping: cursorLine)
        // Rotate the stored .word drag anchor by the SAME delta so the
        // double-click-drag union stays attached to its word; drop it if IT
        // scrolls past retention (the drag path falls back to sel.anchor then).
        var newAnchor = wordDragAnchor
        if var anchorWord = wordDragAnchor {
            let w0 = Int64(anchorWord.0.line) - delta
            let w1 = Int64(anchorWord.1.line) - delta
            if min(w0, w1) < retentionFloor {
                newAnchor = nil
            } else {
                anchorWord.0.line = Int32(clamping: w0)
                anchorWord.1.line = Int32(clamping: w1)
                newAnchor = anchorWord
            }
        }
        return (sel, newAnchor)
    }
}
