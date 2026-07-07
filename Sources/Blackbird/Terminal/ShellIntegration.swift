import Foundation
import os

/// Automatic shell-integration provisioning (issue #23) — sibling of
/// `KittyTerminfo`, and the same shape: a one-shot filesystem
/// materialization resolved once per process, consulted at spawn time.
///
/// Blackbird never edits user rc files. Injection is pure env-var
/// redirection: zsh gets `ZDOTDIR` pointed at a materialized bootstrap
/// `.zshenv` (which restores the user's real ZDOTDIR, chains their
/// `.zshenv`, and defers loading osc133 + the ssh terminfo wrapper to
/// the first precmd), fish gets an `XDG_DATA_DIRS` entry whose
/// `fish/vendor_conf.d/blackbird.fish` does the same via a one-shot
/// `fish_prompt` event. bash is deliberately NOT injected (login bash
/// ignores `--rcfile`; see KNOWN_ISSUES "Shell integration
/// auto-injection") — bash users source the bundled files manually.
///
/// Why materialize to `~/.local/share/blackbird/shell` instead of
/// pointing into the app bundle: bundle resources copy FLAT (no
/// subdirectories, and dotfiles are untrustworthy through the resource
/// copy phase), but `ZDOTDIR` requires a literal `.zshenv` inside a
/// directory and fish requires a `fish/vendor_conf.d/` tree. The
/// materialized copies are rewritten from the bundled templates on
/// every launch — an authoritative overwrite that wipes any tampering,
/// exactly like `KittyTerminfo`'s `~/.terminfo` install (audit L1
/// rationale applies unchanged).
enum ShellIntegration {
    /// Shares `PTY`'s `os.Logger` subsystem/category — shell-integration
    /// diagnostics land under the same `pty` category as the terminfo
    /// install they parallel.
    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "pty")

    /// The one directory-name contract shared by `materialize` (which
    /// writes `<root>/zdotdir/.zshenv`) and `envOverrides` (which points
    /// the child's `ZDOTDIR` at it). Single constant so a rename can't
    /// silently break one side.
    private static let zdotdirComponent = "zdotdir"

    /// Where the bootstrap files live for this process, or nil when
    /// materialization failed (missing bundle templates, unwritable
    /// home). nil disables injection — the shell spawns exactly as it
    /// did before this feature; never block a spawn on integration.
    /// Computed once per process (`swift_once`), same discipline as
    /// `KittyTerminfo.available`.
    static let materializedRoot: URL? = {
        guard
            let zshenv = Bundle.main.url(forResource: "zshenv-bootstrap", withExtension: "zsh"),
            let fishConf = Bundle.main.url(forResource: "fish-vendor-conf", withExtension: "fish")
        else {
            logger.error("ShellIntegration: bundled bootstrap templates missing — auto-injection disabled")
            return nil
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/blackbird/shell", isDirectory: true)
        return materialize(into: root, zshenvTemplate: zshenv, fishTemplate: fishConf)
    }()

    /// Kick the one-shot materialization onto a background thread so the
    /// first `PTY.spawn` on the cold-launch critical path never pays for
    /// the file writes. Same mechanism and safety argument as
    /// `KittyTerminfo.prewarm()`: `swift_once` means a racing first
    /// spawn blocks only for the remaining work, and the resolved value
    /// is identical either way.
    static func prewarm() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = materializedRoot
        }
    }

    /// Write the two bootstrap files under `root`, creating intermediate
    /// directories. Authoritative overwrite: pre-existing (possibly
    /// tampered) destinations are replaced with the template contents on
    /// every call. Returns `root` on success, nil on any failure.
    /// Surfaced with explicit template URLs so tests can drive it
    /// against temp roots and their own template files.
    static func materialize(into root: URL, zshenvTemplate: URL, fishTemplate: URL) -> URL? {
        let fm = FileManager.default
        let zdotdir = root.appendingPathComponent(zdotdirComponent, isDirectory: true)
        let vendorDir = root.appendingPathComponent("fish/vendor_conf.d", isDirectory: true)
        do {
            try fm.createDirectory(at: zdotdir, withIntermediateDirectories: true)
            try fm.createDirectory(at: vendorDir, withIntermediateDirectories: true)
            let zshenvData = try Data(contentsOf: zshenvTemplate)
            let fishData = try Data(contentsOf: fishTemplate)
            // `Data.write` replaces existing content atomically — that IS
            // the authoritative overwrite; no read-compare fast path, so a
            // planted file can't survive by matching length or mtime.
            try zshenvData.write(to: zdotdir.appendingPathComponent(".zshenv"), options: .atomic)
            try fishData.write(to: vendorDir.appendingPathComponent("blackbird.fish"), options: .atomic)
            return root
        } catch {
            logger.error("ShellIntegration.materialize failed: \(String(describing: error), privacy: .public) — auto-injection disabled")
            return nil
        }
    }

    /// Pure spawn-env computation. Returns exactly the extra environment
    /// the child needs for its shell — or `[:]` whenever injection can't
    /// or shouldn't happen (feature toggled off, unknown shell, missing
    /// integration dir / materialized root). Dispatch is on the LAST
    /// path component of `shellPath` (`/bin/zsh` → `zsh`), never a
    /// substring match.
    ///
    /// Ordering dependency: the `BB_*` keys returned here survive only
    /// because `PTY`'s child setup scrubs BB_-namespaced PARENT env
    /// (audit fix-#13) BEFORE applying overrides. In a nested-Blackbird
    /// spawn (Blackbird inside Blackbird — a daily-real scenario) a stale
    /// parent `BB_SHELL_INTEGRATION_DIR` is scrubbed and then freshly
    /// re-set from this dictionary. If PTY's scrub ever moves after the
    /// override application, these keys silently die — keep that order.
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
            // Key-presence, not non-empty: an (unusual) empty ZDOTDIR in
            // the parent is preserved as an empty BB_ORIG_ZDOTDIR so the
            // bootstrap's restore logic owns the interpretation.
            if let orig = parentEnv["ZDOTDIR"] {
                env["BB_ORIG_ZDOTDIR"] = orig
            }
            return env
        case "fish":
            // Prepend our data dir; when the parent had no XDG_DATA_DIRS —
            // or an EMPTY one, which the XDG spec says means "use the
            // default" — the default tail keeps fish's stock vendor dirs
            // reachable (a bare value would HIDE them).
            let parentXDG = parentEnv["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 }
            let tail = parentXDG ?? "/usr/local/share:/usr/share"
            return [
                "XDG_DATA_DIRS": root.path + ":" + tail,
                "BB_SHELL_INTEGRATION_DIR": dir,
            ]
        default:
            // bash: deliberate gap (login bash ignores --rcfile) — manual
            // sourcing documented in the bundled files + KNOWN_ISSUES.
            return [:]
        }
    }
}
