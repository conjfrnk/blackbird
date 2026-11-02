import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests: keys that AppKit's key-binding machinery maps to
/// the "nothing to do" selectors `noop:` / `complete:` must NOT escape the
/// terminal view's `doCommand(by:)` into the responder chain.
///
/// Background (macOS conventions): `inputContext?.handleEvent(event)` runs a
/// key through the standard key bindings and, for anything that is not text,
/// calls the client's `doCommand(by:)`. Ctrl+C / Ctrl+Z / Ctrl+U / Ctrl+W /
/// Ctrl+S / Ctrl+G, every function key F1-F20, and Opt+Esc have no editing
/// meaning in a terminal and arrive as `noop:` (or `complete:` for Opt+Esc /
/// F5). A terminal sends the byte itself afterwards (via the key encoder), so
/// the selector must simply be absorbed. If the view hands it to
/// `super.doCommand(by:)`, `NSResponder` walks the selector up the responder
/// chain, nobody implements it, and AppKit plays the user's system alert
/// sound: an audible "failed keystroke" on Ctrl+C even though the 0x03 byte
/// is delivered. The Emacs-bound keys (Ctrl+A/E/F/B/K...) are silent today,
/// so the behaviour is also inconsistent.
///
/// Observation strategy (no sound is ever played): the `TerminalView` is
/// hosted under a `ResponderChainProbe` superview. A view's next responder
/// is its superview, so any selector `NSResponder`'s default `doCommand(by:)`
/// forwards lands in the probe, which records it and deliberately does NOT
/// call `super` (so a regression in the view cannot beep the test host).
///
/// Precondition: `testProbeObservesDefaultForwardingFromVanillaView` proves
/// the probe really sees what a default `NSResponder` forwards, so the
/// "nothing reached the probe" assertions below cannot pass vacuously.
///
/// Written without reading `TerminalView+IME.swift`'s `doCommand(by:)` body.
final class IMEDoCommandNoAlertBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    /// Records every `doCommand(by:)` that reaches it through the responder
    /// chain. Never calls `super`: the default implementation would run off
    /// the end of the chain and beep.
    private final class ResponderChainProbe: NSView {
        private(set) var received: [String] = []
        override func doCommand(by selector: Selector) {
            received.append(NSStringFromSelector(selector))
        }
    }

    private struct Rig {
        let probe: ResponderChainProbe
        let view: TerminalView
        let pty: RecordingPTY
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests(),
                                 "Metal device required", file: file, line: line)
        let pty = RecordingPTY()
        view.ptyRecorderForTests = pty
        let probe = ResponderChainProbe(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        probe.addSubview(view)
        // Rig sanity: the probe really is the view's next responder.
        XCTAssertTrue(view.nextResponder === probe,
                      "probe must be the view's next responder; got \(String(describing: view.nextResponder))",
                      file: file, line: line)
        return Rig(probe: probe, view: view, pty: pty)
    }

    private static let noop = NSSelectorFromString("noop:")
    private static let complete = NSSelectorFromString("complete:")

    // MARK: - Precondition

    /// Proves the probe can see forwarded selectors: a plain `NSView` that
    /// does not override `doCommand(by:)` hands an unhandled selector to its
    /// superview. If this ever fails, the assertions in the other tests would
    /// be vacuous, so it fails loudly instead.
    func testProbeObservesDefaultForwardingFromVanillaView() {
        let probe = ResponderChainProbe(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let vanilla = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        probe.addSubview(vanilla)

        vanilla.doCommand(by: Self.noop)

        XCTAssertEqual(probe.received, ["noop:"],
                       "a vanilla NSView must forward an unhandled noop: to its superview; probe saw \(probe.received)")
    }

    // MARK: - The bug

    /// Ctrl+C / Ctrl+Z / Ctrl+U / Ctrl+W / Ctrl+S / Ctrl+G / function keys
    /// arrive as `noop:`. It must be absorbed, not forwarded up the chain
    /// where it would ring the system alert.
    func testNoopSelectorDoesNotReachResponderChain() throws {
        let rig = try makeRig()

        rig.view.doCommand(by: Self.noop)

        XCTAssertEqual(rig.probe.received, [],
                       "doCommand(by: noop:) leaked to the responder chain (AppKit would play the system alert); probe saw \(rig.probe.received)")
        XCTAssertEqual(rig.pty.sent, Data(),
                       "doCommand(by:) must not write to the PTY itself (the key encoder sends the byte); sent \(Array(rig.pty.sent))")
    }

    /// Opt+Esc and F5 arrive as `complete:`. Same contract as `noop:`.
    func testCompleteSelectorDoesNotReachResponderChain() throws {
        let rig = try makeRig()

        rig.view.doCommand(by: Self.complete)

        XCTAssertEqual(rig.probe.received, [],
                       "doCommand(by: complete:) leaked to the responder chain (AppKit would play the system alert); probe saw \(rig.probe.received)")
        XCTAssertEqual(rig.pty.sent, Data(),
                       "doCommand(by:) must not write to the PTY itself; sent \(Array(rig.pty.sent))")
    }

    /// F1-F20 plus a handful of Ctrl+letter presses in a row: not a single
    /// one may leak, and the first press must not be special.
    func testRepeatedNoopAndCompleteNeverLeak() throws {
        let rig = try makeRig()

        // 20 function keys + Ctrl+C/Z/U/W/S/G, alternating the two selectors
        // the way F5 / Opt+Esc (complete:) and the rest (noop:) arrive.
        let presses = 26
        for i in 0..<presses {
            rig.view.doCommand(by: i % 5 == 4 ? Self.complete : Self.noop)
        }

        XCTAssertEqual(rig.probe.received.count, 0,
                       "\(rig.probe.received.count) of \(presses) noop:/complete: commands leaked to the responder chain: \(rig.probe.received)")
    }

    /// Mid-composition the same selectors must still be absorbed: an IME
    /// session must not turn a stray Ctrl+key into a system alert either.
    func testNoopDoesNotReachResponderChainWhileComposing() throws {
        let rig = try makeRig()
        rig.view.setMarkedText("あ",
                               selectedRange: NSRange(location: 1, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(rig.view.hasMarkedText(), "precondition: composition must be active")

        rig.view.doCommand(by: Self.noop)

        XCTAssertEqual(rig.probe.received, [],
                       "doCommand(by: noop:) leaked to the responder chain during composition; probe saw \(rig.probe.received)")
        XCTAssertEqual(rig.pty.sent, Data(),
                       "preedit must not reach the PTY; sent \(Array(rig.pty.sent))")
    }

    // MARK: - Control (already-correct behaviour must stay silent)

    /// The editing selectors the doc contract already absorbs. They stay
    /// silent today and must stay silent.
    func testEditingSelectorsStaySilent() throws {
        let rig = try makeRig()
        let names = ["deleteBackward:", "insertNewline:", "moveUp:", "moveDown:",
                     "moveLeft:", "moveRight:", "insertTab:"]

        for name in names {
            rig.view.doCommand(by: NSSelectorFromString(name))
        }

        XCTAssertEqual(rig.probe.received, [],
                       "editing selectors must be absorbed by the view; probe saw \(rig.probe.received)")
    }
}
