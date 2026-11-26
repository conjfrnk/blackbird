import AppKit
import Foundation
import BBCore

extension TerminalView {

    // MARK: - macOS Services + Look Up

    /// Without this override NSResponder returns nil and macOS hides the Services submenu.
    public override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // AppKit asks on every menu open, once per service: keep this O(1) and off the core queue.
        if sendType == .string, returnType == nil,
           selection != nil, session != nil, currentSnapshot != nil {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Part of the informal `NSServicesMenuRequestor` protocol, not an `NSResponder` override.
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

    /// The only source of a hovered href for preview surfaces. Link ids are assigned per snapshot,
    /// so re-resolving `hoveredLinkID` can name a different URL and skips the `OSC8URLPolicy` gate.
    func hoveredLinkURLForPreview() -> URL? {
        hoverCoordinator.hoveredLinkURL()
    }

    public override func quickLook(with event: NSEvent) {
        let text: String? = {
            if let sel = selectedStringForServices(), !sel.isEmpty {
                return TerminalView.lookUpPreviewText(sel)
            }
            if let url = hoveredLinkURLForPreview() {
                return HoverCoordinator.displayString(forHref: url.absoluteString)
            }
            return nil
        }()
        guard let text else {
            super.quickLook(with: event)
            return
        }

        let pointInView = convert(event.locationInWindow, from: nil)
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

    /// `NSTextField.maximumNumberOfLines` is not honoured for text with hard newlines: the label
    /// would typeset the whole selection synchronously, so truncate before handing it over.
    static func lookUpPreviewText(
        _ text: String, maxLines: Int = 6, maxCharacters: Int = 2_000
    ) -> String {
        var lines = 1
        var characters = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isNewline {
                lines += 1
                if lines > maxLines { return String(text[..<index]) + "\n…" }
            }
            characters += 1
            if characters > maxCharacters { return String(text[..<index]) + "…" }
            index = text.index(after: index)
        }
        return text
    }

    /// Raw, without the clipboard scrub: it goes to a service-owned pasteboard, never the general one.
    func selectedStringForServices() -> String? {
        guard let sel = selection, let session, let snap = currentSnapshot else {
            return nil
        }
        guard let text = session.selectedText(sel, displayedIn: snap), !text.isEmpty else {
            return nil
        }
        return text
    }
}
