import SwiftUI
import AppKit
import os

/// Settings → Diagnostics tab. Lists hang reports (written by
/// `MainThreadWatchdog`) and macOS crash reports for Blackbird, with
/// Reveal in Finder / Copy / Email Diagnostics actions per row.
///
/// Read-only — no `@AppStorage`, no auto-upload, no third-party network
/// calls. The Email Diagnostics flow opens the user's mail client; nothing
/// is transmitted automatically. F-S7-001 / F-S7-003 sister fixes ship in
/// the same v0.2 cycle.
public struct DiagnosticsView: View {
    @StateObject private var store = DiagnosticReportStore()
    @State private var lastError: String?

    private static let log = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "diagnostics"
    )

    public init() {}

    public var body: some View {
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
                Self.footer("""
                    Reports are written to ~/Library/Logs/Blackbird (hang reports) \
                    and ~/Library/Logs/DiagnosticReports (crashes). Email Diagnostics \
                    opens your default mail client; nothing is sent automatically.
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

    // Section-footer helper. Mirrors `SettingsView.footer(_:)` — without
    // the explicit leading/full-width treatment, SwiftUI's grouped Form
    // sizes footer text to its content and centers it under the section.
    private static func footer(_ text: String) -> some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    /// Copy the report's text contents to the pasteboard. Returns `true`
    /// on success. Sets `lastError` on failure (read error OR non-text
    /// content). Crash report files (`.ips` modern format is JSON; older
    /// `.crash` is plain text) are expected to be UTF-8 — we surface a
    /// clear error rather than silently substituting `\u{FFFD}` so a user
    /// pasting nonsense into an email knows why.
    @discardableResult
    private func copy(_ report: DiagnosticReportStore.Report) -> Bool {
        let data: Data
        do {
            data = try Data(contentsOf: report.url)
        } catch {
            lastError = "Could not read \(report.url.lastPathComponent): \(error.localizedDescription)"
            Self.log.error("copy read failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        guard let text = String(data: data, encoding: .utf8) else {
            lastError = "\(report.url.lastPathComponent) contains non-text bytes. Use Reveal in Finder to attach the file directly."
            Self.log.error("copy decode failed: \(report.url.lastPathComponent, privacy: .public) is not UTF-8")
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastError = nil
        return true
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
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(DiagnosticReportStore.defaultHangDirectoryName)
        // First-run users (no hangs ever) hit this with a directory that
        // doesn't exist yet. Without a pre-check, NSWorkspace either no-ops
        // or surfaces a confusing Finder window — explain the empty state.
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = "Logs folder hasn't been created yet — it appears the first time Blackbird writes a hang report."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
        // Stage 1 — copy. If reading or decoding fails, abort so we don't
        // open a mail compose window with stale clipboard contents.
        guard copy(report) else { return }

        // Stage 2 — mailto. URLQueryItem percent-encodes per RFC 3986 but
        // mail clients are inconsistent about treating `+` as space; the
        // explicit encoding below adds a belt-and-suspenders pass for the
        // subject line, which contains a filename that can have `+`, `&`,
        // `?`, or non-ASCII.
        let subject = "Blackbird \(versionString()) diagnostic — \(report.url.lastPathComponent)"
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

    private func versionString() -> String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return short == build ? short : "\(short) (\(build))"
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
