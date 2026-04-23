import AppKit

/// File drag-and-drop onto the terminal. Drops N file URLs and pastes
/// the absolute paths, each single-quoted and space-separated, into
/// the session — matching Terminal.app and iTerm2 ergonomics (you can
/// drag a PNG from Finder onto `open ` at the prompt and get
/// `open '/path/to/foo.png'`).
///
/// This extension holds both the NSDraggingDestination overrides
/// (mutating `isDropTargeted` on the class body, which is internal so
/// this file can reach it) and the pure shell-quoting helpers
/// (`shellQuote`, `joinedDroppedPaths`) so DragDropTests can unit-
/// test the formatters without constructing an NSDraggingInfo fake.
extension TerminalView {

    // MARK: - NSDraggingDestination overrides

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggingPasteboardHasFileURLs(sender) else { return [] }
        isDropTargeted = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Re-answer the accepted operation on each move so the OS keeps the
        // copy-cursor badge for the whole hover, not just the initial enter.
        guard draggingPasteboardHasFileURLs(sender) else { return [] }
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTargeted = false
    }

    public override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTargeted = false
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Always clear the ring before returning — whether we accept the
        // drop or not, the drag is over.
        defer { isDropTargeted = false }
        let pb = sender.draggingPasteboard
        let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        // Keep only file-scheme URLs. `readObjects(forClasses: [NSURL.self])`
        // can also return https: URLs from a web-browser drag; those would
        // turn into garbage arguments if we blindly `path`-stringified them.
        let paths = items.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            return url.path
        }
        guard !paths.isEmpty else { return false }
        pasteText(Self.joinedDroppedPaths(paths))
        return true
    }

    // MARK: - Pure helpers (unit-tested via DragDropTests)

    /// Wrap a file path in single quotes using the POSIX `'\''` recipe to
    /// escape any embedded single quote. Single-quoted strings in sh/zsh
    /// suppress *all* metacharacter interpretation (spaces, `$`, backticks,
    /// newlines, globs), so this is safe against arbitrary filesystem
    /// paths including ones that contain quotes.
    ///
    /// Exposed as `static` + `internal` so the unit test can exercise the
    /// pure transform without constructing an NSDraggingInfo fake.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Join N dropped file paths into a single space-separated,
    /// shell-quoted string. Matches Terminal.app / iTerm2 behaviour: no
    /// trailing slash on directories, no trailing newline, no per-file
    /// prompt. The caller feeds the result through `pasteText(_:)` so the
    /// active shell sees a normal paste event (bracketed when the program
    /// has opted in, raw otherwise).
    static func joinedDroppedPaths(_ paths: [String]) -> String {
        paths.map(shellQuote).joined(separator: " ")
    }

    /// Cheap check used by `draggingEntered`/`draggingUpdated` so we don't
    /// light up the accent ring for a drag whose payload we'd reject anyway.
    func draggingPasteboardHasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                       options: options)
    }
}
