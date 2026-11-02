import XCTest
import AppKit
@testable import Blackbird
import BBCore

/// IP-3 -- Kitty flag 2 (`reportEventTypes`): the key-UP half of the protocol
/// is wrong in two directions.
///
/// Contract under test (https://sw.kovidgoyal.net/kitty/keyboard-protocol/,
/// "Report event types"). A TUI that pushes flag 2 together with flag 1
/// (`CSI > 3 u`) asks to be told, for every key that is sent as an escape
/// code, whether the event was a press (1), a repeat (2) or a release (3).
/// The three events of one physical key are a matched set: whatever the TUI
/// was told about the press, it must be told about the release (same key,
/// same modifier field, event type `:3`), and a key the TUI was never told
/// about pressing must not produce a release out of nowhere.
///
/// (a) Alt+letter. With Option-as-Meta on (the default) Option+a under flags
///     1+2 is already an escape code on the way down, `ESC [ 97 ; 3 u`. Its
///     release must therefore be `ESC [ 97 ; 3 : 3 u`. Alt+Shift+a is the
///     same with modifier field 4 (`ESC [ 97 ; 4 u` / `ESC [ 97 ; 4 : 3 u`).
///     The same holds when flag 4 (alternate keys) or flag 16 (associated
///     text) is stacked on 1+2, but NOT necessarily flag 8 (which is the
///     only combination that works today, and so serves as an anchor).
///
/// (b) Cmd shortcuts. Command-modified keys belong to the app layer (menu
///     shortcuts); the TUI never sees their press. Their release must not
///     reach the TUI either -- including when the user lets go of Cmd BEFORE
///     the other key, which is how a quick Cmd+C is typed in practice: the
///     key-up event then carries no Command flag at all and looks like a
///     plain `c` / plain Up arrow release. The TUI would get
///     `ESC [ 99 ; 1 : 3 u` (flags 1+2+8 or 2+8) or `ESC [ 1 ; 1 : 3 A`
///     (flags 1+2, Cmd+arrow) for a key it never saw go down.
///
/// Fixture realism. Option+a is delivered the way AppKit does on a US layout:
/// `characters == "å"`, `charactersIgnoringModifiers == "a"`, flags
/// `.option`. Option+Shift+a is `"Å"` / `"A"` with `.option + .shift`.
/// Cmd+C is `"c"` / `"c"` with `.command`. Navigation keys carry the AppKit
/// private-use scalar as both strings and `.function` (arrows also
/// `.numericPad`). Mode bits are produced by feeding the real `CSI > n u`
/// pushes to a real `BBTerm`, and every rig asserts the bits it relies on.
///
/// Anchors. Releases that work today and must keep working (Up arrow,
/// Ctrl+letter, Alt+letter under flag 8, a plain Cmd-less key after a swallowed
/// Cmd shortcut) and releases that are correctly silent (flag 2 off, plain
/// text key, Option as a native composer) are pinned next to the failing
/// claims, so a red result can only come from the IP-3 mechanism and never from
/// a dead rig.
///
/// Written blind: no `KeyEncoder` / `TerminalView` body was read; only
/// declarations, doc comments and sibling tests.
///
/// Memory/time pre-flight: one headless `TerminalView` + one 40x6 `BBTerm`
/// (scrollback 16) per rig, a handful of rigs per test; no window, no PTY, no
/// child process, no timers, no runloop pumping. A few hundred KiB each.
final class KittyReleaseAltCmdBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private let ESC = "\u{1B}"

    /// `CSI > 3 u`: kitty flags 1 (disambiguate) + 2 (report event types).
    private let push1and2 = "\u{1B}[>3u"
    /// `CSI > 7 u`: flags 1 + 2 + 4 (report alternate keys).
    private let push1and2and4 = "\u{1B}[>7u"
    /// `CSI > 11 u`: flags 1 + 2 + 8 (report all keys as escape codes).
    private let push1and2and8 = "\u{1B}[>11u"
    /// `CSI > 19 u`: flags 1 + 2 + 16 (report associated text).
    private let push1and2and16 = "\u{1B}[>19u"
    /// `CSI > 10 u`: flags 2 + 8 (no disambiguate bit).
    private let push2and8 = "\u{1B}[>10u"
    /// `CSI > 1 u`: flag 1 only (no event types).
    private let push1 = "\u{1B}[>1u"

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

    /// Rig whose snapshot mode is asserted to contain exactly the wanted
    /// kitty bits (and to have flag 8 only when `expectAllKeys`).
    private func makeKittyRig(
        feeding setup: String,
        requiring required: BBTermMode,
        expectAllKeys: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let rig = try makeRig(feeding: setup, file: file, line: line)
        let mode = rig.snapshot.termMode
        XCTAssertTrue(mode.contains(required),
                      "precondition: \(setup.debugDescription) must set \(required.rawValue); "
                      + "termMode.rawValue=\(mode.rawValue)",
                      file: file, line: line)
        XCTAssertTrue(mode.contains(.reportEventTypes),
                      "precondition: \(setup.debugDescription) must set flag 2; termMode.rawValue=\(mode.rawValue)",
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
        chars: String? = nil, ignoring: String? = nil
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
                isARepeat: false,
                keyCode: key.keyCode
            ),
            "NSEvent.keyEvent returned nil for \(key.name) (keyCode \(key.keyCode))"
        )
    }

    private func down(
        _ key: PhysKey, flags: NSEvent.ModifierFlags, on rig: Rig,
        chars: String? = nil, ignoring: String? = nil
    ) throws -> Data {
        rig.recorder.sent = Data()
        rig.view.keyDown(with: try event(.keyDown, key, flags: flags, chars: chars, ignoring: ignoring))
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

    private var keyUpArrow: PhysKey {
        PhysKey(name: "Up", chars: scalar(0xF700), charsIgnoringModifiers: scalar(0xF700),
                keyCode: 126, baseFlags: [.numericPad, .function])
    }

    /// The navigation / function keys the dossier names for Cmd.
    private var cmdNavKeys: [PhysKey] {
        [
            keyUpArrow,
            PhysKey(name: "Home", chars: scalar(0xF729), charsIgnoringModifiers: scalar(0xF729),
                    keyCode: 115, baseFlags: [.function]),
            PhysKey(name: "End", chars: scalar(0xF72B), charsIgnoringModifiers: scalar(0xF72B),
                    keyCode: 119, baseFlags: [.function]),
            PhysKey(name: "PageUp", chars: scalar(0xF72C), charsIgnoringModifiers: scalar(0xF72C),
                    keyCode: 116, baseFlags: [.function]),
            PhysKey(name: "F5", chars: scalar(0xF708), charsIgnoringModifiers: scalar(0xF708),
                    keyCode: 96, baseFlags: [.function]),
        ]
    }

    // MARK: - (a) Encoder level: Alt+letter release

    private let flags1and2: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]

    /// Anchor: the press half. If this were wrong the release expectations
    /// below would not be about the release at all.
    func test_encoder_anchor_altLetterPress_isCsiU_underFlags1and2() {
        let enc = KeyEncoder(optionIsMeta: true)
        let plain = enc.encode(chars: "a", modifiers: [.option], mode: flags1and2, eventType: .press)
        XCTAssertEqual(show(plain), wire("\(ESC)[97;3u"),
                       "anchor: Option+a PRESS under flags 1+2 must be ESC [ 97 ; 3 u; got \(show(plain)) [hex \(hex(plain))]")
        let shifted = enc.encode(chars: "A", modifiers: [.option, .shift], mode: flags1and2, eventType: .press)
        XCTAssertEqual(show(shifted), wire("\(ESC)[97;4u"),
                       "anchor: Option+Shift+a PRESS under flags 1+2 must be ESC [ 97 ; 4 u; got \(show(shifted)) [hex \(hex(shifted))]")
    }

    /// The headline: Option+a released under flags 1+2 is `ESC [ 97 ; 3 : 3 u`,
    /// not nothing.
    func test_encoder_altLetterRelease_flags1and2_reportsReleaseEvent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "a", modifiers: [.option], mode: flags1and2, eventType: .release)
        XCTAssertEqual(show(got), wire("\(ESC)[97;3:3u"),
                       "Option+a RELEASE under flags 1+2 (press was ESC [ 97 ; 3 u) must be "
                       + "ESC [ 97 ; 3 : 3 u; got \(show(got)) [hex \(hex(got))]")
    }

    /// Alt+Shift+letter: modifier field 4, code point stays the unshifted key.
    func test_encoder_altShiftLetterRelease_flags1and2_reportsReleaseEvent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "A", modifiers: [.option, .shift], mode: flags1and2, eventType: .release)
        XCTAssertEqual(show(got), wire("\(ESC)[97;4:3u"),
                       "Option+Shift+a RELEASE under flags 1+2 (press was ESC [ 97 ; 4 u) must be "
                       + "ESC [ 97 ; 4 : 3 u; got \(show(got)) [hex \(hex(got))]")
    }

    /// Stacking flag 4 (alternate keys) must not change the release of an
    /// unshifted Alt+letter: there is no shifted/base-layout key to add.
    func test_encoder_altLetterRelease_flags1and2and4_reportsReleaseEvent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes, .reportAlternateKeys]
        let got = enc.encode(chars: "a", modifiers: [.option], mode: mode, eventType: .release)
        XCTAssertEqual(show(got), wire("\(ESC)[97;3:3u"),
                       "Option+a RELEASE under flags 1+2+4 must be ESC [ 97 ; 3 : 3 u; "
                       + "got \(show(got)) [hex \(hex(got))]")
    }

    /// Stacking flag 16 (associated text): whatever the encoder decides about
    /// text parameters on a release, the key / modifier / event-type head of
    /// the sequence is fixed and the sequence is still a CSI u.
    func test_encoder_altLetterRelease_flags1and2and16_reportsReleaseEvent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes, .reportAssociatedText]
        let got = enc.encode(chars: "a", modifiers: [.option], mode: mode, eventType: .release)
        let s = String(decoding: got, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("\(ESC)[97;3:3") && s.hasSuffix("u"),
                      "Option+a RELEASE under flags 1+2+16 must be a CSI u starting ESC [ 97 ; 3 : 3; "
                      + "got \(show(got)) [hex \(hex(got))]")
    }

    /// Anchor (works today): with flag 8 stacked the same release IS reported,
    /// which is what makes the 1+2 silence a divergence rather than a design.
    func test_encoder_anchor_altLetterRelease_flags1and2and8_reportsReleaseEvent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc]
        let got = enc.encode(chars: "a", modifiers: [.option], mode: mode, eventType: .release)
        XCTAssertEqual(show(got), wire("\(ESC)[97;3:3u"),
                       "anchor: Option+a RELEASE under flags 1+2+8 must be ESC [ 97 ; 3 : 3 u; "
                       + "got \(show(got)) [hex \(hex(got))]")
    }

    /// Must-not-change: a release is only reported when flag 2 is on.
    func test_encoder_anchor_altLetterRelease_flag1Only_staysSilent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "a", modifiers: [.option], mode: [.disambiguateEscCodes], eventType: .release)
        XCTAssertEqual(hex(got), hex(Data()),
                       "anchor: Option+a release without flag 2 must stay silent; got \(show(got)) [hex \(hex(got))]")
    }

    /// Must-not-change: a plain text key (no Option) has no escape-code press
    /// under flags 1+2, so it has no release either.
    func test_encoder_anchor_plainLetterRelease_flags1and2_staysSilent() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "a", modifiers: [], mode: flags1and2, eventType: .release)
        XCTAssertEqual(hex(got), hex(Data()),
                       "anchor: plain 'a' release under flags 1+2 must stay silent; got \(show(got)) [hex \(hex(got))]")
    }

    /// Must-not-change: with Option as a native composer ("å" is typed text,
    /// Option is invisible) the press is text, so the release is silent.
    func test_encoder_anchor_nativeOptionLetterRelease_flags1and2_staysSilent() {
        let enc = KeyEncoder(optionIsMeta: false)
        let press = enc.encode(chars: "å", modifiers: [.option], mode: flags1and2, eventType: .press)
        XCTAssertEqual(hex(press), hex(Data("å".utf8)),
                       "anchor: native Option+a press must be the composed character; got \(show(press)) [hex \(hex(press))]")
        let got = enc.encode(chars: "å", modifiers: [.option], mode: flags1and2, eventType: .release)
        XCTAssertEqual(hex(got), hex(Data()),
                       "anchor: native Option+a release must stay silent; got \(show(got)) [hex \(hex(got))]")
    }

    // MARK: - (a) View level: Alt+letter press + release

    /// The whole key path: Option+a down then up, as AppKit delivers them.
    private func assertAltRoundTrip(
        rig: Rig, shift: Bool, pressWire: String?, releaseHead: String,
        exactRelease: Bool, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let flags: NSEvent.ModifierFlags = shift ? [.option, .shift] : [.option]
        let chars = shift ? "Å" : "å"
        let ignoring = shift ? "A" : "a"
        let label = shift ? "Option+Shift+a" : "Option+a"

        let pressed = try down(keyA, flags: flags, on: rig, chars: chars, ignoring: ignoring)
        if let pressWire = pressWire {
            XCTAssertEqual(show(pressed), wire(pressWire),
                           "\(context): precondition: \(label) PRESS must be \(wire(pressWire)); "
                           + "got \(show(pressed)) [hex \(hex(pressed))]",
                           file: file, line: line)
        }
        XCTAssertFalse(pressed.isEmpty,
                       "\(context): precondition: \(label) PRESS must reach the PTY as an escape code "
                       + "(otherwise there is no press to pair a release with)",
                       file: file, line: line)

        let released = try up(keyA, flags: flags, on: rig, chars: chars, ignoring: ignoring)
        if exactRelease {
            XCTAssertEqual(show(released), wire(releaseHead),
                           "\(context): \(label) RELEASE (press was \(show(pressed))) must be "
                           + "\(wire(releaseHead)); got \(show(released)) [hex \(hex(released))]",
                           file: file, line: line)
        } else {
            let s = String(decoding: released, as: UTF8.self)
            XCTAssertTrue(s.hasPrefix(releaseHead) && s.hasSuffix("u"),
                          "\(context): \(label) RELEASE (press was \(show(pressed))) must be a CSI u "
                          + "starting \(wire(releaseHead)); got \(show(released)) [hex \(hex(released))]",
                          file: file, line: line)
        }
    }

    func test_view_altLetter_pressAndRelease_flags1and2() throws {
        let rig = try makeKittyRig(feeding: push1and2, requiring: flags1and2, expectAllKeys: false)
        try assertAltRoundTrip(rig: rig, shift: false, pressWire: "\(ESC)[97;3u",
                               releaseHead: "\(ESC)[97;3:3u", exactRelease: true, context: "flags 1+2")
    }

    func test_view_altShiftLetter_pressAndRelease_flags1and2() throws {
        let rig = try makeKittyRig(feeding: push1and2, requiring: flags1and2, expectAllKeys: false)
        try assertAltRoundTrip(rig: rig, shift: true, pressWire: "\(ESC)[97;4u",
                               releaseHead: "\(ESC)[97;4:3u", exactRelease: true, context: "flags 1+2")
    }

    func test_view_altLetter_pressAndRelease_flags1and2and4() throws {
        let rig = try makeKittyRig(feeding: push1and2and4,
                                   requiring: [.disambiguateEscCodes, .reportEventTypes, .reportAlternateKeys],
                                   expectAllKeys: false)
        try assertAltRoundTrip(rig: rig, shift: false, pressWire: "\(ESC)[97;3u",
                               releaseHead: "\(ESC)[97;3:3u", exactRelease: true, context: "flags 1+2+4")
    }

    func test_view_altLetter_pressAndRelease_flags1and2and16() throws {
        let rig = try makeKittyRig(feeding: push1and2and16,
                                   requiring: [.disambiguateEscCodes, .reportEventTypes, .reportAssociatedText],
                                   expectAllKeys: false)
        // The press may legitimately carry associated text under flag 16, so
        // only its presence is pinned; the release must lead with the fixed head.
        try assertAltRoundTrip(rig: rig, shift: false, pressWire: nil,
                               releaseHead: "\(ESC)[97;3:3", exactRelease: false, context: "flags 1+2+16")
    }

    /// Anchor: the same Option+a round trip under flags 1+2+8 pairs up today.
    func test_view_anchor_altLetter_pressAndRelease_flags1and2and8() throws {
        let rig = try makeKittyRig(feeding: push1and2and8,
                                   requiring: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc],
                                   expectAllKeys: true)
        try assertAltRoundTrip(rig: rig, shift: false, pressWire: "\(ESC)[97;3u",
                               releaseHead: "\(ESC)[97;3:3u", exactRelease: true, context: "flags 1+2+8")
    }

    /// Anchor: the Up arrow pairs press and release under flags 1+2 today, so
    /// the rig really does deliver key-ups through the event-type path.
    func test_view_anchor_upArrow_pressAndRelease_flags1and2() throws {
        let rig = try makeKittyRig(feeding: push1and2, requiring: flags1and2, expectAllKeys: false)
        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire("\(ESC)[A"),
                       "anchor: Up press under flags 1+2 must be ESC [ A; got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(released), wire("\(ESC)[1;1:3A"),
                       "anchor: Up release under flags 1+2 must be ESC [ 1 ; 1 : 3 A; got \(show(released)) [hex \(hex(released))]")
    }

    /// Anchor: Ctrl+C pairs press and release under flags 1+2 today.
    func test_view_anchor_ctrlC_pressAndRelease_flags1and2() throws {
        let rig = try makeKittyRig(feeding: push1and2, requiring: flags1and2, expectAllKeys: false)
        let pressed = try down(keyC, flags: [.control], on: rig, chars: "\u{03}", ignoring: "c")
        XCTAssertEqual(show(pressed), wire("\(ESC)[99;5u"),
                       "anchor: Ctrl+C press under flags 1+2 must be ESC [ 99 ; 5 u; got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyC, flags: [.control], on: rig, chars: "\u{03}", ignoring: "c")
        XCTAssertEqual(show(released), wire("\(ESC)[99;5:3u"),
                       "anchor: Ctrl+C release under flags 1+2 must be ESC [ 99 ; 5 : 3 u; got \(show(released)) [hex \(hex(released))]")
    }

    // MARK: - (b) View level: Cmd shortcut releases are never reported

    /// One Cmd shortcut, four ways of delivering it. Whatever AppKit does with
    /// the key-down (consumed by the menu, so no `keyDown` reaches the view;
    /// or delivered and swallowed by the view), the TUI sees no press; so the
    /// key-up must produce no bytes either, whether Cmd is still down on the
    /// key-up or was released first.
    private func assertCmdShortcutReleaseSilent(
        _ key: PhysKey, on rig: Rig, context: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for deliverKeyDown in [false, true] {
            for cmdReleasedFirst in [true, false] {
                let how = "keyDown " + (deliverKeyDown ? "delivered" : "consumed by menu")
                    + ", Cmd " + (cmdReleasedFirst ? "released before the key (key-up has NO .command flag)"
                                                    : "still held at key-up")
                if deliverKeyDown {
                    let pressed = try down(key, flags: [.command], on: rig)
                    XCTAssertEqual(hex(pressed), hex(Data()),
                                   "\(context): premise: Cmd+\(key.name) press must not reach the TUI (app shortcut); "
                                   + "got \(show(pressed)) [hex \(hex(pressed))] (\(how))",
                                   file: file, line: line)
                }
                let released = try up(key, flags: cmdReleasedFirst ? [] : [.command], on: rig)
                XCTAssertEqual(hex(released), hex(Data()),
                               "\(context): Cmd+\(key.name) was never pressed from the TUI's point of view, so its "
                               + "release must not be reported; got \(show(released)) [hex \(hex(released))] (\(how))",
                               file: file, line: line)
            }
        }
    }

    func test_view_cmdC_release_flags1and2and8_isNeverReported() throws {
        let rig = try makeKittyRig(feeding: push1and2and8,
                                   requiring: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc],
                                   expectAllKeys: true)
        try assertCmdShortcutReleaseSilent(keyC, on: rig, context: "flags 1+2+8")
    }

    func test_view_cmdC_release_flags2and8_isNeverReported() throws {
        let rig = try makeKittyRig(feeding: push2and8,
                                   requiring: [.reportEventTypes, .reportAllKeysAsEsc],
                                   expectAllKeys: true)
        try assertCmdShortcutReleaseSilent(keyC, on: rig, context: "flags 2+8")
    }

    func test_view_cmdNavKeys_release_flags1and2_isNeverReported() throws {
        let rig = try makeKittyRig(feeding: push1and2, requiring: flags1and2, expectAllKeys: false)
        for key in cmdNavKeys {
            try assertCmdShortcutReleaseSilent(key, on: rig, context: "flags 1+2")
        }
    }

    func test_view_cmdNavKeys_release_flags1and2and8_isNeverReported() throws {
        let rig = try makeKittyRig(feeding: push1and2and8,
                                   requiring: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc],
                                   expectAllKeys: true)
        for key in cmdNavKeys {
            try assertCmdShortcutReleaseSilent(key, on: rig, context: "flags 1+2+8")
        }
    }

    /// Must-not-change: swallowing a Cmd shortcut must not poison the same
    /// physical key afterwards. Up pressed WITHOUT Cmd right after a swallowed
    /// Cmd+Up still pairs press and release.
    func test_view_anchor_upArrowAfterSwallowedCmdUp_stillPairsPressAndRelease_flags1and2() throws {
        let rig = try makeKittyRig(feeding: push1and2, requiring: flags1and2, expectAllKeys: false)
        _ = try down(keyUpArrow, flags: [.command], on: rig)
        _ = try up(keyUpArrow, flags: [], on: rig)

        let pressed = try down(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(pressed), wire("\(ESC)[A"),
                       "anchor: plain Up press after a swallowed Cmd+Up must be ESC [ A; got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyUpArrow, flags: [], on: rig)
        XCTAssertEqual(show(released), wire("\(ESC)[1;1:3A"),
                       "anchor: plain Up release after a swallowed Cmd+Up must still be ESC [ 1 ; 1 : 3 A; "
                       + "got \(show(released)) [hex \(hex(released))]")
    }

    /// Must-not-change: same for a text key under flag 8. After a swallowed
    /// Cmd+C the plain `c` still reports press and release. Skips only when the
    /// headless view never routes a text key-down to the PTY at all (the arrow
    /// anchors above carry the contract then).
    func test_view_anchor_plainCAfterSwallowedCmdC_stillPairsPressAndRelease_flags1and2and8() throws {
        let rig = try makeKittyRig(feeding: push1and2and8,
                                   requiring: [.disambiguateEscCodes, .reportEventTypes, .reportAllKeysAsEsc],
                                   expectAllKeys: true)
        _ = try down(keyC, flags: [.command], on: rig)
        _ = try up(keyC, flags: [], on: rig)

        let pressed = try down(keyC, flags: [], on: rig)
        if pressed.isEmpty {
            throw XCTSkip("headless keyDown does not reach insertText in this host; "
                          + "the arrow anchor carries the contract")
        }
        XCTAssertEqual(show(pressed), wire("\(ESC)[99u"),
                       "anchor: plain c press under flags 1+2+8 must be ESC [ 99 u; got \(show(pressed)) [hex \(hex(pressed))]")
        let released = try up(keyC, flags: [], on: rig)
        XCTAssertEqual(show(released), wire("\(ESC)[99;1:3u"),
                       "anchor: plain c release under flags 1+2+8 must be ESC [ 99 ; 1 : 3 u; got \(show(released)) [hex \(hex(released))]")
    }
}
