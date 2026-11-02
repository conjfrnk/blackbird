import XCTest
import AppKit
@testable import Blackbird
@testable import BBCore

/// KEY-3 — the Insert key (macOS "Help", virtual key code 114) is dead.
///
/// A PC keyboard's Insert key arrives on a Mac as `kVK_Help` (key code 114)
/// carrying the AppKit private-use scalar `NSHelpFunctionKey` (U+F746); some
/// layouts / drivers report `NSInsertFunctionKey` (U+F727) for the same key.
/// The terminal convention (xterm, VT220, terminfo `kich1`) is that Insert is
/// `CSI 2 ~` (`CSI 2 ; <mod> ~` when modified). The encoder already knows
/// that sequence for `KeyEncoder.SpecialKey.insert`; the contract pinned here
/// is that a real Insert keypress actually *reaches* it:
///
///  1. `KeyEventClassifier.specialKey(for:)` classifies the Help / Insert
///     event as `.insert` — with or without Shift / Ctrl held.
///  2. A `keyDown` on a `TerminalView` therefore puts `ESC [ 2 ~` on the PTY
///     and consumes the event — it must NOT be forwarded up the responder
///     chain (where `NSResponder.keyDown` ends in the system beep).
///
/// Every claim is anchored against a neighbouring key that already works
/// (forward delete, `CSI 3 ~`), so a failure can only be the Insert gap and
/// never a broken rig.
///
/// Written blind: no `KeyEventClassifier` / `TerminalView.keyDown` body was
/// read; only declarations, doc comments and sibling tests.
final class InsertHelpKeyBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    /// macOS `kVK_Help` — what a PC keyboard's Insert key reports.
    private let helpKeyCode: UInt16 = 114
    /// `NSHelpFunctionKey`.
    private let helpScalar: UInt32 = 0xF746
    /// `NSInsertFunctionKey`.
    private let insertScalar: UInt32 = 0xF727
    /// `NSDeleteFunctionKey` (forward delete) — the known-good anchor.
    private let forwardDeleteScalar: UInt32 = 0xF728
    private let forwardDeleteKeyCode: UInt16 = 117

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func scalarName(_ v: UInt32) -> String {
        "U+" + String(v, radix: 16, uppercase: true)
    }

    /// A key-down the way AppKit delivers a non-printing editing key: the
    /// private-use scalar is both `characters` and `charactersIgnoringModifiers`.
    private func keyDown(
        scalar: UInt32,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        let chars = String(try XCTUnwrap(Unicode.Scalar(scalar),
                                         "\(scalarName(scalar)) is not a valid Unicode scalar"))
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            ),
            "NSEvent.keyEvent returned nil for keyCode \(keyCode)"
        )
    }

    /// Counts `keyDown` deliveries that fall off the end of the view's own
    /// handling (NSResponder's default `keyDown` forwards to `nextResponder`,
    /// and with nobody to take it the system beeps).
    private final class KeyEventCounter: NSResponder {
        var keyDownCount = 0
        override func keyDown(with event: NSEvent) { keyDownCount += 1 }
    }

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let counter: KeyEventCounter
    }

    /// One headless view (100x100 pt) + a 40x6 BBTerm + a headless session.
    /// A few KiB of memory, no PTY, no window, no child process.
    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "Metal device required", file: file, line: line)
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6), scrollback: 16),
                                 "BBTerm init failed", file: file, line: line)
        let snapshot = try XCTUnwrap(term.snapshot(), "snapshot() returned nil",
                                     file: file, line: line)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        let counter = KeyEventCounter()
        view.nextResponder = counter
        return Rig(view: view, term: term, session: session, recorder: recorder, counter: counter)
    }

    // MARK: - Harness self-checks

    /// The synthesized event really is what the bug report describes, and
    /// the rig really captures a special key that already works. Without
    /// these, an "empty bytes" result for Insert could be a dead rig.
    func test_precondition_rigCapturesForwardDelete_andInsertEventIsWhatAppKitSends() throws {
        let help = try keyDown(scalar: helpScalar, keyCode: helpKeyCode)
        XCTAssertEqual(help.keyCode, helpKeyCode, "synthesized Help event keyCode")
        XCTAssertEqual(help.charactersIgnoringModifiers?.unicodeScalars.first?.value, helpScalar,
                       "synthesized Help event must carry U+F746")
        XCTAssertEqual(help.charactersIgnoringModifiers?.unicodeScalars.count, 1,
                       "synthesized Help event must carry exactly one scalar")

        // Anchor 1: forward delete classifies and encodes today.
        let fwdDelete = try keyDown(scalar: forwardDeleteScalar, keyCode: forwardDeleteKeyCode, flags: [.function])
        XCTAssertEqual(KeyEventClassifier.specialKey(for: fwdDelete), .delete,
                       "anchor: U+F728 must classify as .delete before any Insert claim is trusted")

        // Anchor 2: forward delete through the real keyDown path lands in the
        // recorder as CSI 3 ~ and is consumed (not forwarded up the chain).
        let rig = try makeRig()
        rig.view.keyDown(with: fwdDelete)
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[3~"),
                       "anchor: forward delete via keyDown must record ESC[3~, got \(hex(rig.recorder.sent))")
        XCTAssertEqual(rig.counter.keyDownCount, 0,
                       "anchor: a handled special key must not be forwarded up the responder chain, "
                       + "forwarded \(rig.counter.keyDownCount) time(s)")
    }

    // MARK: - 1. Classifier

    /// The Help key (key code 114, U+F746) is the macOS face of PC Insert.
    /// Tried with the flag sets real keyboards attach (none, `.function`,
    /// `.help`, both) so a fix keyed on an incidental flag cannot pass.
    func test_classifier_helpKey_keyCode114_isInsert() throws {
        let flagSets: [(String, NSEvent.ModifierFlags)] = [
            ("[]", []),
            ("[.function]", [.function]),
            ("[.help]", [.help]),
            ("[.function, .help]", [.function, .help]),
        ]
        for (label, flags) in flagSets {
            let event = try keyDown(scalar: helpScalar, keyCode: helpKeyCode, flags: flags)
            XCTAssertEqual(KeyEventClassifier.specialKey(for: event), .insert,
                           "keyCode 114 + U+F746 (flags \(label)) must classify as .insert; "
                           + "got \(String(describing: KeyEventClassifier.specialKey(for: event))) — "
                           + "the Insert key is dead")
        }
    }

    /// `NSInsertFunctionKey` (U+F727) is the same physical key on some
    /// layouts and must behave identically to the Help scalar.
    func test_classifier_nsInsertFunctionKey_U_F727_isInsert() throws {
        for flags: NSEvent.ModifierFlags in [[], [.function]] {
            let event = try keyDown(scalar: insertScalar, keyCode: helpKeyCode, flags: flags)
            XCTAssertEqual(KeyEventClassifier.specialKey(for: event), .insert,
                           "keyCode 114 + U+F727 (flags \(flags.rawValue)) must classify as .insert; "
                           + "got \(String(describing: KeyEventClassifier.specialKey(for: event)))")
        }
    }

    /// Shift+Insert and Ctrl+Insert (the paste / copy chords on a PC
    /// keyboard) must classify as Insert too, and must encode to the
    /// xterm modified form `CSI 2 ; <1 + mask> ~` (Shift 2, Ctrl 5,
    /// Shift+Ctrl 6) when run through the encoder.
    func test_classifier_insertWithShiftOrControl_isInsert_andEncodesWithModifierParameter() throws {
        let cases: [(label: String, flags: NSEvent.ModifierFlags, mods: KeyEncoder.Modifiers, wire: String)] = [
            ("Shift",        [.shift],            [.shift],            "\u{1B}[2;2~"),
            ("Ctrl",         [.control],          [.control],          "\u{1B}[2;5~"),
            ("Shift+Ctrl",   [.shift, .control],  [.shift, .control],  "\u{1B}[2;6~"),
        ]
        let enc = KeyEncoder()
        for scalar in [helpScalar, insertScalar] {
            for c in cases {
                let event = try keyDown(scalar: scalar, keyCode: helpKeyCode, flags: c.flags)
                let key = KeyEventClassifier.specialKey(for: event)
                XCTAssertEqual(key, .insert,
                               "\(c.label)+Insert (\(scalarName(scalar)), keyCode 114) must classify as .insert; "
                               + "got \(String(describing: key))")
                if let key {
                    let out = enc.encodeSpecial(key, modifiers: c.mods)
                    XCTAssertEqual(out, bytes(c.wire),
                                   "\(c.label)+Insert must encode as \(c.wire.debugDescription); got \(hex(out))")
                }
            }
        }
    }

    /// Mapping Insert must not disturb its neighbours: forward delete stays
    /// `.delete`, Home/End/PageUp/PageDown stay as they were, and Backspace
    /// (a plain DEL character) stays unmapped.
    func test_classifier_insertMapping_leavesNeighbouringKeysAlone() throws {
        let neighbours: [(String, UInt32, UInt16, KeyEncoder.SpecialKey)] = [
            ("forward delete", 0xF728, 117, .delete),
            ("home",           0xF729, 115, .home),
            ("end",            0xF72B, 119, .end),
            ("page up",        0xF72C, 116, .pageUp),
            ("page down",      0xF72D, 121, .pageDown),
        ]
        for (name, scalar, keyCode, expected) in neighbours {
            let event = try keyDown(scalar: scalar, keyCode: keyCode, flags: [.function])
            XCTAssertEqual(KeyEventClassifier.specialKey(for: event), expected,
                           "\(name) (\(scalarName(scalar)), keyCode \(keyCode)) must still classify as \(expected)")
        }
        let backspace = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
        XCTAssertNil(KeyEventClassifier.specialKey(for: backspace),
                     "Backspace must stay unmapped so it emits DEL via the character path")
    }

    // MARK: - 2. Full keyDown path

    /// The headline symptom: pressing Insert must put `ESC [ 2 ~` on the PTY
    /// (vim / nano overwrite toggle) — not nothing, and not the raw UTF-8 of
    /// the private-use scalar — and the event must be consumed, not forwarded
    /// up the responder chain where it beeps.
    func test_keyDown_helpKey_keyCode114_sendsCsi2Tilde_andIsConsumed() throws {
        for flags: NSEvent.ModifierFlags in [[], [.function]] {
            let rig = try makeRig()
            rig.view.keyDown(with: try keyDown(scalar: helpScalar, keyCode: helpKeyCode, flags: flags))
            XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[2~"),
                           "Insert (keyCode 114, U+F746, flags \(flags.rawValue)) must send ESC[2~; "
                           + "sent \(hex(rig.recorder.sent))")
            XCTAssertEqual(rig.counter.keyDownCount, 0,
                           "Insert (flags \(flags.rawValue)) must be consumed, not forwarded up the responder chain "
                           + "(that path ends in the system beep); forwarded \(rig.counter.keyDownCount) time(s)")
        }
    }

    /// Same contract for the `NSInsertFunctionKey` spelling of the key.
    func test_keyDown_nsInsertFunctionKey_U_F727_sendsCsi2Tilde_andIsConsumed() throws {
        let rig = try makeRig()
        rig.view.keyDown(with: try keyDown(scalar: insertScalar, keyCode: helpKeyCode))
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[2~"),
                       "Insert (keyCode 114, U+F727) must send ESC[2~; sent \(hex(rig.recorder.sent))")
        XCTAssertEqual(rig.counter.keyDownCount, 0,
                       "Insert (U+F727) must be consumed, not forwarded up the responder chain; "
                       + "forwarded \(rig.counter.keyDownCount) time(s)")
    }

    /// Holding the key (auto-repeat) must keep producing Insert, one
    /// `CSI 2 ~` per event — the key is not a one-shot.
    func test_keyDown_helpKey_autoRepeat_sendsOneCsi2TildePerEvent() throws {
        let rig = try makeRig()
        let event = try keyDown(scalar: helpScalar, keyCode: helpKeyCode)
        rig.view.keyDown(with: event)
        rig.view.keyDown(with: event)
        rig.view.keyDown(with: event)
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[2~\u{1B}[2~\u{1B}[2~"),
                       "three Insert events must send three ESC[2~; sent \(hex(rig.recorder.sent))")
        XCTAssertEqual(rig.counter.keyDownCount, 0,
                       "no Insert event may be forwarded up the responder chain; "
                       + "forwarded \(rig.counter.keyDownCount) time(s)")
    }
}
