import Foundation

/// Test-only PTY recorder for the IME tests — split out of
/// `TerminalView+IME.swift` so the `NSTextInputClient` conformance there
/// isn't bundled with an unrelated test double (REFACTOR.md Area 3).
#if DEBUG
/// Records bytes that would have been written to a real PTY. Swapped in via
/// `TerminalView.ptyRecorderForTests` so the IME tests can assert exactly
/// which commits reach the shell without spinning up a forkpty. Declared
/// in the production target (gated on DEBUG) so `TerminalView`'s stored
/// property type is resolvable from the test bundle via `@testable import
/// Blackbird`. Internal access is sufficient — the test module pulls it
/// in through `@testable`, and nothing ships this symbol in release.
final class RecordingPTY {
    var sent = Data()
    init() {}
}
#endif
