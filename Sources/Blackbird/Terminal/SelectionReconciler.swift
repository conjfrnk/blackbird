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
///   - MSC-7 row change: a vertical resize pushes rows into (or pulls them
///     back out of) history, shifting every buffer line index by an amount
///     that depends on the cursor row and the scrollback cap and that the
///     core does not report → the points name different text → DROP.
///   - #15 alt-screen toggle: the visible grid was swapped → DROP.
///   - H-6 history collapse (⌘K / RIS): history went non-zero → zero, the
///     selected scrollback lines are gone → DROP.
///   - S5-005 output scroll (linesScrolled advanced): rotate
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
        reconciled(selection: selection, wordDragAnchor: wordDragAnchor,
                   prev: BBTerm.GridState(prev), next: BBTerm.GridState(next))
    }

    /// The same rules against a live grid read as `BBTerm.GridState` — the
    /// copy path reconciles against the core without taking a snapshot.
    static func reconciled(
        selection: Selection,
        wordDragAnchor: (BufferPoint, BufferPoint)?,
        prev: BBTerm.GridState,
        next: BBTerm.GridState
    ) -> (selection: Selection?, wordDragAnchor: (BufferPoint, BufferPoint)?) {
        guard let scrolled = next.linesScrolled(since: prev) else {
            // cols/rows/altScreen/history gates fire: drop the selection. The word
            // drag anchor is left as-is (matches the original branch).
            return (nil, wordDragAnchor)
        }
        // Rows are unchanged here (a row change dropped above), so a
        // linesScrolled advance is genuine output flow, not a resize.
        guard scrolled > 0 else {
            return (selection, wordDragAnchor)
        }
        var sel = selection
        let delta = Int64(scrolled)
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

extension BBTerm.GridState {
    /// Lines the primary screen has pushed toward scrollback since `earlier`
    /// (0 when none), or nil when `earlier`'s buffer lines no longer name the
    /// same cells here: a column reflow (#14), a vertical resize (MSC-7), an
    /// alt-screen toggle (#15) or a history collapse (H-6). The single gate
    /// every reader of a displayed frame's coordinates goes through — the
    /// selection reconcile above, and Find's scrollback reads.
    func linesScrolled(since earlier: BBTerm.GridState) -> UInt64? {
        let altScreenChanged = earlier.termMode.contains(.altScreen)
            != termMode.contains(.altScreen)
        let historyCollapsed = earlier.historySize > 0 && historySize == 0
        if cols != earlier.cols || rows != earlier.rows || altScreenChanged || historyCollapsed {
            return nil
        }
        return linesScrolled > earlier.linesScrolled ? linesScrolled - earlier.linesScrolled : 0
    }
}
