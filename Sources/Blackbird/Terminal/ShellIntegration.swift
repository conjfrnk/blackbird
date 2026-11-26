import Foundation
import os

/// Shell-integration injection by env-var redirection only; user rc files are never edited.
/// bash is not injected: login bash ignores `--rcfile`.
enum ShellIntegration {
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    private static let zdotdirComponent = "zdotdir"

    /// nil disables injection; never block a spawn on integration. Materialized outside the bundle
    /// because resources copy flat, while `ZDOTDIR` needs a literal `.zshenv` and fish a `fish/vendor_conf.d/` tree.
    static let materializedRoot: URL? = {
        guard let (zshenv, fishConf) = bundleTemplates() else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/blackbird/shell", isDirectory: true)
        return materialize(into: root, zshenvTemplate: zshenv, fishTemplate: fishConf)
    }()

    private static func bundleTemplates() -> (zshenv: URL, fish: URL)? {
        guard
            let zshenv = Bundle.main.url(forResource: "zshenv-bootstrap", withExtension: "zsh"),
            let fishConf = Bundle.main.url(forResource: "fish-vendor-conf", withExtension: "fish")
        else {
            logger.error("ShellIntegration: bundled bootstrap templates missing — auto-injection disabled")
            return nil
        }
        return (zshenv, fishConf)
    }

    /// Re-stats the zsh bootstrap on every spawn: with a ZDOTDIR whose `.zshenv` is gone,
    /// zsh resolves all startup files against the dead directory and drops the user's config.
    static func currentRoot() -> URL? {
        guard let root = materializedRoot else { return nil }
        guard let (zshenv, fishConf) = bundleTemplates() else { return nil }
        return revalidatedRoot(root, zshenvTemplate: zshenv, fishTemplate: fishConf)
    }

    static func revalidatedRoot(_ root: URL, zshenvTemplate: URL, fishTemplate: URL) -> URL? {
        let zshenv = root
            .appendingPathComponent(zdotdirComponent, isDirectory: true)
            .appendingPathComponent(".zshenv")
        if FileManager.default.fileExists(atPath: zshenv.path) {
            return root
        }
        logger.error("ShellIntegration: bootstrap tree missing at spawn (deleted mid-session?) — re-materializing")
        return materialize(into: root, zshenvTemplate: zshenvTemplate, fishTemplate: fishTemplate)
    }

    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = materializedRoot
        }
    }

    static func materialize(into root: URL, zshenvTemplate: URL, fishTemplate: URL) -> URL? {
        let fm = FileManager.default
        let zdotdir = root.appendingPathComponent(zdotdirComponent, isDirectory: true)
        let vendorDir = root.appendingPathComponent("fish/vendor_conf.d", isDirectory: true)
        do {
            try fm.createDirectory(at: zdotdir, withIntermediateDirectories: true)
            try fm.createDirectory(at: vendorDir, withIntermediateDirectories: true)
            let zshenvData = try Data(contentsOf: zshenvTemplate)
            let fishData = try Data(contentsOf: fishTemplate)
            // Always overwrite, with no read-compare fast path: a planted file must not survive.
            try zshenvData.write(to: zdotdir.appendingPathComponent(".zshenv"), options: .atomic)
            try fishData.write(to: vendorDir.appendingPathComponent("blackbird.fish"), options: .atomic)
            return root
        } catch {
            logger.error("ShellIntegration.materialize failed: \(String(describing: error), privacy: .public) — auto-injection disabled")
            return nil
        }
    }

    /// The `BB_*` keys returned here survive only because `PTY`'s child setup scrubs
    /// BB_-namespaced parent env before it applies overrides; keep that order.
    static func envOverrides(
        shellPath: String,
        integrationDir: String?,
        materializedRoot: URL?,
        parentEnv: [String: String],
        enabled: Bool
    ) -> [String: String] {
        guard enabled, let dir = integrationDir, let root = materializedRoot else {
            return [:]
        }
        switch (shellPath as NSString).lastPathComponent {
        case "zsh":
            var env = [
                "ZDOTDIR": root.appendingPathComponent(zdotdirComponent).path,
                "BB_SHELL_INTEGRATION_DIR": dir,
            ]
            // Key presence, not non-empty: the bootstrap's restore logic interprets an empty ZDOTDIR.
            if let orig = parentEnv["ZDOTDIR"] {
                env["BB_ORIG_ZDOTDIR"] = orig
            }
            return env
        case "fish":
            // An empty XDG_DATA_DIRS means "use the default" (XDG spec); a bare value would hide fish's
            // stock vendor dirs. The entry is inherited by children, so a nested spawn must not prepend it again.
            let parentXDG = parentEnv["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            let xdg: String
            if let parentXDG, parentXDG.split(separator: ":").contains(Substring(root.path)) {
                xdg = parentXDG
            } else {
                xdg = root.path + ":" + (parentXDG ?? "/usr/local/share:/usr/share")
            }
            return [
                "XDG_DATA_DIRS": xdg,
                "BB_SHELL_INTEGRATION_DIR": dir,
            ]
        default:
            return [:]
        }
    }
}
