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

    /// Support address for the "Email Diagnostics" mailto flow. One definition
    /// rather than inlined in the URL string (REFACTOR.md Area 7).
    private static let supportEmail = "conjfrnk@gmail.com"

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
        let outcome = await DiagnosticFileLoader.loadAndSanitize(url: url, cap: cap)

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
                  let url = URL(string: "mailto:\(Self.supportEmail)?subject=\(encodedSubject)&body=\(encodedBody)") else {
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
