import SwiftUI
import AppKit
import os

struct DiagnosticsView: View {
    @StateObject private var store = DiagnosticReportStore()
    @State private var lastError: String?

    private static let log = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "diagnostics"
    )

    /// Bounds peak memory for Copy / Email; real reports run ~10 KB to ~3 MB.
    private static let inlineLoadCapBytes: Int64 = 16 * 1024 * 1024

    private static let supportEmail = "conjfrnk@gmail.com"

    @ObservedObject private var prefs = Preferences.shared

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

            Section {
                Toggle("Detect main-thread hangs", isOn: $prefs.hangDetection)
            } header: {
                Text("Hang detection")
            } footer: {
                SettingsChrome.footer("""
                    When on, a main-thread stall of one second or more writes a \
                    sampled stack trace to ~/Library/Logs/Blackbird (newest 20 are \
                    kept). Takes effect at the next launch.
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
        // The Settings window is cached, so reopening on Diagnostics never re-fires `.onAppear`.
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.didShow)) { _ in
            store.reload()
        }
    }

    // MARK: - Actions

    private func copy(_ report: DiagnosticReportStore.Report) {
        Task { @MainActor in
            _ = await loadSanitizedAndCopy(report)
        }
    }

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
            lastError = "\(report.url.lastPathComponent) is a symlink — refused for safety."
            Self.log.error("copy refused symlink: \(report.url.lastPathComponent, privacy: .public)")
            return false
        case .failure(.notRegularFile):
            lastError = "\(report.url.lastPathComponent) is not a regular file — refused for safety."
            Self.log.error("copy refused non-regular file: \(report.url.lastPathComponent, privacy: .public)")
            return false
        }
    }

    private func reveal(_ report: DiagnosticReportStore.Report) {
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
        if fm.fileExists(atPath: hangDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([hangDir])
        } else if fm.fileExists(atPath: crashDir.path) {
            NSWorkspace.shared.activateFileViewerSelecting([crashDir])
        } else {
            lastError = "Logs folder hasn't been created yet — it appears the first time Blackbird writes a hang report or macOS records a crash."
        }
    }

    /// mailto: URLs cap at ~2 KB on macOS, so the report travels on the clipboard, not in the body.
    /// `NSSharingService(named: .composeEmail)` fails silently when Mail.app isn't configured.
    private func email(_ report: DiagnosticReportStore.Report) {
        Task { @MainActor in
            guard await loadSanitizedAndCopy(report) else { return }

            // Mail clients are inconsistent about `+` as space, so `+&?#=/` are percent-encoded explicitly.
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
