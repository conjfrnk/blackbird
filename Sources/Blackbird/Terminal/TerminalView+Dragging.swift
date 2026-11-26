import AppKit

extension TerminalView {

    // MARK: - NSDraggingDestination overrides

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggingPasteboardHasFileURLs(sender) else { return [] }
        isDropTargeted = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
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
        defer { isDropTargeted = false }
        let pb = sender.draggingPasteboard
        let items = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        // Use `url.path` as-is: `standardizedFileURL` and `resolvingSymlinksInPath` call
        // `realpath`, which pastes a symlink's target instead of the link that was dragged.
        let paths = items.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            return Self.sanitizeDropPath(url.path)
        }
        return performDropOfPaths(paths)
    }

    @discardableResult
    func performDropOfPaths(_ paths: [String]) -> Bool {
        // Not gated on a foreground child: REPLs and TUIs take dropped paths too.
        guard !paths.isEmpty else { return false }

        // Discard IME composition first, or the next IME keystroke commits the stale preedit onto the path.
        discardCompositionOnResignKey()

        pasteText(PasteSanitizer.joinedDroppedPaths(paths))
        return true
    }

    // MARK: - Pure helpers

    /// Strips C0 controls and DEL before quoting: HFS+/APFS filenames may contain LF and CR, which
    /// survive single quotes, pass the paste sanitizer's LF whitelist and reach the shell as Enter.
    static func sanitizeDropPath(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            let v = scalar.value
            if v < 0x20 || v == 0x7F { return false }
            // Variation selectors and ZWNJ/ZWJ are deliberately not stripped: real filenames (emoji, Persian)
            // contain them, and they cannot reorder text or escape the quotes.
            if v == 0x00AD                          // soft hyphen
                || v == 0x061C                      // Arabic Letter Mark
                || v == 0x180E                      // Mongolian Vowel Sep
                || v == 0x200B                      // ZWSP
                || v == 0x200E || v == 0x200F       // LRM/RLM
                || (v >= 0x2028 && v <= 0x202E)     // LS/PS + bidi formatting
                || v == 0x2060                      // Word Joiner
                || (v >= 0x2066 && v <= 0x2069)     // bidi isolates
                || v == 0xFEFF                      // BOM / ZW no-break space
                || (v >= 0xE0000 && v <= 0xE007F)   // Plane-14 tag block
            { return false }
            return true
        })
    }

    func draggingPasteboardHasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                       options: options)
    }
}
