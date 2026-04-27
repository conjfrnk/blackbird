import AppKit
import Foundation
import BBCore

/// Paste pipeline: CRLF normalisation, C0/DEL scrubbing, Unicode
/// bidi-override stripping (Trojan Source defence), bracketed-paste
/// sanitization. Called from two places: the ⌘V menu action via
/// `paste(_:)` on the main class, and the drag-and-drop path via
/// `pasteText(_:)` after file URLs are joined + shell-quoted.
///
/// Why extracted: the paste pipeline is a cluster of pure / mostly-
/// static sanitizers that doesn't touch mutable view state beyond
/// `session.send` and `currentSnapshot.termMode`. Splitting it out
/// keeps the main `TerminalView.swift` focused on event loop +
/// rendering + first-responder glue. Audit K5 — sanitizer bugs are
/// security issues, and a focused file makes them easier to audit.
extension TerminalView {

    // MARK: - Paste

    @objc public func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(str)
    }

    /// Shared paste implementation: applies CRLF normalisation, wraps in
    /// bracketed-paste markers when the app has enabled mode 2004, and sends
    /// to the session. Used by both the menu/keyboard paste action and the
    /// drag-and-drop code path (file URLs are shell-quoted into a single
    /// string which is then fed through here).
    func pasteText(_ text: String) {
        #if DEBUG
        // Test seam: DragDropTests captures the *pre-encoding* pasted
        // string here so it can assert that drop integration produces
        // the expected shell-quoted command-line text. Real PTY bytes
        // are encoded later (CRLF normalisation, control sanitisation,
        // bracketed-paste wrap) — those have separate sanitiser tests;
        // the drop integration only needs the text-level invariant.
        if let recorder = pasteTextRecorderForTests {
            recorder(text)
        }
        #endif
        guard let session else { return }
        if (currentSnapshot?.displayOffset ?? 0) > 0 {
            session.scrollToBottom()
        }
        let normalized = Self.normalizePasteLineEndings(Data(text.utf8))
        // Strip C0 controls (except TAB/LF) and DEL unconditionally. Pasted
        // payload is "user typing" — Ctrl+C, Ctrl+Z, ESC inside the content
        // can break out of bracketed paste (CVE-2026-26982 class in Ghostty
        // <1.3.0) and execute arbitrary bytes as shell input. The sanitizer
        // replaces blocked bytes with space so column-formatted paste still
        // lines up.
        let cleaned = Self.sanitizePasteControls(normalized)
        // Drop explicit bidi control characters — Trojan Source (Boucher &
        // Anderson 2021). An adversarial webpage / remote can render as
        // `rm -rf harmless` while the copied bytes are `rm -rf ~`, exploiting
        // LRO / RLO overrides to hide the real command. Legitimate RTL
        // (Arabic / Hebrew) text never needs explicit overrides; Unicode
        // bidi algorithm handles it implicitly. Stripping is safe.
        let bytes = Self.stripBidiOverrides(cleaned)
        let bracketedPaste = currentSnapshot?.termMode.contains(.bracketedPaste) ?? false
        if bracketedPaste {
            var wrapped = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC[200~
            wrapped.append(Self.sanitizeBracketedPaste(bytes))
            wrapped.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))  // ESC[201~
            session.send(wrapped)
        } else {
            session.send(bytes)
        }
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

    /// Drop every Unicode bidi formatting / isolate / mark control from
    /// a paste payload. Targets a dozen codepoints across three UTF-8
    /// length classes:
    ///
    ///   U+061C  ALM   D8 9C         Arabic letter mark (2-byte)
    ///   U+180E  MVS   E1 A0 8E      Mongolian vowel separator (3-byte)
    ///   U+200E  LRM   E2 80 8E      left-to-right mark
    ///   U+200F  RLM   E2 80 8F      right-to-left mark
    ///   U+202A  LRE   E2 80 AA      left-to-right embedding
    ///   U+202B  RLE   E2 80 AB      right-to-left embedding
    ///   U+202C  PDF   E2 80 AC      pop directional formatting
    ///   U+202D  LRO   E2 80 AD      left-to-right override  ← Trojan Source
    ///   U+202E  RLO   E2 80 AE      right-to-left override  ← Trojan Source
    ///   U+2066  LRI   E2 81 A6      left-to-right isolate
    ///   U+2067  RLI   E2 81 A7      right-to-left isolate
    ///   U+2068  FSI   E2 81 A8      first strong isolate
    ///   U+2069  PDI   E2 81 A9      pop directional isolate
    ///
    /// These are rare in legitimate text — Unicode's bidirectional
    /// algorithm handles Arabic / Hebrew automatically; explicit
    /// formatting is a spoofing hammer. iTerm2's "Filter control
    /// sequences on paste" option applies the same policy; the extra
    /// codepoints here match CVE-2021-42574 follow-up advisories that
    /// broadened the list beyond the original nine overrides.
    static func stripBidiOverrides(_ input: Data) -> Data {
        // Fast path: no 0xD8 / 0xE1 / 0xE2 byte means no match at all.
        guard input.contains(where: { $0 == 0xD8 || $0 == 0xE1 || $0 == 0xE2 })
        else { return input }
        var out = Data()
        out.reserveCapacity(input.count)
        var i = input.startIndex
        while i < input.endIndex {
            let b0 = input[i]
            let remaining = input.distance(from: i, to: input.endIndex)

            // 2-byte: U+061C  (D8 9C)
            if b0 == 0xD8, remaining >= 2,
               input[input.index(after: i)] == 0x9C {
                i = input.index(i, offsetBy: 2)
                continue
            }

            // 3-byte sequences: E1 A0 8E (U+180E); E2 8x xx for several.
            if remaining >= 3 {
                let b1 = input[input.index(i, offsetBy: 1)]
                let b2 = input[input.index(i, offsetBy: 2)]
                if b0 == 0xE1, b1 == 0xA0, b2 == 0x8E {
                    i = input.index(i, offsetBy: 3)
                    continue
                }
                if b0 == 0xE2 {
                    // U+200E / U+200F: E2 80 8E / 8F
                    if b1 == 0x80 && (b2 == 0x8E || b2 == 0x8F) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                    // U+202A..U+202E: E2 80 AA..AE
                    if b1 == 0x80 && (0xAA...0xAE).contains(b2) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                    // U+2066..U+2069: E2 81 A6..A9
                    if b1 == 0x81 && (0xA6...0xA9).contains(b2) {
                        i = input.index(i, offsetBy: 3)
                        continue
                    }
                }
            }

            out.append(b0)
            i = input.index(after: i)
        }
        return out
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
