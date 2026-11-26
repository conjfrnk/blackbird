import Foundation
import os
import SwiftUI

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

        var id: URL { url }
    }

    static let defaultHangDirectoryName = "Library/Logs/Blackbird"

    static let defaultCrashDirectoryName = "Library/Logs/DiagnosticReports"

    @Published private(set) var reports: [Report] = []

    private let hangDirectory: URL
    private let crashDirectory: URL
    private let log = Logger(subsystem: "dev.conjfrnk.blackbird", category: "diagnostics")

    init(hangDirectory: URL? = nil, crashDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.hangDirectory =
            hangDirectory ?? home.appendingPathComponent(Self.defaultHangDirectoryName)
        self.crashDirectory =
            crashDirectory ?? home.appendingPathComponent(Self.defaultCrashDirectoryName)
    }

    func reload() {
        // The crash directory holds reports for every crashed process; the app prefix filters to ours.
        let hangs = enumerate(directory: hangDirectory, kind: .hang) {
            Self.acceptsReport($0, prefix: "hang-", suffixes: [".txt"])
        }
        let crashes = enumerate(directory: crashDirectory, kind: .crash) {
            Self.acceptsReport($0, prefix: "Blackbird-", suffixes: [".ips", ".crash"])
        }
        reports = (hangs + crashes).sorted { $0.modificationDate > $1.modificationDate }
    }

    /// Requires a non-empty body between the prefix and the suffix.
    private static func acceptsReport(_ name: String, prefix: String, suffixes: [String]) -> Bool {
        guard name.hasPrefix(prefix),
              let suffix = suffixes.first(where: { name.hasSuffix($0) }) else { return false }
        return name.count > prefix.count + suffix.count
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
            // A missing directory is the normal "no reports yet" state; anything else is logged.
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
                log.error(
                    "stat \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public) — dropping from diagnostics list"
                )
                return nil
            }
            // SECURITY: drop symlinks. A planted report symlink would send its target's contents to Copy / Email.
            // `== true` / `== false` (not `!= true`) so a nil resource value is dropped too.
            guard values?.isRegularFile == true, values?.isSymbolicLink == false else {
                return nil
            }
            let mtime = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            return Report(kind: kind, url: url, modificationDate: mtime, byteSize: size)
        }
    }
}
