import Foundation

/// The paste/copy/drop sanitization chain — the app's defense against
/// paste-injection (CVE-2026-26982 class), Trojan-Source bidi, and
/// bracketed-paste breakout. Six pure byte/string transforms extracted verbatim
/// from the TerminalView+Paste NSView extension (REFACTOR.md Part III §3): they
/// are view-independent and security-critical, so they belong in one
/// fuzz/unit-testable type rather than welded to a 3,000-line view. The
/// pipeline order is load-bearing (normalize → control-scrub → bidi-strip, then
/// bracketed vs lone-CR); Variation Selectors are stripped only from *display*
/// (scrubURLForDisplay), never from paste/drop bytes.
enum PasteSanitizer {
    /// Replace every standalone CR (0x0D) with LF (0x0A). CR-LF pairs are
    /// already collapsed to LF by `normalizePasteLineEndings`, so any CR
    /// reaching this function is a lone CR. Audit L4.
    static func convertLoneCRToLF(_ input: Data) -> Data {
        guard input.contains(0x0D) else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        for b in input {
            out.append(b == 0x0D ? 0x0A : b)
        }
        return out
    }

    /// Collapse CRLF → LF in pasted content. Cross-platform clipboards (Windows,
    /// web copy) often carry CRLF; the PTY's ICRNL flag then maps the CR to an
    /// extra LF, so a two-line paste becomes four shell prompts. Matches
    /// Terminal.app / iTerm2 behaviour. Lone CR is left alone — it's rare in
    /// real paste content and some applications still want it as Enter.
    static func normalizePasteLineEndings(_ input: Data) -> Data {
        guard input.contains(0x0D) else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b = input[i]
            if b == 0x0D {
                let next = input.index(after: i)
                if next < input.endIndex, input[next] == 0x0A {
                    out.append(0x0A)
                    i = input.index(after: next)
                    continue
                }
            }
            out.append(b)
            i = input.index(after: i)
        }
        return out
    }

    /// Replace C0 + C1 control bytes (other than TAB / LF / CR) and DEL
    /// with a space. Applied before *every* paste, whether bracketed or
    /// not.
    ///
    /// Rationale: a pasted payload can carry `0x03` (Ctrl+C), `0x1A`
    /// (Ctrl+Z), `0x1B` (ESC), or `0x7F` (DEL) in the C0 set, each of
    /// which — delivered raw to the shell — either interrupts the
    /// current line and runs the bytes that follow (the iTerm2 /
    /// Ghostty CVE-2026-26982 class) or drives the remote into an
    /// unexpected mode via escape sequences embedded in plain text.
    ///
    /// The same applies to the **C1 set** (0x80–0x9F), which xterm's
    /// `allowC1Printable` default treats as control bytes. Encoded in
    /// UTF-8 as `0xC2 0x80 … 0xC2 0x9F`, these include 0x9B (CSI),
    /// 0x9D (OSC), 0x90 (DCS) — ESC-free alternate forms of the same
    /// attack surface. A sanitizer that only strips ESC leaves the
    /// door open; we strip both lead bytes of the C1 UTF-8 sequence
    /// so the decoded scalar never reaches the parser.
    ///
    /// Replacing with space keeps byte offsets stable so column-
    /// formatted paste still lines up. Matches Ghostty ≥1.3.0 and
    /// xterm's default paste sanitizer.
    static func sanitizePasteControls(_ input: Data) -> Data {
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b = input[i]
            // TAB / LF / CR pass through — legitimate whitespace in paste.
            // (CR is normalised to LF upstream, but a lone CR arriving
            // from an old-Mac-encoded file is still valid input.)
            if b == 0x09 || b == 0x0A || b == 0x0D {
                out.append(b)
                i = input.index(after: i)
                continue
            }
            // C0 (0x00–0x1F excluding TAB/LF/CR) and DEL (0x7F) → space.
            if b < 0x20 || b == 0x7F {
                out.append(0x20)
                i = input.index(after: i)
                continue
            }
            // C1 controls encoded as UTF-8: lead 0xC2 followed by a byte
            // in 0x80–0x9F. Replace the whole two-byte scalar with a
            // single space so the parser never sees 0x9B / 0x9D / 0x90.
            // This doesn't strip lone continuation bytes (those are
            // invalid UTF-8 and handled by the parser's UTF-8 state
            // machine); we only match the valid C1 encoding pattern.
            if b == 0xC2,
               input.index(after: i) < input.endIndex {
                let next = input[input.index(after: i)]
                if (0x80...0x9F).contains(next) {
                    out.append(0x20)
                    i = input.index(i, offsetBy: 2)
                    continue
                }
            }
            out.append(b)
            i = input.index(after: i)
        }
        return out
    }

    /// Drop every Unicode bidi-control / zero-width / invisible-payload
    /// codepoint from a paste payload. Three families of attack:
    ///
    ///   1. Bidi reordering (Trojan Source CVE-2021-42574 + follow-ups):
    ///      U+202A-E embedding/override, U+2066-9 isolates, U+200E/F
    ///      directional marks, U+061C ALM, U+180E MVS.
    ///   2. Zero-width / line-separator smuggling: U+200B/C/D
    ///      (ZWSP/ZWNJ/ZWJ), U+2060 (Word Joiner), U+FEFF (BOM/ZWNBSP),
    ///      U+00AD (soft hyphen), U+2028 (LS), U+2029 (PS). Some shells/
    ///      REPLs (Python, zsh `bindkey -e` paste-bracket) treat LS/PS
    ///      as line terminators, so a "single-line" paste can sneak in
    ///      a second command. Zero-width chars hide bytes between
    ///      identifier-shaped tokens (tab-completion homograph, log
    ///      injection).
    ///   3. Tag-character invisible payload: U+E0000-E007F. The
    ///      "Imperceptible Indicator" attack — an invisible string can
    ///      ride along inside a benign paste and replay through a
    ///      subsequent `pbpaste` / clipboard manager / log shipper.
    ///   4. Variation selectors: U+FE00-FE0F (VS1-16), U+E0100-E01EF
    ///      (VS17-256). Modify rendering of the prior glyph; pasted on
    ///      their own they invisibly mutate adjacent characters in
    ///      whatever surface the paste lands in (commit messages,
    ///      issue trackers, log output).
    ///
    /// Full byte map (UTF-8):
    ///
    ///   U+00AD  SHY   C2 AD               soft hyphen (2-byte)
    ///   U+061C  ALM   D8 9C               Arabic letter mark (2-byte)
    ///   U+180E  MVS   E1 A0 8E            Mongolian vowel separator (3)
    ///   U+200B-D ZWSP/ZWNJ/ZWJ E2 80 8B-8D
    ///   U+200E/F LRM/RLM       E2 80 8E/8F
    ///   U+202A-E LRE/RLE/PDF/LRO/RLO E2 80 AA-AE
    ///   U+2028  LS    E2 80 A8            line separator
    ///   U+2029  PS    E2 80 A9            paragraph separator
    ///   U+2060  WJ    E2 81 A0            word joiner
    ///   U+2066-9 LRI/RLI/FSI/PDI E2 81 A6-A9
    ///   U+FEFF  BOM   EF BB BF            byte order mark (ZWNBSP)
    ///   U+E0000-E007F tag block F3 A0 80 80 - F3 A0 81 BF (4-byte)
    ///
    /// These are rare in legitimate text — Unicode's bidi algorithm
    /// handles Arabic / Hebrew automatically and identifier rendering
    /// doesn't need ZWJ. Stripping is safer than rendering.
    /// Audit M3 / M4.
    ///
    /// Variation Selectors (VS1-16 U+FE00–FE0F, VS17-256 U+E0100–E01EF)
    /// are deliberately NOT stripped: unlike the bidi / zero-width set
    /// above, they only change how the immediately-preceding visible
    /// glyph renders, so they cannot reorder or hide pasted text and
    /// they are a legitimate part of pasted emoji ("❤️" = U+2764 U+FE0F,
    /// keycaps like "1️⃣", …). Stripping them silently corrupted every
    /// paste / drop carrying an emoji-presentation selector. See the
    /// rationale block in `TerminalView+Dragging.sanitizeDropPath`.
    static func stripBidiOverrides(_ input: Data) -> Data {
        // Fast path: lead bytes for any tracked codepoint are
        // C2 / D8 / E1 / E2 / EF / F3. Absence of all six → no match.
        guard input.contains(where: {
            $0 == 0xC2 || $0 == 0xD8 || $0 == 0xE1
                || $0 == 0xE2 || $0 == 0xEF || $0 == 0xF3
        })
        else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b0 = input[i]
            let remaining = input.distance(from: i, to: input.endIndex)

            // 2-byte sequences:
            //   U+00AD soft hyphen (C2 AD)
            //   U+061C ALM        (D8 9C)
            if remaining >= 2 {
                let b1 = input[input.index(after: i)]
                if b0 == 0xC2 && b1 == 0xAD {
                    i = input.index(i, offsetBy: 2)
                    continue
                }
                if b0 == 0xD8 && b1 == 0x9C {
                    i = input.index(i, offsetBy: 2)
                    continue
                }
            }

            // 3-byte sequences:
            //   U+180E MVS               (E1 A0 8E)
            //   U+200B-F ZWSP/ZWNJ/ZWJ/LRM/RLM (E2 80 8B-8F)
            //   U+2028/9 LS/PS           (E2 80 A8/A9)
            //   U+202A-E embed/override  (E2 80 AA-AE)
            //   U+2060 WJ                (E2 81 A0)
            //   U+2066-9 isolates        (E2 81 A6-A9)
            //   U+FEFF BOM               (EF BB BF)
            if remaining >= 3 {
                let b1 = input[input.index(i, offsetBy: 1)]
                let b2 = input[input.index(i, offsetBy: 2)]
                if b0 == 0xE1, b1 == 0xA0, b2 == 0x8E {
                    i = input.index(i, offsetBy: 3)
                    continue
                }
                if b0 == 0xE2 {
                    // E2 80 8B..8F  → ZWSP/ZWNJ/ZWJ/LRM/RLM
                    if b1 == 0x80 && (0x8B...0x8F).contains(b2) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                    // E2 80 A8..AE  → LS/PS plus the embed/override block
                    if b1 == 0x80 && (0xA8...0xAE).contains(b2) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                    // E2 81 A0       → Word Joiner
                    // E2 81 A6..A9   → isolates
                    if b1 == 0x81 && (b2 == 0xA0 || (0xA6...0xA9).contains(b2)) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                }
                if b0 == 0xEF {
                    // EF BB BF       → BOM / ZWNBSP. (VS1-16, EF B8
                    // 80..8F, is deliberately preserved — see the doc
                    // comment above.)
                    if b1 == 0xBB && b2 == 0xBF {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                }
            }

            // 4-byte sequences:
            //   U+E0000-E007F tag block   (F3 A0 80 80 - F3 A0 81 BF)
            // (VS17-256, F3 A0 84 80 - F3 A0 87 AF, is deliberately
            // preserved — see the doc comment above.)
            if remaining >= 4, b0 == 0xF3 {
                let b1 = input[input.index(i, offsetBy: 1)]
                let b2 = input[input.index(i, offsetBy: 2)]
                let b3 = input[input.index(i, offsetBy: 3)]
                // Tag block U+E0000–E007F: F3 A0 {80|81} XX, where XX must be a
                // UTF-8 continuation byte (0x80–0xBF) for the four bytes to form
                // a valid scalar. Validate b3 so a *malformed* lead
                // `F3 A0 80 <non-continuation>` is NOT mistaken for a tag-block
                // scalar and over-consumed — over-consuming would silently drop
                // the byte after the prefix. Like every other near-miss above
                // (e.g. `C2 <not AD>`, `E2 80 <out of range>`), an unrecognised
                // lead falls through and is preserved verbatim. Audit S3-005.
                if b1 == 0xA0, b2 == 0x80 || b2 == 0x81, (0x80...0xBF).contains(b3) {
                    i = input.index(i, offsetBy: 4)
                    continue
                }
            }

            out.append(b0)
            i = input.index(after: i)
        }
        return out
    }

    /// Scrub a remote-controlled string for safe display in chrome
    /// surfaces (hover tooltip, "Open in Finder" affordance, OSC 7 cwd
    /// in the proxy icon, etc.). Stricter than `sanitizePasteControls`
    /// + `stripBidiOverrides`: chrome surfaces are single-line and a
    /// legitimate URL never contains TAB/LF/CR, so those pass-through
    /// bytes get dropped here rather than preserved.
    ///
    /// Audit critical-1: the OSC 8 hover tooltip is the user's
    /// "verify before clicking" affordance. A hostile remote that
    /// emits `ESC]8;;https://evil.tld/login\u{202E}moc.elppa//:sptth\x07`
    /// stores the bidi override in the link table; `URL(string:)`
    /// accepts the percent-encoded form so the click target stays
    /// `https://evil.tld/...`, but if the tooltip renders the bidi
    /// override the user reads `https://apple.com/login` and the
    /// affordance is defeated. The same pattern applies to any
    /// snapshot-derived string we surface in chrome.
    static func scrubURLForDisplay(_ s: String) -> String {
        var bytes = sanitizePasteControls(Data(s.utf8))
        // sanitizePasteControls keeps TAB/LF/CR (legitimate in paste);
        // a chrome surface is single-line, so drop them. Replace with
        // nothing rather than space — a fake space could survive
        // truncation and look like part of the URL host.
        bytes = bytes.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        bytes = stripBidiOverrides(bytes)
        // `stripBidiOverrides` deliberately PRESERVES Variation Selectors
        // (VS1-16 U+FE00–FE0F, VS17-256 U+E0100–E01EF) — they're
        // legitimate in pasted/dropped *data* (see its doc comment). But
        // this is a *display* scrubber for the "verify before clicking"
        // affordance, where exact glyph fidelity is a non-goal and an
        // invisible scalar riding a host character must not survive into
        // the tooltip. So strip VS here, matching the display posture of
        // `DiagnosticsView.stripControlCharacters`. VS only restyle the
        // preceding glyph and can't reorder a host, so this is
        // defense-in-depth, not the primary bidi guard above.
        let scrubbed = String(decoding: bytes, as: UTF8.self)
        return String(scrubbed.unicodeScalars.filter {
            !((0xFE00...0xFE0F).contains($0.value)
                || (0xE0100...0xE01EF).contains($0.value))
        })
    }

    /// Strip any literal `ESC [ 2 0 1 ~` terminators from a bracketed-paste
    /// payload so they can't prematurely close the paste window and let
    /// subsequent bytes execute as shell input — the classic paste-injection
    /// attack. Copying another terminal's output that happens to include
    /// that exact sequence is the realistic trigger. We only redact the
    /// closing marker (ESC[200~ inside a paste is harmless — bracketed paste
    /// doesn't nest).
    ///
    /// Post-`sanitizePasteControls` this is largely redundant (ESC is
    /// already stripped), but we keep the second-stage defence so a future
    /// refactor that loosens the controls pass doesn't silently re-open the
    /// nested-paste attack surface.
    static func sanitizeBracketedPaste(_ input: Data) -> Data {
        let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        guard input.count >= terminator.count else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let remaining = input.distance(from: i, to: input.endIndex)
            if remaining >= terminator.count {
                var match = true
                for k in 0..<terminator.count {
                    if input[input.index(i, offsetBy: k)] != terminator[k] {
                        match = false
                        break
                    }
                }
                if match {
                    i = input.index(i, offsetBy: terminator.count)
                    continue
                }
            }
            out.append(input[i])
            i = input.index(after: i)
        }
        return out
    }
}
