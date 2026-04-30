import Foundation
import os
import SwiftUI

/// Surfaces hang reports (written by `MainThreadWatchdog`) and macOS-emitted
/// crash reports for Blackbird. Used by the Settings → Diagnostics tab.
///
/// Why @MainActor: every consumer is SwiftUI bound; bouncing across queues
/// for a feature whose hot path is "user opened the tab" buys nothing and
/// would expose us to publishing races on `reports`. The actual file
/// enumeration is a synchronous `contentsOfDirectory` call — fast on the
/// directories involved (handful of files in normal use).
///
/// Why no FSEvents / DispatchSource watcher: `reload()` is cheap, the user
/// reaches this tab infrequently, and a watcher would require an actor or
/// a DispatchQueue with an extra boundary for almost no win. The view
/// re-loads on appear.
@MainActor
final class DiagnosticReportStore: ObservableObject {

    enum Kind: String, Equatable {
        case hang, crash
    }

    struct Report: Identifiable, Equatable {
        /// File URL doubles as identifier — unique per file, stable across
        /// reloads as long as the file isn't moved/renamed.
        let id: URL
        let kind: Kind
        let url: URL
        let modificationDate: Date
        let byteSize: Int64
    }

    /// Path RELATIVE to the user's home directory where `MainThreadWatchdog`
    /// writes hang reports.
    static let defaultHangDirectoryName = "Library/Logs/Blackbird"

    /// Path RELATIVE to the user's home directory where macOS's
    /// ReportCrash service writes per-app crash reports.
    static let defaultCrashDirectoryName = "Library/Logs/DiagnosticReports"

    @Published private(set) var reports: [Report] = []

    private let hangDirectory: URL
    private let crashDirectory: URL
    private let log = Logger(subsystem: "dev.conjfrnk.blackbird", category: "diagnostics")

    /// Pass `nil` for either argument to use the user-default location.
    /// Tests inject temp directories so they don't read or write the
    /// real `~/Library/Logs` tree.
    init(hangDirectory: URL? = nil, crashDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.hangDirectory =
            hangDirectory ?? home.appendingPathComponent(Self.defaultHangDirectoryName)
        self.crashDirectory =
            crashDirectory ?? home.appendingPathComponent(Self.defaultCrashDirectoryName)
    }

    /// Re-enumerate both directories and update `reports`. Sorted by
    /// modification date descending — newest first.
    func reload() {
        let hangs = enumerate(directory: hangDirectory, kind: .hang) { name in
            // Hang reports written by `MainThreadWatchdog` follow `hang-<ts>.txt`.
            name.hasPrefix("hang-") && name.hasSuffix(".txt")
        }
        let crashes = enumerate(directory: crashDirectory, kind: .crash) { name in
            // macOS writes `Blackbird-<ts>-<random>.ips` (modern) or
            // `Blackbird-<ts>-<random>.crash` (legacy). The crash directory
            // contains reports for every crashed process on the system, so
            // filter by app prefix to surface only ours.
            name.hasPrefix("Blackbird-") && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
        }
        reports = (hangs + crashes).sorted { $0.modificationDate > $1.modificationDate }
    }

    private func enumerate(directory: URL, kind: Kind, accept: (String) -> Bool) -> [Report] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            // Missing directory is the normal "no reports yet" state — not
            // an error. We can't distinguish "doesn't exist" from "exists
            // but unreadable" without a separate stat, but both render to
            // the same empty list, so don't log here.
            return []
        }
        return entries.compactMap { url in
            guard accept(url.lastPathComponent) else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            return Report(id: url, kind: kind, url: url, modificationDate: mtime, byteSize: size)
        }
    }
}
