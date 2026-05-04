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

    /// Audit L4: non-bracketed paste of `"foo\rbar"` must arrive as
    /// `"foo\nbar"` — ICRNL on the line discipline maps lone CR → LF
    /// regardless, so the helper normalises explicitly so byte-level
    /// inspection (test, debugger, or a future shell that disables
    /// ICRNL) sees the consistent shape. Bracketed paste is unchanged
    /// — its markers already protect against CR-as-Enter.
    func testNonBracketedPaste_loneCRConvertsToLF() {
        // Lone CR (no LF after it) — `normalizePasteLineEndings` leaves
        // it intact (CR-LF pairs collapse, but a lone CR survives), and
        // `sanitizePasteControls` keeps CR (it's whitespace). The L4
        // converter — applied only on the non-bracketed paste branch —
        // is the layer that maps it to LF.
        let input = Data("foo\rbar".utf8)
        let normalized = TerminalView.normalizePasteLineEndings(input)
        let sanitized = TerminalView.sanitizePasteControls(normalized)
        let stripped = TerminalView.stripBidiOverrides(sanitized)
        let nonBracketed = TerminalView.convertLoneCRToLF(stripped)
        XCTAssertEqual(
            nonBracketed, Data("foo\nbar".utf8),
            "lone CR in non-bracketed paste must become LF (audit L4)"
        )
        // Sanity: bracketed paste does NOT run convertLoneCRToLF — the
        // upstream sanitizer chain leaves the lone CR alone, and the
        // bracketed markers protect against CR-as-Enter.
        XCTAssertTrue(
            stripped.contains(0x0D),
            "lone CR must survive the upstream sanitizer chain (bracketed-paste path)"
        )
    }

    /// L4 sibling: CR-LF pairs in the input still collapse to LF via
    /// `normalizePasteLineEndings` and don't get double-converted by
    /// `convertLoneCRToLF`. This pins that the new helper only acts
    /// when normalisation has already run.
    func testNonBracketedPaste_crlfStillCollapsesToSingleLF() {
        let input = Data("foo\r\nbar".utf8)
        let normalized = TerminalView.normalizePasteLineEndings(input)
        let sanitized = TerminalView.sanitizePasteControls(normalized)
        let stripped = TerminalView.stripBidiOverrides(sanitized)
        let nonBracketed = TerminalView.convertLoneCRToLF(stripped)
        XCTAssertEqual(
            nonBracketed, Data("foo\nbar".utf8),
            "CRLF must collapse to a single LF (no spurious doubling)"
        )
    }

    /// OSC 52 clipboard writes (shell → system clipboard) run through a
    /// 2-step scrub chain before reaching NSPasteboard:
    /// `stripBidiOverrides(sanitizePasteControls(data))`.
    ///
    /// The paste-direction pipeline adds normalizePasteLineEndings +
    /// sanitizeBracketedPaste on top, but those aren't applied on the
    /// *write-out* side (the user is being handed bytes to paste, not the
    /// shell). This test pins that the narrower write-direction pipeline
    /// still catches the two threat classes we care about on a write:
    ///   - C0/C1 controls (ESC sequences, DEL, Ctrl-chars) that a later
    ///     paste into another terminal would re-execute.
    ///   - Bidi overrides (Trojan Source) that rewrite visible direction
    ///     once the text is pasted into a code editor or chat box.
    func test_osc52WriteScrubStripsControlsAndBidi() {
        // Mirror of the production path in TerminalSession.wire() —
        // `case .osc52Clipboard(let text): ... stripBidiOverrides(
        // sanitizePasteControls(data))`.
        var payload = Data("user@host:~$ secret-token-123".utf8)
        payload.insert(0x1B, at: 12)                               // ESC hidden after "user"
        payload.append(0x07)                                       // BEL
        payload.append(contentsOf: [0xE2, 0x80, 0xAE])             // U+202E RLO
        payload.append(Data("tail-bytes".utf8))

        let step1 = TerminalView.sanitizePasteControls(payload)
        let step2 = TerminalView.stripBidiOverrides(step1)

        XCTAssertFalse(step2.contains(0x1B),
                       "ESC must be stripped before OSC 52 write")
        XCTAssertFalse(step2.contains(0x07),
                       "BEL must be stripped before OSC 52 write")
        XCTAssertFalse(step2.contains(Data([0xE2, 0x80, 0xAE])),
                       "U+202E RLO must be stripped before OSC 52 write")

        // Counter-check: legitimate content survives. Otherwise the
        // scrub would make OSC 52 useless for its intended use case
        // (copy-out from remote session).
        let decoded = String(decoding: step2, as: UTF8.self)
        XCTAssertTrue(decoded.contains("secret-token-123"),
                      "legitimate payload must pass through: got \(decoded)")
        XCTAssertTrue(decoded.contains("tail-bytes"),
                      "content after a bidi override must still arrive: got \(decoded)")
    }

    // MARK: - Property-style fuzz (audit F8)

    /// Feed 1000 random byte sequences (each 1..128 bytes) into a single
    /// `BBTerm.input` and assert zero `Fatal` events surface. The Rust side
    /// uses `catch_unwind` so a panic becomes a `Fatal` event rather than a
    /// process-level abort; observing zero is the correctness signal.
    ///
    /// Memory ceiling: 128 bytes × 1000 iterations = 128 KB of test input
    /// total, all freed after each input call returns (BBTerm doesn't retain
    /// the raw bytes — it parses them into grid state with a 10k-line
    /// scrollback cap already enforced by the core).
    func testRandomByteInputDoesNotPanic() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var fatals: [String] = []
        term.onEvent { ev in
            if case .fatal(let msg) = ev { fatals.append(msg) }
        }
        // Deterministic seed: we want reproducible failures, not a flaky CI
        // signal. `SystemRandomNumberGenerator` is unseeded; use a simple
        // xorshift so re-running the test with the same source yields the
        // same input stream.
        var rng = SeededRNG(seed: 0xB1ACBBBD)
        for iter in 0..<1000 {
            let length = Int.random(in: 1...128, using: &rng)
            var bytes = [UInt8](repeating: 0, count: length)
            for i in 0..<length {
                bytes[i] = UInt8.random(in: 0...255, using: &rng)
            }
            term.input(bytes)
            XCTAssertTrue(
                fatals.isEmpty,
                "iter \(iter): BBTerm raised fatal event for \(bytes.count)-byte input: \(fatals)"
            )
        }
    }

    /// Overlong / illegal UTF-8 must not kill the parser. The cases here are
    /// the classic attack shapes:
    ///   - `0xC0 0x80`       — overlong NUL (historically used to smuggle
    ///                          a NUL past naive length checks).
    ///   - `0xED 0xA0 0x80`  — UTF-16 surrogate half encoded as CESU-8.
    ///   - `0xF8 0x88 0x80 0x80 0x80` — 5-byte UTF-8 (encodes > U+10FFFF).
    ///   - `0xFF` / `0xFE`   — bytes that are never valid anywhere in UTF-8.
    /// The terminal must ingest them without panicking; garbled output is OK,
    /// a crash is not.
    func testMalformedUtf8DoesNotPanic() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var fatals: [String] = []
        term.onEvent { ev in
            if case .fatal(let msg) = ev { fatals.append(msg) }
        }
        let sequences: [[UInt8]] = [
            [0xC0, 0x80],                               // overlong NUL
            [0xED, 0xA0, 0x80],                         // U+D800 surrogate
            [0xED, 0xBF, 0xBF],                         // U+DFFF surrogate
            [0xF8, 0x88, 0x80, 0x80, 0x80],             // 5-byte (> U+10FFFF)
            [0xFF],                                     // never valid
            [0xFE],                                     // never valid
            [0xC2],                                     // truncated 2-byte lead
            [0xE2, 0x82],                               // truncated 3-byte
            [0xF0, 0x9F],                               // truncated 4-byte
            [0x80],                                     // lone continuation byte
        ]
        for seq in sequences {
            term.input(seq)
            XCTAssertTrue(
                fatals.isEmpty,
                "malformed UTF-8 \(seq.map { String($0, radix: 16) }) produced fatal: \(fatals)"
            )
        }
    }

    /// A 3-byte UTF-8 scalar split across two `input` calls must resume
    /// correctly once the tail arrives. We don't assert the intermediate
    /// state (parser may or may not buffer bytes internally) — the
    /// correctness signal is zero fatal events and some non-empty grid
    /// state after both halves have landed.
    func testSplitMultibyteAtBoundaryDoesNotPanic() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        var fatals: [String] = []
        term.onEvent { ev in
            if case .fatal(let msg) = ev { fatals.append(msg) }
        }
        // "€" = U+20AC = 0xE2 0x82 0xAC (3 bytes).
        term.input([0xE2, 0x82])
        term.input([0xAC])
        // "😀" = U+1F600 = 0xF0 0x9F 0x98 0x80 (4 bytes).
        term.input([0xF0, 0x9F, 0x98])
        term.input([0x80])
        XCTAssertTrue(fatals.isEmpty,
                      "split-multibyte input produced fatal: \(fatals)")
        _ = try XCTUnwrap(term.snapshot(),
                          "terminal must still produce a snapshot after split-multibyte input")
    }

    /// OSC-8 URI boundary around the 4 KiB cap enforced by
    /// `bb_term_take_snapshot`. Sizes:
    ///   - 4095 bytes: well under the cap, must be accepted.
    ///   - 4097 bytes: one byte over the cap, must be rejected.
    /// We don't test the exact cap (4096) because the spec allows either
    /// side of the fence to own the boundary — both 4096-accepted and
    /// 4096-rejected are defensible. We do pin the two sides so a cap
    /// regression of more than one byte in either direction fails CI.
    func testOsc8URICapBoundary() throws {
        // Memory note: 4097 bytes of 'a' + the OSC 8 overhead is ~4.2 KB per
        // iteration; no concern.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))

        // 4095: under the cap. Use "https://example.com/" (20 bytes) + 4075 'a's.
        let underCapURI = "https://example.com/" + String(repeating: "a", count: 4075)
        XCTAssertEqual(underCapURI.count, 4095)
        term.input("\u{1B}]8;;\(underCapURI)\u{1B}\\x\u{1B}]8;;\u{1B}\\")
        let snapUnder = try XCTUnwrap(term.snapshot())
        XCTAssertNotEqual(
            snapUnder.linkID(row: 0, col: 0), 0,
            "4095-byte OSC 8 URI must be accepted (under 4 KiB cap)"
        )

        // Clear and try the 4097-byte case on a clean term.
        term.clearAll()
        let overCapURI = "https://example.com/" + String(repeating: "b", count: 4077)
        XCTAssertEqual(overCapURI.count, 4097)
        term.input("\u{1B}]8;;\(overCapURI)\u{1B}\\y\u{1B}]8;;\u{1B}\\")
        let snapOver = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(
            snapOver.linkID(row: 0, col: 0), 0,
            "4097-byte OSC 8 URI must be rejected (over 4 KiB cap)"
        )
    }
}

/// Deterministic xorshift32 RNG. Used only in `testRandomByteInputDoesNotPanic`
/// so the fuzz signal is reproducible — a flaky-because-random test would
/// defeat the purpose of the sweep.
///
/// Not a security-grade RNG; the audit explicitly asked for "property-style"
/// coverage which is plenty for smoke-testing `term.input` panic paths.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) {
        // Avoid zero state (xorshift would lock up).
        self.state = seed == 0 ? 1 : seed
    }
    mutating func next() -> UInt64 {
        var x = state
        x ^= x << 13
        x ^= x >> 7
        x ^= x << 17
        state = x
        return x
    }
}
