import Foundation

/// Paste/copy/drop sanitization chain. The pipeline order is load-bearing: normalize → control-scrub → bidi-strip, then
/// bracketed vs LF→CR. Variation Selectors are stripped only from display (`scrubURLForDisplay`), never from paste/drop bytes.
enum PasteSanitizer {
    private static func finishRewrite(
        _ input: Data, _ out: inout [UInt8], dirty: Bool,
        _ p: UnsafeRawBufferPointer, from runStart: Int
    ) -> Data {
        guard dirty else { return input }
        out.append(contentsOf: UnsafeRawBufferPointer(rebasing: p[runStart..<p.count]))
        return Data(out)
    }

    private static func flushRun(
        _ out: inout [UInt8], dirty: inout Bool,
        _ p: UnsafeRawBufferPointer, from runStart: Int, to i: Int
    ) {
        if !dirty {
            out.reserveCapacity(p.count)
            dirty = true
        }
        out.append(contentsOf: UnsafeRawBufferPointer(rebasing: p[runStart..<i]))
    }

    /// CR, not LF: a raw-mode program without bracketed paste that binds only CR to Enter (`/usr/bin/nano`, Pico, where
    /// ^J is Justify) merges the lines of an LF paste. Cooked mode is unaffected: ICRNL maps the CR back to NL.
    static func convertLFToCR(_ input: Data) -> Data {
        guard input.contains(0x0A) else { return input }
        return input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
            var out = [UInt8]()
            out.reserveCapacity(p.count)
            for b in p {
                out.append(b == 0x0A ? 0x0D : b)
            }
            return Data(out)
        }
    }

    /// CRLF → LF: the PTY's ICRNL flag would otherwise map the CR to an extra LF. A lone CR is left alone.
    static func normalizePasteLineEndings(_ input: Data) -> Data {
        guard input.contains(0x0D) else { return input }
        return input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
            let n = p.count
            var out = [UInt8]()
            var dirty = false
            var runStart = 0
            var i = 0
            while i < n {
                if p[i] == 0x0D, i + 1 < n, p[i + 1] == 0x0A {
                    flushRun(&out, dirty: &dirty, p, from: runStart, to: i)
                    i += 1
                    runStart = i
                }
                i += 1
            }
            return finishRewrite(input, &out, dirty: dirty, p, from: runStart)
        }
    }

    /// Replaces C0 (except TAB / LF / CR), DEL and the C1 set with a space, before every paste, bracketed or not.
    /// C1 (0x80–0x9F) is UTF-8 `C2 80`…`C2 9F` and holds ESC-free CSI (0x9B), OSC (0x9D) and DCS (0x90).
    static func sanitizePasteControls(_ input: Data) -> Data {
        input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
            let n = p.count
            var out = [UInt8]()
            var dirty = false
            var runStart = 0
            var i = 0
            while i < n {
                let b = p[i]
                if b >= 0x20, b != 0x7F, b != 0xC2 {
                    i += 1
                    continue
                }
                if b == 0x09 || b == 0x0A || b == 0x0D {
                    i += 1
                    continue
                }
                var consumed = 1
                if b == 0xC2 {
                    // Only the valid C1 encoding is matched; lone continuation bytes are left to the parser.
                    guard i + 1 < n, (0x80...0x9F).contains(p[i + 1]) else {
                        i += 1
                        continue
                    }
                    consumed = 2
                }
                flushRun(&out, dirty: &dirty, p, from: runStart, to: i)
                out.append(0x20)
                i += consumed
                runStart = i
            }
            return finishRewrite(input, &out, dirty: dirty, p, from: runStart)
        }
    }

    /// Drops bidi controls, zero-width and line-separator scalars (some REPLs treat U+2028/9 as line terminators) and tag characters.
    /// ZWNJ/ZWJ (U+200C/D) and Variation Selectors are kept: they are content (emoji sequences, Persian / Indic orthography) and cannot reorder text.
    static func stripBidiOverrides(_ input: Data) -> Data {
        input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
            let n = p.count
            var out = [UInt8]()
            var dirty = false
            var runStart = 0
            var i = 0
            while i < n {
                let b0 = p[i]
                guard b0 == 0xC2 || b0 == 0xD8 || b0 == 0xE1
                    || b0 == 0xE2 || b0 == 0xEF || b0 == 0xF3
                else {
                    i += 1
                    continue
                }
                let remaining = n - i
                var matched = 0

                if remaining >= 2 {
                    let b1 = p[i + 1]
                    // U+00AD soft hyphen (C2 AD), U+061C ALM (D8 9C).
                    if (b0 == 0xC2 && b1 == 0xAD) || (b0 == 0xD8 && b1 == 0x9C) {
                        matched = 2
                    }
                }

                if matched == 0, remaining >= 3 {
                    let b1 = p[i + 1]
                    let b2 = p[i + 2]
                    // U+180E MVS (E1 A0 8E); U+200B ZWSP, U+200E/F LRM/RLM (E2 80 8B/8E/8F); U+2028/9 LS/PS, U+202A-E
                    // (E2 80 A8-AE); U+2060 WJ (E2 81 A0); U+2066-9 isolates (E2 81 A6-A9); U+FEFF BOM (EF BB BF).
                    if b0 == 0xE1, b1 == 0xA0, b2 == 0x8E {
                        matched = 3
                    } else if b0 == 0xE2 {
                        if b1 == 0x80, b2 == 0x8B || b2 == 0x8E || b2 == 0x8F
                            || (0xA8...0xAE).contains(b2) {
                            matched = 3
                        } else if b1 == 0x81, b2 == 0xA0 || (0xA6...0xA9).contains(b2) {
                            matched = 3
                        }
                    } else if b0 == 0xEF, b1 == 0xBB, b2 == 0xBF {
                        matched = 3
                    }
                }

                if matched == 0, remaining >= 4, b0 == 0xF3 {
                    let b1 = p[i + 1]
                    let b2 = p[i + 2]
                    let b3 = p[i + 3]
                    // Tag block U+E0000–E007F: F3 A0 {80|81} XX. XX must be a continuation byte, or a malformed
                    // lead would be over-consumed and the byte after the prefix silently dropped.
                    if b1 == 0xA0, b2 == 0x80 || b2 == 0x81, (0x80...0xBF).contains(b3) {
                        matched = 4
                    }
                }

                guard matched > 0 else {
                    i += 1
                    continue
                }
                flushRun(&out, dirty: &dirty, p, from: runStart, to: i)
                i += matched
                runStart = i
            }
            return finishRewrite(input, &out, dirty: dirty, p, from: runStart)
        }
    }

    /// For single-line chrome surfaces (hover tooltip, OSC 7 cwd in the proxy icon). The OSC 8 tooltip is the user's
    /// "verify before clicking" affordance: a bidi override surviving into it makes a hostile URL read as a trusted one.
    static func scrubURLForDisplay(_ s: String) -> String {
        var bytes = sanitizePasteControls(Data(s.utf8))
        // Dropped, not replaced with a space: a fake space could survive truncation and look like part of the URL host.
        bytes = bytes.filter { $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
        bytes = stripBidiOverrides(bytes)
        // Display only: also strip the Variation Selectors and ZWNJ/ZWJ that `stripBidiOverrides` preserves.
        let scrubbed = String(decoding: bytes, as: UTF8.self)
        return String(scrubbed.unicodeScalars.filter {
            !((0xFE00...0xFE0F).contains($0.value)
                || (0xE0100...0xE01EF).contains($0.value)
                || $0.value == 0x200C || $0.value == 0x200D)
        })
    }

    /// Removes literal `ESC [ 2 0 1 ~` terminators so a payload cannot close the paste window early (`ESC [ 200 ~` is harmless: bracketed
    /// paste does not nest). Largely redundant after `sanitizePasteControls` strips ESC; kept as a second stage in case that pass is loosened.
    static func sanitizeBracketedPaste(_ input: Data) -> Data {
        let terminator: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        let tlen = terminator.count
        guard input.count >= tlen else { return input }
        return input.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Data in
            let n = p.count
            var out = [UInt8]()
            var dirty = false
            var runStart = 0
            var i = 0
            while i + tlen <= n {
                guard p[i] == terminator[0] else {
                    i += 1
                    continue
                }
                var match = true
                for k in 1..<tlen where p[i + k] != terminator[k] {
                    match = false
                    break
                }
                guard match else {
                    i += 1
                    continue
                }
                flushRun(&out, dirty: &dirty, p, from: runStart, to: i)
                i += tlen
                runStart = i
            }
            return finishRewrite(input, &out, dirty: dirty, p, from: runStart)
        }
    }

    /// Single quotes, stepping outside them for `'` (`'\''`) and `\` (`'\\'`). The backslash rewrite is for fish,
    /// where `\\` and `\'` are escapes inside single quotes: a bare `'\''` after a `\` would run the tail as a command.
    static func shellQuote(_ path: String) -> String {
        var quoted = "'"
        // Single pass over scalars: replacing `'` first would feed the backslash of `'\''` into the `\` rewrite.
        for scalar in path.unicodeScalars {
            switch scalar {
            case "'": quoted += "'\\''"
            case "\\": quoted += "'\\\\'"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "'"
    }

    static func joinedDroppedPaths(_ paths: [String]) -> String {
        paths.map(shellQuote).joined(separator: " ")
    }
}
