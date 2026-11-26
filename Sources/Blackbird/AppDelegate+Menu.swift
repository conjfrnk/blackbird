import AppKit
import SwiftUI

extension AppDelegate {

    // MARK: - Menu

    func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appSubmenu = buildAppMenu()
        // Insert before publishing `mainMenu`; mutating a published menu briefly exposes a half-built App submenu.
        insertSparkleMenuItem(into: appSubmenu)
        appItem.submenu = appSubmenu

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
        // With a custom main menu the responder chain doesn't reliably reach SwiftUI's hidden Settings
        // controller; openSettings(_:) routes through NSApp.sendAction, which does.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        // The Services submenu is only wired up when an item hosts `NSApp.servicesMenu`.
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
        menu.addItem(.separator())
        let export = NSMenuItem(
            title: "Export Scrollback…",
            action: #selector(TerminalView.exportScrollback(_:)),
            keyEquivalent: "s"
        )
        export.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(export)
        return menu
    }

    private func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        menu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        // ⌘-prefixed key events are handed to super at keyDown, so ⌘F / ⌘G / ⌘⇧G only arrive as menu actions.
        let findSubmenu = NSMenu(title: "Find")
        // Not `performFindPanelAction:`: the NSTextView field editor implements it, becomes the target
        // and greys ⌘F out. No AppKit responder implements `showFindBar:`.
        findSubmenu.addItem(
            withTitle: "Find…",
            action: #selector(TerminalView.showFindBar(_:)),
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
        let useSelection = NSMenuItem(
            title: "Use Selection for Find",
            action: #selector(TerminalView.useSelectionForFind(_:)),
            keyEquivalent: "e"
        )
        findSubmenu.addItem(useSelection)
        let replaceSelection = NSMenuItem(
            title: "Replace Selection",
            action: #selector(TerminalView.performReplaceCurrent(_:)),
            keyEquivalent: "e"
        )
        replaceSelection.keyEquivalentModifierMask = [.command, .option]
        findSubmenu.addItem(replaceSelection)
        findSubmenu.addItem(.separator())
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
        menu.addItem(
            withTitle: "Clear Buffer",
            action: #selector(TerminalView.clearBufferAndScrollback(_:)),
            keyEquivalent: "k"
        )
        return menu
    }

    private func buildViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        // The "+" key equivalent fires on ⌘⇧= on most layouts.
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

        // ⌃⌘R, not ⌥⌘R: Edit ▸ Find ▸ Regular Expression claims ⌥⌘R and AppKit searches Edit first.
        let rename = NSMenuItem(
            title: "Rename Tab…",
            action: #selector(MainWindowController.renameActiveTab(_:)),
            keyEquivalent: "r"
        )
        rename.keyEquivalentModifierMask = [.command, .control]
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

        let nextTabCtrl = NSMenuItem(
            title: "Show Next Tab",
            action: #selector(NSWindow.selectNextTab(_:)),
            keyEquivalent: "\t"
        )
        nextTabCtrl.keyEquivalentModifierMask = [.control]
        menu.addItem(nextTabCtrl)

        let prevTabCtrl = NSMenuItem(
            title: "Show Previous Tab",
            action: #selector(NSWindow.selectPreviousTab(_:)),
            keyEquivalent: "\t"
        )
        prevTabCtrl.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(prevTabCtrl)

        menu.addItem(.separator())

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
