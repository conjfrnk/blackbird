import Foundation
import Darwin

/// TOCTOU/OOM-safe loader for the Diagnostics tab's inline report reads,
/// lifted out of the SwiftUI `DiagnosticsView` so the security-critical file
/// IO + sanitisation is a plain testable type rather than static methods on a
/// View (REFACTOR.md Area 7: "security-critical file IO + sanitization inside a
/// SwiftUI View"). The View owns the policy (size cap, error presentation) and
/// calls `loadAndSanitize`; the loader owns the `O_NOFOLLOW | O_NONBLOCK` open,
/// the `fstat` regular-file gate, the post-read cap, and the control/bidi scrub.
enum DiagnosticFileLoader {
    /// Read + sanitize on a detached background task. Internal so tests
    /// can verify the work runs off the main thread without going through
    /// SwiftUI's @State machinery for `lastError` / pasteboard side effects.
    static func loadAndSanitize(url: URL, cap: Int) async -> Result<String, LoadError> {
        let (result, _) = await loadAndSanitizeTraced(url: url, cap: cap)
        return result
    }

    /// The core implementation. Returns the load result plus whether the
    /// detached worker actually executed off the main thread — a small piece
    /// of observability the M6 off-main test pins on. Production callers go
    /// through `loadAndSanitize` and ignore the flag. Neutrally named (not a
    /// `…ForTesting` seam) so no test-only symbol ships in a Release build
    /// (REFACTOR.md Part VI acceptance §4).
    static func loadAndSanitizeTraced(url: URL, cap: Int) async -> (Result<String, LoadError>, ranOffMain: Bool) {
        await Task.detached {
            let ranOffMain = !Thread.isMainThread
            // Audit S5-003: open with O_NOFOLLOW so a TOCTOU swap of the
            // file inode between `reload()` (which filters symlinks at
            // enumerate time) and this read cannot redirect us to an
            // attacker-chosen target like ~/.ssh/id_rsa. ELOOP at open
            // time surfaces the symlink as a typed failure rather than
            // routing the symlink's target through the sanitiser to the
            // pasteboard / Email-Diagnostics compose. `Data(contentsOf:)`
            // (the prior call) silently follows symlinks.
            // Audit S2-001: also pass O_NONBLOCK. O_NOFOLLOW rejects a
            // symlink final component but NOT a FIFO / socket / device node.
            // `reload()` admits only regular files at enumerate time, but a
            // same-uid process can swap the regular report for a FIFO between
            // scan and this read; `open(O_RDONLY)` on a writer-less FIFO
            // blocks indefinitely (and so would the subsequent read), hanging
            // and leaking this detached worker on every Copy/Email click.
            // O_NONBLOCK makes the open return immediately for a FIFO/device
            // so the fstat gate below can reject it. It is harmless for the
            // regular-file fast path — regular files never report EAGAIN on
            // read, so readToEnd() behaves identically.
            let fd = url.withUnsafeFileSystemRepresentation { cPath -> Int32 in
                guard let cPath = cPath else { return -1 }
                return Darwin.open(cPath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            }
            if fd < 0 {
                let err = errno
                if err == ELOOP {
                    return (.failure(.symlinkRejected), ranOffMain)
                }
                let msg = String(cString: strerror(err))
                return (.failure(.read("open: \(msg)")), ranOffMain)
            }
            defer { Darwin.close(fd) }
            // Audit S2-001: reject anything that is not a regular file. Closes
            // the FIFO/device-node TOCTOU gap that O_NOFOLLOW does not cover.
            var st = stat()
            guard fstat(fd, &st) == 0 else {
                let msg = String(cString: strerror(errno))
                return (.failure(.read("fstat: \(msg)")), ranOffMain)
            }
            // Work in `mode_t` (the type of `st_mode`); `S_IFMT`/`S_IFREG`
            // are bridged as `mode_t` on this SDK, and the values fit, so this
            // is homogeneous regardless of how the constants are imported.
            guard (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                return (.failure(.notRegularFile), ranOffMain)
            }
            let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data: Data
            do {
                // readToEnd() returns Data? — nil only on empty (legitimate);
                // we treat that as an empty success below.
                data = try fh.readToEnd() ?? Data()
            } catch {
                return (.failure(.read(error.localizedDescription)), ranOffMain)
            }
            // Post-read size check defends against a TOCTOU window — if the
            // file grew between reload() (which captured `report.byteSize`)
            // and `Data(contentsOf:)`, the pre-flight check above would have
            // passed. Real-world hang reports are written atomically by
            // sample(1) and ReportCrash, so this should never fire — flag it
            // if it does so we know an adversarial logger is appending mid-
            // read.
            if data.count > cap {
                return (.failure(.grewDuringRead(data.count)), ranOffMain)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return (.failure(.notUTF8), ranOffMain)
            }
            return (.success(Self.stripControlCharacters(text)), ranOffMain)
        }.value
    }

    enum LoadError: Error, Sendable, Equatable {
        case read(String)
        case grewDuringRead(Int)
        case notUTF8
        /// Audit S5-003: `open(O_NOFOLLOW)` returned ELOOP — the path
        /// resolved to a symlink. `reload()` filters symlinks at scan,
        /// but a same-uid attacker can swap a regular file for a
        /// symlink between scan and read; the read-time gate refuses
        /// to follow.
        case symlinkRejected
        /// Audit S2-001: `fstat` after open showed the path is not a
        /// regular file (e.g. a FIFO / device node swapped in via a
        /// same-uid TOCTOU). O_NOFOLLOW does not cover these, and
        /// reading one could block the worker forever; the read-time
        /// gate refuses anything that is not `S_IFREG`.
        case notRegularFile
    }

    /// Replace C0 / C1 control characters AND bidi / zero-width /
    /// invisible scalars (other than `\n` and `\t`) with the Unicode
    /// replacement character. Defense-in-depth: a planted report should
    /// not be able to slip terminal escape sequences OR Trojan-source-
    /// class bidi overrides onto the user's pasteboard when they Copy
    /// or Email Diagnostics. The legitimate writers (MainThreadWatchdog
    /// `sample(1)` output and macOS `.ips` JSON) only use printable ASCII
    /// + `\n`, so the substitution never touches real reports.
    ///
    /// The bidi / zero-width set mirrors `TerminalView+Paste.swift`'s
    /// `stripBidiOverrides` so the inbound-paste and outbound-copy paths
    /// have symmetric coverage — otherwise a `\u{202E}`-flipped string
    /// could survive Copy and reach a bidi-rendering target (GitHub
    /// issue, Slack, Mail compose) where it visually misrepresents the
    /// underlying bytes. Audit S4-002.
    ///
    /// Performance: stays in `String.UnicodeScalarView` end-to-end, reserves
    /// capacity via `s.utf8.count` (O(1) on Swift's contiguous storage),
    /// and avoids per-scalar `Character` boxing. A clean 16 MiB report at
    /// the inline cap should hold the main thread for tens of ms, not
    /// seconds.
    internal static func stripControlCharacters(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.utf8.count)
        let replacement = Unicode.Scalar(0xFFFD)!
        for scalar in s.unicodeScalars {
            let v = scalar.value
            // Allow newline (0x0A) and horizontal tab (0x09); strip every
            // other C0 (0x00-0x1F) and DEL (0x7F) plus the C1 range
            // (0x80-0x9F) which is where ANSI/VT escape control bytes live
            // when they bypass ESC-introducers.
            let isControl = (v < 0x20 && v != 0x0A && v != 0x09)
                || v == 0x7F
                || (v >= 0x80 && v <= 0x9F)
            // Bidi / zero-width / invisible formatting — Trojan-source set.
            // Discrete scalars (soft hyphen, ALM, MVS, BOM, word joiner)
            // plus the ZWSP/ZWNJ/ZWJ/LRM/RLM (200B–200F), LS/PS (2028/9),
            // bidi formatting (202A–202E), bidi isolates (2066–2069),
            // the Plane-14 tag block (E0000–E007F), and the Variation
            // Selectors blocks VS1-16 (FE00–FE0F) and VS17-256
            // (E0100–E01EF). Audit fix-#16 (2026-05-21): VS blocks were
            // missing from this set even though the doc comment claims
            // it 'mirrors `stripBidiOverrides`' — the inbound-paste
            // sanitizer strips them. Now symmetric.
            let isInvisible = v == 0x00AD
                || v == 0x061C
                || v == 0x180E
                || (v >= 0x200B && v <= 0x200F)
                || (v >= 0x2028 && v <= 0x202E)
                || v == 0x2060
                || (v >= 0x2066 && v <= 0x2069)
                || (v >= 0xFE00 && v <= 0xFE0F)
                || v == 0xFEFF
                || (v >= 0xE0000 && v <= 0xE007F)
                || (v >= 0xE0100 && v <= 0xE01EF)
            if isControl || isInvisible {
                out.append(replacement)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
