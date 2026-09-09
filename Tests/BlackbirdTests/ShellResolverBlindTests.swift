import XCTest
import Foundation
@testable import Blackbird

/// Blind behaviour tests for `ShellResolver` — picks the shell binary a new
/// session execs. Written from the spec, not the implementation.
///
/// Resolution order:
///   1. A non-empty (after trimming whitespace) preference that starts
///      with "/" AND is executable → wins, `preferenceRejected == false`.
///   2. Otherwise, if a (non-empty) preference was given, whatever is
///      returned carries `preferenceRejected == true`.
///   3. Login shell (from passwd) if absolute + executable.
///   4. `$SHELL` if absolute + executable.
///   5. `/bin/zsh` as the last resort.
///
/// Memory + time pre-flight: the `resolve` tests are pure string logic with
/// an injected `isExecutable` — < 16 KB, < 1 ms each. `isExecutableFile`
/// stats up to one real path per case; `loginShellFromPasswd` reads the
/// current account's passwd entry. Both < 10 ms, no subprocess, no PTY.
final class ShellResolverBlindTests: XCTestCase {

    private typealias Resolution = ShellResolver.Resolution

    /// Executable set for most cases: bash, zsh, fish are "real"; anything
    /// else is not.
    private let exec: (String) -> Bool = { ["/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish"].contains($0) }

    // MARK: - Constants

    func testLastResortIsBinZsh() {
        XCTAssertEqual(ShellResolver.lastResort, "/bin/zsh")
    }

    // MARK: - Preference wins

    func testExecutableAbsolutePreferenceWins() {
        let r = ShellResolver.resolve(
            preference: "/opt/homebrew/bin/fish", loginShell: "/bin/zsh",
            environmentShell: "/bin/bash", isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/opt/homebrew/bin/fish", preferenceRejected: false))
    }

    func testPreferenceIsTrimmedBeforeUse() {
        let r = ShellResolver.resolve(
            preference: "  /bin/bash \n", loginShell: "/bin/zsh",
            environmentShell: nil, isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: false),
                       "surrounding whitespace in the preference must be trimmed, not treated as part of the path")
    }

    // MARK: - Preference rejected

    func testRelativePreferenceIsRejectedEvenIfExecutableSaysYes() {
        let r = ShellResolver.resolve(
            preference: "zsh", loginShell: "/bin/bash",
            environmentShell: nil, isExecutable: { _ in true })
        XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: true),
                       "a non-absolute preference is never trusted, regardless of isExecutable")
    }

    func testNonExecutablePreferenceIsRejectedAndFallsToLoginShell() {
        let r = ShellResolver.resolve(
            preference: "/usr/local/bin/nushell", loginShell: "/bin/zsh",
            environmentShell: "/bin/bash", isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/zsh", preferenceRejected: true))
    }

    func testRejectedPreferenceFallsThroughToEnvironmentShell() {
        let r = ShellResolver.resolve(
            preference: "/nope", loginShell: "/also/nope",
            environmentShell: "/bin/bash", isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: true))
    }

    func testRejectedPreferenceFallsThroughToLastResort() {
        let r = ShellResolver.resolve(
            preference: "/nope", loginShell: nil,
            environmentShell: nil, isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/zsh", preferenceRejected: true))
    }

    func testRejectedPreferenceStillFlagsWhenLastResortIsAlsoNotExecutable() {
        // Even if the executable oracle denies everything, the resolver must
        // still return /bin/zsh (there is nothing better) with the rejection
        // flag set so the UI can tell the user their preference was ignored.
        let r = ShellResolver.resolve(
            preference: "/nope", loginShell: "/bin/zsh",
            environmentShell: "/bin/bash", isExecutable: { _ in false })
        XCTAssertEqual(r, Resolution(path: "/bin/zsh", preferenceRejected: true))
    }

    // MARK: - No preference: login shell, $SHELL, last resort

    func testNilPreferenceUsesLoginShell() {
        let r = ShellResolver.resolve(
            preference: nil, loginShell: "/bin/bash",
            environmentShell: "/bin/zsh", isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: false))
    }

    func testEmptyPreferenceIsNotAPreference() {
        for empty in ["", "   ", "\n\t"] {
            let r = ShellResolver.resolve(
                preference: empty, loginShell: "/bin/bash",
                environmentShell: nil, isExecutable: exec)
            XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: false),
                           "preference \(empty.debugDescription) is empty after trimming and must not be flagged as rejected")
        }
    }

    func testRelativeLoginShellIsSkipped() {
        let r = ShellResolver.resolve(
            preference: nil, loginShell: "bash",
            environmentShell: "/bin/bash", isExecutable: { _ in true })
        XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: false),
                       "a login shell that isn't an absolute path must be skipped")
    }

    func testNonExecutableLoginShellFallsToEnvironmentShell() {
        let r = ShellResolver.resolve(
            preference: nil, loginShell: "/usr/local/bin/gone",
            environmentShell: "/bin/bash", isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/bash", preferenceRejected: false))
    }

    func testRelativeEnvironmentShellIsSkipped() {
        let r = ShellResolver.resolve(
            preference: nil, loginShell: nil,
            environmentShell: "fish", isExecutable: { _ in true })
        XCTAssertEqual(r, Resolution(path: "/bin/zsh", preferenceRejected: false))
    }

    func testEverythingMissingYieldsLastResort() {
        let r = ShellResolver.resolve(
            preference: nil, loginShell: nil,
            environmentShell: nil, isExecutable: exec)
        XCTAssertEqual(r, Resolution(path: "/bin/zsh", preferenceRejected: false))
    }

    func testEverythingNonExecutableYieldsLastResortUnflagged() {
        let r = ShellResolver.resolve(
            preference: nil, loginShell: "/x", environmentShell: "/y",
            isExecutable: { _ in false })
        XCTAssertEqual(r, Resolution(path: "/bin/zsh", preferenceRejected: false))
    }

    // MARK: - isExecutableFile (real filesystem)

    func testIsExecutableFileTrueForBinZsh() {
        XCTAssertTrue(ShellResolver.isExecutableFile("/bin/zsh"))
    }

    func testIsExecutableFileFalseForNonExecutableRegularFile() {
        XCTAssertFalse(ShellResolver.isExecutableFile("/etc/hosts"))
    }

    func testIsExecutableFileFalseForDirectory() {
        XCTAssertFalse(ShellResolver.isExecutableFile("/bin"),
                       "a directory has the x bit but is not an executable FILE")
    }

    func testIsExecutableFileFalseForMissingPath() {
        XCTAssertFalse(ShellResolver.isExecutableFile("/definitely/not/here/\(UUID().uuidString)"))
    }

    // MARK: - loginShellFromPasswd (real account)

    func testLoginShellFromPasswdIsAbsolute() throws {
        let shell = try XCTUnwrap(ShellResolver.loginShellFromPasswd(),
                                  "a normal account always has a passwd shell")
        XCTAssertTrue(shell.hasPrefix("/"), "passwd shell must be absolute; got \(shell)")
    }
}
