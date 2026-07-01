import AppKit
import Foundation

/// The one place the app writes a remote-shell-controlled string to the system
/// clipboard (OSC 52). Lifted out of `TerminalSession` so the session model no
/// longer reaches up into AppKit's `NSPasteboard` directly (REFACTOR.md Area 4:
/// "layering inversion — the model reaches up into the AppKit view +
/// NSPasteboard for clipboard scrubbing"). The session keeps the policy gates
/// (OSC 52 enabled, oversize) and hands a vetted payload here.
enum ClipboardWriter {
    /// Write an OSC 52 payload to `NSPasteboard.general`, scrubbed
    /// symmetrically with inbound paste. A compromised remote would otherwise
    /// push a Trojan-Source blob or raw ESC sequences into the user's system
    /// clipboard — invisible to Blackbird's own paste scrubber because that
    /// runs on *inbound* paste, not on the write side. Symmetric treatment:
    /// anything dirty enough to strip on paste-in is dirty enough to strip on
    /// paste-out. A payload that scrubs to empty is treated as a
    /// clipboard-clear (OSC 52 ; c ; ST).
    static func writeOSC52(_ text: String) {
        let data = Data(text.utf8)
        let scrubbed = PasteSanitizer.stripBidiOverrides(
            PasteSanitizer.sanitizePasteControls(data)
        )
        let clean = String(decoding: scrubbed, as: UTF8.self)
        let pb = NSPasteboard.general
        pb.clearContents()
        if !clean.isEmpty {
            pb.setString(clean, forType: .string)
        }
    }
}
