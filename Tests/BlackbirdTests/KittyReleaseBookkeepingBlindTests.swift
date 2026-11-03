import XCTest
import AppKit
@testable import Blackbird
import BBCore

/// IP-3b -- Kitty flag 2 (`reportEventTypes`): the key-UP bookkeeping must
/// mirror exactly what the TUI was told on the way DOWN.
///
/// Contract (https://sw.kovidgoyal.net/kitty/keyboard-protocol/, "Report event
/// types"). A TUI that pushed flags 1+2 (`CSI > 3 u`) is sent a press (1), a
/// repeat (2) and a release (3) for every key reported as an escape code. The
/// three events of one physical key are a matched set:
///
///   * a release is only ever sent for a press the TUI was actually given;
///   * the release carries the modifier field the PRESS carried, so a TUI that
///     tracks held keys / chords can pair the two. (An Alt+a press that was
///     `ESC [ 97 ; 3 u` is released with `ESC [ 97 ; 3 : 3 u` even if the user
///     lifted Option a moment before the letter.)
///
/// Three ways the bookkeeping goes wrong, one test group each:
///
/// (a) Focus loss. The user holds a key the TUI saw go down, then loses focus
///     (Cmd-Tab, click into another window) before releasing it, comes back,
///     and presses + releases the same physical key together with Cmd (a menu
///     shortcut such as Cmd+Up / Cmd+C). The Cmd shortcut belongs to the app
///     layer, so the TUI must not receive any key event for it. The record of
///     "presses the TUI was given" must therefore be dropped when the view
///     resigns first responder / its window resigns key; otherwise the
///     shortcut's key-up (which usually arrives with Cmd already lifted, so it
///     looks like a plain key release) is reported as an orphan release.
///
/// (b) IME. A key press that the input method absorbs (a keystroke that
///     arrives while a composition is pending belongs to the IME: candidate
///     selection with Up, Esc to cancel) is never delivered to the TUI, so its
///     release must not be reported either.
///
/// (c) Modifier release order. Option+a, then Option is lifted BEFORE the
///     letter: the key-up event for `a` carries no Option flag and looks like a
///     plain `a` release (silent under flags 1+2). The TUI was told
///     `ESC [ 97 ; 3 u`, so it must be told `ESC [ 97 ; 3 : 3 u`; the release
///     modifiers come from the press, not from the release-time modifier flags.
///
/// Fixture realism. Option+a is delivered the way AppKit does on a US layout:
/// `characters == "å"`, `charactersIgnoringModifiers == "a"`, flags `.option`;
/// once Option is lifted the key-up of the same physical key reads `"a"` / `"a"`
/// with no flags (Shift still held: `"A"` / `"A"`, `.shift`). Navigation keys
/// carry the AppKit private-use scalar as both strings plus `.function`
/// (arrows also `.numericPad`). Mode bits come from feeding the real
/// `CSI > n u` push to a real `BBTerm` and every rig asserts the bits it relies
/// on. Focus loss is exercised through the view's two production seams:
/// `resignFirstResponder()` and the window-resign-key teardown hook
/// (`_testOnly_simulateWindowResignKey`); a real key-window transition cannot
/// be driven from a headless host.
///
/// Anchors. Behaviours that work today and must keep working (a release with
/// nothing unusual in between, a fresh press / release after focus loss or
/// after an absorbed press, no stale modifiers after an Alt cycle) are pinned
/// next to the failing claims, so a red result can only come from the IP-3b
/// mechanism and never from a dead rig.
///
/// Written blind: no `KeyEncoder` / `TerminalView` body was read; only
/// declarations, doc comments and sibling tests. The final "Review follow-ups"
/// section was added after the implementation and is NOT blind.
///
/// Memory/time pre-flight: one headless `TerminalView` + one 40x6 `BBTerm`
/// (scrollback 16) per rig, at most four rigs per test; no window, no PTY, no
/// child process, no timers, no runloop pumping. A few hundred KiB each.
final class KittyReleaseBookkeepingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private let ESC = "\u{1B}"

    /// `CSI > 3 u`: kitty flags 1 (disambiguate) + 2 (report event types).
    private let push1and2 = "\u{1B}[>3u"
    /// `CSI > 11 u`: flags 1 + 2 + 8 (report all keys as escape codes).
    private let push1and2and8 = "\u{1B}[>11u"

    private let flags1and2: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]

    private let notFound = NSRange(location: NSNotFound, length: 0)

    private func hex(_ d: Data) -> String {
        d.isEmpty ? "<empty>" : d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Human-readable wire form: `ESC` for 0x1B, the character for printable
    /// ASCII, `\xNN` otherwise.
    private func show(_ d: Data) -> String {
        if d.isEmpty { return "<empty>" }
        return d.map { b -> String in
            switch b {
            case 0x1B: return "ESC "
            case 0x20...0x7E: return String(UnicodeScalar(b)) + " "
            default: return String(format: "\\x%02X ", b)
            }
        }.joined().trimmingCharacters(in: .whitespaces)
    }

    private func wire(_ s: String) -> String { show(Data(s.utf8)) }

    private func scalar(_ v: UInt32) -> String { String(Unicode.Scalar(v)!) }

    // MARK: - Rig

    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let snapshot: BBSnapshot
    }

    /// One headless view + a 40x6 BBTerm. `setup` is fed to the real parser and
    /// the resulting snapshot (and so `termMode`) is installed on the view.
    private func makeRig(
        feeding setup: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
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
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder
        return Rig(view: view, term: term, session: session, recorder: recorder, snapshot: snapshot)
    }

    /// Rig whose snapshot mode is asserted to contain flags 1+2 (and flag 8
    /// only when `expectAllKeys`).
    private func makeKittyRig(
        feeding setup: String,
        expectAllKeys: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let rig = try makeRig(feeding: setup, file: file, line: line)
        let mode = rig.snapshot.termMode
        XCTAssertTrue(mode.contains(flags1and2),
                      "precondition: \(setup.debugDescription) must set flags 1+2; termMode.rawValue=\(mode.rawValue)",
                      file: file, line: line)
        XCTAssertEqual(mode.contains(.reportAllKeysAsEsc), expectAllKeys,
                       "precondition: flag 8 presence for \(setup.debugDescription) must be \(expectAllKeys); "
                       + "termMode.rawValue=\(mode.rawValue)",
                       file: file, line: line)
        return rig
    }

    /// A physical key and how AppKit would describe it.
    private struct PhysKey {
        let name: String
        let chars: String
        let charsIgnoringModifiers: String
        let keyCode: UInt16
        /// Flags the key itself brings (`.function`, `.numericPad`), without
        /// any user modifier.
        let baseFlags: NSEvent.ModifierFlags
    }

    private func event(
        _ type: NSEvent.EventType, _ key: PhysKey, flags: NSEvent.ModifierFlags,
        chars: String? = nil, ignoring: String? = nil, isRepeat: Bool = false
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: key.baseFlags.union(flags),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars ?? key.chars,
                charactersIgnoringModifiers: ignoring ?? key.charsIgnoringModifiers,
                isARepeat: isRepeat,
                keyCode: key.keyCode
            ),
            "NSEvent.keyEvent returned nil for \(key.name) (keyCode \(key.keyCode))"
        )
    }

    private func down(
        _ key: PhysKey, flags: NSEvent.ModifierFlags, on rig: Rig,
        chars: String? = nil, ignoring: String? = nil, isRepeat: Bool = false
    ) throws -> Data {
        rig.recorder.sent = Data()
        rig.view.keyDown(with: try event(.keyDown, key, flags: flags, chars: chars, ignoring: ignoring,
                                         isRepeat: isRepeat))
        return rig.recorder.sent
    }

    private func up(
        _ key: PhysKey, flags: NSEvent.ModifierFlags, on rig: Rig,
        chars: String? = nil, ignoring: String? = nil
    ) throws -> Data {
        rig.recorder.sent = Data()
        rig.view.keyUp(with: try event(.keyUp, key, flags: flags, chars: chars, ignoring: ignoring))
        return rig.recorder.sent
    }

    // Keys ---------------------------------------------------------------

    private let keyA = PhysKey(name: "a", chars: "a", charsIgnoringModifiers: "a", keyCode: 0, baseFlags: [])
    private let keyC = PhysKey(name: "c", chars: "c", charsIgnoringModifiers: "c", keyCode: 8, baseFlags: [])
    private let keyEsc = PhysKey(name: "Esc", chars: "\u{1B}", charsIgnoringModifiers: "\u{1B}",
                                 keyCode: 53, baseFlags: [])

    private var keyUpArrow: PhysKey {
        PhysKey(name: "Up", chars: scalar(0xF700), charsIgnoringModifiers: scalar(0xF700),
                keyCode: 126, baseFlags: [.numericPad, .function])
    }

    // Wire forms ----------------------------------------------------------

    private var upPress: String { "\(ESC)[A" }
    private var upRelease: String { "\(ESC)[1;1:3A" }

    // Focus loss ----------------------------------------------------------

    /// The user switches away from the terminal (Cmd-Tab / click elsewhere):
    /// the view resigns first responder and its window resigns key. Both
    /// production seams are exercised, in the order AppKit uses.
    private func loseFocus(_ rig: Rig) {
        _ = rig.view.resignFirstResponder()
        rig.view._testOnly_simulateWindowResignKey()
    }

    // IME -----------------------------------------------------------------

    /// Start a pending composition the way an input method does.
    private func beginComposition(
        on rig: Rig, file: StaticString = #filePath, line: UInt = #line
    ) {
        rig.view.setMarkedText("かん",
                               selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: notFound)
        XCTAssertTrue(rig.view.hasMarkedText(),
                      "precondition: a composition (preedit \"かん\") must be pending",
                      file: file, line: line)
    }

    // MARK: - Anchors (work today, must keep working)

    /// Rig honesty: Up arrow under flags 1+2 reports press and release with
    /// nothing unusual in between.
    func test_anchor_upArrow_pressAndRelease_withoutFocusLoss_pair() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire(upPress),
                       "anchor: Up press under flags 1+2 must be \(wire(upPress)); got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(released), wire(upRelease),
                       "anchor: Up release under flags 1+2 must be \(wire(upRelease)); got \(show(released)) [hex \(hex(released))]")
    }

    /// Dropping the record on focus loss must not break later presses: after
    /// the view lost focus, a fresh press + release of the same key still pairs.
    func test_anchor_upArrow_afterFocusLoss_freshPressAndRelease_stillPair() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        loseFocus(rig)
        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire(upPress),
                       "anchor: Up press after focus loss must be \(wire(upPress)); got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(released), wire(upRelease),
                       "anchor: Up release of a press made after focus loss must be \(wire(upRelease)); "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    /// Rig honesty for group (b): with no composition pending, Esc is an escape
    /// code on the way down and its release is reported.
    func test_anchor_esc_noComposition_pressAndRelease_pair() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: no composition pending")
        let pressed = try down(keyEsc, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire("\(ESC)[27u"),
                       "anchor: Esc press (no composition) under flags 1+2 must be ESC [ 27 u; "
                       + "got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyEsc, flags: [], on: rig)
        XCTAssertEqual(show(released), wire("\(ESC)[27;1:3u"),
                       "anchor: Esc release (no composition) under flags 1+2 must be ESC [ 27 ; 1 : 3 u; "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    /// An absorbed press must not poison the same physical key afterwards: once
    /// the composition is over, a fresh Up press + release pairs normally.
    func test_anchor_upArrow_afterAbsorbedPress_freshPressAndRelease_stillPair() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        beginComposition(on: rig)
        _ = try down(keyUpArrow, flags: [], on: rig)
        rig.view.unmarkText()
        _ = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertFalse(rig.view.hasMarkedText(), "precondition: composition is over")

        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire(upPress),
                       "anchor: Up press after the composition ended must be \(wire(upPress)); "
                       + "got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(released), wire(upRelease),
                       "anchor: Up release after the composition ended must be \(wire(upRelease)); "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    /// Anchor for group (c): Option+a with Option still held at the key-up is
    /// the order that is reported today.
    func test_anchor_altLetter_optionHeldAtRelease_flags1and2_pairs() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        let pressed = try down(keyA, flags: [.option], on: rig, chars: "å", ignoring: "a")
        XCTAssertEqual(show(pressed), wire("\(ESC)[97;3u"),
                       "anchor: Option+a press under flags 1+2 must be ESC [ 97 ; 3 u; got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyA, flags: [.option], on: rig, chars: "å", ignoring: "a")
        XCTAssertEqual(show(released), wire("\(ESC)[97;3:3u"),
                       "anchor: Option+a release (Option still held) must be ESC [ 97 ; 3 : 3 u; "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    /// The press-time modifier record must be consumed by the release: after an
    /// Alt+a cycle in which Option was lifted first, a plain `a` press + release
    /// must not be reported as another Alt release.
    func test_anchor_plainLetter_afterAltCycle_hasNoStaleModifiers() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        let altPress = try down(keyA, flags: [.option], on: rig, chars: "å", ignoring: "a")
        XCTAssertEqual(show(altPress), wire("\(ESC)[97;3u"),
                       "precondition: Option+a press must be ESC [ 97 ; 3 u; got \(show(altPress)) [hex \(hex(altPress))]")
        _ = try up(keyA, flags: [], on: rig, chars: "a", ignoring: "a")

        let plainPress = try down(keyA, flags: [], on: rig)
        let plainRelease = try up(keyA, flags: [], on: rig)
        XCTAssertEqual(hex(plainRelease), hex(Data()),
                       "anchor: a plain `a` release under flags 1+2 must stay silent (the plain press was "
                       + "\(show(plainPress)), not an escape code); got \(show(plainRelease)) [hex \(hex(plainRelease))]")
    }

    // MARK: - (a) Focus loss drops the record of forwarded presses

    /// One scenario: `key` goes down and is forwarded to the TUI; the view
    /// loses focus before the key-up; on return the same physical key is used
    /// for a Cmd shortcut. Returns the bytes the key-up of the shortcut put on
    /// the PTY. `deliverCmdKeyDown` is false when the menu's key-equivalent
    /// consumed the shortcut's key-down before the view saw it. `expectedPress`
    /// nil means "any escape code" (the premise is only that the TUI was given
    /// the press).
    private func focusLossThenCmdShortcutRelease(
        key: PhysKey, pressFlags: NSEvent.ModifierFlags = [],
        pressChars: String? = nil, pressIgnoring: String? = nil, expectedPress: String?,
        feeding setup: String, expectAllKeys: Bool = false,
        deliverCmdKeyDown: Bool, cmdReleasedFirst: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> Data {
        let rig = try makeKittyRig(feeding: setup, expectAllKeys: expectAllKeys, file: file, line: line)
        let pressed = try down(key, flags: pressFlags, on: rig, chars: pressChars, ignoring: pressIgnoring)
        if let expectedPress = expectedPress {
            XCTAssertEqual(show(pressed), wire(expectedPress),
                           "premise: the TUI must be given the press \(wire(expectedPress)); "
                           + "got \(show(pressed)) [hex \(hex(pressed))]",
                           file: file, line: line)
        } else {
            XCTAssertTrue(pressed.starts(with: Data([0x1B])),
                          "premise: the TUI must be given an escape-code press for \(key.name); "
                          + "got \(show(pressed)) [hex \(hex(pressed))]",
                          file: file, line: line)
        }

        // The key-up never arrives: focus moved to another app / window.
        loseFocus(rig)

        if deliverCmdKeyDown {
            let cmdPress = try down(key, flags: [.command], on: rig)
            XCTAssertEqual(hex(cmdPress), hex(Data()),
                           "premise: Cmd+\(key.name) is an app shortcut; its press must not reach the TUI; "
                           + "got \(show(cmdPress)) [hex \(hex(cmdPress))]",
                           file: file, line: line)
        }
        return try up(key, flags: cmdReleasedFirst ? [] : [.command], on: rig)
    }

    private var focusLossCombos: [(deliverCmdKeyDown: Bool, cmdReleasedFirst: Bool, label: String)] {
        [
            (false, true, "Cmd keyDown consumed by menu, Cmd released before the key (key-up has NO .command flag)"),
            (false, false, "Cmd keyDown consumed by menu, Cmd still held at key-up"),
            (true, true, "Cmd keyDown delivered to the view, Cmd released before the key (key-up has NO .command flag)"),
            (true, false, "Cmd keyDown delivered to the view, Cmd still held at key-up"),
        ]
    }

    /// Up held, focus lost before its key-up, then Cmd+Up (a scroll / navigation
    /// shortcut) on return: the shortcut's release is not for the TUI.
    func test_a_focusLossThenCmdUpShortcut_releaseIsNotReported() throws {
        for combo in focusLossCombos {
            let released = try focusLossThenCmdShortcutRelease(
                key: keyUpArrow, expectedPress: upPress, feeding: push1and2,
                deliverCmdKeyDown: combo.deliverCmdKeyDown, cmdReleasedFirst: combo.cmdReleasedFirst)
            XCTAssertEqual(hex(released), hex(Data()),
                           "Up was pressed (TUI saw it), focus was lost, then Cmd+Up was typed on return. "
                           + "The TUI never saw that Cmd+Up go down, so it must get no release for it; "
                           + "got \(show(released)) [hex \(hex(released))] (\(combo.label))")
        }
    }

    /// Same with other navigation / function keys that report a plain release:
    /// Home and F5 held across the focus loss, then Cmd+Home / Cmd+F5.
    func test_a_focusLossThenCmdNavAndFunctionKeys_releaseIsNotReported() throws {
        let keys: [PhysKey] = [
            PhysKey(name: "Home", chars: scalar(0xF729), charsIgnoringModifiers: scalar(0xF729),
                    keyCode: 115, baseFlags: [.function]),
            PhysKey(name: "F5", chars: scalar(0xF708), charsIgnoringModifiers: scalar(0xF708),
                    keyCode: 96, baseFlags: [.function]),
        ]
        for key in keys {
            for combo in focusLossCombos where combo.cmdReleasedFirst {
                let released = try focusLossThenCmdShortcutRelease(
                    key: key, expectedPress: nil, feeding: push1and2,
                    deliverCmdKeyDown: combo.deliverCmdKeyDown, cmdReleasedFirst: combo.cmdReleasedFirst)
                XCTAssertEqual(hex(released), hex(Data()),
                               "\(key.name) was pressed (TUI saw it), focus was lost, then Cmd+\(key.name) was typed "
                               + "on return. The TUI never saw that Cmd shortcut go down, so it must get no release "
                               + "for it; got \(show(released)) [hex \(hex(released))] (\(combo.label))")
            }
        }
    }

    /// Same with a text key under flag 8 (every key is an escape code): `c`
    /// held across the focus loss, then Cmd+C (copy) on return. Skips only if
    /// the headless view never routes a plain text key-down to the PTY at all.
    func test_a_focusLossThenCmdCShortcut_flags1and2and8_releaseIsNotReported() throws {
        let probe = try makeKittyRig(feeding: push1and2and8, expectAllKeys: true)
        let probePress = try down(keyC, flags: [], on: probe)
        if probePress.isEmpty {
            throw XCTSkip("headless keyDown does not reach insertText in this host; "
                          + "the Up / Home / F5 tests carry the contract")
        }
        for combo in focusLossCombos where combo.cmdReleasedFirst {
            let released = try focusLossThenCmdShortcutRelease(
                key: keyC, expectedPress: "\(ESC)[99u", feeding: push1and2and8, expectAllKeys: true,
                deliverCmdKeyDown: combo.deliverCmdKeyDown, cmdReleasedFirst: combo.cmdReleasedFirst)
            XCTAssertEqual(hex(released), hex(Data()),
                           "`c` was pressed (TUI saw ESC [ 99 u), focus was lost, then Cmd+C was typed on return. "
                           + "The TUI never saw that Cmd+C go down, so it must get no release for it; "
                           + "got \(show(released)) [hex \(hex(released))] (\(combo.label))")
        }
    }

    // MARK: - (b) A press absorbed by the IME is not a forwarded press

    /// Press `key` while a composition is pending (the IME owns it) and return
    /// the bytes of the press and of the release. `endCompositionBeforeRelease`
    /// models the user committing / cancelling before lifting the key.
    private func absorbedPressRelease(
        key: PhysKey, endCompositionBeforeRelease: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (press: Data, release: Data) {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false, file: file, line: line)
        beginComposition(on: rig, file: file, line: line)
        let pressed = try down(key, flags: [], on: rig)
        XCTAssertEqual(hex(pressed), hex(Data()),
                       "premise: \(key.name) pressed mid-composition belongs to the IME and must not reach the TUI; "
                       + "got \(show(pressed)) [hex \(hex(pressed))]",
                       file: file, line: line)
        if endCompositionBeforeRelease {
            rig.view.unmarkText()
        }
        let released = try up(key, flags: [], on: rig)
        return (pressed, released)
    }

    func test_b_upArrowAbsorbedByComposition_releaseIsNotReported() throws {
        for ended in [false, true] {
            let result = try absorbedPressRelease(key: keyUpArrow, endCompositionBeforeRelease: ended)
            XCTAssertEqual(hex(result.release), hex(Data()),
                           "Up pressed during a pending composition was consumed by the IME (the TUI got "
                           + "\(show(result.press))), so its release must not be reported; "
                           + "got \(show(result.release)) [hex \(hex(result.release))] "
                           + "(composition \(ended ? "ended" : "still pending") at key-up)")
        }
    }

    func test_b_escAbsorbedByComposition_releaseIsNotReported() throws {
        for ended in [false, true] {
            let result = try absorbedPressRelease(key: keyEsc, endCompositionBeforeRelease: ended)
            XCTAssertEqual(hex(result.release), hex(Data()),
                           "Esc pressed during a pending composition was consumed by the IME (the TUI got "
                           + "\(show(result.press))), so its release must not be reported; "
                           + "got \(show(result.release)) [hex \(hex(result.release))] "
                           + "(composition \(ended ? "ended" : "still pending") at key-up)")
        }
    }

    // MARK: - (c) The release carries the modifiers the press carried

    /// Option(+Shift)+a goes down, then the modifiers are lifted in the order
    /// described by `release*`, then the letter comes up. The press must be the
    /// expected escape code (otherwise there is nothing to pair), and the
    /// release must repeat the press' modifier field with event type 3.
    private func assertAltReleaseCarriesPressModifiers(
        setup: String, expectAllKeys: Bool,
        pressFlags: NSEvent.ModifierFlags, pressChars: String, pressIgnoring: String,
        releaseFlags: NSEvent.ModifierFlags, releaseChars: String, releaseIgnoring: String,
        expectedPress: String, expectedRelease: String, scenario: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeKittyRig(feeding: setup, expectAllKeys: expectAllKeys, file: file, line: line)
        let pressed = try down(keyA, flags: pressFlags, on: rig, chars: pressChars, ignoring: pressIgnoring)
        XCTAssertEqual(show(pressed), wire(expectedPress),
                       "\(scenario): premise: PRESS must be \(wire(expectedPress)); got \(show(pressed)) [hex \(hex(pressed))]",
                       file: file, line: line)
        let released = try up(keyA, flags: releaseFlags, on: rig, chars: releaseChars, ignoring: releaseIgnoring)
        XCTAssertEqual(show(released), wire(expectedRelease),
                       "\(scenario): the TUI was told \(show(pressed)); the RELEASE must repeat the press' "
                       + "modifiers and be \(wire(expectedRelease)); got \(show(released)) [hex \(hex(released))]",
                       file: file, line: line)
    }

    /// Option+a, Option lifted first, flags 1+2: release must be CSI 97;3:3u.
    func test_c_altLetter_optionLiftedBeforeLetter_flags1and2_releaseCarriesPressModifiers() throws {
        try assertAltReleaseCarriesPressModifiers(
            setup: push1and2, expectAllKeys: false,
            pressFlags: [.option], pressChars: "å", pressIgnoring: "a",
            releaseFlags: [], releaseChars: "a", releaseIgnoring: "a",
            expectedPress: "\(ESC)[97;3u", expectedRelease: "\(ESC)[97;3:3u",
            scenario: "Option+a, Option lifted first, flags 1+2")
    }

    /// Option+Shift+a, both lifted before the letter: modifier field stays 4.
    func test_c_altShiftLetter_bothModifiersLiftedBeforeLetter_flags1and2_releaseCarriesPressModifiers() throws {
        try assertAltReleaseCarriesPressModifiers(
            setup: push1and2, expectAllKeys: false,
            pressFlags: [.option, .shift], pressChars: "Å", pressIgnoring: "A",
            releaseFlags: [], releaseChars: "a", releaseIgnoring: "a",
            expectedPress: "\(ESC)[97;4u", expectedRelease: "\(ESC)[97;4:3u",
            scenario: "Option+Shift+a, both modifiers lifted first, flags 1+2")
    }

    /// Option+Shift+a, only Option lifted (Shift still down at the key-up): the
    /// release must still say 4, not the release-time 2.
    func test_c_altShiftLetter_optionLiftedShiftHeld_flags1and2_releaseCarriesPressModifiers() throws {
        try assertAltReleaseCarriesPressModifiers(
            setup: push1and2, expectAllKeys: false,
            pressFlags: [.option, .shift], pressChars: "Å", pressIgnoring: "A",
            releaseFlags: [.shift], releaseChars: "A", releaseIgnoring: "A",
            expectedPress: "\(ESC)[97;4u", expectedRelease: "\(ESC)[97;4:3u",
            scenario: "Option+Shift+a, Option lifted first with Shift still held, flags 1+2")
    }

    /// Flags 1+2+8: a plain-looking release is reported under flag 8, so the
    /// failure there is the wrong modifier field (`97;1:3`), not silence.
    func test_c_altLetter_optionLiftedBeforeLetter_flags1and2and8_releaseCarriesPressModifiers() throws {
        try assertAltReleaseCarriesPressModifiers(
            setup: push1and2and8, expectAllKeys: true,
            pressFlags: [.option], pressChars: "å", pressIgnoring: "a",
            releaseFlags: [], releaseChars: "a", releaseIgnoring: "a",
            expectedPress: "\(ESC)[97;3u", expectedRelease: "\(ESC)[97;3:3u",
            scenario: "Option+a, Option lifted first, flags 1+2+8")
    }

    // MARK: - Review follow-ups (authored AFTER the implementation, NOT blind)

    // These pin gaps the post-implementation review found in the ledger; they
    // are regression guards for specific mechanisms, not contract tests.

    private let keyTwo = PhysKey(name: "2", chars: "2", charsIgnoringModifiers: "2", keyCode: 18, baseFlags: [])

    /// Shift goes down AFTER `2`, so the key-up reads `@` (Shift is the one
    /// modifier `charactersIgnoringModifiers` keeps). The release must name the
    /// key the press named (50), not the shifted symbol's code (64).
    func test_review_shiftPressedAfterKeyDown_releaseKeepsThePressKeyCode() throws {
        let rig = try makeKittyRig(feeding: push1and2and8, expectAllKeys: true)
        let pressed = try down(keyTwo, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire("\(ESC)[50u"),
                       "premise: `2` under flags 1+2+8 must be ESC [ 50 u; got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyTwo, flags: [.shift], on: rig, chars: "@", ignoring: "@")
        XCTAssertEqual(show(released), wire("\(ESC)[50;1:3u"),
                       "the TUI was told key 50 went down; its release must be ESC [ 50 ; 1 : 3 u even though "
                       + "Shift made the key-up read `@`; got \(show(released)) [hex \(hex(released))]")
    }

    /// Option+a goes down, the user holds `a` into auto-repeat, and Option is
    /// lifted mid-hold, so the next repeat arrives without Option. The repeat
    /// must not rewrite what the TUI was told about the press.
    func test_review_autoRepeatAfterOptionLifted_doesNotRewriteTheReleaseModifiers() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        let pressed = try down(keyA, flags: [.option], on: rig, chars: "å", ignoring: "a")
        XCTAssertEqual(show(pressed), wire("\(ESC)[97;3u"),
                       "premise: Option+a press must be ESC [ 97 ; 3 u; got \(show(pressed)) [hex \(hex(pressed))]")
        _ = try down(keyA, flags: [], on: rig, chars: "a", ignoring: "a", isRepeat: true)
        let released = try up(keyA, flags: [], on: rig, chars: "a", ignoring: "a")
        XCTAssertEqual(show(released), wire("\(ESC)[97;3:3u"),
                       "the release must repeat the PRESS' modifiers (3) after an auto-repeat that carried none; "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    /// A key whose key-up was lost (no focus change), then pressed again with
    /// Cmd and released: the fresh Cmd press purges the stale entry, so the
    /// shortcut's key-up is not paired with the earlier plain press.
    func test_review_cmdKeyDownOverStaleEntry_dropsTheOwedRelease() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire(upPress),
                       "premise: Up press must be \(wire(upPress)); got \(show(pressed)) [hex \(hex(pressed))]")
        let cmdPress = try down(keyUpArrow, flags: [.command], on: rig)
        XCTAssertEqual(hex(cmdPress), hex(Data()),
                       "premise: Cmd+Up is an app shortcut; got \(show(cmdPress)) [hex \(hex(cmdPress))]")
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(hex(released), hex(Data()),
                       "the shortcut's release is not for the TUI; got \(show(released)) [hex \(hex(released))]")
    }

    /// Cmd goes down while a forwarded key is held: the key-up carries
    /// `.command`, but the TUI saw the press and is still owed the release.
    func test_review_commandHeldAtKeyUp_ofForwardedPress_releaseStillReported() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire(upPress),
                       "premise: Up press must be \(wire(upPress)); got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyUpArrow, flags: [.command], on: rig)
        XCTAssertEqual(show(released), wire(upRelease),
                       "the TUI saw Up go down; its release must be \(wire(upRelease)) even with Cmd down at the "
                       + "key-up; got \(show(released)) [hex \(hex(released))]")
    }

    /// Each focus-loss seam must clear the ledger on its own (the shared
    /// `loseFocus` helper lets either mask the other).
    func test_review_resignFirstResponderAlone_dropsTheLedger() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        _ = try down(keyUpArrow, flags: [], on: rig)
        _ = rig.view.resignFirstResponder()
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(hex(released), hex(Data()),
                       "first-responder loss alone must forget the press; got \(show(released)) [hex \(hex(released))]")
    }

    func test_review_windowResignKeyAlone_dropsTheLedger() throws {
        let rig = try makeKittyRig(feeding: push1and2, expectAllKeys: false)
        _ = try down(keyUpArrow, flags: [], on: rig)
        rig.view._testOnly_simulateWindowResignKey()
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(hex(released), hex(Data()),
                       "window-resign-key alone must forget the press; got \(show(released)) [hex \(hex(released))]")
    }
}
