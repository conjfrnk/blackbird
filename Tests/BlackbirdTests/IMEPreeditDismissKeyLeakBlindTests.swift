import XCTest
import AppKit
import ObjectiveC
@testable import Blackbird

/// Blind behaviour tests (BUG IME-1): a keystroke that DISMISSES a pending
/// preedit must be consumed by the composition, not also delivered to the
/// foreground program.
///
/// Background (macOS / terminal conventions): while an input method has marked
/// text on screen (a CJK clause, a Korean jamo, a US Option+E dead-key accent)
/// Esc means "cancel the composition" and Backspace means "delete one preedit
/// character". Terminal.app and iTerm2 swallow both; the shell never sees an
/// ESC or a DEL for them. The input context reports such a dismissal to the
/// client in one of three ways, depending on the input method:
///
///   - `doCommand(by: cancelOperation:)`   (Esc handed back to the app),
///   - `setMarkedText("")`                 (preedit emptied),
///   - `unmarkText()`                      (preedit discarded, nothing committed).
///
/// None of them is `insertText`, so there is no "committed text" for the app to
/// see; the event is still *consumed by the IME*. Delivering it to the PTY as
/// well is user-visible: ESC interrupts a running Claude Code turn or leaves
/// vim insert mode, and a DEL after backspacing a one-character preedit erases
/// a character the user never meant to touch. Under the kitty keyboard
/// protocol the leak is `CSI 27 u` instead of 0x1B.
///
/// Rig. `keyDown` hands every event to `inputContext?.handleEvent(_:)`. The
/// real system input context cannot be scripted from a unit test (it depends on
/// the active keyboard layout and on a live window server), so this suite
/// installs a `ScriptedInputContext` as the view's `inputContext` and has it
/// play the part of the input method: given the event, call the
/// `NSTextInputClient` entry points the real IME would call. The seam is an
/// ObjC `inputContext` getter added to `TerminalView` only (the class is
/// `final`, so it cannot be subclassed) that answers the scripted context for
/// registered views and defers to `NSView`'s own getter for everything else.
/// Nothing in this suite posts a CGEvent or touches the window server.
///
/// Non-vacuity. The precondition tests prove (a) the scripted context really is
/// what `keyDown` consults, and (b) the very same keystrokes DO reach the PTY
/// (0x1B / `CSI 27 u` / 0x7F) when no composition is pending, so a green
/// "nothing was sent" assertion cannot be explained by a rig that swallows
/// everything.
///
/// Written without reading the bodies of `TerminalView.keyDown` or
/// `TerminalView+IME.swift`.
final class IMEPreeditDismissKeyLeakBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        for view in registeredViews {
            // Break the ime -> script -> rig -> ime retain cycle.
            (InputContextSeam.contexts[ObjectIdentifier(view)] as? ScriptedInputContext)?.script = { _ in false }
            InputContextSeam.contexts[ObjectIdentifier(view)] = nil
        }
        registeredViews.removeAll()
        super.tearDown()
    }

    private var registeredViews: [TerminalView] = []

    // MARK: - Input-context seam

    /// Plays the input method. `script` is invoked for each `keyDown` and
    /// returns what `handleEvent(_:)` should report ("the IME consumed it").
    private final class ScriptedInputContext: NSTextInputContext {
        var script: (NSEvent) -> Bool = { _ in false }
        private(set) var keyCodesSeen: [UInt16] = []

        override func handleEvent(_ event: NSEvent) -> Bool {
            keyCodesSeen.append(event.keyCode)
            return script(event)
        }
    }

    /// Adds an `inputContext` getter to `TerminalView` (not to `NSView`, so no
    /// other class is affected) that returns the registered scripted context
    /// and otherwise forwards to `NSView`'s implementation.
    private enum InputContextSeam {
        static var contexts: [ObjectIdentifier: NSTextInputContext] = [:]

        static let installed: Bool = {
            let sel = #selector(getter: NSView.inputContext)
            guard let base = class_getInstanceMethod(NSView.self, sel) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
            let original = unsafeBitCast(method_getImplementation(base), to: Getter.self)
            let block: @convention(block) (AnyObject) -> AnyObject? = { obj in
                if let fake = contexts[ObjectIdentifier(obj)] { return fake }
                return original(obj, sel)
            }
            return class_addMethod(TerminalView.self, sel,
                                   imp_implementationWithBlock(block),
                                   method_getTypeEncoding(base))
        }()
    }

    // MARK: - Rig

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let pty: RecordingPTY
        let ime: ScriptedInputContext
        let snapshot: BBSnapshot
    }

    private let notFound = NSRange(location: NSNotFound, length: 0)
    private let kittyDisambiguate = "\u{1B}[>1u"

    private func makeRig(
        feeding setup: String = "",
        optionIsMeta: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        XCTAssertTrue(InputContextSeam.installed,
                      "rig: could not install the inputContext seam on TerminalView",
                      file: file, line: line)
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "Metal device required", file: file, line: line)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
                                 "BBTerm init failed", file: file, line: line)
        term.input(setup)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil",
                                     file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let pty = RecordingPTY()
        view.ptyRecorderForTests = pty
        view.setOptionIsMetaForTests(optionIsMeta)

        let ime = ScriptedInputContext(client: view)
        InputContextSeam.contexts[ObjectIdentifier(view)] = ime
        registeredViews.append(view)
        XCTAssertTrue(view.inputContext === ime,
                      "rig: keyDown must consult the scripted input context; view.inputContext = \(String(describing: view.inputContext))",
                      file: file, line: line)
        return Rig(view: view, term: term, session: session, pty: pty, ime: ime, snapshot: snapshot)
    }

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "(none)" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private let escByte = Data([0x1B])
    private let delByte = Data([0x7F])
    private let csi27u = Data("\u{1B}[27u".utf8)

    // MARK: - Key events

    private func escKeyDown() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53))
    }

    private func backspaceKeyDown() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
            isARepeat: false, keyCode: 51))
    }

    /// US-layout Option+E: produces the acute-accent dead key.
    private func optionEKeyDown() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
            windowNumber: 0, context: nil,
            characters: "\u{B4}", charactersIgnoringModifiers: "e",
            isARepeat: false, keyCode: 14))
    }

    // MARK: - IME scripts (what the input method does with a dismissing key)

    private enum Dismissal: String, CaseIterable {
        case doCommandCancelOperation = "doCommand(cancelOperation:)"
        case emptySetMarkedText = "setMarkedText(\"\")"
        case unmarkText = "unmarkText()"
    }

    private func perform(_ dismissal: Dismissal, on view: TerminalView) {
        switch dismissal {
        case .doCommandCancelOperation:
            view.doCommand(by: NSSelectorFromString("cancelOperation:"))
        case .emptySetMarkedText:
            view.setMarkedText("",
                               selectedRange: NSRange(location: 0, length: 0),
                               replacementRange: notFound)
        case .unmarkText:
            view.unmarkText()
        }
    }

    private func beginPreedit(_ text: String, on view: TerminalView,
                              file: StaticString = #filePath, line: UInt = #line) {
        view.setMarkedText(text,
                           selectedRange: NSRange(location: (text as NSString).length, length: 0),
                           replacementRange: notFound)
        XCTAssertTrue(view.hasMarkedText(),
                      "precondition: preedit \"\(text)\" must be pending", file: file, line: line)
    }

    // MARK: - Preconditions (rig honesty)

    /// The scripted context is what `keyDown` consults, and the kitty fixture
    /// really sets the disambiguate flag.
    func test_precondition_keyDownConsultsScriptedContext_andKittyFlagIsSet() throws {
        let rig = try makeRig(feeding: kittyDisambiguate)
        XCTAssertTrue(rig.snapshot.termMode.contains(.disambiguateEscCodes),
                      "CSI > 1 u must set kitty flag 1; termMode = \(rig.snapshot.termMode)")

        rig.view.keyDown(with: try escKeyDown())

        XCTAssertEqual(rig.ime.keyCodesSeen, [53],
                       "keyDown must hand the Esc event to the input context exactly once; scripted context saw keyCodes \(rig.ime.keyCodesSeen)")
    }

    /// With NO composition pending Esc is an ordinary keystroke and must reach
    /// the PTY, in legacy mode as 0x1B and under kitty flag 1 as CSI 27 u.
    func test_precondition_escWithNoPreedit_reachesPTY() throws {
        let legacy = try makeRig()
        legacy.view.keyDown(with: try escKeyDown())
        XCTAssertEqual(legacy.pty.sent, escByte,
                       "idle IME, no preedit: Esc must send 0x1B; sent \(hex(legacy.pty.sent))")

        let kitty = try makeRig(feeding: kittyDisambiguate)
        kitty.view.keyDown(with: try escKeyDown())
        XCTAssertEqual(kitty.pty.sent, csi27u,
                       "idle IME, no preedit, kitty flag 1: Esc must send ESC [ 27 u; sent \(hex(kitty.pty.sent))")
    }

    /// Same for Backspace: with no preedit it is DEL.
    func test_precondition_backspaceWithNoPreedit_reachesPTY() throws {
        let rig = try makeRig()
        rig.view.keyDown(with: try backspaceKeyDown())
        XCTAssertEqual(rig.pty.sent, delByte,
                       "idle IME, no preedit: Backspace must send 0x7F; sent \(hex(rig.pty.sent))")
    }

    /// Real input contexts route Esc through key bindings to
    /// `cancelOperation:` even when nothing is composing. The terminal must
    /// still send ESC then: only a *pending preedit* makes Esc a cancel.
    func test_escWithNoPreedit_whenIMEForwardsCancelOperation_stillSendsEsc() throws {
        let rig = try makeRig()
        rig.ime.script = { _ in
            self.perform(.doCommandCancelOperation, on: rig.view)
            return true
        }
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no preedit")

        rig.view.keyDown(with: try escKeyDown())

        XCTAssertEqual(rig.pty.sent, escByte,
                       "no preedit pending: Esc (even delivered as cancelOperation:) must still send 0x1B; sent \(hex(rig.pty.sent))")
    }

    // MARK: - The bug: Esc dismissing a preedit must not reach the PTY

    func test_escDismissingPreedit_doesNotSendEsc() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig()
            beginPreedit("\u{B4}", on: rig.view)           // dead-key accent
            rig.ime.script = { _ in
                self.perform(dismissal, on: rig.view)
                return true
            }

            rig.view.keyDown(with: try escKeyDown())

            XCTAssertEqual(rig.pty.sent, Data(),
                           "[\(dismissal.rawValue)] Esc that cancels a pending preedit must be consumed by the IME; PTY received \(hex(rig.pty.sent)) (expected nothing)")
            XCTAssertFalse(rig.view.hasMarkedText(),
                           "[\(dismissal.rawValue)] the preedit must be gone after the cancel")
        }
    }

    /// CJK flavour: a multi-character clause (kana) cancelled with Esc.
    func test_escDismissingCJKClause_doesNotSendEsc() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig()
            beginPreedit("かんじ", on: rig.view)
            rig.ime.script = { _ in
                self.perform(dismissal, on: rig.view)
                return true
            }

            rig.view.keyDown(with: try escKeyDown())

            XCTAssertEqual(rig.pty.sent, Data(),
                           "[\(dismissal.rawValue)] Esc cancelling a kana clause leaked to the PTY: \(hex(rig.pty.sent)) (expected nothing)")
            XCTAssertFalse(rig.view.hasMarkedText(),
                           "[\(dismissal.rawValue)] the clause must be gone after the cancel")
        }
    }

    /// Kitty keyboard protocol flag 1: the leak is `CSI 27 u`.
    func test_escDismissingPreedit_underKittyDisambiguate_doesNotSendCsi27u() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig(feeding: kittyDisambiguate)
            XCTAssertTrue(rig.snapshot.termMode.contains(.disambiguateEscCodes),
                          "precondition: kitty flag 1 active")
            beginPreedit("\u{B4}", on: rig.view)
            rig.ime.script = { _ in
                self.perform(dismissal, on: rig.view)
                return true
            }

            rig.view.keyDown(with: try escKeyDown())

            XCTAssertEqual(rig.pty.sent, Data(),
                           "[\(dismissal.rawValue)] kitty flag 1: Esc cancelling a preedit must not emit ESC [ 27 u; PTY received \(hex(rig.pty.sent)) (expected nothing)")
        }
    }

    /// Full dead-key flow in Native-Option mode: Option+E starts the "´"
    /// preedit (nothing sent), then Esc abandons it (still nothing sent).
    func test_optionEDeadKeyThenEsc_nativeOption_sendsNothing() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig(optionIsMeta: false)

            // Keystroke 1: Option+E -> the IME starts the dead-key preedit.
            rig.ime.script = { _ in
                rig.view.setMarkedText("\u{B4}",
                                       selectedRange: NSRange(location: 1, length: 0),
                                       replacementRange: self.notFound)
                return true
            }
            rig.view.keyDown(with: try optionEKeyDown())
            XCTAssertTrue(rig.view.hasMarkedText(),
                          "[\(dismissal.rawValue)] Option+E must leave the dead-key preedit pending")
            XCTAssertEqual(rig.pty.sent, Data(),
                           "[\(dismissal.rawValue)] the dead-key preedit must not reach the PTY; sent \(hex(rig.pty.sent))")

            // Keystroke 2: Esc -> the IME abandons the accent.
            rig.ime.script = { _ in
                self.perform(dismissal, on: rig.view)
                return true
            }
            rig.view.keyDown(with: try escKeyDown())

            XCTAssertEqual(rig.pty.sent, Data(),
                           "[\(dismissal.rawValue)] Option+E then Esc: the Esc belongs to the dead key, not the shell; PTY received \(hex(rig.pty.sent)) (expected nothing)")
            XCTAssertFalse(rig.view.hasMarkedText(),
                           "[\(dismissal.rawValue)] the dead-key preedit must be gone")
        }
    }

    /// The suppression covers only the keystroke that dismissed the preedit.
    /// The NEXT Esc, with no preedit, is a real Esc and must be delivered
    /// exactly once.
    func test_escAfterDismissedPreedit_isDeliveredNormally() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig()
            beginPreedit("\u{B4}", on: rig.view)
            rig.ime.script = { _ in
                self.perform(dismissal, on: rig.view)
                return true
            }
            rig.view.keyDown(with: try escKeyDown())
            XCTAssertEqual(rig.pty.sent, Data(),
                           "[\(dismissal.rawValue)] first Esc (dismisses preedit) leaked: \(hex(rig.pty.sent))")

            rig.ime.script = { _ in false }                  // IME idle now
            rig.view.keyDown(with: try escKeyDown())

            XCTAssertEqual(rig.pty.sent, escByte,
                           "[\(dismissal.rawValue)] the second Esc has no preedit to cancel and must send exactly one 0x1B in total; PTY received \(hex(rig.pty.sent))")
        }
    }

    /// Control: Esc that merely closes the candidate list while the preedit
    /// survives (the IME re-asserts the same marked text) is also consumed.
    func test_escWhilePreeditSurvives_sendsNothing() throws {
        let rig = try makeRig()
        beginPreedit("かん", on: rig.view)
        rig.ime.script = { _ in
            rig.view.setMarkedText("かん",
                                   selectedRange: NSRange(location: 2, length: 0),
                                   replacementRange: self.notFound)
            return true
        }

        rig.view.keyDown(with: try escKeyDown())

        XCTAssertEqual(rig.pty.sent, Data(),
                       "Esc consumed by the IME with the preedit still pending must not reach the PTY; sent \(hex(rig.pty.sent))")
        XCTAssertTrue(rig.view.hasMarkedText(), "the surviving preedit must stay pending")
    }

    // MARK: - The bug: Backspace dismissing a one-character preedit

    /// Backspacing the only character of a preedit empties it
    /// (`setMarkedText("")` / `unmarkText`). The DEL belongs to the IME; if it
    /// also reaches the PTY the shell deletes a character the user never
    /// meant to touch.
    func test_backspaceEmptyingOneCharPreedit_doesNotSendDel() throws {
        for dismissal in [Dismissal.emptySetMarkedText, .unmarkText] {
            for preedit in ["\u{B4}", "ㅎ", "a"] {
                let rig = try makeRig()
                beginPreedit(preedit, on: rig.view)
                rig.ime.script = { _ in
                    self.perform(dismissal, on: rig.view)
                    return true
                }

                rig.view.keyDown(with: try backspaceKeyDown())

                XCTAssertEqual(rig.pty.sent, Data(),
                               "[\(dismissal.rawValue), preedit \"\(preedit)\"] Backspace that empties the preedit must not also send DEL; PTY received \(hex(rig.pty.sent)) (expected nothing)")
                XCTAssertFalse(rig.view.hasMarkedText(),
                               "[\(dismissal.rawValue), preedit \"\(preedit)\"] the preedit must be gone")
            }
        }
    }

    /// Secondary symptom: during a dead-key preedit Backspace arrives as
    /// `doCommand(by: deleteBackward:)`. It must remove the pending accent
    /// (preedit gone) and must not be sent to the shell as DEL.
    func test_backspaceDuringDeadKeyPreedit_deleteBackwardCommand_removesAccent() throws {
        let rig = try makeRig(optionIsMeta: false)
        beginPreedit("\u{B4}", on: rig.view)
        rig.ime.script = { _ in
            rig.view.doCommand(by: NSSelectorFromString("deleteBackward:"))
            return true
        }

        rig.view.keyDown(with: try backspaceKeyDown())

        XCTAssertFalse(rig.view.hasMarkedText(),
                       "Backspace during a one-character dead-key preedit must delete the pending accent; it is still pending")
        XCTAssertEqual(rig.pty.sent, Data(),
                       "Backspace consumed by the preedit must not send DEL; PTY received \(hex(rig.pty.sent)) (expected nothing)")
    }
}
