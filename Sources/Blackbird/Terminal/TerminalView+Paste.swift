import AppKit
import Foundation
import BBCore

/// Paste pipeline: CRLF normalisation, C0/DEL scrubbing, Unicode
/// bidi-override stripping (Trojan Source defence), bracketed-paste
/// sanitization. Called from two places: the ⌘V menu action via
/// `paste(_:)` on the main class, and the drag-and-drop path via
/// `pasteText(_:)` after file URLs are joined + shell-quoted.
///
/// Why extracted: the paste pipeline is a cluster of pure / mostly-
/// static sanitizers that doesn't touch mutable view state beyond
/// `session.send` and `currentSnapshot.termMode`. Splitting it out
/// keeps the main `TerminalView.swift` focused on event loop +
/// rendering + first-responder glue. Audit K5 — sanitizer bugs are
/// security issues, and a focused file makes them easier to audit.
extension TerminalView {

    // MARK: - Paste

    @objc public func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(str)
    }

    /// Shared paste implementation: applies CRLF normalisation, wraps in
    /// bracketed-paste markers when the app has enabled mode 2004, and sends
    /// to the session. Used by both the menu/keyboard paste action and the
    /// drag-and-drop code path (file URLs are shell-quoted into a single
    /// string which is then fed through here).
    func pasteText(_ text: String) {
        #if DEBUG
        // Test seam: DragDropTests captures the *pre-encoding* pasted
        // string here so it can assert that drop integration produces
        // the expected shell-quoted command-line text. Real PTY bytes
        // are encoded later (CRLF normalisation, control sanitisation,
        // bracketed-paste wrap) — those have separate sanitiser tests;
        // the drop integration only needs the text-level invariant.
        if let recorder = pasteTextRecorderForTests {
            recorder(text)
        }
        #endif
        guard let session else { return }
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }
        let normalized = PasteSanitizer.normalizePasteLineEndings(Data(text.utf8))
        // Strip C0 controls (except TAB/LF) and DEL unconditionally. Pasted
        // payload is "user typing" — Ctrl+C, Ctrl+Z, ESC inside the content
        // can break out of bracketed paste (CVE-2026-26982 class in Ghostty
        // <1.3.0) and execute arbitrary bytes as shell input. The sanitizer
        // replaces blocked bytes with space so column-formatted paste still
        // lines up.
        let cleaned = PasteSanitizer.sanitizePasteControls(normalized)
        // Drop explicit bidi control characters — Trojan Source (Boucher &
        // Anderson 2021). An adversarial webpage / remote can render as
        // `rm -rf harmless` while the copied bytes are `rm -rf ~`, exploiting
        // LRO / RLO overrides to hide the real command. Legitimate RTL
        // (Arabic / Hebrew) text never needs explicit overrides; Unicode
        // bidi algorithm handles it implicitly. Stripping is safe.
        let bytes = PasteSanitizer.stripBidiOverrides(cleaned)
        let bracketedPaste = currentSnapshot?.termMode.contains(.bracketedPaste) ?? false
        if bracketedPaste {
            var wrapped = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC[200~
            wrapped.append(PasteSanitizer.sanitizeBracketedPaste(bytes))
            wrapped.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))  // ESC[201~
            session.send(wrapped)
            return
        }
        // Audit L19. Non-bracketed paste of multi-line content sends LF
        // bytes that the shell treats as Enter — each line executes
        // immediately. A hostile clipboard with `\nrm -rf ~/Desktop\n`
        // is the textbook paste-jacking primitive. Bracketed paste
        // (handled above) protects modern TUIs; this guard catches the
        // unprotected case at a bare shell prompt. Opt-in: default off
        // preserves the long-standing terminal behaviour.
        // Gate also matches lone CR (0x0D): a clipboard like
        // `foo\rbar\rbaz` slips past LF detection but the
        // `convertLoneCRToLF(bytes)` call below turns each `\r` into
        // `\n`, executing each fragment as its own command. Same
        // injection class as LF — keep the warning symmetric.
        if Preferences.shared.confirmMultiLinePaste,
           bytes.contains(0x0A) || bytes.contains(0x0D) {
            let alert = NSAlert()
            alert.messageText = "Paste multiple lines?"
            alert.informativeText = "The clipboard contains line breaks. Each line will execute as a separate command at the shell prompt."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            // App-modal runModal keeps the synchronous control flow we
            // need here; window-modal `beginSheetModal` would force the
            // function into an async / completion-handler shape just to
            // dispatch the send(_:) on the same call site.
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }
        // L4: when the foreground process is in raw / ICRNL-off mode
        // (vim, less, fzf, most TUIs), a lone CR survives to the
        // shell as `\r` and triggers Enter — same injection class as
        // a raw LF from a hostile clipboard. `normalizePasteLineEndings`
        // intentionally leaves lone CR alone (some apps want it as
        // Enter), but bracketed paste protects via the markers; the
        // non-bracketed branch is the exposed surface, so we override
        // that prior decision here only.
        session.send(PasteSanitizer.convertLoneCRToLF(bytes))
    }


}
