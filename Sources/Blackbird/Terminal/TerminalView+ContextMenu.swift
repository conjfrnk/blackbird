import AppKit
import Foundation
import BBCore

extension TerminalView: NSMenuItemValidation {

    // The conformance is required: a plain Swift method is not @objc, so without it
    // NSMenu never calls this and every item targeting the view is auto-enabled.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):                      return selection != nil
        case #selector(selectAll(_:)):                 return currentSnapshot != nil
        case #selector(paste(_:)):
            // Presence-only: `availableType` does not decode the payload.
            return session != nil && NSPasteboard.general.availableType(from: [.string]) != nil
        case #selector(performFindPanelAction(_:)),
             #selector(showFindBar(_:)):               return currentSnapshot != nil
        case #selector(performFindNextAction(_:)),
             #selector(performFindPreviousAction(_:)):
            // Gate on an active search, not a non-empty match cache: a rescan empties `findMatches`
            // transiently, and a disabled item would drop a ⌘G that `advanceFind` would have deferred.
            let find = findController
            return !find.findMatches.isEmpty || (find.findBar != nil && !find.findQuery.isEmpty)
        case #selector(toggleFindCaseSensitive(_:)):
            item.state = (findController.findBar?.options.caseSensitive == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(toggleFindRegex(_:)):
            item.state = (findController.findBar?.options.regex == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(clearBufferAndScrollback(_:)):  return session != nil
        case #selector(jumpToPreviousPrompt(_:)),
             #selector(jumpToNextPrompt(_:)):
            return (session?.promptMarks.isEmpty == false)
        case #selector(increaseFontSize(_:)),
             #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)): return session != nil
        default:                                       return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let p = bufferPointFromEvent(event)
        let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
        if let url = resolveClickURL(screenRow: screenRow, col: p.col) {
            let openItem = NSMenuItem(title: "Open Link",
                                      action: #selector(openResolvedLink(_:)),
                                      keyEquivalent: "")
            openItem.target = self
            openItem.representedObject = url
            let copyLinkItem = NSMenuItem(title: "Copy Link",
                                          action: #selector(copyResolvedLink(_:)),
                                          keyEquivalent: "")
            copyLinkItem.target = self
            copyLinkItem.representedObject = url
            m.addItem(openItem)
            m.addItem(copyLinkItem)
            m.addItem(NSMenuItem.separator())
        } else if let blockedHref = blockedDivergentOSC8Href(screenRow: screenRow, col: p.col) {
            // An OSC 8 link whose visible host differs from its href: offer copy only, never open.
            let copyMismatch = NSMenuItem(title: "Copy Link (host mismatch)",
                                          action: #selector(copyResolvedLink(_:)),
                                          keyEquivalent: "")
            copyMismatch.target = self
            copyMismatch.representedObject = blockedHref
            m.addItem(copyMismatch)
            m.addItem(NSMenuItem.separator())
        }
        let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        copyItem.target = self
        pasteItem.target = self
        m.addItem(copyItem)
        m.addItem(pasteItem)
        return m
    }

    @objc private func openResolvedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        urlOpener.open(url)
    }

    @objc private func copyResolvedLink(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.absoluteString, forType: .string)
    }
}

/// AppKit swallows Ctrl+Return (it opens the context menu and skips `keyDown`); the interceptor forwards it here.
extension TerminalView: ContextMenuKeyReceiving {
    func receiveContextMenuChord(_ event: NSEvent) -> Bool {
        guard session != nil else { return false }
        keyDown(with: event)
        return true
    }
}
