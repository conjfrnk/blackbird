import AppKit
import Foundation

enum ClipboardWriter {
    /// Scrubbed like inbound paste; a payload that scrubs to empty is a clipboard clear (OSC 52 ; c ; ST).
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
