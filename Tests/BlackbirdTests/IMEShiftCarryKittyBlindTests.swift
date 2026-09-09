import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests for the Shift carry-through on the
/// `NSTextInputClient.insertText` path under kitty flags 4 / 8.
///
/// Background: AppKit delivers a plain Shift+A keystroke to a text-input
/// client as `insertText("A")`, having already applied Shift to the
/// character. Under kitty flag 8 (`reportAllKeysAsEsc`) every key must be
/// reported as CSI u with its modifiers, so the view has to remember the
/// keyDown's modifiers for the duration of the input-context round trip
/// (`pendingInsertTextModifiers`) and hand them to the encoder. Under flag 4
/// (`reportAlternateKeys`) the shifted key is appended as `<cp>:<shifted>`.
///
/// Legacy modes are pinned unchanged: with no kitty flags — or with only
/// xterm `modifyOtherKeys` — Shift+A is the plain byte `A`.
///
/// The snapshot whose `termMode` gates the encoder comes from a real
/// `BBTerm` that has had the flags pushed via `CSI > <flags> u`, so the test
/// cannot pass on a mode the parser does not actually set.
///
/// Written without reading `TerminalView+IME.swift` or `KeyEncoder.swift`.
final class IMEShiftCarryKittyBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    /// Everything the view weakly references is held strongly here.
    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let recorder: RecordingPTY
        let snapshot: BBSnapshot
    }

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

    private let noFlags = ""
    private let flag8 = "\u{1B}[>8u"
    private let flag8and4 = "\u{1B}[>12u"
    private let modifyOtherKeys2 = "\u{1B}[>4;2m"

    private let notFound = NSRange(location: NSNotFound, length: 0)

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// What AppKit synthesises for a physical Shift+A on a US layout.
    private func shiftAKeyDown() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "A",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ))
    }

    /// Whether `keyDown` on a headless (window-less) view reaches
    /// `insertText` at all in this host. Probed against the no-flags
    /// fixture, where the only acceptable outcome is the plain byte `A`.
    /// Returns false when the input context is unavailable (no bytes at
    /// all), in which case the keyDown-driven tests skip and the direct
    /// `insertText` tests carry the spec.
    private func keyDownReachesInsertText() throws -> Bool {
        let rig = try makeRig(feeding: noFlags)
        rig.view.keyDown(with: try shiftAKeyDown())
        if rig.recorder.sent.isEmpty { return false }
        XCTAssertEqual(rig.recorder.sent, bytes("A"),
                       "harness self-check: no-flags Shift+A via keyDown must be plain 'A', got \(hex(rig.recorder.sent))")
        return true
    }

    // MARK: - Mode preconditions (so a fixture can never silently pass)

    func test_precondition_flagPushesSetTermMode() throws {
        let r8 = try makeRig(feeding: flag8)
        XCTAssertTrue(r8.snapshot.termMode.contains(.reportAllKeysAsEsc), "CSI > 8 u must set flag 8")
        XCTAssertFalse(r8.snapshot.termMode.contains(.reportAlternateKeys))

        let r12 = try makeRig(feeding: flag8and4)
        XCTAssertTrue(r12.snapshot.termMode.contains(.reportAllKeysAsEsc), "CSI > 12 u must set flag 8")
        XCTAssertTrue(r12.snapshot.termMode.contains(.reportAlternateKeys), "CSI > 12 u must set flag 4")

        let rMOK = try makeRig(feeding: modifyOtherKeys2)
        XCTAssertTrue(rMOK.snapshot.termMode.contains(.modifyOtherKeys), "CSI > 4 ; 2 m must set modifyOtherKeys")
        XCTAssertFalse(rMOK.snapshot.termMode.contains(.reportAllKeysAsEsc))

        let r0 = try makeRig(feeding: noFlags)
        XCTAssertTrue(r0.snapshot.termMode.isDisjoint(with: [.reportAllKeysAsEsc, .reportAlternateKeys, .modifyOtherKeys]))
    }

    // MARK: - keyDown-driven (full AppKit route)

    func test_keyDown_shiftA_flag8_carriesShift() throws {
        guard try keyDownReachesInsertText() else {
            throw XCTSkip("headless keyDown does not reach insertText in this host; direct insertText tests cover the contract")
        }
        let rig = try makeRig(feeding: flag8)
        rig.view.keyDown(with: try shiftAKeyDown())
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[97;2u"),
                       "flag 8 Shift+A must be ESC[97;2u, got \(hex(rig.recorder.sent))")
    }

    func test_keyDown_shiftA_flag8and4_carriesShiftAndAlternateKey() throws {
        guard try keyDownReachesInsertText() else {
            throw XCTSkip("headless keyDown does not reach insertText in this host; direct insertText tests cover the contract")
        }
        let rig = try makeRig(feeding: flag8and4)
        rig.view.keyDown(with: try shiftAKeyDown())
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[97:65;2u"),
                       "flags 8+4 Shift+A must be ESC[97:65;2u, got \(hex(rig.recorder.sent))")
    }

    func test_keyDown_shiftA_noFlags_isPlainA() throws {
        guard try keyDownReachesInsertText() else {
            throw XCTSkip("headless keyDown does not reach insertText in this host; direct insertText tests cover the contract")
        }
        let rig = try makeRig(feeding: noFlags)
        rig.view.keyDown(with: try shiftAKeyDown())
        XCTAssertEqual(rig.recorder.sent, bytes("A"), "got \(hex(rig.recorder.sent))")
    }

    func test_keyDown_shiftA_modifyOtherKeys_isPlainA() throws {
        guard try keyDownReachesInsertText() else {
            throw XCTSkip("headless keyDown does not reach insertText in this host; direct insertText tests cover the contract")
        }
        let rig = try makeRig(feeding: modifyOtherKeys2)
        rig.view.keyDown(with: try shiftAKeyDown())
        XCTAssertEqual(rig.recorder.sent, bytes("A"),
                       "modifyOtherKeys: Shift alone never produces CSI 27; got \(hex(rig.recorder.sent))")
    }

    // MARK: - Direct insertText with the pending-modifier seam

    func test_insertText_pendingShift_flag8_carriesShift() throws {
        let rig = try makeRig(feeding: flag8)
        rig.view.pendingInsertTextModifiers = [.shift]
        rig.view.insertText("A", replacementRange: notFound)
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[97;2u"),
                       "got \(hex(rig.recorder.sent))")
    }

    func test_insertText_pendingShift_flag8and4_carriesShiftAndAlternateKey() throws {
        let rig = try makeRig(feeding: flag8and4)
        rig.view.pendingInsertTextModifiers = [.shift]
        rig.view.insertText("A", replacementRange: notFound)
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[97:65;2u"),
                       "got \(hex(rig.recorder.sent))")
    }

    func test_insertText_pendingShift_noFlags_isPlainA() throws {
        let rig = try makeRig(feeding: noFlags)
        rig.view.pendingInsertTextModifiers = [.shift]
        rig.view.insertText("A", replacementRange: notFound)
        XCTAssertEqual(rig.recorder.sent, bytes("A"), "got \(hex(rig.recorder.sent))")
    }

    func test_insertText_pendingShift_modifyOtherKeys_isPlainA() throws {
        let rig = try makeRig(feeding: modifyOtherKeys2)
        rig.view.pendingInsertTextModifiers = [.shift]
        rig.view.insertText("A", replacementRange: notFound)
        XCTAssertEqual(rig.recorder.sent, bytes("A"),
                       "modifyOtherKeys: Shift alone must not produce CSI 27; got \(hex(rig.recorder.sent))")
    }

    func test_insertText_noPendingModifiers_flag8_isCsiU97Unmodified() throws {
        let rig = try makeRig(feeding: flag8)
        rig.view.pendingInsertTextModifiers = nil
        rig.view.insertText("a", replacementRange: notFound)
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[97u"),
                       "flag 8 with no pending modifiers must be ESC[97u, got \(hex(rig.recorder.sent))")
    }

    // MARK: - IME composition commit never carries Shift

    func test_compositionCommit_flag8_ignoresPendingShift() throws {
        let rig = try makeRig(feeding: flag8)
        rig.view.setMarkedText("a",
                               selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: notFound)
        XCTAssertTrue(rig.view.hasMarkedText(), "precondition: composition in flight")
        XCTAssertTrue(rig.recorder.sent.isEmpty, "preedit must not reach the PTY")

        rig.view.pendingInsertTextModifiers = [.shift]
        rig.view.insertText("A", replacementRange: notFound)
        XCTAssertFalse(rig.view.hasMarkedText())
        XCTAssertEqual(rig.recorder.sent, bytes("\u{1B}[97u"),
                       "a composed commit is not a keystroke: no Shift bit; got \(hex(rig.recorder.sent))")
    }
}
