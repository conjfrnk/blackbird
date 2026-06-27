import SwiftUI
import AppKit
import os

/// Settings → Diagnostics tab. Lists hang reports (written by
/// `MainThreadWatchdog`) and macOS crash reports for Blackbird, with
/// Reveal in Finder / Copy / Email Diagnostics actions per row.
///
/// Read-only — no `@AppStorage`, no auto-upload, no third-party network
/// calls. The Email Diagnostics flow opens the user's mail client; nothing
/// is transmitted automatically.
///
/// Visibility is `internal` (default): only `SettingsView` in the same
/// module mounts the view. Promoting to `public` would widen the API
/// surface for no benefit.
struct DiagnosticsView: View {
    @StateObject private var store = DiagnosticReportStore()
    @State private var lastError: String?

    private static let log = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "diagnostics"
    )

    /// Max file size to load into memory for Copy / Email Diagnostics.
    /// Real-world hang reports run ~10–200 KB; macOS `.ips` crash reports
    /// run ~1–3 MB. 16 MB gives ~50× headroom while bounding the worst
    /// case (planted multi-GB file, a 32 GB unrelated process spew that
    /// happened to match `Blackbird-*.ips`). Beyond the cap we ask the
    /// user to Reveal in Finder and attach manually.
    private static let inlineLoadCapBytes: Int64 = 16 * 1024 * 1024

    init() {}

    var body: some View {
        Form {
            Section {
                if store.reports.isEmpty {
                    Text("No diagnostics yet. If Blackbird ever hangs or crashes, the report will appear here.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(store.reports) { report in
                        DiagnosticRow(
                            report: report,
                            onCopy: { copy(report) },
                            onReveal: { reveal(report) },
                            onEmail: { email(report) }
                        )
                    }
                }
            } header: {
                Text("Reports")
            } footer: {
                SettingsChrome.footer("""
                    Reports are written to ~/Library/Logs/Blackbird (hang reports) \
                    and ~/Library/Logs/DiagnosticReports (crashes). Email Diagnostics \
                    opens your default mail client; nothing is sent automatically. \
                    Crash reports may include file paths under your home folder, \
                    process arguments, and dyld image paths — review the compose \
                    window before sending.
                    """)
            }

            if let lastError {
                Section {
                    Text(lastError)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                Button("Refresh") { store.reload() }
                Button("Reveal Logs Folder in Finder") { revealLogsFolder() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { store.reload() }
    }

    // MARK: - Actions

    /// Copy the report's text contents to the pasteboard. Sets `lastError`
    /// on failure (read error OR non-text content OR oversized file).
    ///
    /// Crash report files (`.ips` modern format is JSON; older `.crash` is
    /// plain text) are expected to be UTF-8 — we surface a clear error
    /// rather than silently substituting `\u{FFFD}` so a user pasting
    /// nonsense into an email knows why.
    ///
    /// Oversized files (> 16 MB) are rejected to bound peak memory and
    /// main-thread stall. Reading a 2 GB file synchronously into Data,
    /// then UTF-8-decoding it, then `NSPasteboard.setString` would each
    /// be a copy — peak ~6 GB and seconds of beachball. Real-world
    /// reports never approach the cap; if one does, it's adversarial
    /// or a runaway log.
    ///
    /// Control characters in the report (BEL, OSC introducers, CSI bytes)
    /// are stripped before placing on the pasteboard. A planted hang
    /// report containing `\x1b]52;c;...\x07` (OSC 52 clipboard write)
    /// would otherwise pose as inert text and, when pasted into another
    /// terminal emulator, re-execute the escape sequence. The defense
    /// is shallow but cheap.
    private func copy(_ report: DiagnosticReportStore.Report) {
        Task { @MainActor in
            _ = await loadSanitizedAndCopy(report)
        }
    }

    /// Worker shared by Copy and Email Diagnostics. Runs the disk read
    /// and the per-byte control-char scan on a detached background task
    /// so a 16 MB report on a network home directory can't beachball
    /// Settings. Returns `true` after the pasteboard write completes;
    /// `false` (with `lastError` set) on every failure path.
    @MainActor
    private func loadSanitizedAndCopy(_ report: DiagnosticReportStore.Report) async -> Bool {
        if report.byteSize > Self.inlineLoadCapBytes {
            let mb = Double(report.byteSize) / (1024 * 1024)
            lastError = String(format: "%@ is %.1f MB — too large for inline copy. Use Reveal in Finder to attach the file directly.",
                               report.url.lastPathComponent, mb)
            Self.log.notice("copy refused: \(report.url.lastPathComponent, privacy: .public) is \(report.byteSize, privacy: .public) bytes (cap \(Self.inlineLoadCapBytes, privacy: .public))")
            return false
        }
        let url = report.url
        let cap = Int(Self.inlineLoadCapBytes)
        let outcome = await Self.loadAndSanitize(url: url, cap: cap)

        switch outcome {
        case .success(let sanitized):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(sanitized, forType: .string)
            lastError = nil
            return true
        case .failure(.read(let message)):
            lastError = "Could not read \(report.url.lastPathComponent): \(message)"
            Self.log.error("copy read failed: \(message, privacy: .public)")
            return false
        case .failure(.grewDuringRead(let bytes)):
            let mb = Double(bytes) / (1024 * 1024)
            lastError = String(format: "%@ grew to %.1f MB during read — too large for inline copy. Use Reveal in Finder to attach the file directly.",
                               report.url.lastPathComponent, mb)
            Self.log.notice("copy refused mid-read: \(report.url.lastPathComponent, privacy: .public) read \(bytes, privacy: .public) bytes (cap \(Self.inlineLoadCapBytes, privacy: .public))")
            return false
        case .failure(.notUTF8):
            lastError = "\(report.url.lastPathComponent) contains non-text bytes. Use Reveal in Finder to attach the file directly."
            Self.log.error("copy decode failed: \(report.url.lastPathComponent, privacy: .public) is not UTF-8")
            return false
        case .failure(.symlinkRejected):
            // Audit S5-003: enumerate filters symlinks, but a same-uid
            // attacker can swap the inode between scan and click. The
            // read-time O_NOFOLLOW gate refused; surface a clear
            // diagnostic so the operator notices something changed.
            lastError = "\(report.url.lastPathComponent) is a symlink — refused for safety."
            Self.log.error("copy refused symlink: \(report.url.lastPathComponent, privacy: .public)")
            return false
        case .failure(.notRegularFile):
            // Audit S2-001: enumerate admits only regular files, but a
            // same-uid attacker can swap the inode for a FIFO/device node
            // between scan and click. The read-time fstat gate refused
            // (and O_NONBLOCK kept the open from hanging); surface a clear
            // diagnostic so the operator notices something changed.
            lastError = "\(report.url.lastPathComponent) is not a regular file — refused for safety."
            Self.log.error("copy refused non-regular file: \(report.url.lastPathComponent, privacy: .public)")
            return false
        }
    }

    /// Read + sanitize on a detached background task. Internal so tests
    /// can verify the work runs off the main thread without going through
    /// SwiftUI's @State machinery for `lastError` / pasteboard side effects.
    static func loadAndSanitize(url: URL, cap: Int) async -> Result<String, LoadError> {
        let (result, _) = await loadAndSanitizeForTesting(url: url, cap: cap)
        return result
    }

    /// Same as `loadAndSanitize` but additionally returns whether the
    /// detached worker actually executed off the main thread. Tests use
    /// the second tuple element to pin the M6 invariant; production
    /// callers go through `loadAndSanitize` and ignore the flag.
    static func loadAndSanitizeForTesting(url: URL, cap: Int) async -> (Result<String, LoadError>, ranOffMain: Bool) {
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

    private func reveal(_ report: DiagnosticReportStore.Report) {
        // Stale `lastError` from a previous action would persist across a
        // successful reveal otherwise — clear it so the UI matches what
        // the user just saw work.
        lastError = nil
        guard FileManager.default.fileExists(atPath: report.url.path) else {
            lastError = "\(report.url.lastPathComponent) was deleted. Refresh to update the list."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([report.url])
    }

    private func revealLogsFolder() {
        lastError = nil
        let home = FileManager.default.homeDirectoryForCurrentUser
        let hangDir = home.appendingPathComponent(DiagnosticReportStore.defaultHangDirectoryName)
        let crashDir = home.appendingPathComponent(DiagnosticReportStore.defaultCrashDirectoryName)
        let fm = FileManager.default
        // Prefer the hang-report directory (Blackbird's own), but fall
        // back to the crash directory if hangs don't exist yet — first-
        // run users may have a crash before they ever experience a hang.
        // If neither exists, surface the empty-state explanation.
        if fm.fileExists(atPath: hangDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([hangDir])
        } else if fm.fileExists(atPath: crashDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([crashDir])
        } else {
            lastError = "Logs folder hasn't been created yet — it appears the first time Blackbird writes a hang report or macOS records a crash."
        }
    }

    /// Email Diagnostics: copy report → open mailto: with subject + brief
    /// instructional body. mailto: URLs cap at ~2 KB on macOS so we can't
    /// inline the report itself; the clipboard-and-paste pattern is the
    /// reliable path that works regardless of whether the user has Mail.app
    /// configured.
    ///
    /// Why not `NSSharingService(named: .composeEmail)`: returns non-nil
    /// even when Mail.app isn't configured, then `perform(withItems:)`
    /// fails asynchronously via a delegate. Without a delegate the failure
    /// is silent (no compose window, no error). Wiring the delegate adds
    /// boilerplate for a path that's strictly worse than mailto+clipboard
    /// when it does work (Mail's compose window with attachment) and is
    /// indistinguishable when it doesn't.
    private func email(_ report: DiagnosticReportStore.Report) {
        Task { @MainActor in
            // Stage 1 — copy. If reading or decoding fails, abort so we
            // don't open a mail compose window with stale clipboard
            // contents.
            guard await loadSanitizedAndCopy(report) else { return }

            // Stage 2 — mailto. URLQueryItem percent-encodes per RFC 3986
            // but mail clients are inconsistent about treating `+` as
            // space; the explicit encoding below adds a belt-and-
            // suspenders pass for the subject line, which contains a
            // filename that can have `+`, `&`, `?`, or non-ASCII.
            let subject = "Blackbird \(SettingsChrome.versionString) diagnostic — \(report.url.lastPathComponent)"
            let body = "Diagnostic copied to clipboard — paste below this line, then describe what you were doing.\n\n"
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&?#=/"))
            guard let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: allowed),
                  let encodedBody = body.addingPercentEncoding(withAllowedCharacters: allowed),
                  let url = URL(string: "mailto:conjfrnk@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)") else {
                lastError = "Report copied to clipboard. Could not construct the mail URL — paste manually into a new message."
                return
            }
            if NSWorkspace.shared.open(url) {
                lastError = "Report copied to clipboard. Paste into your email."
            } else {
                lastError = "Could not open a mail client. The report is on your clipboard; paste it into your email manually."
            }
        }
    }

}

private struct DiagnosticRow: View {
    let report: DiagnosticReportStore.Report
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onEmail: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.url.lastPathComponent)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(report.kind == .hang ? "Hang" : "Crash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            (report.kind == .hang ? Color.yellow : Color.red)
                                .opacity(0.2)
                        )
                        .clipShape(Capsule())
                }
                Text("\(Self.dateFormatter.string(from: report.modificationDate)) · \(byteCountString(report.byteSize))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions") {
                Button("Reveal in Finder", action: onReveal)
                Button("Copy to Clipboard", action: onCopy)
                Button("Email Diagnostics", action: onEmail)
            }
            .menuStyle(.button)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func byteCountString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
