import AppKit
import Foundation
import BBCore

/// macOS Services + Look Up + QuickLook integration for `TerminalView`.
/// Split out of `TerminalView+Find.swift` so the find/search engine there
/// isn't interleaved with these unrelated responder-chain concerns
/// (REFACTOR.md Area 3). These overrides expose the current selection to the
/// Services submenu, Look Up (Ctrl-⌘-D / three-finger tap), and QuickLook;
/// without them NSResponder returns nil and macOS hides the Services submenu.
/// `selectedStringForServices` returns the RAW selection (no clipboard scrub)
/// because these paths go through a service-owned NSPasteboard, never the
/// general pasteboard.
extension TerminalView {

    // MARK: - macOS Services + Look Up

    /// Expose the current selection to the Services menu and Look Up
    /// (three-finger tap, Ctrl-⌘-D). Without this override, NSResponder's
    /// default returns nil for our view and macOS hides the Services
    /// submenu entirely. Accepts string-type sends; we never accept
    /// pasteboard-originated changes here (paste still routes through
    /// `paste(_:)` so the TUI's bracketed-paste / sanitizer stays in play).
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == .string, returnType == nil, selectedStringForServices() != nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Called by the Services infrastructure when the user picks
    /// "Services → …" on a selection; writes the selection text onto the
    /// supplied pasteboard so the chosen service can read it.
    /// Part of the informal `NSServicesMenuRequestor` protocol — not an
    /// `NSResponder` override, so no `override` keyword.
    @objc public func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.string), let text = selectedStringForServices() else {
            return false
        }
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    /// The hovered OSC 8 href that a preview surface may display: resolved
    /// against the snapshot on screen and gated by `OSC8URLPolicy`. Nil when
    /// nothing clickable is under the pointer or the href fails policy.
    /// Single entry point so no preview path can re-derive it from the
    /// per-snapshot `hoveredLinkID` and skip the gate.
    func hoveredLinkURLForPreview() -> URL? {
        hoverCoordinator.hoveredLinkURL()
    }

    /// Three-finger tap / Force Touch on the trackpad triggers
    /// `quickLook(with:)` on the responder chain. Preview the current
    /// selection (or the hovered OSC-8 link URL when no selection) in an
    /// NSPopover anchored under the pointer — Ghostty / Safari / Xcode
    /// idiom. Falls back to `super` when nothing useful is under the
    /// pointer so macOS can still offer dictionary lookup / media preview
    /// for other responder hits.
    public override func quickLook(with event: NSEvent) {
        // Priority: selection wins (user picked it explicitly) > hovered
        // OSC-8 URL (already highlighted). Nothing actionable → defer
        // to AppKit's default behaviour (dictionary / None).
        let text: String? = {
            if let sel = selectedStringForServices(), !sel.isEmpty {
                return sel
            }
            // The hovered href, already policy-checked and resolved against the
            // snapshot that is on screen. Previously this re-resolved
            // `hoveredLinkID` against `currentSnapshot` — but link ids are
            // assigned per snapshot, so a stale id could name a *different*
            // URL, and that URL reached `NSTextField` having passed neither
            // `OSC8URLPolicy` nor the credential-redaction / control-character
            // scrub the dwell tooltip applies. Both holes close by asking the
            // coordinator for the href it actually resolved.
            if let url = hoveredLinkURLForPreview() {
                let redacted = OSC8URLPolicy.redactCredentialsForDisplay(url.absoluteString)
                let scrubbed = PasteSanitizer.scrubURLForDisplay(redacted)
                return scrubbed.count > 512 ? String(scrubbed.prefix(512)) + "…" : scrubbed
            }
            return nil
        }()
        guard let text else {
            super.quickLook(with: event)
            return
        }

        // Pointer position for the popover anchor. event.locationInWindow
        // is in window space; convert to view space for the popover's
        // positioning rect.
        let pointInView = convert(event.locationInWindow, from: nil)
        // Anchor a 1-pt rect at the pointer so the popover arrows find
        // a precise spot. AppKit expands as needed to place the popover.
        let anchor = NSRect(origin: pointInView, size: NSSize(width: 1, height: 1))

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 6
        label.preferredMaxLayoutWidth = 420
        label.cell?.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = {
            let vc = NSViewController()
            vc.view = container
            return vc
        }()
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
    }

    /// Selection → String without the clipboard scrubbing step. Services
    /// and Look Up get the raw text: the downstream app may legitimately
    /// want formatting characters the clipboard-sanitizer would strip,
    /// and any bidi overrides won't reach Safari/Mail via this path (it
    /// goes through an NSPasteboard the service owns, then a UI chosen
    /// by the user — we never copy onto the general pasteboard here).
    private func selectedStringForServices() -> String? {
        guard let sel = selection, let session, let snap = currentSnapshot else {
            return nil
        }
        let (start, end) = sel.copyRange(cols: snap.cols)
        let text = session.textRange(from: start, to: end, rectangular: sel.mode == .rectangular)
        return text.isEmpty ? nil : text
    }
}
