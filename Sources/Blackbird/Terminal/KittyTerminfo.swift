import Foundation
import os

/// Installs the bundled kitty terminfo under `~/.terminfo` and decides whether the child gets `TERM=xterm-kitty`.
enum KittyTerminfo {
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    /// Once-per-process latch (`swift_once`): it does not track later changes to `~/.terminfo`.
    static let available: Bool = installIfNeeded()

    #if DEBUG
    static var terminfoDirectoryOverrideForTesting: URL?
    #endif

    private static var terminfoDirectory: URL {
        #if DEBUG
        if let override = terminfoDirectoryOverrideForTesting { return override }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".terminfo", isDirectory: true)
    }

    private static let reinstallLock = NSLock()

    /// Re-stats the entry per spawn: `~/.terminfo` can vanish mid-session and the macOS system
    /// terminfo has no `xterm-kitty` to fall back on. Never upgrades a false `available`.
    static func availableForSpawn() -> Bool {
        guard available else { return false }
        if installedEntryExists() { return true }
        reinstallLock.lock()
        defer { reinstallLock.unlock() }
        if installedEntryExists() { return true }
        logger.error("KittyTerminfo: xterm-kitty entry missing at spawn (deleted mid-session?) — re-installing")
        let healed = installIfNeeded()
        logger.error("KittyTerminfo: mid-session re-install \(healed ? "succeeded" : "failed — falling back to xterm-256color for this spawn", privacy: .public)")
        return healed
    }

    /// macOS ncurses reads only the hex bucket `78/`; a plain `x/xterm-kitty` is invisible to it.
    private static func installedEntryExists() -> Bool {
        FileManager.default.fileExists(
            atPath: terminfoDirectory.appendingPathComponent("78/xterm-kitty").path)
    }

    /// Runs on every launch: `tic` overwriting the target wipes a pre-planted hostile entry.
    private static func installIfNeeded() -> Bool {
        guard
            let src = Bundle.main.url(forResource: "kitty", withExtension: "terminfo"),
            FileManager.default.fileExists(atPath: src.path)
        else {
            return false
        }
        let dst = terminfoDirectory
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tic")
        task.arguments = ["-x", "-o", dst.path, src.path]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        let ticStatus: Int32
        do {
            try task.run()
            task.waitUntilExit()
            ticStatus = task.terminationStatus
        } catch {
            logger.error("KittyTerminfo.installIfNeeded: tic failed to launch: \(String(describing: error), privacy: .public)")
            return false
        }
        return decideAvailability(
            ticExit: ticStatus,
            probe: { infocmpSucceeds(term: "xterm-kitty") }
        )
    }

    /// Resolves `available` off the main thread. A spawn that races the warm-up blocks in
    /// `swift_once` only for the remaining work; `tic` never runs twice.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = available
        }
    }

    static func decideAvailability(
        ticExit: Int32,
        probe: () -> Bool
    ) -> Bool {
        // A failed `tic` must not fall through to the probe: a pre-planted hostile
        // `xterm-kitty` entry would let it succeed.
        if ticExit != 0 {
            logger.error(
                "KittyTerminfo.installIfNeeded: tic exit=\(ticExit, privacy: .public) — falling back to xterm-256color (will not trust pre-existing terminfo)"
            )
            return false
        }
        return probe()
    }

    /// Absolute path: `$PATH` may not be sane this early in app startup.
    private static func infocmpSucceeds(term: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/infocmp")
        task.arguments = [term]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return false
        }
        return task.terminationStatus == 0
    }
}
