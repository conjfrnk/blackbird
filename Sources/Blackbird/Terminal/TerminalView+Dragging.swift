import AppKit

/// File drag-and-drop onto the terminal. Drops N file URLs and pastes the
/// absolute paths, each single-quoted and space-separated, into the
/// session — matching Terminal.app and iTerm2 ergonomics (you can drag a
/// PNG from Finder onto `open ` at the prompt and get `open '/path/to/foo.png'`).
///
/// The `NSDraggingDestination` overrides live on the main class so they
/// sit next to the `isDropTargeted` stored state they mutate. The pure
/// formatters (`shellQuote`, `joinedDroppedPaths`) stay in the extension
/// so they can be unit-tested without constructing a drag fake.
extension TerminalView {
    /// Wrap a file path in single quotes using the POSIX `'\''` recipe to
    /// escape any embedded single quote. Single-quoted strings in sh/zsh
    /// suppress *all* metacharacter interpretation (spaces, `$`, backticks,
    /// newlines, globs), so this is safe against arbitrary filesystem
    /// paths including ones that contain quotes.
    ///
    /// Exposed as `static` + `internal` so the unit test can exercise the
    /// pure transform without constructing an NSDraggingInfo fake.
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Join N dropped file paths into a single space-separated,
    /// shell-quoted string. Matches Terminal.app / iTerm2 behaviour: no
    /// trailing slash on directories, no trailing newline, no per-file
    /// prompt. The caller feeds the result through `pasteText(_:)` so the
    /// active shell sees a normal paste event (bracketed when the program
    /// has opted in, raw otherwise).
    static func joinedDroppedPaths(_ paths: [String]) -> String {
        paths.map(shellQuote).joined(separator: " ")
    }

    /// Cheap check used by `draggingEntered`/`draggingUpdated` so we don't
    /// light up the accent ring for a drag whose payload we'd reject anyway.
    func draggingPasteboardHasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] =
            [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                       options: options)
    }
}
