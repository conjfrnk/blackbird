import BBCore

/// Drops or rotates a selection whose buffer points a new snapshot has moved or deleted.
enum SelectionReconciler {
    /// A nil `selection` in the result means "drop it".
    static func reconciled(
        selection: Selection,
        wordDragAnchor: (BufferPoint, BufferPoint)?,
        prev: BBSnapshot,
        next: BBSnapshot
    ) -> (selection: Selection?, wordDragAnchor: (BufferPoint, BufferPoint)?) {
        reconciled(selection: selection, wordDragAnchor: wordDragAnchor,
                   prev: BBTerm.GridState(prev), next: BBTerm.GridState(next))
    }

    static func reconciled(
        selection: Selection,
        wordDragAnchor: (BufferPoint, BufferPoint)?,
        prev: BBTerm.GridState,
        next: BBTerm.GridState
    ) -> (selection: Selection?, wordDragAnchor: (BufferPoint, BufferPoint)?) {
        guard let scrolled = next.linesScrolled(since: prev) else {
            return (nil, wordDragAnchor)
        }
        guard scrolled > 0 else {
            return (selection, wordDragAnchor)
        }
        var sel = selection
        let delta = Int64(scrolled)
        let anchorLine = Int64(sel.anchor.line) - delta
        let cursorLine = Int64(sel.cursor.line) - delta
        let retentionFloor = -Int64(next.historySize)
        if min(anchorLine, cursorLine) < retentionFloor {
            // Drop the word-drag anchor too so a resumed drag cannot re-pin to vacated coordinates.
            return (nil, nil)
        }
        sel.anchor.line = Int32(clamping: anchorLine)
        sel.cursor.line = Int32(clamping: cursorLine)
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
    /// Lines pushed toward scrollback since `earlier`, or nil when `earlier`'s buffer lines no
    /// longer name the same cells: column reflow, row resize, alt-screen toggle, history collapse.
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
