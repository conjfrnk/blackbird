import XCTest
@testable import Blackbird
@testable import BBCore

/// End-to-end hardening tests: feed a crafted byte stream into a BBTerm
/// and assert the terminal doesn't leak state back to the "attacker" via
/// PtyWrite, doesn't retain oversized data, and doesn't produce garbage
/// glyphs. Complements the unit tests for individual sanitizers — this
/// layer catches interaction bugs.
final class HostileInputIntegrationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Attack 1: OSC 0/2 title with embedded shell metachars

    /// A remote sets the title to `$(rm -rf ~)` via OSC 2. A terminal
    /// that responded to CSI 21t (title report) would echo that payload
    /// back into the shell line as if typed. We must never respond.
    /// Verified via the core-level test already; this end-to-end check
    /// confirms the Swift title event still arrives (no drop) AND no
    /// PtyWrite leak.
    func testTitleWithShellMetacharsDoesNotRoundTrip() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var titles: [String] = []
        var writes: [Data] = []
        term.onEvent { ev in
            switch ev {
            case .title(let t): titles.append(t)
            case .ptyWrite(let d): writes.append(d)
            default: break
            }
        }
        // Hostile title.
        term.input("\u{1B}]2;$(rm -rf ~)\u{07}")
        // Query that a vulnerable emulator would respond to.
        term.input("\u{1B}[21t")
        XCTAssertEqual(titles.last, "$(rm -rf ~)")
        XCTAssertTrue(
            writes.isEmpty,
            "CSI 21t must never round-trip title; pty writes: \(writes)"
        )
    }

    // MARK: - Attack 2: OSC 8 with javascript: scheme

    func testOsc8WithJavascriptSchemeIsBlocked() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("\u{1B}]8;;javascript:alert(1)\u{1B}\\click\u{1B}]8;;\u{1B}\\")
        let snap = try XCTUnwrap(term.snapshot())
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertNil(
            resolver.osc8URL(row: 0, col: 0),
            "javascript: OSC 8 URLs must not surface through the resolver"
        )
    }

    // MARK: - Attack 3: OSC 8 with a shell: / vbscript: scheme

    func testOsc8WithCustomHandlerSchemesBlocked() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        for scheme in ["shell", "vbscript", "x-man-page", "jar"] {
            term.input("\u{1B}]8;;\(scheme):payload\u{1B}\\x\u{1B}]8;;\u{1B}\\")
            let snap = try XCTUnwrap(term.snapshot())
            let resolver = SnapshotHyperlinkResolver(snapshot: snap)
            XCTAssertNil(
                resolver.osc8URL(row: 0, col: 0),
                "\(scheme): scheme must be blocked"
            )
            // Clear the term's content so subsequent iterations don't
            // find the previous link at (0, 0).
            term.clearAll()
        }
    }

    // MARK: - Attack 4: Oversize OSC 8 URL should drop

    func testOsc8OversizeURLIsDropped() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        // 5 KiB URI exceeds the 4 KiB cap in bb_term_take_snapshot.
        let bigURI = "https://example.com/" + String(repeating: "a", count: 5 * 1024)
        term.input("\u{1B}]8;;\(bigURI)\u{1B}\\x\u{1B}]8;;\u{1B}\\")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(
            snap.linkID(row: 0, col: 0), 0,
            "oversize OSC 8 URI must drop to no-attribution"
        )
    }

    // MARK: - Attack 5: DSR + CSI 21t interleaved under title spoof

    /// Set a title containing shell-bait, then fire several different
    /// queries: some should reply (DSR status), some must stay silent
    /// (CSI 21t). The reply order must match the input order; the
    /// silent ones must produce zero bytes.
    func testInterleavedQueriesRespectSilentPolicy() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var writes: [Data] = []
        term.onEvent { ev in
            if case .ptyWrite(let d) = ev { writes.append(d) }
        }
        // 1. Set title to bait
        term.input("\u{1B}]2;malicious\u{07}")
        // 2. DSR status (should reply ESC[0n)
        term.input("\u{1B}[5n")
        // 3. CSI 21t (must NOT reply)
        term.input("\u{1B}[21t")
        // 4. DSR cursor-position (should reply ESC[1;1R)
        term.input("\u{1B}[6n")

        XCTAssertEqual(writes.count, 2, "exactly 2 replies expected")
        XCTAssertEqual(writes[0], Data("\u{1B}[0n".utf8))
        XCTAssertEqual(writes[1], Data("\u{1B}[1;1R".utf8))
    }

    // MARK: - Attack 6: paste with combined attack payload

    /// Simulate a user pasting hostile content from a webpage: CRLF line
    /// endings, embedded Ctrl+C, ESC, U+202E RLO, and the bracketed-
    /// paste terminator. Running the full Swift sanitizer chain must
    /// produce a byte sequence with none of those artifacts.
    func testPasteSanitizerChainOnCombinedHostilePayload() {
        var input = Data("ok\r\n".utf8)
        input.append(0x03)                                          // Ctrl+C
        input.append(Data("curl evil/i".utf8))
        input.append(contentsOf: [0xE2, 0x80, 0xAE])                // U+202E
        input.append(Data("pwnd\n".utf8))
        input.append(0x1B)                                          // ESC
        input.append(Data("[2J".utf8))
        input.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]) // ESC[201~

        let step1 = TerminalView.normalizePasteLineEndings(input)
        let step2 = TerminalView.sanitizePasteControls(step1)
        let step3 = TerminalView.stripBidiOverrides(step2)
        let step4 = TerminalView.sanitizeBracketedPaste(step3)

        // None of the dangerous bytes may survive.
        XCTAssertFalse(step4.contains(0x03), "Ctrl+C must be gone")
        XCTAssertFalse(step4.contains(0x1B), "ESC must be gone")
        XCTAssertFalse(
            step4.contains(Data([0xE2, 0x80, 0xAE])),
            "U+202E RLO must be gone"
        )
        XCTAssertFalse(
            step4.contains(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])),
            "bracketed-paste terminator must be gone"
        )
        // No CR (CRLF normalized, lone CR absent here).
        XCTAssertFalse(step4.contains(0x0D), "CR must be gone after normalization")
    }
}
