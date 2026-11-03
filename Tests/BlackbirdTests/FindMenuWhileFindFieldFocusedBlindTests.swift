import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind behaviour tests for "menus-3": Edit > Find > "Find..." (Cmd-F) must
/// stay usable while the find bar's own text field has keyboard focus.
///
/// Contract under test (macOS conventions; Safari, Terminal.app):
///   - With the find bar open and the QUERY field focused, the user's second
///     Cmd-F is a live command: the "Find..." item is ENABLED, and invoking it
///     re-selects the whole query text (so typing replaces it) while leaving
///     the bar open and the focus in the query field.
///   - With the REPLACE field focused, the "Find..." item is likewise ENABLED
///     (it must not be greyed because a field editor happens to be the first
///     responder).
///   - Control: with the terminal view itself focused, the item is enabled.
///
/// **How the menu is driven.** The item under test is the REAL "Find..." item
/// of the real main menu (`AppDelegate().installMainMenu()`, the same way
/// `CmdLetterInterceptMatrixTests` builds it), located by its Cmd-F key
/// equivalent, so the test follows whatever action / target the app wires.
/// AppKit resolves a `nil`-target item by walking the KEY window's responder
/// chain from the first responder; a headless, never-shown window cannot be
/// key (and showing / closing windows destabilises this xctest host), so the
/// harness performs the same walk by hand against the test window's first
/// responder (`responds(to:)` on each responder, then window delegate, app,
/// app delegate), and then lets AppKit itself decide enabled / disabled with
/// a real auto-enabling `NSMenu.update()` against that target, once with the
/// item seeded enabled and once seeded disabled (the two must agree, so a
/// validation pass that never ran cannot pass vacuously). Dispatch uses
/// `NSApp.sendAction(_:to:from:)` with the resolved target, and only when the
/// menu validated the item enabled -- exactly what a real Cmd-F does.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`): one
/// 640 x 240 `NSWindow` per test (never shown, never closed, parked for the
/// process lifetime), one 640 x 240 headless `TerminalView`, one 40 x 6
/// `BBTerm` (240 cells, scrollback 16). No PTY, no `MainWindowController`, no
/// runloop pumping, no timers waited on, no key / CGEvent injection. Each test
/// well under 1 s.
@MainActor
final class FindMenuWhileFindFieldFocusedBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private static let query = "alpha"
    private static let replacement = "repl-marker"

    /// Windows are parked UNTOUCHED for process lifetime (never shown, never
    /// closed, never ordered out), per the repo's CA-transaction SEGV rule.
    private static var parkedWindows: [NSWindow] = []

    private var savedMainMenu: NSMenu?

    override func setUpWithError() throws {
        savedMainMenu = NSApplication.shared.mainMenu
        AppDelegate().installMainMenu()
    }

    override func tearDownWithError() throws {
        NSApplication.shared.mainMenu = savedMainMenu
        savedMainMenu = nil
    }

    // MARK: - Rig

    private struct Rig {
        let window: NSWindow
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
    }

    /// A never-shown window whose content view is a headless `TerminalView`
    /// with a live snapshot and an attached headless session (the view's own
    /// menu validation requires a snapshot). `session` is weak on the view, so
    /// the strong reference in `Rig` is load-bearing.
    private func makeRig() throws -> Rig {
        let device = try requireMetalDevice()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 240),
            device: device
        )
        window.contentView = view
        Self.parkedWindows.append(window)

        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
            "BBTerm init failed"
        )
        term.input("alpha one\r\nbeta\r\nalpha two\r\n")
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil")
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        return Rig(window: window, view: view, term: term, session: session)
    }

    private struct OpenBar {
        let bar: FindBar
        let queryField: NSTextField
        let replaceField: NSTextField
    }

    private func editableFields(in root: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        for sub in root.subviews {
            if let tf = sub as? NSTextField, tf.isEditable { out.append(tf) }
            out.append(contentsOf: editableFields(in: sub))
        }
        return out
    }

    /// The user's first Cmd-F: opens the bar through the production entry
    /// point, then seeds a query and a replacement and exposes the two fields.
    private func openFindBar(_ rig: Rig) throws -> OpenBar {
        rig.view.performFindPanelAction(nil)
        let bar = try XCTUnwrap(rig.view.findController.findBar,
                                "precondition: the first Cmd-F must install the find bar")
        XCTAssertTrue(bar.window === rig.window,
                      "precondition: the find bar must live in the test window")
        bar.setQuery(Self.query)
        bar.setReplaceVisible(true)
        bar._setReplaceFieldStringForTests(Self.replacement)
        let fields = editableFields(in: bar)
        let q: NSTextField = try XCTUnwrap(
            fields.first(where: { (f: NSTextField) -> Bool in f.stringValue == Self.query }),
            "precondition: a find-bar text field holds the query; editable fields: \(fields.map({ (f: NSTextField) -> String in f.stringValue }))"
        )
        let r: NSTextField = try XCTUnwrap(
            fields.first(where: { (f: NSTextField) -> Bool in f.stringValue == Self.replacement }),
            "precondition: a find-bar text field holds the replacement; editable fields: \(fields.map({ (f: NSTextField) -> String in f.stringValue }))"
        )
        XCTAssertFalse(q === r, "precondition: query and replace fields are different views")
        return OpenBar(bar: bar, queryField: q, replaceField: r)
    }

    /// The window's first responder as the field editor of `field`, or nil.
    private func fieldEditor(of field: NSTextField, in window: NSWindow) -> NSTextView? {
        guard let tv = window.firstResponder as? NSTextView,
              tv.isFieldEditor,
              (tv.delegate as AnyObject?) === field else { return nil }
        return tv
    }

    private func firstResponderDescription(_ window: NSWindow) -> String {
        guard let fr = window.firstResponder else { return "nil" }
        if let tv = fr as? NSTextView {
            return "\(type(of: tv)) (fieldEditor=\(tv.isFieldEditor), string=\"\(tv.string)\", selectedRange=\(NSStringFromRange(tv.selectedRange())))"
        }
        return "\(type(of: fr))"
    }

    // MARK: - Menu harness

    /// The real Edit > Find > "Find..." item, located by its Cmd-F binding.
    private func realFindItem() throws -> NSMenuItem {
        let main = try XCTUnwrap(NSApplication.shared.mainMenu, "precondition: installMainMenu() set a main menu")
        var hits: [NSMenuItem] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub) }
                let mask = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                if item.keyEquivalent == "f" && mask == .command { hits.append(item) }
            }
        }
        walk(main)
        XCTAssertEqual(hits.map({ (i: NSMenuItem) -> String in i.title }), ["Find\u{2026}"],
                       "precondition: exactly one plain Cmd-F menu item, titled Find...")
        return try XCTUnwrap(hits.first, "precondition: a Cmd-F menu item exists")
    }

    private struct MenuOutcome {
        let target: AnyObject?
        let isEnabled: Bool
        var targetDescription: String {
            guard let t = target else { return "none (no responder handles the action)" }
            return "\(type(of: t))"
        }
    }

    /// What AppKit would do with `item` given `window`'s current first
    /// responder: resolve the target like the responder chain does, then run
    /// a real auto-enabling `NSMenu.update()` against it.
    private func validate(_ item: NSMenuItem, in window: NSWindow) throws -> MenuOutcome {
        let action = try XCTUnwrap(item.action, "precondition: the Find item has an action")
        var target: AnyObject? = item.target
        if target == nil {
            var r: NSResponder? = window.firstResponder
            while let cur = r {
                if cur.responds(to: action) { target = cur; break }
                r = cur.nextResponder
            }
        }
        if target == nil, let d = window.delegate as? NSObject, d.responds(to: action) { target = d }
        if target == nil, NSApp.responds(to: action) { target = NSApp }
        if target == nil, let d = NSApp.delegate as? NSObject, d.responds(to: action) { target = d }
        guard let resolved = target else {
            return MenuOutcome(target: nil, isEnabled: false)
        }

        func run(seed: Bool) -> Bool {
            let probe = NSMenuItem(title: item.title, action: action, keyEquivalent: item.keyEquivalent)
            probe.keyEquivalentModifierMask = item.keyEquivalentModifierMask
            probe.tag = item.tag
            probe.target = resolved
            probe.isEnabled = seed
            let menu = NSMenu(title: "probe")
            menu.autoenablesItems = true
            menu.addItem(probe)
            menu.update()
            return probe.isEnabled
        }
        let seededOn = run(seed: true)
        let seededOff = run(seed: false)
        XCTAssertEqual(seededOn, seededOff,
                       "harness: AppKit validation must decide the item's state regardless of its seed (target \(type(of: resolved)))")
        return MenuOutcome(target: resolved, isEnabled: seededOn)
    }

    /// A real Cmd-F: validate, and only if the menu enables the item, send the
    /// action to the resolved target.
    private func pressCmdF(_ item: NSMenuItem, in window: NSWindow) throws -> MenuOutcome {
        let outcome = try validate(item, in: window)
        if outcome.isEnabled, let action = item.action, let target = outcome.target {
            _ = NSApp.sendAction(action, to: target, from: item)
        }
        return outcome
    }

    // MARK: - Tests

    /// Control: with the terminal itself focused (no find bar), Find... is
    /// enabled and handled by the TerminalView. Passes before and after the
    /// fix; it exists so "disable / hijack everything" cannot satisfy the suite.
    func test_findItem_enabledWhenTerminalViewIsFirstResponder() throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.window.makeFirstResponder(rig.view),
                      "precondition: the terminal view accepts first responder")
        XCTAssertTrue(rig.window.firstResponder === rig.view,
                      "precondition: terminal view is first responder, got \(firstResponderDescription(rig.window))")

        let outcome = try validate(try realFindItem(), in: rig.window)
        XCTAssertEqual(outcome.isEnabled, true,
                       "Find... must be enabled with the terminal focused; target=\(outcome.targetDescription)")
        XCTAssertTrue(outcome.target === rig.view,
                      "with the terminal focused the Find action is handled by the TerminalView; target=\(outcome.targetDescription)")
        withExtendedLifetime(rig.session) {}
        withExtendedLifetime(rig.term) {}
    }

    /// The reported bug, validation half: with the QUERY field focused (its
    /// field-editor NSTextView is first responder), Edit > Find > Find... must
    /// not be greyed.
    func test_findItem_enabledWhileQueryFieldHasFocus() throws {
        let rig = try makeRig()
        let open = try openFindBar(rig)
        XCTAssertTrue(rig.window.makeFirstResponder(open.queryField),
                      "precondition: window grants first responder to the query field")
        let editor = fieldEditor(of: open.queryField, in: rig.window)
        XCTAssertEqual(editor != nil, true,
                       "precondition: the query field's field editor is first responder; got \(firstResponderDescription(rig.window))")

        let outcome = try validate(try realFindItem(), in: rig.window)
        XCTAssertEqual(outcome.isEnabled, true,
                       "Cmd-F -> Find... must be enabled while the find field has focus (first responder \(firstResponderDescription(rig.window)), resolved target \(outcome.targetDescription))")
        withExtendedLifetime(rig.session) {}
        withExtendedLifetime(rig.term) {}
    }

    /// Same, with the REPLACE field focused (the report says it has the same
    /// effect).
    func test_findItem_enabledWhileReplaceFieldHasFocus() throws {
        let rig = try makeRig()
        let open = try openFindBar(rig)
        XCTAssertTrue(rig.window.makeFirstResponder(open.replaceField),
                      "precondition: window grants first responder to the replace field")
        let editor = fieldEditor(of: open.replaceField, in: rig.window)
        XCTAssertEqual(editor != nil, true,
                       "precondition: the replace field's field editor is first responder; got \(firstResponderDescription(rig.window))")

        let outcome = try validate(try realFindItem(), in: rig.window)
        XCTAssertEqual(outcome.isEnabled, true,
                       "Cmd-F -> Find... must be enabled while the replace field has focus (first responder \(firstResponderDescription(rig.window)), resolved target \(outcome.targetDescription))")
        withExtendedLifetime(rig.session) {}
        withExtendedLifetime(rig.term) {}
    }

    /// The reported bug, behaviour half: pressing Cmd-F again with the caret
    /// parked inside the query re-selects the whole query (Safari /
    /// Terminal.app), keeps the bar open, and keeps focus in the query field.
    func test_secondCmdF_withQueryFieldFocused_selectsWholeQuery_andKeepsBarOpen() throws {
        let rig = try makeRig()
        let open = try openFindBar(rig)
        XCTAssertTrue(rig.window.makeFirstResponder(open.queryField),
                      "precondition: window grants first responder to the query field")
        let editor = try XCTUnwrap(fieldEditor(of: open.queryField, in: rig.window),
                                   "precondition: the query field's field editor is first responder; got \(firstResponderDescription(rig.window))")
        XCTAssertEqual(editor.string, Self.query, "precondition: the field editor shows the query")

        // The user clicked / typed so the query is no longer selected: the
        // caret is collapsed at the end.
        let end = (Self.query as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        XCTAssertEqual(NSStringFromRange(editor.selectedRange()),
                       NSStringFromRange(NSRange(location: end, length: 0)),
                       "precondition: caret is collapsed at the end of the query")

        let outcome = try pressCmdF(try realFindItem(), in: rig.window)

        let after = fieldEditor(of: open.queryField, in: rig.window)
        XCTAssertEqual(after != nil, true,
                       "focus must stay in the query field after Cmd-F; first responder is \(firstResponderDescription(rig.window))")
        XCTAssertEqual(after.map({ (tv: NSTextView) -> String in NSStringFromRange(tv.selectedRange()) }),
                       NSStringFromRange(NSRange(location: 0, length: end)),
                       "Cmd-F with the find field focused must re-select the whole query \"\(Self.query)\" (menu item enabled=\(outcome.isEnabled), target=\(outcome.targetDescription), first responder \(firstResponderDescription(rig.window)))")
        XCTAssertTrue(rig.view.findController.findBar === open.bar,
                      "Cmd-F must not close or replace the open find bar")
        withExtendedLifetime(rig.session) {}
        withExtendedLifetime(rig.term) {}
    }
}
