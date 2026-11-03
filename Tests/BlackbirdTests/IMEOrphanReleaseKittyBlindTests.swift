import XCTest
import AppKit
import ObjectiveC
@testable import Blackbird
import BBCore

/// XL-ime-orphan-release -- a key that the input method ABSORBS on the way
/// down must not be reported as RELEASED to the foreground program on the way
/// up.
///
/// Contract (https://sw.kovidgoyal.net/kitty/keyboard-protocol/, "Report event
/// types"). A TUI that pushes kitty flag 2 is told, for every key that is sent
/// to it as an escape code, whether the event was a press (1), a repeat (2) or
/// a release (3). A program that tracks key state (hold / chord / auto-repeat
/// logic: helix, crossterm, Zellij-style clients, games) pairs the events of
/// one physical key: a `:3` release belongs to a press it has already seen. A
/// release whose press never arrived is an ORPHAN, and it corrupts that
/// bookkeeping (a release for a key it believes is up; a "key up" that closes a
/// chord it never opened).
///
/// Where the press goes missing. While an input method is composing (a CJK
/// clause, a Korean jamo, a US Option+E dead-key accent), the keystrokes that
/// drive the composition are consumed by the input method: `keyDown` hands the
/// event to the input context, the context calls `setMarkedText` /
/// `unmarkText` / `doCommand(by: cancelOperation:)` on the view, and NOTHING
/// goes to the PTY (the existing `IMEPreeditDismissKeyLeakBlindTests` pins
/// that for the press). The TUI never saw a press of that key, so it must not
/// be sent its release either:
///
///   1. Esc that cancels a pending preedit, under kitty flag 2 plus flag 1
///      (`CSI > 3 u`, enough for Esc to be an escape code) or flag 8
///      (`CSI > 10 u`): the press is swallowed, the later key-up must be too.
///   2. The first composing keystroke (and every following one) of a CJK or
///      dead-key preedit under flags 2+8 (`CSI > 10 u`): the press is swallowed
///      by the IME, the key-up for `a` must not become `CSI 97 ; 1 : 3 u`.
///
/// Without flag 2 there are no release events at all (nothing is sent for a
/// key-up before or after the fix); that is pinned too, so a "fix" that starts
/// reporting releases it should not report cannot pass.
///
/// What must NOT change (anchors, all green today and after the fix): when the
/// press WAS reported (no preedit pending, or an Esc the IME handed back as
/// `cancelOperation:` with no preedit to cancel, or an ordinary letter that the
/// input method commits straight away with `insertText`), the release is still
/// reported, so press and release pair. The suppression is also per-keystroke:
/// after a swallowed Esc, the NEXT Esc (nothing composing) is a real Esc and
/// its press/release pair is intact.
///
/// Rig. `keyDown` consults `inputContext?.handleEvent(_:)`. The real system
/// context cannot be scripted in a unit test (it depends on the active layout
/// and a live window server), so a `ScriptedInputContext` plays the input
/// method: for each key-down it calls the `NSTextInputClient` entry points the
/// real one would. It is installed through a private, runtime-created SUBCLASS
/// of `TerminalView` that is adopted by the views of THIS suite only
/// (`object_setClass`); that way the seam coexists with the
/// `IMEPreeditDismissKeyLeakBlindTests` seam, which patches `TerminalView`
/// itself, in one test process. Nothing here posts a CGEvent or touches the
/// window server. Key-ups are delivered straight to `keyUp(with:)`, the way
/// AppKit delivers them (key-ups never go through the input context).
///
/// Oracle. Every expected wire form is hard-coded from the protocol (press
/// `ESC [ 27 u`, release `ESC [ 27 ; 1 : 3 u`, press `ESC [ 97 u`, release
/// `ESC [ 97 ; 1 : 3 u`); never derived from what the view sent. Each test that
/// claims "nothing is sent" first proves the press half of the story with the
/// matching anchor (the same keystrokes DO reach the PTY, and DO pair, when the
/// input method is not composing) and asserts that the mode bits and the
/// pending-preedit state are what the test relies on.
///
/// Written blind: no body of `TerminalView.keyDown` / `keyUp`,
/// `TerminalView+IME.swift` or `KeyEncoder` was read; only declarations, doc
/// comments and sibling tests.
///
/// Memory/time pre-flight: one headless `TerminalView` (Metal renderer) plus a
/// 40x6 `BBTerm` (scrollback 16) per rig; at most three rigs per test (the
/// Esc-cancel tests loop over three dismissal styles), about twenty rigs for the
/// whole suite; no window, no PTY, no child process, no timers, no runloop
/// pumping. A few hundred KiB each.
final class IMEOrphanReleaseKittyBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func tearDown() {
        for view in registeredViews {
            // Break the ime -> script -> rig -> view retain cycle, then give the
            // view its real class back before it deallocates.
            (InputContextSeam.contexts[ObjectIdentifier(view)] as? ScriptedInputContext)?.script =
                { (_: NSEvent) -> Bool in false }
            InputContextSeam.contexts[ObjectIdentifier(view)] = nil
            object_setClass(view, TerminalView.self)
        }
        registeredViews.removeAll()
        super.tearDown()
    }

    private var registeredViews: [TerminalView] = []

    // MARK: - Input-context seam

    /// Plays the input method. `script` is invoked for each key-down and
    /// returns what `handleEvent(_:)` reports ("the IME consumed it").
    private final class ScriptedInputContext: NSTextInputContext {
        var script: (NSEvent) -> Bool = { (_: NSEvent) -> Bool in false }
        private(set) var keyCodesSeen: [UInt16] = []

        override func handleEvent(_ event: NSEvent) -> Bool {
            keyCodesSeen.append(event.keyCode)
            return script(event)
        }
    }

    /// A runtime-created subclass of `TerminalView` whose `inputContext`
    /// getter answers the scripted context registered for the receiver.
    /// Adopted per instance with `object_setClass`, so the real class (and the
    /// seam of `IMEPreeditDismissKeyLeakBlindTests`) is never touched.
    private enum InputContextSeam {
        static var contexts: [ObjectIdentifier: NSTextInputContext] = [:]

        static let subclass: AnyClass? = {
            let sel = #selector(getter: NSView.inputContext)
            guard let base = class_getInstanceMethod(NSView.self, sel),
                  let sub = objc_allocateClassPair(TerminalView.self,
                                                   "BlindIMEOrphanReleaseTerminalView", 0)
            else { return nil }
            let block: @convention(block) (AnyObject) -> AnyObject? = { (obj: AnyObject) -> AnyObject? in
                return contexts[ObjectIdentifier(obj)]
            }
            let added = class_addMethod(sub, sel,
                                        imp_implementationWithBlock(block),
                                        method_getTypeEncoding(base))
            guard added else { return nil }
            objc_registerClassPair(sub)
            return sub
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
        let setup: String
    }

    private let notFound = NSRange(location: NSNotFound, length: 0)

    /// `CSI > 1 u`: kitty flag 1 (disambiguate).
    private let push1 = "\u{1B}[>1u"
    /// `CSI > 3 u`: kitty flags 1 (disambiguate) + 2 (report event types).
    private let push1and2 = "\u{1B}[>3u"
    /// `CSI > 8 u`: kitty flag 8 (report all keys as escape codes) alone.
    private let push8 = "\u{1B}[>8u"
    /// `CSI > 10 u`: kitty flags 2 (event types) + 8 (report all keys).
    private let push2and8 = "\u{1B}[>10u"
    /// `CSI > 11 u`: kitty flags 1 + 2 + 8.
    private let push1and2and8 = "\u{1B}[>11u"

    private func makeRig(
        feeding setup: String,
        expecting expected: BBTermMode,
        absent: BBTermMode = [],
        optionIsMeta: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let sub: AnyClass = try XCTUnwrap(
            InputContextSeam.subclass,
            "rig: could not create the TerminalView subclass that carries the inputContext seam",
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
        let originalClass: AnyClass = try XCTUnwrap(object_getClass(view),
                                                    "object_getClass returned nil", file: file, line: line)
        XCTAssertTrue(ObjectIdentifier(originalClass) == ObjectIdentifier(TerminalView.self),
                      "rig: a fresh headless view must be a plain TerminalView before the seam subclass is adopted; class = \(originalClass)",
                      file: file, line: line)
        object_setClass(view, sub)
        registeredViews.append(view)
        XCTAssertTrue(view.inputContext === ime,
                      "rig: keyDown must consult the scripted input context; view.inputContext = \(String(describing: view.inputContext))",
                      file: file, line: line)

        let mode = snapshot.termMode
        XCTAssertTrue(mode.contains(expected),
                      "precondition: setup \(setup.debugDescription) must set mode bits \(expected.rawValue); termMode.rawValue = \(mode.rawValue)",
                      file: file, line: line)
        XCTAssertTrue(mode.isDisjoint(with: absent),
                      "precondition: setup \(setup.debugDescription) must leave mode bits \(absent.rawValue) clear; termMode.rawValue = \(mode.rawValue)",
                      file: file, line: line)
        return Rig(view: view, term: term, session: session, pty: pty, ime: ime,
                   snapshot: snapshot, setup: setup)
    }

    // MARK: - Formatting

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<none>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Human-readable wire form: `ESC` for 0x1B, the character for printable
    /// ASCII, `\xNN` otherwise.
    private func show(_ d: Data) -> String {
        if d.isEmpty { return "<none>" }
        return d.map { (b: UInt8) -> String in
            switch b {
            case 0x1B: return "ESC "
            case 0x20...0x7E: return String(UnicodeScalar(b)) + " "
            default: return String(format: "\\x%02X ", b)
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private func wire(_ s: String) -> String { show(Data(s.utf8)) }

    // MARK: - Hard-coded wire forms

    private let escPress = "\u{1B}[27u"
    private let escRelease = "\u{1B}[27;1:3u"
    private let aPress = "\u{1B}[97u"
    private let aRelease = "\u{1B}[97;1:3u"
    private let none = ""

    // MARK: - Keys

    private struct PhysKey {
        let name: String
        let keyCode: UInt16
        let chars: String
        let ignoring: String
        let flags: NSEvent.ModifierFlags
    }

    private let escKey = PhysKey(name: "Esc", keyCode: 53, chars: "\u{1B}", ignoring: "\u{1B}", flags: [])
    private let aKey = PhysKey(name: "a", keyCode: 0, chars: "a", ignoring: "a", flags: [])
    private let iKey = PhysKey(name: "i", keyCode: 34, chars: "i", ignoring: "i", flags: [])
    /// US-layout Option+E: produces the acute-accent dead key.
    private let optionEKey = PhysKey(name: "Option+E", keyCode: 14, chars: "\u{B4}", ignoring: "e", flags: [.option])

    private func event(_ type: NSEvent.EventType, _ key: PhysKey) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: key.flags, timestamp: 0,
                windowNumber: 0, context: nil,
                characters: key.chars, charactersIgnoringModifiers: key.ignoring,
                isARepeat: false, keyCode: key.keyCode),
            "NSEvent.keyEvent returned nil for \(key.name) (keyCode \(key.keyCode))")
    }

    /// Key-down; returns the bytes this one event put on the wire.
    private func down(_ key: PhysKey, on rig: Rig) throws -> Data {
        rig.pty.sent = Data()
        rig.view.keyDown(with: try event(.keyDown, key))
        return rig.pty.sent
    }

    /// Key-up; returns the bytes this one event put on the wire.
    private func up(_ key: PhysKey, on rig: Rig) throws -> Data {
        rig.pty.sent = Data()
        rig.view.keyUp(with: try event(.keyUp, key))
        return rig.pty.sent
    }

    // MARK: - Input-method scripts

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
            view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0),
                               replacementRange: notFound)
        case .unmarkText:
            view.unmarkText()
        }
    }

    /// The input method takes the key and replaces the preedit with `text`.
    private func scriptSetsPreedit(_ text: String, on rig: Rig) {
        let view = rig.view
        let range = notFound
        let length = (text as NSString).length
        rig.ime.script = { (_: NSEvent) -> Bool in
            view.setMarkedText(text, selectedRange: NSRange(location: length, length: 0),
                               replacementRange: range)
            return true
        }
    }

    /// The input method takes the key and cancels the pending preedit.
    private func scriptDismisses(_ dismissal: Dismissal, on rig: Rig) {
        let view = rig.view
        rig.ime.script = { [self] (_: NSEvent) -> Bool in
            perform(dismissal, on: view)
            return true
        }
    }

    private func beginPreedit(_ text: String, on rig: Rig,
                              file: StaticString = #filePath, line: UInt = #line) {
        rig.view.setMarkedText(text,
                               selectedRange: NSRange(location: (text as NSString).length, length: 0),
                               replacementRange: notFound)
        XCTAssertTrue(rig.view.hasMarkedText(),
                      "precondition: preedit \"\(text)\" must be pending", file: file, line: line)
    }

    private func assertSent(_ got: Data, _ expectedWire: String, _ message: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(show(got), wire(expectedWire),
                       "\(message()); sent [hex \(hex(got))], expected [hex \(hex(Data(expectedWire.utf8)))]",
                       file: file, line: line)
    }

    // MARK: - Preconditions (rig honesty)

    /// `keyDown` really hands the event to the scripted context, and the rig's
    /// mode fixtures really set the flags the claims below rely on.
    func test_precondition_keyDownConsultsScriptedContext_andModesAreSet() throws {
        let rig = try makeRig(feeding: push1and2,
                              expecting: [.disambiguateEscCodes, .reportEventTypes],
                              absent: [.reportAllKeysAsEsc])
        _ = try down(escKey, on: rig)
        XCTAssertEqual(rig.ime.keyCodesSeen, [53],
                       "keyDown must hand the Esc event to the input context exactly once; scripted context saw keyCodes \(rig.ime.keyCodesSeen)")

        let r2 = try makeRig(feeding: push2and8,
                             expecting: [.reportEventTypes, .reportAllKeysAsEsc],
                             absent: [.disambiguateEscCodes])
        _ = try down(aKey, on: r2)
        XCTAssertEqual(r2.ime.keyCodesSeen, [0],
                       "keyDown must hand the 'a' event to the input context exactly once; scripted context saw keyCodes \(r2.ime.keyCodesSeen)")
    }

    // MARK: - Anchors: reported presses keep their releases (green today and after)

    /// No preedit, the input method declines the key: Esc is an ordinary escape
    /// code under flags 1+2, and press and release pair.
    func test_anchor_escWithNoPreedit_flags1and2_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push1and2,
                              expecting: [.disambiguateEscCodes, .reportEventTypes])
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no preedit")

        let pressed = try down(escKey, on: rig)
        assertSent(pressed, escPress, "anchor: Esc PRESS with no preedit, flags 1+2, must be ESC [ 2 7 u")
        let released = try up(escKey, on: rig)
        assertSent(released, escRelease,
                   "anchor: Esc RELEASE (press was \(show(pressed))) with no preedit, flags 1+2, must be ESC [ 2 7 ; 1 : 3 u")
    }

    /// Real input contexts route Esc to `cancelOperation:` even when nothing is
    /// composing. The press is still sent then (pinned by
    /// `IMEPreeditDismissKeyLeakBlindTests`), so its release must be too.
    func test_anchor_escForwardedAsCancelWithNoPreedit_flags1and2_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push1and2,
                              expecting: [.disambiguateEscCodes, .reportEventTypes])
        scriptDismisses(.doCommandCancelOperation, on: rig)
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no preedit")

        let pressed = try down(escKey, on: rig)
        assertSent(pressed, escPress,
                   "anchor: Esc PRESS with no preedit (IME forwards cancelOperation:), flags 1+2, must be ESC [ 2 7 u")
        let released = try up(escKey, on: rig)
        assertSent(released, escRelease,
                   "anchor: Esc RELEASE (press was \(show(pressed))) must pair with the reported press: ESC [ 2 7 ; 1 : 3 u")
    }

    /// Flags 2+8, a plain letter that the input method commits straight away
    /// with `insertText` (an ABC layout, or a CJK IME in direct-input mode):
    /// the press is reported as `CSI 97 u`, so the release must be too.
    func test_anchor_letterCommittedByInsertText_flags2and8_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push2and8,
                              expecting: [.reportEventTypes, .reportAllKeysAsEsc])
        let view = rig.view
        let range = notFound
        rig.ime.script = { (_: NSEvent) -> Bool in
            view.insertText("a", replacementRange: range)
            return true
        }
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no preedit")

        let pressed = try down(aKey, on: rig)
        assertSent(pressed, aPress, "anchor: 'a' PRESS (insertText path), flags 2+8, must be ESC [ 9 7 u")
        let released = try up(aKey, on: rig)
        assertSent(released, aRelease,
                   "anchor: 'a' RELEASE (press was \(show(pressed))) must pair with the reported press: ESC [ 9 7 ; 1 : 3 u")
    }

    // MARK: - Control: without flag 2 a key-up is never reported

    /// No flag 2, no release events: Esc cancelling a preedit and a composing
    /// letter produce no bytes on the way down OR up. Green today; protects
    /// against a fix that starts reporting releases it must not report.
    func test_control_withoutFlag2_composingAndCancelling_sendNothingAtAll() throws {
        let setups: [(String, BBTermMode)] = [(push1, [.disambiguateEscCodes]), (push8, [.reportAllKeysAsEsc])]
        for (setup, bits) in setups {
            let rig = try makeRig(feeding: setup, expecting: bits, absent: [.reportEventTypes])

            // Composing letter.
            scriptSetsPreedit("あ", on: rig)
            let aDown = try down(aKey, on: rig)
            let aUp = try up(aKey, on: rig)
            XCTAssertTrue(rig.view.hasMarkedText(), "setup \(setup.debugDescription): the letter must leave a preedit pending")
            assertSent(aDown, none, "setup \(setup.debugDescription), no flag 2: composing 'a' PRESS must be swallowed")
            assertSent(aUp, none, "setup \(setup.debugDescription), no flag 2: composing 'a' RELEASE must stay silent")

            // Esc cancelling it.
            scriptDismisses(.doCommandCancelOperation, on: rig)
            let escDown = try down(escKey, on: rig)
            let escUp = try up(escKey, on: rig)
            XCTAssertFalse(rig.view.hasMarkedText(), "setup \(setup.debugDescription): Esc must have cancelled the preedit")
            assertSent(escDown, none, "setup \(setup.debugDescription), no flag 2: cancelling Esc PRESS must be swallowed")
            assertSent(escUp, none, "setup \(setup.debugDescription), no flag 2: cancelling Esc RELEASE must stay silent")
        }
    }

    // MARK: - The bug: Esc that cancels a preedit, flags 1+2

    /// `CSI > 3 u`: the press of the cancelling Esc is swallowed (nothing
    /// sent), so the key-up must be swallowed as well.
    func test_escCancellingPreedit_flags1and2_releaseIsNotSent() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig(feeding: push1and2,
                                  expecting: [.disambiguateEscCodes, .reportEventTypes])
            beginPreedit("かんじ", on: rig)
            scriptDismisses(dismissal, on: rig)

            let pressed = try down(escKey, on: rig)
            XCTAssertFalse(rig.view.hasMarkedText(),
                           "[\(dismissal.rawValue)] precondition: the cancelling Esc must have emptied the preedit")
            assertSent(pressed, none,
                       "[\(dismissal.rawValue)] precondition: Esc that cancels a preedit is consumed by the IME (no PRESS reaches the PTY)")

            let released = try up(escKey, on: rig)
            assertSent(released, none,
                       "[\(dismissal.rawValue)] flags 1+2: the TUI never saw this Esc go down, so the key-up must not be reported (orphan release ESC [ 2 7 ; 1 : 3 u)")
        }
    }

    // MARK: - The bug: Esc that cancels a preedit, flags 2+8 and 1+2+8

    func test_escCancellingPreedit_flags2and8_releaseIsNotSent() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig(feeding: push2and8,
                                  expecting: [.reportEventTypes, .reportAllKeysAsEsc])
            beginPreedit("かんじ", on: rig)
            scriptDismisses(dismissal, on: rig)

            let pressed = try down(escKey, on: rig)
            XCTAssertFalse(rig.view.hasMarkedText(),
                           "[\(dismissal.rawValue)] precondition: the cancelling Esc must have emptied the preedit")
            assertSent(pressed, none,
                       "[\(dismissal.rawValue)] precondition: Esc that cancels a preedit is consumed by the IME (no PRESS reaches the PTY)")

            let released = try up(escKey, on: rig)
            assertSent(released, none,
                       "[\(dismissal.rawValue)] flags 2+8: the TUI never saw this Esc go down, so the key-up must not be reported (orphan release ESC [ 2 7 ; 1 : 3 u)")
        }
    }

    func test_escCancellingPreedit_flags1and2and8_releaseIsNotSent() throws {
        for dismissal in Dismissal.allCases {
            let rig = try makeRig(feeding: push1and2and8,
                                  expecting: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc])
            beginPreedit("かんじ", on: rig)
            scriptDismisses(dismissal, on: rig)

            let pressed = try down(escKey, on: rig)
            XCTAssertFalse(rig.view.hasMarkedText(),
                           "[\(dismissal.rawValue)] precondition: the cancelling Esc must have emptied the preedit")
            assertSent(pressed, none,
                       "[\(dismissal.rawValue)] precondition: Esc that cancels a preedit is consumed by the IME (no PRESS reaches the PTY)")

            let released = try up(escKey, on: rig)
            assertSent(released, none,
                       "[\(dismissal.rawValue)] flags 1+2+8: the TUI never saw this Esc go down, so the key-up must not be reported (orphan release ESC [ 2 7 ; 1 : 3 u)")
        }
    }

    // MARK: - The bug: composing keystrokes under flags 2+8

    /// A whole CJK composition under flags 2+8: type `a`, type `i` (the preedit
    /// grows to あい), then Esc abandons it. Every key-down is consumed by the
    /// IME, so the TUI must receive NOTHING for the session: no press, and no
    /// orphan release for `a`, `i` or Esc.
    func test_composingSession_flags2and8_sendsNothingAtAll() throws {
        let rig = try makeRig(feeding: push2and8,
                              expecting: [.reportEventTypes, .reportAllKeysAsEsc])
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no preedit at the start")

        // First composing keystroke: 'a' starts the preedit.
        scriptSetsPreedit("あ", on: rig)
        let aDown = try down(aKey, on: rig)
        XCTAssertTrue(rig.view.hasMarkedText(), "precondition: 'a' must have started a preedit")
        assertSent(aDown, none, "precondition: the composing 'a' PRESS is consumed by the IME")
        let aUp = try up(aKey, on: rig)
        assertSent(aUp, none,
                   "flags 2+8: the first composing keystroke 'a' was swallowed by the IME, so its key-up must not become ESC [ 9 7 ; 1 : 3 u")

        // Second composing keystroke: 'i' grows the preedit.
        scriptSetsPreedit("あい", on: rig)
        let iDown = try down(iKey, on: rig)
        assertSent(iDown, none, "precondition: the composing 'i' PRESS is consumed by the IME")
        let iUp = try up(iKey, on: rig)
        assertSent(iUp, none,
                   "flags 2+8: the composing keystroke 'i' was swallowed by the IME, so its key-up must not become ESC [ 1 0 5 ; 1 : 3 u")

        // Esc abandons the composition.
        scriptDismisses(.doCommandCancelOperation, on: rig)
        let escDown = try down(escKey, on: rig)
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: Esc must have cancelled the preedit")
        assertSent(escDown, none, "precondition: the cancelling Esc PRESS is consumed by the IME")
        let escUp = try up(escKey, on: rig)
        assertSent(escUp, none,
                   "flags 2+8: the cancelling Esc was swallowed by the IME, so its key-up must not become ESC [ 2 7 ; 1 : 3 u")
    }

    /// Same first composing keystroke under flags 1+2+8.
    func test_firstComposingKeystroke_flags1and2and8_releaseIsNotSent() throws {
        let rig = try makeRig(feeding: push1and2and8,
                              expecting: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc])
        scriptSetsPreedit("あ", on: rig)

        let pressed = try down(aKey, on: rig)
        XCTAssertTrue(rig.view.hasMarkedText(), "precondition: 'a' must have started a preedit")
        assertSent(pressed, none, "precondition: the composing 'a' PRESS is consumed by the IME")

        let released = try up(aKey, on: rig)
        assertSent(released, none,
                   "flags 1+2+8: the first composing keystroke 'a' was swallowed by the IME, so its key-up must not become ESC [ 9 7 ; 1 : 3 u")
    }

    /// Dead-key flavour under flags 2+8 (Native Option, US layout): Option+E
    /// starts the acute-accent preedit and is consumed by the IME; releasing
    /// Option+E must not be reported to a TUI that never saw it pressed.
    func test_deadKeyOptionE_flags2and8_nativeOption_releaseIsNotSent() throws {
        let rig = try makeRig(feeding: push2and8,
                              expecting: [.reportEventTypes, .reportAllKeysAsEsc],
                              optionIsMeta: false)
        scriptSetsPreedit("\u{B4}", on: rig)

        let pressed = try down(optionEKey, on: rig)
        XCTAssertTrue(rig.view.hasMarkedText(), "precondition: Option+E must have started the dead-key preedit")
        assertSent(pressed, none, "precondition: the dead-key Option+E PRESS is consumed by the IME")

        let released = try up(optionEKey, on: rig)
        assertSent(released, none,
                   "flags 2+8, Native Option: the dead-key keystroke was swallowed by the IME, so its key-up must not be reported (orphan release)")
    }

    // MARK: - The suppression is per keystroke

    /// After a swallowed Esc (press and release both silent), the NEXT Esc with
    /// nothing composing is an ordinary Esc: press and release both reach the
    /// TUI. A "fix" that latches suppression for the rest of the session, or
    /// that silences every Esc release, fails here.
    func test_escAfterSwallowedEsc_flags1and2_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push1and2,
                              expecting: [.disambiguateEscCodes, .reportEventTypes])
        beginPreedit("かんじ", on: rig)
        scriptDismisses(.doCommandCancelOperation, on: rig)

        let firstDown = try down(escKey, on: rig)
        assertSent(firstDown, none, "precondition: the first Esc cancels the preedit and its PRESS is consumed")
        let firstUp = try up(escKey, on: rig)
        assertSent(firstUp, none,
                   "flags 1+2: the first (swallowed) Esc must have a silent key-up")

        rig.ime.script = { (_: NSEvent) -> Bool in false }      // IME idle now
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: nothing is composing any more")
        let secondDown = try down(escKey, on: rig)
        assertSent(secondDown, escPress,
                   "the second Esc has nothing to cancel; its PRESS must be ESC [ 2 7 u")
        let secondUp = try up(escKey, on: rig)
        assertSent(secondUp, escRelease,
                   "the second Esc was reported as pressed, so its RELEASE (press was \(show(secondDown))) must be ESC [ 2 7 ; 1 : 3 u")
    }

    /// Same per-keystroke rule on the composing-letter path: after a swallowed
    /// composing `a` (flags 2+8), a later `a` that the IME commits with
    /// `insertText` is a reported press and its release pairs.
    func test_letterAfterSwallowedComposingLetter_flags2and8_pairsPressAndRelease() throws {
        let rig = try makeRig(feeding: push2and8,
                              expecting: [.reportEventTypes, .reportAllKeysAsEsc])
        scriptSetsPreedit("あ", on: rig)
        let firstDown = try down(aKey, on: rig)
        assertSent(firstDown, none, "precondition: the composing 'a' PRESS is consumed by the IME")
        let firstUp = try up(aKey, on: rig)
        assertSent(firstUp, none,
                   "flags 2+8: the swallowed composing 'a' must have a silent key-up")

        // The composition ends (the IME drops the preedit), then a plain 'a'
        // typed in direct-input mode goes through insertText.
        rig.view.unmarkText()
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: composition over")
        let view = rig.view
        let range = notFound
        rig.ime.script = { (_: NSEvent) -> Bool in
            view.insertText("a", replacementRange: range)
            return true
        }
        let secondDown = try down(aKey, on: rig)
        assertSent(secondDown, aPress, "the direct-input 'a' PRESS must be ESC [ 9 7 u")
        let secondUp = try up(aKey, on: rig)
        assertSent(secondUp, aRelease,
                   "the direct-input 'a' was reported as pressed, so its RELEASE (press was \(show(secondDown))) must be ESC [ 9 7 ; 1 : 3 u")
    }
}
