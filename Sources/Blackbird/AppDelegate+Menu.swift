import AppKit
import SwiftUI

/// Main-menu construction for `AppDelegate`. Extracted from `App.swift`
/// (which had grown to ~720 lines covering startup, controllers, tab
/// actions, Sparkle plumbing, AND the whole menu tree). Menu code only
/// depends on `AppDelegate`'s public selectors plus shared plist-
/// derived constants — pure view layer, no state.
///
/// Kept as an extension on `AppDelegate` rather than a standalone
/// builder type so the `#selector(...)` targets continue to resolve
/// against `self` without a delegate hop. The extension lives in the
/// same module so file private visibility and `Self` references
/// continue to work across the split.
extension AppDelegate {

    // MARK: - Menu

    /// Install the application's main menu. Internal so the
    /// `applicationDidFinishLaunching` path in `App.swift` can call it
    /// across the file boundary — `private` would be scoped to this
    /// extension only.
    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        appItem.submenu = buildAppMenu()

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        fileItem.submenu = buildFileMenu()

        let editItem = NSMenuItem()
        main.addItem(editItem)
        editItem.submenu = buildEditMenu()

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        viewItem.submenu = buildViewMenu()

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        windowItem.submenu = buildWindowMenu()

        NSApplication.shared.mainMenu = main
    }

    private func buildAppMenu() -> NSMenu {
        let menu = NSMenu(title: "Blackbird")
        menu.addItem(
            withTitle: "About Blackbird",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        // SwiftUI's Settings scene registers a hidden controller that handles
        // `showSettingsWindow:`. With @NSApplicationDelegateAdaptor + a fully
        // custom main menu, the responder chain doesn't reliably reach that
        // controller (NSApp isn't a handler, and the hidden SwiftUI controller
        // isn't in the chain). Route via AppDelegate.openSettings(_:) which
        // calls NSApp.sendAction — sendAction IS what correctly dispatches
        // to SwiftUI's registered selector handler. Fallback covers older
        // macOS that still uses `showPreferencesWindow:`.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        // Services submenu. TerminalView conforms to NSServicesMenuRequestor
        // so individual services (Dictionary, Open URL, system translate,
        // third-party text tools) can read the current selection. Without
        // this item the submenu doesn't get wired up — the protocol
        // conformance is live but no user-accessible entry point. Audit
        // app-entry F3. `servicesMenu` is a full NSMenu NSApp owns; we
        // just need an item to host it.
        let servicesItem = NSMenuItem(
            title: "Services",
            action: nil,
            keyEquivalent: ""
        )
        let servicesSubmenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesSubmenu
        menu.addItem(servicesItem)
        NSApp.servicesMenu = servicesSubmenu
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Blackbird",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Blackbird",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        return menu
    }

    private func buildFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(
            withTitle: "New Window",
            action: #selector(newWindow(_:)),
            keyEquivalent: "n"
        )
        menu.addItem(
            withTitle: "New Tab",
            action: #selector(newWindowForTab(_:)),
            keyEquivalent: "t"
        )
        return menu
    }

    private func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        // Selectors route to first responder. TerminalView will wire these
        // in Plan 6 (selection + copy/paste). Present now so Mac users see
        // the expected menu items.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // Find submenu. Without an explicit menu entry, AppKit won't map
        // ⌘F / ⌘G / ⌘⇧G to TerminalView's performFind*Action selectors —
        // the custom first responder only receives menu-dispatched actions,
        // not raw key events (those are filtered as ⌘-prefixed at keyDown
        // and handed to super).
        let findSubmenu = NSMenu(title: "Find")
        findSubmenu.addItem(
            withTitle: "Find…",
            action: #selector(TerminalView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        let findNext = NSMenuItem(
            title: "Find Next",
            action: #selector(TerminalView.performFindNextAction(_:)),
            keyEquivalent: "g"
        )
        findSubmenu.addItem(findNext)
        let findPrev = NSMenuItem(
            title: "Find Previous",
            action: #selector(TerminalView.performFindPreviousAction(_:)),
            keyEquivalent: "G"
        )
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findSubmenu.addItem(findPrev)
        let replaceSelection = NSMenuItem(
            title: "Replace Selection",
            action: #selector(TerminalView.performReplaceCurrent(_:)),
            keyEquivalent: "e"
        )
        replaceSelection.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(replaceSelection)
        findSubmenu.addItem(.separator())
        // ⌘⌥C toggles case-sensitive find, ⌘⌥R toggles regex mode.
        // Matches iTerm2 Find's equivalents; visible in the placeholder
        // when enabled. Routes through the responder chain to the focused
        // TerminalView's findBar (target=nil).
        let caseToggle = NSMenuItem(
            title: "Find: Case Sensitive",
            action: #selector(TerminalView.toggleFindCaseSensitive(_:)),
            keyEquivalent: "c"
        )
        caseToggle.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(caseToggle)
        let regexToggle = NSMenuItem(
            title: "Find: Regular Expression",
            action: #selector(TerminalView.toggleFindRegex(_:)),
            keyEquivalent: "r"
        )
        regexToggle.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(regexToggle)
        let findParent = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        findParent.submenu = findSubmenu
        menu.addItem(findParent)
        menu.addItem(.separator())
        // ⌘K clears viewport + scrollback. Action is dispatched via the
        // responder chain (target = nil) so the focused TerminalView handles it.
        menu.addItem(
            withTitle: "Clear Buffer",
            action: #selector(TerminalView.clearBufferAndScrollback(_:)),
            keyEquivalent: "k"
        )
        return menu
    }

    private func buildViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // ⌘+/⌘-/⌘0 adjust font size. The "+" key equivalent actually fires
        // on ⌘⇧= on most layouts; spelling it as "+" with the default command
        // mask matches what users expect to see in the menu and what AppKit
        // matches against the incoming keyDown.
        let biggerItem = NSMenuItem(
            title: "Bigger Text",
            action: #selector(TerminalView.increaseFontSize(_:)),
            keyEquivalent: "+"
        )
        biggerItem.keyEquivalentModifierMask = [.command]
        menu.addItem(biggerItem)

        let smallerItem = NSMenuItem(
            title: "Smaller Text",
            action: #selector(TerminalView.decreaseFontSize(_:)),
            keyEquivalent: "-"
        )
        smallerItem.keyEquivalentModifierMask = [.command]
        menu.addItem(smallerItem)

        let resetItem = NSMenuItem(
            title: "Actual Size",
            action: #selector(TerminalView.resetFontSize(_:)),
            keyEquivalent: "0"
        )
        resetItem.keyEquivalentModifierMask = [.command]
        menu.addItem(resetItem)

        menu.addItem(.separator())

        // Prompt navigation — walks the OSC 133 A marks recorded by
        // TerminalSession whenever the user's shell integration snippet
        // emits a prompt-start escape. Matches iTerm2's ⌘⇧↑ / ⌘⇧↓
        // convention so muscle memory carries over. No-op when no marks
        // have been recorded (shell integration not sourced).
        let prevPrompt = NSMenuItem(
            title: "Previous Prompt",
            action: #selector(TerminalView.jumpToPreviousPrompt(_:)),
            keyEquivalent: "\u{F700}" // NSUpArrowFunctionKey
        )
        prevPrompt.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevPrompt)

        let nextPrompt = NSMenuItem(
            title: "Next Prompt",
            action: #selector(TerminalView.jumpToNextPrompt(_:)),
            keyEquivalent: "\u{F701}" // NSDownArrowFunctionKey
        )
        nextPrompt.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextPrompt)

        menu.addItem(.separator())

        // Rename Tab… — routes via the responder chain to the key window's
        // MainWindowController. Uses ⌥⌘R because ⌘R is commonly a
        // refresh/reload shortcut in other apps, and we want to leave it
        // free for shells that bind it (zsh's history-incremental-search-
        // backward, for instance, is sometimes mapped to Ctrl-R — but
        // ⌘-R would still reach us first).
        let rename = NSMenuItem(
            title: "Rename Tab…",
            action: #selector(MainWindowController.renameActiveTab(_:)),
            keyEquivalent: "r"
        )
        rename.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(rename)
        return menu
    }

    private func buildWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        let closeWindow = NSMenuItem(
            title: "Close Window",
            action: #selector(closeWindow(_:)),
            keyEquivalent: "W"
        )
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(closeWindow)
        menu.addItem(.separator())

        // Next / previous tab — AppKit handles these natively on tab-grouped
        // windows; wiring them here ensures they appear in the menu and are
        // discoverable via ⌘⇧] / ⌘⇧[.
        let nextTab = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            keyEquivalent: "]"
        )
        nextTab.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(nextTab)

        let prevTab = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            keyEquivalent: "["
        )
        prevTab.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(prevTab)

        menu.addItem(.separator())

        // ⌘1-9 jump to a specific tab by position.
        for i in 1...9 {
            let item = NSMenuItem(
                title: "Tab \(i)",
                action: #selector(selectTab(_:)),
                keyEquivalent: String(i)
            )
            item.tag = i
            menu.addItem(item)
        }

        NSApplication.shared.windowsMenu = menu
        return menu
    }
}
