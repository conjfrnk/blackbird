import XCTest
import AppKit
@testable import Blackbird

/// Pins the Ctrl+Enter path. On macOS a real Ctrl+Return (and Ctrl+Shift+Return)
/// keyDown is consumed inside `NSApplication.sendEvent` as AppKit's "show
/// contextual menu" gesture and never reaches the window or the view's
/// `keyDown`. A local event monitor (`ContextMenuKeyInterceptor.route`) re-routes
/// exactly those chords to a focused terminal view. `KeyEventClassifier` decides
/// which chords are swallowed and what characters to hand `KeyEncoder` ("\r" for
/// Return regardless of what Cocoa reports under Ctrl); the encoder then emits
/// CSI u under the kitty keyboard protocol.
final class CtrlEnterKeyTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    private let kVKReturn: UInt16 = 36
    private let kVKKeypadEnter: UInt16 = 76

    /// `ESC [ <codepoint> ; <mod> u`. `mod == 1` collapses to `ESC [ <cp> u`.
    private func csiU(_ codepoint: Int, mod: Int = 1) -> Data {
        var s = "\u{1B}[\(codepoint)"
        if mod > 1 { s += ";\(mod)" }
        s += "u"
        return Data(s.utf8)
    }

    private let kittyOn: BBTermMode = [.disambiguateEscCodes]

    /// Synthetic key event. Never posted anywhere; only handed to `route`.
    private func makeKeyEvent(
        _ type: NSEvent.EventType = .keyDown,
        keyCode: UInt16 = 36,
        flags: NSEvent.ModifierFlags
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode)!
    }

    /// Counts deliveries and remembers the event; stands in for the terminal view.
    /// `result` is what the receiver reports back: true = delivered, false = declined.
    private final class ChordReceiverView: NSView, ContextMenuKeyReceiving {
        var result = true
        private(set) var callCount = 0
        private(set) var lastEvent: NSEvent?

        func receiveContextMenuChord(_ event: NSEvent) -> Bool {
            callCount += 1
            lastEvent = event
            return result
        }
    }

    // MARK: - isContextMenuKeyChord: positives

    func test_chord_ctrlReturn_true() {
        XCTAssertTrue(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: [.control]),
            "Ctrl+Return is swallowed by AppKit's contextual-menu gesture")
    }

    func test_chord_ctrlShiftReturn_true() {
        XCTAssertTrue(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: [.control, .shift]),
            "Ctrl+Shift+Return is swallowed too (measured with real HID events)")
    }

    func test_chord_incidentalFlags_stillTrue() {
        let extras: [NSEvent.ModifierFlags] = [
            [.control, .capsLock],
            [.control, .function],
            [.control, .numericPad],
            [.control, .shift, .capsLock, .function, .numericPad],
        ]
        for flags in extras {
            XCTAssertTrue(
                KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: flags),
                "flags \(flags.rawValue): shift/capsLock/fn/numpad must not change the answer")
        }
    }

    // MARK: - isContextMenuKeyChord: negatives

    func test_chord_returnWithoutControl_false() {
        let noCtrl: [NSEvent.ModifierFlags] = [[], [.shift], [.option], [.capsLock], [.shift, .option]]
        for flags in noCtrl {
            XCTAssertFalse(
                KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: flags),
                "flags \(flags.rawValue): without Ctrl AppKit delivers Return normally")
        }
    }

    func test_chord_ctrlOptionReturn_false() {
        XCTAssertFalse(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: [.control, .option]),
            "Ctrl+Option+Return is not swallowed, so the monitor must leave it alone")
        XCTAssertFalse(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: [.control, .option, .shift]),
            "Option vetoes the chord even with Shift added")
    }

    func test_chord_ctrlCommandReturn_false() {
        XCTAssertFalse(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: [.control, .command]),
            "Ctrl+Cmd+Return is a menu/system chord and must not be hijacked")
        XCTAssertFalse(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKReturn, modifierFlags: [.control, .command, .shift]),
            "Command vetoes the chord even with Shift added")
    }

    func test_chord_ctrlKeypadEnter_false() {
        XCTAssertFalse(
            KeyEventClassifier.isContextMenuKeyChord(keyCode: kVKKeypadEnter, modifierFlags: [.control]),
            "Ctrl+keypad Enter is not swallowed (measured), so it is not part of the chord")
    }

    func test_chord_otherKeysWithControl_false() {
        // a, c, tab, space, delete, esc, left arrow.
        for code: UInt16 in [0, 8, 48, 49, 51, 53, 123] {
            XCTAssertFalse(
                KeyEventClassifier.isContextMenuKeyChord(keyCode: code, modifierFlags: [.control]),
                "keyCode \(code): only Return is part of the swallowed chord")
        }
    }

    // MARK: - isEnterKey

    func test_isEnterKey_returnAndKeypadEnter_true() {
        XCTAssertTrue(KeyEventClassifier.isEnterKey(keyCode: kVKReturn))
        XCTAssertTrue(KeyEventClassifier.isEnterKey(keyCode: kVKKeypadEnter))
    }

    func test_isEnterKey_otherKeys_false() {
        // a, c, tab, space, delete, esc, left arrow.
        for code: UInt16 in [0, 8, 48, 49, 51, 53, 123] {
            XCTAssertFalse(KeyEventClassifier.isEnterKey(keyCode: code),
                           "keyCode \(code) is not an Enter key")
        }
    }

    // MARK: - ContextMenuKeyInterceptor.route

    func test_route_ctrlReturnToReceiver_deliveredOnceAndConsumed() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(flags: [.control])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertNil(result, "A routed chord is consumed so AppKit never sees it")
        XCTAssertEqual(view.callCount, 1, "The receiver gets the chord exactly once")
        XCTAssertTrue(view.lastEvent === event, "The receiver gets the original event")
    }

    func test_route_ctrlShiftReturnToReceiver_deliveredOnceAndConsumed() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(flags: [.control, .shift])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertNil(result, "Ctrl+Shift+Return is swallowed by AppKit too, so it is routed")
        XCTAssertEqual(view.callCount, 1)
        XCTAssertTrue(view.lastEvent === event)
    }

    func test_route_receiverDeclines_eventPassesThroughUntouched() {
        let view = ChordReceiverView()
        view.result = false
        let event = makeKeyEvent(flags: [.control])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertTrue(result === event, "If the receiver can't act on the chord, AppKit must still see the event")
        XCTAssertEqual(view.callCount, 1, "The receiver is still asked exactly once")
    }

    func test_route_keyUp_passesThroughUntouched() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(.keyUp, flags: [.control])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertTrue(result === event, "Only keyDown is routed; keyUp must come back unchanged")
        XCTAssertEqual(view.callCount, 0)
    }

    func test_route_ctrlOptionReturn_passesThroughUntouched() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(flags: [.control, .option])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertTrue(result === event, "Ctrl+Option+Return already reaches keyDown; don't double-deliver")
        XCTAssertEqual(view.callCount, 0)
    }

    func test_route_ctrlCommandReturn_passesThroughUntouched() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(flags: [.control, .command])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertTrue(result === event, "Ctrl+Cmd+Return is left to menus/system")
        XCTAssertEqual(view.callCount, 0)
    }

    func test_route_ctrlKeypadEnter_passesThroughUntouched() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(keyCode: kVKKeypadEnter, flags: [.control])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertTrue(result === event, "Ctrl+keypad Enter is not swallowed, so not routed")
        XCTAssertEqual(view.callCount, 0)
    }

    func test_route_plainReturn_passesThroughUntouched() {
        let view = ChordReceiverView()
        let event = makeKeyEvent(flags: [])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: view)

        XCTAssertTrue(result === event, "Unmodified Return takes the normal keyDown path")
        XCTAssertEqual(view.callCount, 0)
    }

    func test_route_nonConformingResponder_passesThroughUntouched() {
        let event = makeKeyEvent(flags: [.control])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: NSView())

        XCTAssertTrue(result === event, "A first responder that isn't a terminal view must keep default AppKit behavior")
    }

    func test_route_nilResponder_passesThroughUntouched() {
        let event = makeKeyEvent(flags: [.control])

        let result = ContextMenuKeyInterceptor.route(event, firstResponder: nil)

        XCTAssertTrue(result === event, "No first responder: nothing to route to, event is returned as-is")
    }

    // MARK: - normalizedReturnChars

    func test_normalizedReturn_keyCode36_alwaysCR() {
        for chars in ["\n", "\u{3}", "", "\r"] {
            XCTAssertEqual(
                KeyEventClassifier.normalizedReturnChars(keyCode: kVKReturn, chars: chars), "\r",
                "Return must normalize to CR regardless of Cocoa's reported chars \(chars.unicodeScalars.map { $0.value })")
        }
    }

    func test_normalizedReturn_otherKeyCodes_unchanged() {
        // 0 'a', 48 tab, 51 delete, 53 esc, 76 keypad Enter.
        for code: UInt16 in [0, 48, 51, 53, 76] {
            for chars in ["\n", "\r", "a", "", "\u{3}"] {
                XCTAssertEqual(
                    KeyEventClassifier.normalizedReturnChars(keyCode: code, chars: chars), chars,
                    "keyCode \(code): only Return (36) is rewritten; everything else passes through, including keypad Enter")
            }
        }
    }

    // MARK: - Encoder end-to-end (kitty)

    func test_encode_ctrlEnter_kittyFlag1_csiU13_5() {
        XCTAssertEqual(KeyEncoder().encode(chars: "\r", modifiers: [.control], mode: kittyOn),
                       Data([0x1B, 0x5B, 0x31, 0x33, 0x3B, 0x35, 0x75]),
                       "Ctrl+Enter under flag 1 must be ESC[13;5u")
    }

    func test_encode_ctrlShiftEnter_kittyFlag1_csiU13_6() {
        XCTAssertEqual(KeyEncoder().encode(chars: "\r", modifiers: [.control, .shift], mode: kittyOn),
                       csiU(13, mod: 6),
                       "Ctrl+Shift+Enter: modifier param is 1 + shift(1) + ctrl(4) = 6")
    }

    func test_encode_ctrlOptionEnter_kittyFlag1_csiU13_7() {
        XCTAssertEqual(KeyEncoder().encode(chars: "\r", modifiers: [.control, .option], mode: kittyOn),
                       csiU(13, mod: 7),
                       "Ctrl+Option+Enter: modifier param is 1 + alt(2) + ctrl(4) = 7")
    }

    func test_encode_plainEnter_kittyFlag1_bareCR() {
        XCTAssertEqual(KeyEncoder().encode(chars: "\r", modifiers: [], mode: kittyOn),
                       Data([0x0D]),
                       "Unmodified Enter stays a bare CR so line discipline keeps working")
    }

    func test_encode_ctrlEnter_kittyFlag8_csiU13_5() {
        let mode: BBTermMode = [.disambiguateEscCodes, .reportAllKeysAsEsc]
        XCTAssertEqual(KeyEncoder().encode(chars: "\r", modifiers: [.control], mode: mode),
                       csiU(13, mod: 5),
                       "Ctrl+Enter with flags 1+8 is still ESC[13;5u")
    }

    func test_encode_ctrlEnter_legacy_singleCR() {
        // Pins only the encoder: fed "\r" under legacy mode it yields one CR byte.
        XCTAssertEqual(KeyEncoder().encode(chars: "\r", modifiers: [.control], mode: []),
                       Data([0x0D]),
                       "Legacy Ctrl+Enter with chars \"\\r\" must be a single 0x0D byte")
    }

    // MARK: - Pipeline

    func test_pipeline_ctrlReturnReportedAsLF_normalizesToCsiU13_5() {
        // Cocoa may report "\n" for Return under Ctrl; the classifier must
        // normalize to "\r" before encoding.
        let chars = KeyEventClassifier.normalizedReturnChars(keyCode: kVKReturn, chars: "\n")
        XCTAssertEqual(KeyEncoder().encode(chars: chars, modifiers: [.control], mode: [.disambiguateEscCodes]),
                       csiU(13, mod: 5),
                       "Normalized Return under Ctrl with kitty flag 1 must reach the TUI as ESC[13;5u")
    }
}
