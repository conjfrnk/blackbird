import Foundation

/// Which program a new tab runs.
///
/// Through v0.8.0 this was `$SHELL` or `/bin/zsh`. The login shell of record
/// (`getpwuid().pw_shell`, what `dscl` / System Settings › Users set) was never
/// consulted, so launching Blackbird from another terminal, via `open -a`
/// from a bash session, or nested inside Blackbird with a different `SHELL`
/// exported changed which shell every tab ran — and there was no way to pick
/// a custom shell at all.
///
/// Resolution order, first executable wins:
///   1. the `bb.shellPath` preference (empty = "login shell");
///   2. the account's login shell (`pw_shell`);
///   3. `$SHELL` from the parent environment;
///   4. `/bin/zsh`.
///
/// Pure: the executability probe is injected so the order is unit-testable.
enum ShellResolver {
    static let lastResort = "/bin/zsh"

    struct Resolution: Equatable {
        let path: String
        /// True when the preference named a program that could not be run
        /// and resolution fell through to a lower rung. The caller surfaces
        /// this once so a typo in Settings is not a silent downgrade.
        let preferenceRejected: Bool
    }

    static func resolve(
        preference: String?,
        loginShell: String?,
        environmentShell: String?,
        isExecutable: (String) -> Bool
    ) -> Resolution {
        var preferenceRejected = false
        if let pref = preference?.trimmingCharacters(in: .whitespacesAndNewlines), !pref.isEmpty {
            if pref.hasPrefix("/"), isExecutable(pref) {
                return Resolution(path: pref, preferenceRejected: false)
            }
            preferenceRejected = true
        }
        for candidate in [loginShell, environmentShell] {
            if let c = candidate, c.hasPrefix("/"), isExecutable(c) {
                return Resolution(path: c, preferenceRejected: preferenceRejected)
            }
        }
        return Resolution(path: lastResort, preferenceRejected: preferenceRejected)
    }

    /// `access(path, X_OK)` on a regular file.
    static func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return false
        }
        return access(path, X_OK) == 0
    }

    /// The current account's login shell from the passwd database.
    static func loginShellFromPasswd() -> String? {
        guard let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell else { return nil }
        let s = String(cString: shell)
        return s.isEmpty ? nil : s
    }
}
