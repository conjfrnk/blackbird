import XCTest
import AppKit
import Metal
@testable import Blackbird
@testable import BBCore

/// Blind regression tests for bug MSC-3: the copy, paste, OSC 52 and
/// drop-path scrub chains silently delete U+200D ZERO WIDTH JOINER and
/// U+200C ZERO WIDTH NON-JOINER, corrupting text that legitimately needs
/// them.
///
/// Contract under test (observable, end to end). U+200D and U+200C are
/// *content*, not noise, in three very common kinds of text:
///
///   - Emoji ZWJ sequences. A family emoji is man + ZWJ + woman + ZWJ +
///     girl; a technologist is woman + ZWJ + laptop. Delete the joiners
///     and the user gets three (or two) separate emoji.
///   - Persian (and other Arabic-script) text. "mikhaham" (می‌خواهم) has a
///     ZWNJ between its first and second morpheme; without it the word is
///     spelled differently.
///   - Indic scripts, where ZWJ / ZWNJ after a virama select the half-form
///     or the explicit-virama rendering of a conjunct.
///
/// So whatever the user copies out of the terminal (Cmd-C), pastes into it
/// (Cmd-V), pushes to the clipboard from tmux / vim (OSC 52), or drags in as
/// a file whose NAME contains these scalars, those scalars must arrive
/// intact. A dropped file named with a ZWJ emoji that arrives with the ZWJs
/// removed is a path that does not exist.
///
/// What must NOT change (and is guarded here so the fix cannot "pass" by
/// disabling the scrub): genuinely dangerous invisibles, such as U+202E
/// RIGHT-TO-LEFT OVERRIDE, are still removed from the same payloads.
///
/// Layers exercised:
///   1. `PasteSanitizer.stripBidiOverrides` (the shared byte scrub).
///   2. `TerminalView.copy(_:)` (Cmd-C -> NSPasteboard.general).
///   3. `ClipboardWriter.writeOSC52` (remote-controlled clipboard write).
///   4. `TerminalView.sanitizeDropPath` (drop path scrub).
///   5. `TerminalView.paste(_:)` / `performDropOfPaths(_:)` into a REAL pty
///      whose child is `cat > file`, so the oracle is the exact byte stream
///      a program in the terminal would read.
///
/// Pre-flight cost (project rule): every payload is under 100 bytes. The
/// pty tests each start one `/bin/sh` + `cat`, torn down before the test
/// returns; never two sessions at once, no window, no MainWindowController.
/// The copy tests use one 80x24 BBTerm + one view. Nothing here allocates
/// anything measurable.
///
/// The tests share the system pasteboard with the host, so every test
/// snapshots and restores `NSPasteboard.general`.
final class ZeroWidthJoinerPreservationBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures (explicit scalar escapes so no editor can normalise them)

    /// man + ZWJ + woman + ZWJ + girl.
    private static let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    /// woman + ZWJ + laptop.
    private static let technologist = "\u{1F469}\u{200D}\u{1F4BB}"
    /// Persian "mikhaham": meem yeh ZWNJ khah waw alef heh meem.
    private static let persian = "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645}"
    /// Devanagari KA + virama + ZWJ + SSA (half-form request).
    private static let devanagariZWJ = "\u{0915}\u{094D}\u{200D}\u{0937}"
    /// Devanagari KA + virama + ZWNJ + SSA (explicit-virama request).
    private static let devanagariZWNJ = "\u{0915}\u{094D}\u{200C}\u{0937}"

    private static let rlo = "\u{202E}"

    // MARK: - Pasteboard hygiene (same idiom as PasteboardSourceTypePinTests)

    private var savedItems: [NSPasteboardItem] = []
    private var cleanupDirectories: [URL] = []

    override func setUp() {
        super.setUp()
        let pb = NSPasteboard.general
        savedItems = (pb.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    override func tearDown() {
        let pb = NSPasteboard.general
        pb.clearContents()
        if !savedItems.isEmpty {
            pb.writeObjects(savedItems)
        }
        savedItems = []
        for dir in cleanupDirectories { try? FileManager.default.removeItem(at: dir) }
        cleanupDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    /// "U+0645 U+06CC U+200C ..." so a failing XCTAssertEqual shows exactly
    /// which scalars survived.
    private func scalarList(_ s: String?) -> String {
        guard let s else { return "<nil>" }
        return s.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
    }

    private func scalarList(_ data: Data) -> String {
        scalarList(String(decoding: data, as: UTF8.self))
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func count(of scalar: Unicode.Scalar, in s: String) -> Int {
        s.unicodeScalars.filter { $0 == scalar }.count
    }

    /// Fixtures must really carry the joiners, otherwise every test below
    /// would pass vacuously.
    private func assertFixturesCarryJoiners(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(count(of: "\u{200D}", in: Self.family), 2,
                       "fixture: family emoji must contain exactly two ZWJ", file: file, line: line)
        XCTAssertEqual(count(of: "\u{200D}", in: Self.technologist), 1,
                       "fixture: technologist emoji must contain exactly one ZWJ", file: file, line: line)
        XCTAssertEqual(count(of: "\u{200C}", in: Self.persian), 1,
                       "fixture: Persian word must contain exactly one ZWNJ", file: file, line: line)
        XCTAssertEqual(count(of: "\u{200D}", in: Self.devanagariZWJ), 1,
                       "fixture: Devanagari ZWJ cluster must contain one ZWJ", file: file, line: line)
        XCTAssertEqual(count(of: "\u{200C}", in: Self.devanagariZWNJ), 1,
                       "fixture: Devanagari ZWNJ cluster must contain one ZWNJ", file: file, line: line)
    }

    private func pasteboardString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    // MARK: - 1. Shared byte scrub (paste / copy / OSC 52 / find-replace all use it)

    func test_stripBidiOverrides_keepsZWJInsideFamilyEmoji() {
        assertFixturesCarryJoiners()
        let input = "a" + Self.family + "b"
        let out = PasteSanitizer.stripBidiOverrides(Data(input.utf8))
        XCTAssertEqual(scalarList(out), scalarList(input),
                       "a family emoji (man ZWJ woman ZWJ girl) must pass the scrub unchanged; "
                       + "got \(scalarList(out)) for input \(scalarList(input))")
    }

    func test_stripBidiOverrides_keepsZWJInsideTechnologistEmoji() {
        let input = "a" + Self.technologist + "b"
        let out = PasteSanitizer.stripBidiOverrides(Data(input.utf8))
        XCTAssertEqual(scalarList(out), scalarList(input),
                       "a professional emoji (woman ZWJ laptop) must pass the scrub unchanged; "
                       + "got \(scalarList(out)) for input \(scalarList(input))")
    }

    func test_stripBidiOverrides_keepsZWNJInsidePersianWord() {
        let input = "a " + Self.persian + " b"
        let out = PasteSanitizer.stripBidiOverrides(Data(input.utf8))
        XCTAssertEqual(scalarList(out), scalarList(input),
                       "Persian text with its ZWNJ must pass the scrub unchanged; "
                       + "got \(scalarList(out)) for input \(scalarList(input))")
    }

    func test_stripBidiOverrides_keepsJoinersInsideDevanagariConjuncts() {
        let zwj = "a " + Self.devanagariZWJ + " b"
        let zwnj = "a " + Self.devanagariZWNJ + " b"
        let outZWJ = PasteSanitizer.stripBidiOverrides(Data(zwj.utf8))
        let outZWNJ = PasteSanitizer.stripBidiOverrides(Data(zwnj.utf8))
        XCTAssertEqual(scalarList(outZWJ), scalarList(zwj),
                       "Devanagari KA+virama+ZWJ+SSA must pass the scrub unchanged; got \(scalarList(outZWJ))")
        XCTAssertEqual(scalarList(outZWNJ), scalarList(zwnj),
                       "Devanagari KA+virama+ZWNJ+SSA must pass the scrub unchanged; got \(scalarList(outZWNJ))")
    }

    /// Guard against a "fix" that turns the scrub off: the joiners survive,
    /// but an RLO riding in the same payload must still be removed.
    func test_stripBidiOverrides_stillRemovesRLOAroundPreservedJoiners() {
        let input = "a" + Self.family + Self.rlo + Self.persian + Self.rlo + "b"
        let expected = "a" + Self.family + Self.persian + "b"
        let out = PasteSanitizer.stripBidiOverrides(Data(input.utf8))
        XCTAssertEqual(scalarList(out), scalarList(expected),
                       "RLO (U+202E) must still be stripped while the ZWJ / ZWNJ stay; "
                       + "got \(scalarList(out))")
    }

    // MARK: - 2. Copy (Cmd-C) end to end

    /// Builds a view over a headless 80x24 session that has had `text`
    /// printed at the origin. (`selection` text is read back through the
    /// session, so a bare BBTerm would not do.)
    private func makeCopyRig(printing text: String) throws -> (view: TerminalView, session: TerminalSession) {
        let device = try requireMetalDevice()
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        session.resize(to: .init(cols: 80, rows: 24))
        session.feedBytesForTests(Data(text.utf8))
        let snap = try XCTUnwrap(session.takeSnapshotForTests(), "snapshot() returned nil")
        XCTAssertEqual(snap.cols, 80, "precondition: headless session must be resized to 80 columns")
        view.render(snapshot: snap)
        return (view, session)
    }

    private func trimmedTrailingWhitespace(_ s: String?) -> String? {
        guard var s else { return nil }
        while let last = s.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            s.unicodeScalars.removeLast()
        }
        return s
    }

    /// Select row 0 end to end, make sure the raw selection really carries
    /// the joiners (otherwise this test would be blaming the scrub for a
    /// grid problem), press Cmd-C, and read the general pasteboard.
    private func copyFirstRow(printing text: String) throws -> String? {
        let (view, session) = try makeCopyRig(printing: text)
        defer { withExtendedLifetime(session) {} }
        view.selection = Selection(
            anchor: BufferPoint(line: 0, col: 0),
            cursor: BufferPoint(line: 0, col: 79),
            mode: .character
        )
        let raw = trimmedTrailingWhitespace(view.selectedStringForServices())
        XCTAssertEqual(scalarList(raw), scalarList(text),
                       "precondition: the unscrubbed selection of row 0 must equal what was printed "
                       + "(otherwise the grid, not the clipboard scrub, lost the joiners)")

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("copy-did-not-run", forType: .string)
        view.copy(nil)
        return trimmedTrailingWhitespace(pasteboardString())
    }

    func test_copy_familyEmoji_keepsZWJs() throws {
        assertFixturesCarryJoiners()
        let text = Self.family
        let copied = try copyFirstRow(printing: text)
        XCTAssertEqual(scalarList(copied), scalarList(text),
                       "Cmd-C of a selected family emoji must put man ZWJ woman ZWJ girl on the "
                       + "clipboard; clipboard held \(scalarList(copied))")
    }

    func test_copy_persianWithZWNJ_keepsZWNJ() throws {
        let text = Self.persian
        let copied = try copyFirstRow(printing: text)
        XCTAssertEqual(scalarList(copied), scalarList(text),
                       "Cmd-C of a selected Persian word must keep its ZWNJ; "
                       + "clipboard held \(scalarList(copied))")
    }

    // MARK: - 3. OSC 52 clipboard write

    func test_osc52Write_familyEmoji_keepsZWJs() {
        let payload = "yanked " + Self.family
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("osc52-did-not-run", forType: .string)
        ClipboardWriter.writeOSC52(payload)
        XCTAssertEqual(scalarList(pasteboardString()), scalarList(payload),
                       "an OSC 52 write of a family emoji must reach the clipboard with both ZWJs; "
                       + "clipboard held \(scalarList(pasteboardString()))")
    }

    func test_osc52Write_persianWithZWNJ_keepsZWNJ() {
        let payload = "yanked " + Self.persian
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("osc52-did-not-run", forType: .string)
        ClipboardWriter.writeOSC52(payload)
        XCTAssertEqual(scalarList(pasteboardString()), scalarList(payload),
                       "an OSC 52 write of Persian text must reach the clipboard with its ZWNJ; "
                       + "clipboard held \(scalarList(pasteboardString()))")
    }

    /// Guard: the OSC 52 scrub still removes an RLO while keeping the joiners.
    func test_osc52Write_stillRemovesRLOButKeepsJoiners() {
        let payload = Self.family + Self.rlo + Self.persian
        let expected = Self.family + Self.persian
        ClipboardWriter.writeOSC52(payload)
        XCTAssertEqual(scalarList(pasteboardString()), scalarList(expected),
                       "OSC 52 must still strip RLO yet keep ZWJ / ZWNJ; "
                       + "clipboard held \(scalarList(pasteboardString()))")
    }

    // MARK: - 4. Drop path scrub (pure)

    func test_sanitizeDropPath_keepsZWJsInEmojiFilename() {
        let path = "/tmp/dir/" + Self.family + ".png"
        let out = TerminalView.sanitizeDropPath(path)
        XCTAssertEqual(scalarList(out), scalarList(path),
                       "a path naming a ZWJ-emoji file must round-trip through sanitizeDropPath; "
                       + "got \(scalarList(out))")
    }

    func test_sanitizeDropPath_keepsZWNJInPersianFilename() {
        let path = "/tmp/dir/" + Self.persian + ".txt"
        let out = TerminalView.sanitizeDropPath(path)
        XCTAssertEqual(scalarList(out), scalarList(path),
                       "a path naming a ZWNJ-bearing Persian file must round-trip through sanitizeDropPath; "
                       + "got \(scalarList(out))")
    }

    func test_sanitizeDropPath_stillRemovesRLOButKeepsJoiners() {
        let path = "/tmp/dir/" + Self.family + Self.rlo + Self.persian + ".txt"
        let expected = "/tmp/dir/" + Self.family + Self.persian + ".txt"
        let out = TerminalView.sanitizeDropPath(path)
        XCTAssertEqual(scalarList(out), scalarList(expected),
                       "sanitizeDropPath must still strip RLO yet keep ZWJ / ZWNJ; got \(scalarList(out))")
    }

    // MARK: - 5. Real-pty rig: what does a program in the terminal actually read?

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let received: URL
    }

    private static let sentinel = Array("~~BB-END~~".utf8)
    private static let bracketOpen: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC [ 2 0 0 ~
    private static let bracketClose: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~

    @discardableResult
    private func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            Thread.sleep(forTimeInterval: 0.005)
        }
        return condition()
    }

    /// One real `/bin/sh` that goes raw / no-echo, optionally enables DECSET
    /// 2004, drops a "ready" file, then `exec cat > received.bin`.
    private func makeRig(bracketed: Bool, file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-zwj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let received = dir.appendingPathComponent("received.bin")
        let ready = dir.appendingPathComponent("ready")

        let script = """
        stty raw -echo || exit 3
        if [ "$3" = "1" ]; then printf '\\033[?2004h'; fi
        : > "$2"
        exec cat > "$1"
        """
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", script, "sh", received.path, ready.path, bracketed ? "1" : "0"],
            size: .init(cols: 80, rows: 24)
        )
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240), device: device)
        view.session = session

        let readyInTime = spin(timeout: 15) { FileManager.default.fileExists(atPath: ready.path) }
        if !readyInTime { session.terminate() }
        XCTAssertTrue(readyInTime, "precondition: child never reached its read loop (ready file missing after 15 s)",
                      file: file, line: line)
        guard readyInTime else { throw XCTSkip("rig failed to start; see precondition failure above") }

        let modeSeen = spin(timeout: 15) {
            (view.currentSnapshot?.termMode.contains(.bracketedPaste) ?? false) == bracketed
        }
        XCTAssertTrue(
            modeSeen,
            "precondition: view snapshot bracketedPaste should be \(bracketed); observed "
            + "\(view.currentSnapshot?.termMode.contains(.bracketedPaste) ?? false) after 15 s",
            file: file, line: line
        )
        guard modeSeen else {
            session.terminate()
            throw XCTSkip("rig failed to reach the requested paste mode; see precondition failure above")
        }
        return Rig(view: view, session: session, received: received)
    }

    /// Queues the sentinel behind whatever the test already wrote (the PTY
    /// writer preserves order) and returns every byte the child read before
    /// it. Nil if the sentinel never arrives.
    private func bytesBeforeSentinel(_ rig: Rig, timeout: TimeInterval = 20) -> Data? {
        rig.session.send(Data(Self.sentinel))
        let tail = Data(Self.sentinel)
        var result: Data?
        spin(timeout: timeout) {
            guard let data = try? Data(contentsOf: rig.received), data.count >= tail.count,
                  Data(data.suffix(tail.count)) == tail else { return false }
            result = Data(data.prefix(data.count - tail.count))
            return true
        }
        return result
    }

    private func setPasteboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        XCTAssertEqual(pb.string(forType: .string).map { Array($0.utf8) }, Array(s.utf8),
                       "precondition: the pasteboard must hold the exact payload before Cmd-V")
    }

    func test_paste_familyEmoji_deliversZWJsToTheProgram() throws {
        assertFixturesCarryJoiners()
        let rig = try makeRig(bracketed: false)
        defer { rig.session.terminate() }

        let payload = "x" + Self.family + "y"
        setPasteboard(payload)
        rig.view.paste(nil)

        let got = try XCTUnwrap(bytesBeforeSentinel(rig), "the child never received the sentinel after the paste")
        XCTAssertEqual(scalarList(got), scalarList(payload),
                       "Cmd-V of a family emoji must deliver man ZWJ woman ZWJ girl to the program; "
                       + "child read \(hex([UInt8](got)))")
    }

    func test_paste_persianWithZWNJ_deliversZWNJToTheProgram() throws {
        let rig = try makeRig(bracketed: false)
        defer { rig.session.terminate() }

        let payload = "x " + Self.persian + " y"
        setPasteboard(payload)
        rig.view.paste(nil)

        let got = try XCTUnwrap(bytesBeforeSentinel(rig), "the child never received the sentinel after the paste")
        XCTAssertEqual(scalarList(got), scalarList(payload),
                       "Cmd-V of a Persian word must deliver its ZWNJ to the program; "
                       + "child read \(hex([UInt8](got)))")
    }

    func test_bracketedPaste_familyEmoji_deliversZWJsInsideTheMarkers() throws {
        let rig = try makeRig(bracketed: true)
        defer { rig.session.terminate() }

        let payload = "x" + Self.family + "y"
        setPasteboard(payload)
        rig.view.paste(nil)

        let got = try XCTUnwrap(bytesBeforeSentinel(rig), "the child never received the sentinel after the paste")
        var expected = Data(Self.bracketOpen)
        expected.append(Data(payload.utf8))
        expected.append(contentsOf: Self.bracketClose)
        XCTAssertEqual(hex([UInt8](got)), hex([UInt8](expected)),
                       "a bracketed Cmd-V of a family emoji must arrive as ESC[200~ + payload (both ZWJs) + ESC[201~")
    }

    /// Dragging a file whose NAME contains ZWJs: the program must be handed
    /// a (quoted) path that still names the file.
    func test_drop_fileNamedWithFamilyEmoji_deliversPathThatExists() throws {
        let rig = try makeRig(bracketed: false)
        defer { rig.session.terminate() }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-zwj-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cleanupDirectories.append(dir)
        let fileURL = dir.appendingPathComponent(Self.family + ".txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8)),
                      "precondition: the ZWJ-named file must be creatable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "precondition: the ZWJ-named file must exist at \(scalarList(fileURL.path))")
        XCTAssertFalse(fileURL.path.contains("'"),
                       "precondition: the temp path must not contain a single quote (it would be re-escaped)")

        // Same entry as production: url.path -> sanitizeDropPath -> drop.
        let sanitized = TerminalView.sanitizeDropPath(fileURL.path)
        XCTAssertTrue(rig.view.performDropOfPaths([sanitized]), "the drop must be accepted")

        let got = try XCTUnwrap(bytesBeforeSentinel(rig), "the child never received the sentinel after the drop")
        let text = String(decoding: got, as: UTF8.self)
        XCTAssertEqual(scalarList(text), scalarList("'" + fileURL.path + "'"),
                       "the dropped path must reach the program quoted and with both ZWJs intact; "
                       + "child read \(hex([UInt8](got)))")

        // Strip the outer single quotes the drop adds and ask the filesystem.
        let unquoted = String(text.dropFirst().dropLast())
        XCTAssertTrue(FileManager.default.fileExists(atPath: unquoted),
                      "the path the program received must name the real file; "
                      + "received \(scalarList(unquoted)), real \(scalarList(fileURL.path))")
    }
}
