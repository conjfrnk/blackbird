import Foundation
import os

/// The hang-report file store, split out of `MainThreadWatchdog` (REFACTOR.md
/// Area 5). Shells `/usr/bin/sample` against our own PID into
/// `~/Library/Logs/Blackbird/hang-<tsMs>-<pid>-<uuid>.txt`, applies the S5-004
/// atomic `.partial`→`.txt` rename (a force-quit mid-capture leaves an ignored
/// `.partial`, never a truncated visible trace), and reaps orphan partials at
/// startup. The single filename grammar lives here. (`DiagnosticReportStore`'s
/// `hang-*.txt` filter is the consumer.)
enum HangReportStore {
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "watchdog")

    /// Write a brief hang report to `~/Library/Logs/Blackbird/hang-<wall-time>.txt`.
    /// Shells out to `/usr/bin/sample` with our own PID — that's the
    /// cleanest way to get a symbolicated trace of every thread from
    /// inside the same process; `Thread.callStackSymbols` only gives us
    /// the CALLING thread's stack (i.e., the watchdog thread's), which
    /// isn't what we want.
    ///
    /// `~/Library/Logs/Blackbird/` over `/tmp`: matches Apple's
    /// convention (Console.app reads this location automatically),
    /// survives reboots so post-hoc investigation works, and doesn't
    /// race with `/tmp` cleaners on very long sessions.
    static func captureHangReport(age: Double) {
        // Audit fix-#21 (2026-05-11): the previous filename used 1-second
        // granularity (`Int(timeIntervalSince1970)`). Two hangs that recover
        // and re-stall within the same wall-clock second produce identical
        // paths; sample(1) -file opens with truncate semantics, silently
        // clobbering the first trace. Append a per-process UUID component
        // so each capture is unique even on collision and the first trace
        // survives to disk for post-hoc investigation.
        let now = Date().timeIntervalSince1970
        let tsMs = Int64(now * 1000.0)
        let unique = String(UUID().uuidString.prefix(8))
        let pid = getpid()
        let dir = logDirectory()
        let file = "\(dir)/hang-\(tsMs)-\(pid)-\(unique).txt"
        // S5-004: sample(1) -file opens with O_TRUNC and writes
        // incrementally over the 2 s window. If Blackbird is force-
        // quit during that window (the typical user response to a
        // visible beachball) the final-name file would be left half-
        // written and surface in Settings → Diagnostics with no
        // incomplete marker. Write to a `.partial` sibling first;
        // only `FileManager.replaceItem`-rename to the final path
        // after waitUntilExit returns cleanly. A mid-capture crash
        // leaves the `.partial` (which DiagnosticReportStore's
        // `hang-*.txt` filter ignores) instead of polluting the
        // visible report list with a truncated trace.
        let partialFile = "\(file).partial"
        logger.warning("main-thread hang \(age, format: .fixed(precision: 2), privacy: .public)s — writing \(file, privacy: .public)")

        // 2 seconds of sampling at default granularity — enough to catch
        // the hot frame on main while not stretching the capture window past
        // the hang itself.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        proc.arguments = ["\(pid)", "2", "-file", partialFile]
        // Sample's own stdout/stderr is noise; redirect to /dev/null so the
        // unified log only sees the watchdog's own line.
        proc.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        proc.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do {
            try proc.run()
            proc.waitUntilExit()
            // Promote the partial-named file to its final name. Using
            // `moveItem` (not `replaceItem`) because the destination
            // path is fresh per-capture (timestamp + UUID + pid in the
            // name) — no existing file to replace, so we want a hard
            // failure if something raced our path.
            let fm = FileManager.default
            do {
                try fm.moveItem(atPath: partialFile, toPath: file)
                logger.warning("hang report ready: \(file, privacy: .public)")
            } catch {
                logger.error(
                    "hang report rename \(partialFile, privacy: .public) → \(file, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                // Best-effort cleanup of the partial so the user
                // doesn't accumulate orphan `.partial` files. If this
                // also fails, the next captureHangReport invocation
                // is independent (fresh timestamp+UUID); the orphan
                // is invisible to the Settings → Diagnostics filter.
                try? fm.removeItem(atPath: partialFile)
            }
        } catch {
            logger.error("sample(1) invocation failed: \(error.localizedDescription, privacy: .public)")
            // Sample never ran; if -file opened anyway with truncate,
            // remove the empty placeholder to keep the directory clean.
            try? FileManager.default.removeItem(atPath: partialFile)
        }
    }

    /// Audit S4-003 (2026-05-17): reap orphan `hang-*.txt.partial`
    /// siblings left over from a prior session's force-quit during
    /// `captureHangReport`'s 2 s sample(1) window.
    ///
    /// The S5-004 atomic-rename pattern protects Settings → Diagnostics
    /// from surfacing a truncated trace, but the matching
    /// `DiagnosticReportStore` filter requires the `.txt` suffix — a
    /// `.partial` orphan is invisible to the user, never garbage-
    /// collected, and accumulates silently across force-quit cycles.
    /// Run at app startup; any partial older than `olderThan` is
    /// reaped. The safety threshold keeps a concurrent in-flight
    /// capture (vanishingly unlikely at launch, but cheap insurance)
    /// from being reaped from under itself.
    ///
    /// Filename gate is the exact shape `captureHangReport` writes
    /// (`hang-<tsMs>-<pid>-<uuid>.txt.partial`); arbitrary user-placed
    /// `*.partial` files and other tools' `*.txt.partial` swap files
    /// are out of scope.
    static func pruneOrphanPartials(in directory: String, olderThan: TimeInterval = 60) {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: directory)
        } catch let error as NSError {
            // ENOENT (directory missing) is the normal first-launch state.
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
                // Younger than safety threshold — could be a live capture.
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

    /// No-arg variant: prune `~/Library/Logs/Blackbird/`. Call at app
    /// startup from `App.applicationDidFinishLaunching`.
    static func pruneOrphanPartials() {
        pruneOrphanPartials(in: logDirectory(), olderThan: 60)
    }

    /// Return (and create on demand) `~/Library/Logs/Blackbird/`. Falls
    /// back to `/tmp` only if the real directory can't be created — a
    /// hang report in `/tmp` is still better than dropping the sample
    /// on the floor.
    private static func logDirectory() -> String {
        let fm = FileManager.default
        if let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let dir = lib.appendingPathComponent("Logs/Blackbird", isDirectory: true)
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
