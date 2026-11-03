import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests for the find bar's KEYBOARD handling. Spec, not
/// implementation:
///
///  The bar has two editable text fields (Find, and Replace once the replace
///  row is expanded). When a text field is being edited, AppKit turns the
///  user's keys into editing commands and offers them to the field's delegate
///  (`NSTextFieldDelegate.control(_:textView:doCommandBy:)`) before applying
///  its own default:
///
///      Esc          -> `cancelOperation:`
///      Return       -> `insertNewline:`
///      Shift-Tab    -> `insertBacktab:`
///
///  macOS / editor conventions the bar must honour from EITHER field:
///
///   1. ESC DISMISSES THE BAR. A keyboard-only user who has moved into the
///      Replace field must be able to close the bar with Esc, exactly as from
///      the Find field. Dismissal is observable as the delegate's
///      `findBarDidClose(_:)`.
///   2. RETURN IN THE REPLACE FIELD REPLACES. Return is the "commit" gesture
///      of the field the user is typing in; in the Replace field that is
///      "replace the current match with this text" (what the Replace button
///      does), observable as `findBar(_:didRequestReplace:with:)` carrying
///      `.current` and the field's text. (Return in the Find field already
///      means "next match" and is pinned here as a control.)
///   3. SHIFT-TAB IS NOT "PREVIOUS MATCH". Shift-Tab is the standard
///      backward-focus gesture of every macOS text field; the Find field must
///      not repurpose it as "previous match" (Shift-Return is that gesture).
///      Observable as: the delegate sees NO `findBar(_:didAdvance:)` (nor any
///      other search / close / replace call) when Shift-Tab is pressed in the
///      Find field. Whether focus then really moves is AppKit's key-view
///      machinery and cannot be observed in a never-shown window (a headless
///      window has no key-view loop: `selectPreviousKeyView` is a no-op), so
///      the contract pinned here is the negative one.
///
///  The keys are delivered the way AppKit delivers them: the bar's own live
///  Find / Replace `NSTextField` instances (found from outside by walking the
///  view hierarchy, ordered top to bottom) are made first responder in a real
///  (never shown) window so each has its real field editor, and the editing
///  command the key produces is delivered to that field editor with
///  `doCommand(by:)`. The field editor offers it to its field, which forwards
///  to the field's delegate, so a field that is not wired to the bar delivers
///  nothing to it, exactly as in the app. No CGEvent / keystroke injection.
///
///  Control cases (Esc and Return in the FIND field) must hold on any
///  implementation and prove the rig delivers commands and the recorder sees
///  them, so a pass/fail on the Replace-field cases is not a rig artefact.
///
/// Cost: one titled NSWindow (never ordered front, parked for the process
/// lifetime) hosting a 600x120 container and one FindBar (a handful of
/// subviews) per test; no PTY, no session, no run-loop pumping; sub-ms each,
/// well under 1 MB.
@MainActor
final class FindBarKeyboardBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Windows are parked untouched for the process lifetime (repo rule:
    /// closing / ordering out headless windows can poison a deferred
    /// CoreAnimation flush in the xctest host).
    private static var parkedWindows: [NSWindow] = []

    // MARK: - Recorder

    /// Records only the delegate calls these keys are specified to produce.
    /// Query changes are deliberately not recorded: they are not part of the
    /// keyboard contract under test.
    private final class KeyRecorder: FindBarDelegate {
        var events: [String] = []

        func findBar(_ bar: FindBar, didChangeQuery query: String) {}

        func findBar(_ bar: FindBar, didAdvance direction: FindBar.Direction) {
            switch direction {
            case .forward:  events.append("advance:forward")
            case .backward: events.append("advance:backward")
            }
        }

        func findBarDidClose(_ bar: FindBar) {
            events.append("close")
        }

        func findBar(_ bar: FindBar, didRequestReplace kind: FindBar.ReplaceKind, with replacement: String) {
            switch kind {
            case .current: events.append("replace:current:\(replacement)")
            case .all:     events.append("replace:all:\(replacement)")
            }
        }
    }

    /// Stands in for the TerminalView the bar is a subview of: its `keyDown`
    /// is where an unhandled key from the bar ends up encoded into the PTY.
    /// Records the key codes that leak up to it.
    private final class LeakProbeView: NSView {
        var leakedKeyCodes: [UInt16] = []
        override func keyDown(with event: NSEvent) {
            leakedKeyCodes.append(event.keyCode)
        }
    }

    // MARK: - Fixture

    private struct Rig {
        let window: NSWindow
        let parent: LeakProbeView
        let bar: FindBar
        let recorder: KeyRecorder
        let findField: NSTextField
        /// nil when the replace row is collapsed.
        let replaceField: NSTextField?
    }

    private func isEffectivelyVisible(_ view: NSView, within bar: NSView) -> Bool {
        var current: NSView? = view
        while let c = current {
            if c.isHidden { return false }
            if c === bar { return true }
            current = c.superview
        }
        return false
    }

    /// Visible, editable text fields under `view`, collected without
    /// descending into controls (AppKit's own button chrome is not a field of
    /// the bar).
    private func collectEditableFields(in view: NSView, bar: FindBar, into out: inout [NSTextField]) {
        for sub in view.subviews {
            if let field = sub as? NSTextField {
                if field.isEditable && isEffectivelyVisible(field, within: bar) { out.append(field) }
                continue
            }
            if sub is NSControl { continue }
            collectEditableFields(in: sub, bar: bar, into: &out)
        }
    }

    /// Editable fields ordered top to bottom: first is Find, second (only with
    /// the replace row expanded) is Replace.
    private func editableFieldsTopToBottom(_ bar: FindBar) -> [NSTextField] {
        var found: [NSTextField] = []
        collectEditableFields(in: bar, bar: bar, into: &found)
        let flipped = bar.isFlipped
        return found.sorted { (a: NSTextField, b: NSTextField) -> Bool in
            let ra = bar.convert(a.bounds, from: a)
            let rb = bar.convert(b.bounds, from: b)
            let topA: CGFloat = flipped ? -ra.minY : ra.maxY
            let topB: CGFloat = flipped ? -rb.minY : rb.maxY
            return topA > topB
        }
    }

    /// A themed 600 pt bar (as `installFindBar()` builds it in the app) hosted
    /// in a never-shown window, optionally with the replace row expanded and
    /// pre-filled with `replacementText`.
    private func makeRig(expanded: Bool,
                         replacementText: String = "",
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> Rig {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        Self.parkedWindows.append(window)

        let container = LeakProbeView(frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        window.contentView = container

        let bar = FindBar(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        bar.applyTheme(Theme.gruvboxDark)
        container.addSubview(bar)

        let recorder = KeyRecorder()
        bar.delegate = recorder

        if expanded {
            bar.setReplaceVisible(true)
            XCTAssertTrue(bar.isReplaceVisible,
                          "precondition: replace row must be expanded", file: file, line: line)
        }
        // Fill the replace field BEFORE it gets a field editor, so the text is
        // there when the user "presses Return" in it.
        bar._setReplaceFieldStringForTests(replacementText)

        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()

        let fields = editableFieldsTopToBottom(bar)
        XCTAssertEqual(fields.count, expanded ? 2 : 1,
                       "precondition: visible editable fields (expanded=\(expanded)); found \(fields.count)",
                       file: file, line: line)
        let findField = try XCTUnwrap(fields.first, "precondition: Find field must be visible",
                                      file: file, line: line)
        let replaceField: NSTextField? = expanded ? fields.dropFirst().first : nil
        if expanded {
            XCTAssertEqual(replaceField?.stringValue, replacementText,
                           "precondition: the second (Replace) field must hold the injected text",
                           file: file, line: line)
        }
        XCTAssertTrue(recorder.events.isEmpty,
                      "precondition: building the rig must not emit key-driven delegate calls; saw \(recorder.events)",
                      file: file, line: line)
        return Rig(window: window, parent: container, bar: bar, recorder: recorder,
                   findField: findField, replaceField: replaceField)
    }

    /// Puts `field` in edit mode (real field editor, first responder) and
    /// delivers `command` (the editing command AppKit derives from the key) to
    /// the field editor via `doCommand(by:)`, which is the entry point AppKit's
    /// own key interpretation uses. The field editor offers it to its field
    /// (which forwards to the field's delegate), then applies AppKit's default
    /// if nobody claimed it. So a field whose delegate is not the bar delivers
    /// nothing to the bar, exactly as in the app.
    private func press(_ command: String,
                       in field: NSTextField,
                       of rig: Rig,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws {
        XCTAssertTrue(rig.window.makeFirstResponder(field),
                      "precondition: the field must accept first responder", file: file, line: line)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView,
                                   "precondition: a focused field has a field editor",
                                   file: file, line: line)
        XCTAssertTrue(rig.window.firstResponder === editor,
                      "precondition: the field editor must be the first responder; was \(String(describing: rig.window.firstResponder))",
                      file: file, line: line)
        editor.doCommand(by: NSSelectorFromString(command))
    }

    // MARK: - Esc

    /// Control: Esc in the Find field dismisses the bar (long-standing
    /// behaviour; proves the rig delivers commands and the recorder hears
    /// the close).
    func test_control_escapeInFindField_dismissesBar() throws {
        let rig = try makeRig(expanded: true)
        try press("cancelOperation:", in: rig.findField, of: rig)
        XCTAssertEqual(rig.recorder.events, ["close"],
                       "Esc in the Find field must dismiss the bar (delegate events: \(rig.recorder.events))")
    }

    /// THE BUG (Esc half): with the replace row expanded and focus in the
    /// Replace field, Esc did nothing.
    func test_escapeInReplaceField_dismissesBar() throws {
        let rig = try makeRig(expanded: true, replacementText: "baz")
        let replaceField = try XCTUnwrap(rig.replaceField, "precondition: Replace field")
        try press("cancelOperation:", in: replaceField, of: rig)
        XCTAssertEqual(rig.recorder.events, ["close"],
                       "Esc in the Replace field must dismiss the bar exactly like Esc in the Find field "
                       + "(delegate events: \(rig.recorder.events))")
    }

    /// Esc in an EMPTY Replace field is the most common keyboard-only exit
    /// (expand, change mind, Esc). The bar must close then too.
    func test_escapeInEmptyReplaceField_dismissesBar() throws {
        let rig = try makeRig(expanded: true, replacementText: "")
        let replaceField = try XCTUnwrap(rig.replaceField, "precondition: Replace field")
        try press("cancelOperation:", in: replaceField, of: rig)
        XCTAssertEqual(rig.recorder.events, ["close"],
                       "Esc in an empty Replace field must dismiss the bar (delegate events: \(rig.recorder.events))")
    }

    // MARK: - Return

    /// Control: Return in the Find field steps to the next match (existing
    /// behaviour that a keyboard fix must not break).
    func test_control_returnInFindField_advancesForward() throws {
        let rig = try makeRig(expanded: true, replacementText: "baz")
        try press("insertNewline:", in: rig.findField, of: rig)
        XCTAssertEqual(rig.recorder.events, ["advance:forward"],
                       "Return in the Find field must step to the next match (delegate events: \(rig.recorder.events))")
    }

    /// THE BUG (Return half): Return in the Replace field is the "replace"
    /// gesture and did nothing.
    func test_returnInReplaceField_replacesCurrentMatchWithFieldText() throws {
        let rig = try makeRig(expanded: true, replacementText: "baz")
        let replaceField = try XCTUnwrap(rig.replaceField, "precondition: Replace field")
        try press("insertNewline:", in: replaceField, of: rig)
        let replaces = rig.recorder.events.filter { (e: String) -> Bool in e.hasPrefix("replace:") }
        XCTAssertEqual(replaces, ["replace:current:baz"],
                       "Return in the Replace field must replace the current match (once, not all) with the "
                       + "field's text (delegate events: \(rig.recorder.events))")
        XCTAssertFalse(rig.recorder.events.contains("close"),
                       "Return in the Replace field must not dismiss the bar (delegate events: \(rig.recorder.events))")
    }

    /// Return in the Replace field must carry exactly the field's text, not a
    /// stale or default one (guards a fix that dispatches with "").
    func test_returnInReplaceField_passesTheExactText() throws {
        let rig = try makeRig(expanded: true, replacementText: "hello world \u{00e9}")
        let replaceField = try XCTUnwrap(rig.replaceField, "precondition: Replace field")
        try press("insertNewline:", in: replaceField, of: rig)
        let replaces = rig.recorder.events.filter { (e: String) -> Bool in e.hasPrefix("replace:") }
        XCTAssertEqual(replaces, ["replace:current:hello world \u{00e9}"],
                       "Return in the Replace field must pass the field's exact text "
                       + "(delegate events: \(rig.recorder.events))")
    }

    // MARK: - Shift-Tab

    /// THE BUG (Shift-Tab half), replace row expanded: Shift-Tab in the Find
    /// field is the backward-focus gesture and must never step to the
    /// previous match.
    func test_shiftTabInFindField_expanded_doesNotStepToPreviousMatch() throws {
        let rig = try makeRig(expanded: true)
        try press("insertBacktab:", in: rig.findField, of: rig)
        XCTAssertEqual(rig.recorder.events, [],
                       "Shift-Tab in the Find field must not drive the search (previous match is Shift-Return); "
                       + "delegate events: \(rig.recorder.events)")
    }

    /// Same, replace row collapsed (the common state).
    func test_shiftTabInFindField_collapsed_doesNotStepToPreviousMatch() throws {
        let rig = try makeRig(expanded: false)
        try press("insertBacktab:", in: rig.findField, of: rig)
        XCTAssertEqual(rig.recorder.events, [],
                       "Shift-Tab in the Find field must not drive the search (previous match is Shift-Return); "
                       + "delegate events: \(rig.recorder.events)")
    }

    // MARK: - Focused buttons (Full Keyboard Access)

    private func collectVisibleButtons(in view: NSView, bar: FindBar, into out: inout [NSButton]) {
        for sub in view.subviews {
            if let button = sub as? NSButton, isEffectivelyVisible(button, within: bar) {
                out.append(button)
                continue
            }
            collectVisibleButtons(in: sub, bar: bar, into: &out)
        }
    }

    /// A key-down event as AppKit would hand it to a focused control.
    private func keyEvent(keyCode: UInt16, characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            ),
            "precondition: a key event can be constructed"
        )
    }

    /// Every button of the expanded bar (caret, close, Replace, Replace All).
    private func expandedBarButtons(_ rig: Rig) -> [NSButton] {
        var buttons: [NSButton] = []
        collectVisibleButtons(in: rig.bar, bar: rig.bar, into: &buttons)
        return buttons
    }

    /// Esc on a focused button must close the bar and must not reach the
    /// TerminalView (which would write 0x1B to the shell).
    func test_escapeOnFocusedButton_dismissesBar_andDoesNotReachTerminalView() throws {
        let rig = try makeRig(expanded: true)
        let buttons = expandedBarButtons(rig)
        XCTAssertGreaterThanOrEqual(buttons.count, 4,
                                    "precondition: caret, close, Replace, Replace All are visible; found \(buttons.count)")
        for button in buttons {
            rig.recorder.events.removeAll()
            let event = try keyEvent(keyCode: 53, characters: "\u{1B}", in: rig.window)
            button.keyDown(with: event)
            XCTAssertEqual(rig.recorder.events, ["close"],
                           "Esc on button '\(button.title)' must dismiss the bar (delegate events: \(rig.recorder.events))")
        }
        XCTAssertEqual(rig.parent.leakedKeyCodes, [],
                       "Esc must not leak past the bar to the terminal view; leaked \(rig.parent.leakedKeyCodes)")
    }

    /// Return / keypad Enter on a focused button is swallowed: it neither
    /// reaches the TerminalView (a stray CR would run the shell's command
    /// line) nor drives the search / replace / close.
    func test_returnOnFocusedButton_isSwallowed() throws {
        let rig = try makeRig(expanded: true, replacementText: "baz")
        let buttons = expandedBarButtons(rig)
        XCTAssertGreaterThanOrEqual(buttons.count, 4,
                                    "precondition: caret, close, Replace, Replace All are visible; found \(buttons.count)")
        let enterKeys: [(code: UInt16, chars: String)] = [(36, "\r"), (76, "\u{3}")]
        for button in buttons {
            for key in enterKeys {
                let event = try keyEvent(keyCode: key.code, characters: key.chars, in: rig.window)
                button.keyDown(with: event)
            }
        }
        XCTAssertEqual(rig.parent.leakedKeyCodes, [],
                       "Return / Enter must not leak past the bar to the terminal view; leaked \(rig.parent.leakedKeyCodes)")
        XCTAssertEqual(rig.recorder.events, [],
                       "Return / Enter on a bar button must not drive search, replace or close; "
                       + "delegate events: \(rig.recorder.events)")
    }

    /// The responder-chain `cancelOperation:` (Esc routed by AppKit rather
    /// than as a raw key) closes the bar too.
    func test_cancelOperationOnBar_dismissesBar() throws {
        let rig = try makeRig(expanded: false)
        rig.bar.cancelOperation(nil)
        XCTAssertEqual(rig.recorder.events, ["close"],
                       "cancelOperation: on the bar must dismiss it (delegate events: \(rig.recorder.events))")
    }
}
