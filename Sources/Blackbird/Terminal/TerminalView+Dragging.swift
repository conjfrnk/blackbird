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
        //
        // Bug #20: NSPasteboard's URL reader can hand back a URL whose
        // backing string was already symlink-resolved by the kernel
        // (Finder favorites pointing at /etc, network-mount aliases that
        // were canonicalised at NSURL bookmark resolution time). Drop a
        // symlink that targets `/etc/passwd` and the shell's history
        // would record the resolved target rather than the link the
        // user actually dragged. We can't recover the link string in the
        // leaky case (kernel-side lookup is destructive), but we *can*
        // guarantee we never double-resolve here. `standardizedFileURL`
        // and `resolvingSymlinksInPath` are intentionally NOT used: both
        // eagerly call `realpath`, which IS the bug. Using `url.path`
        // directly preserves the link path on healthy drags.
        let paths = items.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            return Self.sanitizeDropPath(url.path)
        }
        return performDropOfPaths(paths)
    }

    /// Test seam for `performDragOperation`. Splits the
    /// gate-and-paste decision from the NSDraggingInfo decoding so unit
    /// tests can drive the same behaviour without constructing an
    /// `NSDraggingInfo` fake (the protocol is non-trivially mockable —
    /// AppKit treats it specially and synthesised conformers crash on
    /// the framework's internal `_concreteDraggingInfo` lookup).
    ///
    /// Returns whether bytes reached the session: false when `paths`
    /// is empty, true when a paste was issued. Invariants:
    /// - `paths` is the already-shell-quote-input list (link strings,
    ///   not realpath-resolved targets) — caller is responsible for
    ///   the symlink-leak guard.
    /// - On the empty-paths early return, no bytes are written to the
    ///   PTY recorder or the session.
    /// - On accept, IME composition is cleared *before* paste so the
    ///   preedit overlay can't render over the dropped path (Bug #21).
    @discardableResult
    func performDropOfPaths(_ paths: [String]) -> Bool {
        // The drop is forwarded to whoever owns the TTY — shell at a
        // prompt, or a running foreground child like claude / python /
        // psql / irb / vim insert mode. This matches Terminal.app and
        // iTerm2: the user explicitly initiated the drop, so route the
        // bytes to the active reader and let the user judge fit. An
        // earlier version of this method (Bug #19) refused drops while
        // any foreground child existed — that broke every interactive
        // REPL, including Claude Code itself, where dragging in an
        // image path is a primary workflow.
        guard !paths.isEmpty else { return false }

        // Bug #21: drop any pending IME composition before the path bytes
        // hit the PTY. Otherwise the preedit overlay (a CALayer-backed
        // subview at the cursor) keeps rendering above the freshly-pasted
        // text — visual confusion, and the next IME keystroke commits the
        // stale preedit on top of the path. `discardCompositionOnResignKey`
        // is the existing helper that pairs
        // `inputContext?.discardMarkedText()` with our own `unmarkText()`,
        // so the system input context and our local `composition` slot
        // stay in sync.
        discardCompositionOnResignKey()

        pasteText(PasteSanitizer.joinedDroppedPaths(paths))
        return true
    }

    // MARK: - Pure helpers (unit-tested via DragDropTests)


    /// Strip C0 control bytes (0x00–0x1F) and DEL (0x7F) from a dropped
    /// URL's path before passing it to `shellQuote`. CVE-class fix:
    ///
    /// HFS+/APFS filenames legally contain LF (0x0A) and CR (0x0D). A
    /// hostile pasteboard provider — a sandboxed peer app, or a
    /// synthesised drop from a script using NSPasteboard APIs — can
    /// hand us a `file://` URL whose path is `/tmp/x\nrm -rf ~`.
    /// `shellQuote` wraps that in single quotes (`'/tmp/x\nrm -rf ~'`),
    /// but the LF byte survives the wrap unchanged. Downstream,
    /// `pasteText` runs `sanitizePasteControls`, which **whitelists
    /// 0x0A** as legitimate paste content (correct for user-typed
    /// paste from `pbpaste`-style flows). `convertLoneCRToLF`
    /// preserves the LF, the shell sees Enter, and the bytes after
    /// the newline execute as a fresh command. One drag → arbitrary
    /// command execution.
    ///
    /// The drag-drop path is *data*, not user-typed paste — the user
    /// never typed a literal newline into a Finder filename. The
    /// `sanitizePasteControls` whitelist for LF/CR doesn't apply here;
    /// strip every C0 control plus DEL up-front so the post-quote
    /// payload can't carry an Enter to the shell. TAB (0x09) is also
    /// in C0 but real filenames are exceptionally unlikely to need it
    /// and a TAB at the shell prompt triggers tab-completion — strip
    /// it too.
    static func sanitizeDropPath(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            let v = scalar.value
            // Strip C0 controls (0x00–0x1F) and DEL (0x7F).
            if v < 0x20 || v == 0x7F { return false }
            // Strip bidi / zero-width / invisible scalars. A pasteboard
            // provider (sandboxed peer / web drag) can hand a `file://`
            // URL whose path contains U+202E RIGHT-TO-LEFT OVERRIDE —
            // the pasted line displays as `'/tmp/jpg.bad.jpg'` while
            // the shell actually opens the byte-order-flipped real
            // path. Same Trojan-source-class smuggling as the
            // DiagnosticsView Copy path. This set mirrors
            // `TerminalView+Paste.stripBidiOverrides`. Audit S4-014.
            //
            // Variation Selectors (VS1-16 U+FE00–FE0F, VS17-256
            // U+E0100–E01EF) are deliberately NOT in this set. They only
            // alter how the immediately-preceding visible glyph renders
            // — they cannot reorder text, escape the single quotes that
            // `shellQuote` wraps the path in, or inject a control byte —
            // so they carry none of the Trojan-source risk above. They
            // ARE a legitimate, common part of real filenames: APFS
            // stores names as raw UTF-8 (no normalization) and macOS
            // users routinely name files with emoji that decompose to
            // base + U+FE0F (❤️, ⭐️, 1️⃣, …). Stripping them turned a
            // dragged `❤️.png` into a non-existent `❤.png`, pasting a
            // command the shell can't resolve. fix-#16 added them on the
            // wrong assumption that "legitimate writers emit only
            // printable ASCII" — false for filenames. The diagnostics
            // display-scrubber (`DiagnosticsView.stripControlCharacters`)
            // intentionally still strips VS: it scrubs an untrusted
            // crash-log file purely for safe display, where exact glyph
            // fidelity is not a goal — the opposite trade-off from this
            // user-chosen path. Do not re-add VS here for "lockstep".
            if v == 0x00AD                          // soft hyphen
                || v == 0x061C                      // Arabic Letter Mark
                || v == 0x180E                      // Mongolian Vowel Sep
                || (v >= 0x200B && v <= 0x200F)     // ZWSP/ZWNJ/ZWJ/LRM/RLM
                || (v >= 0x2028 && v <= 0x202E)     // LS/PS + bidi formatting
                || v == 0x2060                      // Word Joiner
                || (v >= 0x2066 && v <= 0x2069)     // bidi isolates
                || v == 0xFEFF                      // BOM / ZW no-break space
                || (v >= 0xE0000 && v <= 0xE007F)   // Plane-14 tag block
            { return false }
            return true
        })
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
