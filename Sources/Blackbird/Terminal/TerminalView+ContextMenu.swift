import AppKit
import Foundation
import BBCore

/// Right-click context menu + menu-item validation for `TerminalView`.
/// Split out of `TerminalView+Find.swift` so the find/search engine there
/// isn't interleaved with this responder concern (REFACTOR.md Area 3).
/// `menu(for:)` surfaces Open-Link / Copy-Link items when the right-click
/// lands on a resolvable URL (OSC 8 first, regex fallback; the anti-phishing
/// gate offers a deliberate Copy-only for a host-divergent OSC 8 link), then
/// the standard Copy / Paste. `validateMenuItem` enables/disables the app
/// menu's edit / find / prompt-nav / font items against the live selection,
/// snapshot, session, and match state.
extension TerminalView {

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):                      return selection != nil
        case #selector(selectAll(_:)):                 return currentSnapshot != nil
        case #selector(paste(_:)):
            // Paste needs BOTH a session to receive the bytes AND string
            // content on the pasteboard. Before this check, a paste on a
            // view with no session silently dropped the clipboard content
            // instead of clearly disabling the menu item.
            // Audit terminal-view-2 F13.
            return session != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(performFindPanelAction(_:)):    return currentSnapshot != nil
        case #selector(performFindNextAction(_:)):     return !findController.findMatches.isEmpty
        case #selector(performFindPreviousAction(_:)): return !findController.findMatches.isEmpty
        case #selector(toggleFindCaseSensitive(_:)):
            item.state = (findController.findBar?.options.caseSensitive == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(toggleFindRegex(_:)):
            item.state = (findController.findBar?.options.regex == true) ? .on : .off
            return currentSnapshot != nil
        case #selector(clearBufferAndScrollback(_:)):  return session != nil
        case #selector(jumpToPreviousPrompt(_:)),
             #selector(jumpToNextPrompt(_:)):
            // Same pattern: disabling until OSC 133 marks exist is more
            // honest than beeping on every press.
            return (session?.promptMarks.isEmpty == false)
        case #selector(increaseFontSize(_:)),
             #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)): return session != nil
        default:                                       return true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        // Surface "Open Link" / "Copy Link" when the right-click lands on
        // a resolvable URL (OSC 8 hyperlink or regex-detected). Safari-
        // parity affordance; without it users can only reach URLs via
        // ⌘-click which is hidden UI. Audit terminal-view-2 F27.
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
            // The ⌘-click anti-phishing gate blocks this OSC 8 link because the
            // visible anchor's host differs from the href. Offer a deliberate,
            // clearly-labelled COPY (not open) so a legitimate divergent link
            // isn't permanently unreachable — the user pastes into the browser
            // and sees the real destination host before committing.
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
