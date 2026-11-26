import AppKit
import Foundation
import BBCore

extension TerminalView {

    // MARK: - Paste

    @objc public func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(str)
    }

    func pasteText(_ text: String) {
        #if DEBUG
        if let recorder = pasteTextRecorderForTests {
            recorder(text)
        }
        #endif
        guard let session else { return }
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }
        let normalized = PasteSanitizer.normalizePasteLineEndings(Data(text.utf8))
        // C0 controls (except TAB/LF) and DEL are stripped unconditionally: ESC or Ctrl+C
        // inside the payload can break out of bracketed paste and run as shell input.
        let cleaned = PasteSanitizer.sanitizePasteControls(normalized)
        // Explicit bidi overrides are dropped (Trojan Source); legitimate RTL text never needs them.
        let bytes = PasteSanitizer.stripBidiOverrides(cleaned)
        let bracketedPaste = currentSnapshot?.termMode.contains(.bracketedPaste) ?? false
        if bracketedPaste {
            var wrapped = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC[200~
            wrapped.append(PasteSanitizer.sanitizeBracketedPaste(bytes))
            wrapped.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))  // ESC[201~
            session.send(wrapped)
            return
        }
        if Preferences.shared.confirmMultiLinePaste,
           bytes.contains(0x0A) || bytes.contains(0x0D) {
            let alert = NSAlert()
            alert.messageText = "Paste multiple lines?"
            alert.informativeText = "The clipboard contains line breaks. Each line will execute as a separate command at the shell prompt."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Paste")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }
        // Line breaks go out as CR, as Return does: raw-mode programs that bind only CR to
        // Enter (the macOS built-in nano reads ^J as Justify) would mangle LF.
        session.send(PasteSanitizer.convertLFToCR(bytes))
    }

}
