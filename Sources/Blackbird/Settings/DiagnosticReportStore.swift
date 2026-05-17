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

    enum Kind: Equatable {
        case hang, crash
    }

    struct Report: Identifiable, Equatable {
        let kind: Kind
        let url: URL
        let modificationDate: Date
        let byteSize: Int64

        /// File URL doubles as identifier — unique per file, stable across
        /// reloads as long as the file isn't moved/renamed. Computed so we
        /// don't store the same URL twice (a duplicated `id` field is a
        /// future-refactor trap: a refactor that updates `url` without `id`
        /// silently breaks deduplication in `ForEach`).
        var id: URL { url }
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
            // Hang reports written by `MainThreadWatchdog` follow
            // `hang-<ts>.txt`. The length check rejects degenerate
            // filenames like `hang-.txt` (prefix+suffix only with no
            // timestamp content).
            let prefix = "hang-"
            let suffix = ".txt"
            return name.hasPrefix(prefix)
                && name.hasSuffix(suffix)
                && name.count > prefix.count + suffix.count
        }
        let crashes = enumerate(directory: crashDirectory, kind: .crash) { name in
            // macOS writes `Blackbird-<ts>-<random>.ips` (modern) or
            // `Blackbird-<ts>-<random>.crash` (legacy). The crash directory
            // contains reports for every crashed process on the system, so
            // filter by app prefix to surface only ours. Length check
            // rejects `Blackbird-.ips` and `Blackbird-.crash` (prefix-only
            // filenames that would otherwise render as zero-byte rows).
            let prefix = "Blackbird-"
            return name.hasPrefix(prefix)
                && (name.hasSuffix(".ips") || name.hasSuffix(".crash"))
                && name.count > prefix.count + (name.hasSuffix(".ips") ? 4 : 6)
        }
        reports = (hangs + crashes).sorted { $0.modificationDate > $1.modificationDate }
    }

    private func enumerate(directory: URL, kind: Kind, accept: (String) -> Bool) -> [Report] {
        let fm = FileManager.default
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
        } catch let error as NSError {
            // ENOENT (directory missing) is the normal "no reports yet"
            // state — first-launch users have no Logs/Blackbird/ until the
            // first hang gets written. Stay silent in that case.
            // EPERM/EACCES (TCC denial, parent dir permissions) and other
            // failures are NOT normal — log so a user reporting "the
            // Diagnostics tab is empty but I have hangs" can be diagnosed
            // via `log show --predicate 'subsystem == "dev.conjfrnk.blackbird"
            // && category == "diagnostics"'`.
            if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                log.error("enumerate \(directory.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
        return entries.compactMap { url in
            guard accept(url.lastPathComponent) else { return nil }
            let values: URLResourceValues?
            do {
                values = try url.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                // S2-008: prior code wrapped the call in `try?`, silently
                // dropping a legitimate report whose stat raced
                // contentsOfDirectory (transient EBUSY on a slow disk, a
                // TCC re-evaluation, etc.). Users reporting "I hit a hang
                // but Diagnostics is empty" had no breadcrumb. Log at
                // error level so the directory-level + per-file failures
                // both surface in `log stream --predicate 'subsystem ==
                // "dev.conjfrnk.blackbird" && category == "diagnostics"'`.
                log.error(
                    "stat \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — dropping from diagnostics list"
                )
                return nil
            }
            // SECURITY: drop symlinks. Any process running as the user can
            // place `~/Library/Logs/DiagnosticReports/Blackbird-foo.ips` →
            // `/etc/passwd` (or any user-readable file). Without this guard,
            // clicking Email Diagnostics on a planted symlink exfiltrates
            // its target's contents to `conjfrnk@gmail.com` and Copy puts
            // them on the user's pasteboard. The legitimate ReportCrash /
            // MainThreadWatchdog writers always emit regular files, so
            // symlink-named reports are inherently suspicious.
            //
            // Both checks use explicit `== true` / `== false` (not `!= true`)
            // so that a `nil` resource value — which means "stat succeeded
            // but the key wasn't populated", possible on edge filesystems —
            // is treated as suspicious-by-default and dropped.
            guard values?.isRegularFile == true, values?.isSymbolicLink == false else {
                return nil
            }
            let mtime = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            return Report(kind: kind, url: url, modificationDate: mtime, byteSize: size)
        }
    }
}
