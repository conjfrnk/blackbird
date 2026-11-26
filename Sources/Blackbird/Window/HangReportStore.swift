import Foundation
import os

/// Hang-report files: `~/Library/Logs/Blackbird/hang-<tsMs>-<pid>-<uuid>.txt`.
enum HangReportStore {
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "watchdog")

    #if DEBUG
    /// Test seam: replaces the log directory. Un-set it only after
    /// `MainThreadWatchdog._disarmForTesting()`. Locked because the watchdog thread reads it.
    static let logDirectoryOverride = OSAllocatedUnfairLock<String?>(initialState: nil)
    #endif

    /// Shells out to `/usr/bin/sample`: `Thread.callStackSymbols` only gives the calling thread's stack.
    static func captureHangReport(age: Double, directory dir: String) {
        defer { pruneExcessReports(in: dir, keep: 20) }
        // sample(1) -file truncates, so the name carries a UUID: two hangs in one tick must not collide.
        let now = Date().timeIntervalSince1970
        let tsMs = Int64(now * 1000.0)
        let unique = String(UUID().uuidString.prefix(8))
        let pid = getpid()
        let file = "\(dir)/hang-\(tsMs)-\(pid)-\(unique).txt"
        // sample(1) writes incrementally over its 2 s window; capture to `.partial` and rename so a
        // force-quit mid-capture never leaves a truncated `hang-*.txt`.
        let partialFile = "\(file).partial"
        logger.warning("main-thread hang \(age, format: .fixed(precision: 2), privacy: .public)s — writing \(file, privacy: .public)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        proc.arguments = ["\(pid)", "2", "-file", partialFile]
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try proc.run()
            proc.waitUntilExit()
            // `moveItem`, not `replaceItem`: the destination is fresh, so a collision must fail.
            let fm = FileManager.default
            do {
                try fm.moveItem(atPath: partialFile, toPath: file)
                logger.warning("hang report ready: \(file, privacy: .public)")
            } catch {
                logger.error(
                    "hang report rename \(partialFile, privacy: .public) → \(file, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                try? fm.removeItem(atPath: partialFile)
            }
        } catch {
            logger.error("sample(1) invocation failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(atPath: partialFile)
        }
    }

    /// Reaps orphan `hang-*.txt.partial` files. `olderThan` keeps an in-flight capture from being reaped.
    static func pruneOrphanPartials(in directory: String, olderThan: TimeInterval = 60) {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: directory)
        } catch let error as NSError {
            if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                logger.error("pruneOrphanPartials enumerate \(directory, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        let now = Date()
        let prefix = "hang-"
        let suffix = ".txt.partial"
        for name in entries {
            guard name.hasPrefix(prefix),
                  name.hasSuffix(suffix),
                  name.count > prefix.count + suffix.count
            else { continue }
            let path = "\(directory)/\(name)"
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try fm.attributesOfItem(atPath: path)
            } catch {
                logger.error("pruneOrphanPartials stat \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let mtime = attrs[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(mtime) <= olderThan {
                continue
            }
            do {
                try fm.removeItem(atPath: path)
                logger.log("pruned orphan \(name, privacy: .public)")
            } catch {
                logger.error("pruneOrphanPartials remove \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func pruneOrphanPartials() {
        pruneOrphanPartials(in: logDirectory(), olderThan: 60)
    }

    static func pruneExcessReports(in directory: String, keep: Int) {
        guard keep >= 0 else { return }
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: directory)
        } catch let error as NSError {
            if error.domain != NSCocoaErrorDomain || error.code != NSFileReadNoSuchFileError {
                logger.error("pruneExcessReports enumerate \(directory, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        var dated: [(name: String, mtime: Date)] = []
        for name in entries where name.hasPrefix("hang-") && name.hasSuffix(".txt") {
            let path = "\(directory)/\(name)"
            let attrs: [FileAttributeKey: Any]
            do {
                attrs = try fm.attributesOfItem(atPath: path)
            } catch {
                logger.error("pruneExcessReports stat \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            guard let mtime = attrs[.modificationDate] as? Date else { continue }
            dated.append((name, mtime))
        }
        guard dated.count > keep else { return }
        dated.sort { $0.mtime != $1.mtime ? $0.mtime > $1.mtime : $0.name > $1.name }
        for victim in dated.dropFirst(keep) {
            let path = "\(directory)/\(victim.name)"
            do {
                try fm.removeItem(atPath: path)
                logger.log("pruned excess hang report \(victim.name, privacy: .public)")
            } catch {
                logger.error("pruneExcessReports remove \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func pruneExcessReports(keep: Int) {
        pruneExcessReports(in: logDirectory(), keep: keep)
    }

    static func logDirectory() -> String {
        let fm = FileManager.default
        let libraryLogs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Blackbird", isDirectory: true)
        #if DEBUG
        let logs = logDirectoryOverride.withLock { $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? libraryLogs
        #else
        let logs = libraryLogs
        #endif
        if let dir = logs {
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                return dir.path
            } catch {
                logger.error("could not create \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return "/tmp"
    }
}
