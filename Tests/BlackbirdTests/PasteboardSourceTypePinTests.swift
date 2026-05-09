import XCTest
import AppKit
@testable import Blackbird

/// Pin the architectural boundary for the `paste(_:)` path:
/// **`paste(_:)` reads ONLY the `.string` representation from the
/// pasteboard.** No `.rtf`, no `.html`, no `.tabularText`, no
/// `.fileURL` fallback. Adding any such fallback would re-open a
/// hostile-clipboard injection class — a pasteboard provider could
/// place benign bytes in `.string` (what the user "sees" via the
/// clipboard manager) and malicious bytes in an alternate type, then
/// the alternate-type read would bypass everything the user
/// inspected. The drag-and-drop path is *deliberately* separate
/// (`TerminalView+Dragging.swift`) and runs its own quote +
/// sanitization pipeline; the paste menu / ⌘V keyboard binding must
/// not silently absorb file URLs.
///
/// Three behavioural pins + one source-level pin (so a future
/// refactor that *adds* `.rtf` without touching the sanitizer fails
/// CI even if the contributor forgot to add a behavioural test).
///
/// Memory cost: each test allocates one TerminalView + headless
/// session + a few hundred bytes of pasteboard data. Trivial.
final class PasteboardSourceTypePinTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Snapshot of the user's pasteboard contents at test entry.
    /// `paste(_:)` reads `NSPasteboard.general` (it has to — that's
    /// the AppKit-defined source for menu/keyboard paste), so the
    /// test must clobber it. Politeness: snapshot every `pasteboardItems`
    /// representation in `setUp`, restore in `tearDown`. If the user
    /// had `.string`, `.rtf`, or a `.fileURL` on the clipboard before
    /// running tests, they get it back.
    ///
    /// Why a snapshot of items rather than `pb.types`: `types` returns
    /// a flattened list, but `pasteboardItems` preserves the per-item
    /// structure including all data representations. Restoring item-
    /// by-item replays the original clipboard faithfully.
    private var savedItems: [NSPasteboardItem] = []

    override func setUp() {
        super.setUp()
        let pb = NSPasteboard.general
        savedItems = (pb.pasteboardItems ?? []).map { original in
            // NSPasteboardItem can't be re-added to a pasteboard once
            // owned by another. Clone every type's data into a fresh
            // item so tearDown can put the contents back without an
            // ownership conflict.
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
        super.tearDown()
    }

    // MARK: - Test 1: mixed .string + .rtf, pick .string

    /// A hostile pasteboard places `ls` as `.string` (the rendition
    /// the user inspects in clipboard managers / `pbpaste`) AND
    /// `\nrm -rf ~\n` as `.rtf` (an alternate representation that a
    /// naive `richString-first` reader would prefer). `paste(_:)`
    /// must read only `.string`. The recorded paste payload is the
    /// `.string` bytes, never the `.rtf` bytes.
    func test_paste_readsOnlyStringRepresentation_whenStringPresent() throws {
        let pb = NSPasteboard.general
        pb.clearContents()

        // Build a pasteboard item carrying both representations.
        // Single item, two types — exactly the shape a hostile copier
        // would synthesize.
        let item = NSPasteboardItem()
        item.setString("ls", forType: .string)
        // Minimal valid RTF document containing "\nrm -rf". RTF
        // parsers look for `{\rtf` at offset 0; the `\par` is the
        // RTF newline, so a fallback that ran an attributed-string
        // decode would yield a payload starting with "\n".
        let hostileRTF = #"{\rtf1\ansi\par rm -rf ~\par}"#
        item.setData(Data(hostileRTF.utf8), forType: .rtf)
        XCTAssertTrue(pb.writeObjects([item]),
                      "precondition: pasteboard accepts the dual-type item")

        // Sanity check: both types are actually visible on the
        // pasteboard. If this fails, the test is no longer exercising
        // the mixed-type case (e.g., AppKit dropped one rep) and
        // would silently pass for the wrong reason.
        XCTAssertTrue(pb.types?.contains(.string) ?? false,
                      "precondition: .string type is set")
        XCTAssertTrue(pb.types?.contains(.rtf) ?? false,
                      "precondition: .rtf type is set")

        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.paste(nil)

        XCTAssertEqual(pastes, ["ls"],
                       "paste(_:) must read only the .string rep — got: \(pastes)")
        // Defence-in-depth assertion: if any byte from the RTF
        // payload bled through, the recorder would contain at least
        // one substring from the hostile rep.
        for paste in pastes {
            XCTAssertFalse(paste.contains("\n"),
                           "RTF \\par bytes must not reach the paste payload")
            XCTAssertFalse(paste.contains("rm -rf"),
                           "RTF body must not reach the paste payload")
            XCTAssertFalse(paste.contains("\\rtf"),
                           "raw RTF prelude must not reach the paste payload")
        }
    }

    // MARK: - Test 2: only .rtf, no .string → no-op

    /// With ONLY `.rtf` on the pasteboard, `paste(_:)` must short-
    /// circuit at the `guard let str = NSPasteboard.general.string(
    /// forType: .string) else { return }` line. The recorder never
    /// fires, no bytes reach the session.
    ///
    /// This is the security-critical case: if a future change
    /// introduced `.rtf` fallback ("be helpful — let the user paste
    /// rich text!"), a pasteboard with only `.rtf` would suddenly
    /// start delivering bytes. Pin the no-op explicitly.
    func test_paste_isNoopOrSanitized_whenOnlyRtfPresent() throws {
        let pb = NSPasteboard.general
        pb.clearContents()

        let item = NSPasteboardItem()
        let hostileRTF = #"{\rtf1\ansi\par rm -rf ~\par}"#
        item.setData(Data(hostileRTF.utf8), forType: .rtf)
        XCTAssertTrue(pb.writeObjects([item]),
                      "precondition: pasteboard accepts .rtf-only item")
        XCTAssertTrue(pb.types?.contains(.rtf) ?? false,
                      "precondition: .rtf type is set")
        // Precondition recording the *actual* AppKit behaviour we are
        // defending against: when only .rtf is on the pasteboard,
        // AppKit's `string(forType: .string)` accessor SYNTHESIZES a
        // plain-string rep by decoding the RTF document body — `\par`
        // collapses to `\n`. So the bug class isn't "no .string rep
        // exists and a fallback grabs .rtf"; it's "AppKit silently
        // returns rtf-decoded bytes via the .string accessor". We
        // assert the synthesized payload contains the post-newline
        // shell command we'd expect from the hostile RTF, which is
        // EXACTLY the byte sequence that would reach the shell if
        // paste(_:) trusted the .string accessor blindly.
        let coercedString = pb.string(forType: .string)
        XCTAssertEqual(coercedString, "\nrm -rf ~\n",
                       "precondition: AppKit coerces .rtf into a synthesized .string rep — this is exactly what we want to defend against")

        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.paste(nil)

        XCTAssertTrue(pastes.isEmpty,
                      "paste(_:) must be a no-op when .string is absent — got: \(pastes)")

        // Positive control. `pastes.isEmpty` passes if the recorder
        // never receives anything for ANY reason — broken view wiring,
        // a missing `pasteTextRecorderForTests` hook, an unrelated
        // session-setup failure. Replace the rtf-only pasteboard with
        // a clean `.string = "ls"` and re-paste; the recorder MUST
        // fire to prove the rtf-only result above is genuine, not
        // infrastructure breakage. If THIS arm fails the test was
        // passing for the wrong reason.
        pb.clearContents()
        let stringItem = NSPasteboardItem()
        stringItem.setString("ls", forType: .string)
        XCTAssertTrue(pb.writeObjects([stringItem]),
                      "positive-control precondition: pasteboard accepts .string-only item")

        view.paste(nil)

        XCTAssertEqual(pastes, ["ls"],
                       "positive control: paste(_:) MUST surface a .string payload — " +
                       "if this fails, the rtf-only assertion above was a false negative " +
                       "(broken recorder / view / session wiring), not a real defence.")
    }

    // MARK: - Test 3: .string + .fileURL → ignore .fileURL

    /// `.fileURL` lives on the drop path (see `TerminalView+Dragging.swift`),
    /// not the paste path. A pasteboard with both `.string` and
    /// `.fileURL` (e.g. Finder-copy of a file: it sets both reps) must
    /// route through the paste pipeline as the `.string` content. The
    /// drop path is invoked separately by AppKit's drag-and-drop
    /// machinery — never by the ⌘V menu / keyboard action.
    ///
    /// Why this matters: the drop path runs its own quote /
    /// sanitization pipeline on file URLs (see DragDropTests). If
    /// `paste(_:)` started reading `.fileURL`, those bytes would
    /// bypass `shellQuote`, and a hostile `.fileURL` carrying shell
    /// metacharacters would land in the prompt unquoted.
    func test_paste_ignoresFileURLAlternative() throws {
        let pb = NSPasteboard.general
        pb.clearContents()

        // Two pasteboard items: a string item, plus a file-URL item.
        // Real macOS Finder copies use this shape — the URL rides
        // alongside a textual fallback.
        let textItem = NSPasteboardItem()
        textItem.setString("data", forType: .string)
        // Also tack on the URL as a string-encoded file URL: many
        // pasteboard producers redundantly populate both `.fileURL`
        // and a string rep of the URL. A naïve fallback that read
        // `.fileURL` first would surface the URL itself.
        let fileURL = URL(fileURLWithPath: "/tmp/x")
        let fileItem = NSPasteboardItem()
        fileItem.setData(fileURL.dataRepresentation, forType: .fileURL)

        XCTAssertTrue(pb.writeObjects([textItem, fileItem]),
                      "precondition: pasteboard accepts .string + .fileURL items")

        // Sanity check: `paste(_:)` reads via
        // `pb.string(forType: .string)`, which yields the first
        // string-typed item's value when multiple items are present.
        XCTAssertEqual(pb.string(forType: .string), "data",
                       "precondition: NSPasteboard returns the .string rep we set")

        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        var pastes: [String] = []
        view.pasteTextRecorderForTests = { pastes.append($0) }

        view.paste(nil)

        XCTAssertEqual(pastes, ["data"],
                       "paste(_:) must read only the .string rep, ignoring .fileURL — got: \(pastes)")
        // Cross-check: the file URL's filesystem path must not appear
        // anywhere in the captured paste — would prove a fallback
        // exists that prefers `.fileURL`.
        for paste in pastes {
            XCTAssertFalse(paste.contains("/tmp/x"),
                           ".fileURL path must not reach the paste payload")
            XCTAssertFalse(paste.contains("file://"),
                           "URL scheme prefix must not reach the paste payload")
        }
    }

    // MARK: - Test 4: source-level pin

    /// Static analysis pin: the production paste source file must
    /// reference `NSPasteboard` only via the `.string` type. Any
    /// future contributor that adds `.rtf`, `.html`, `.tabularText`,
    /// or another fallback will fail this test immediately, even if
    /// they forgot to add a behavioural test.
    ///
    /// This is the architectural boundary: behavioural tests can
    /// only catch fallbacks for representations they think to seed.
    /// The source pin catches the broader class — anything mentioning
    /// an alternate `PasteboardType` in the paste source is a red
    /// flag that needs maintainer review.
    func test_paste_sourcePin_readsOnlyStringType() throws {
        // Locate the production source. The Tests bundle isn't
        // shipped with the source files, so look up the repo root
        // via #file. The test file lives at
        // `Tests/BlackbirdTests/PasteboardSourceTypePinTests.swift`,
        // so `../../Sources/Blackbird/Terminal/TerminalView+Paste.swift`
        // is the production file.
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repoRoot = testFileURL
            .deletingLastPathComponent()  // Tests/BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sourceURL = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Blackbird")
            .appendingPathComponent("Terminal")
            .appendingPathComponent("TerminalView+Paste.swift")

        let source: String
        do {
            source = try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            XCTFail("Could not read \(sourceURL.path): \(error). " +
                    "If the paste source moved, update this test's path.")
            return
        }

        // Forbidden tokens. We're looking for any reference to a
        // pasteboard type other than `.string` in this file. Comments
        // describing the policy may legitimately mention "rtf" or
        // "html" in prose, so we match on the API-surface forms only:
        // a leading dot or the fully-qualified type, which is what a
        // call site would actually use.
        let forbiddenTokens: [String] = [
            // Dotted PasteboardType references — the form a call site
            // like `pb.string(forType: .rtf)` would use.
            ".rtf",
            ".html",
            ".tabularText",
            ".fileURL",
            ".fileContents",
            ".pdf",
            ".png",
            ".tiff",
            // Fully-qualified forms (defensive — a future contributor
            // might write `NSPasteboard.PasteboardType.rtf` to dodge
            // a `.rtf`-pattern grep).
            "PasteboardType.rtf",
            "PasteboardType.html",
            "PasteboardType.tabularText",
            "PasteboardType.fileURL",
            "PasteboardType.fileContents",
        ]

        for token in forbiddenTokens {
            XCTAssertFalse(
                source.contains(token),
                "TerminalView+Paste.swift must not reference '\(token)' — " +
                "the paste path reads only the .string representation. " +
                "If you intentionally added an alternate type, update " +
                "this test AND ensure the new path runs through the " +
                "full sanitizer chain (sanitizePasteControls + " +
                "stripBidiOverrides + bracketed-paste protection)."
            )
        }

        // Positive pin: the `.string` reference IS expected to appear.
        // If `.string` is the only token referenced, the test should
        // see it. Failing this assertion means the file no longer
        // reads from NSPasteboard at all (refactor moved it elsewhere
        // — at which point the test path needs to follow).
        XCTAssertTrue(
            source.contains("forType: .string"),
            "TerminalView+Paste.swift was expected to read NSPasteboard via " +
            "`forType: .string`. If the read moved to a different file, " +
            "update this test's source path."
        )

        // Tighter positive pin: the per-item-types-first idiom that
        // defends against AppKit's `.string` synthesis from richer
        // types (the bug class
        // `test_paste_isNoopOrSanitized_whenOnlyRtfPresent` defends
        // against). The forbidden-token list above catches the broad
        // "added an alternate type" class, but a refactor that drops
        // the per-item enumeration AND keeps reading via
        // `pb.string(forType: .string)` directly would re-open the
        // synthesis attack surface without tripping any forbidden
        // token. Pin both required tokens so a refactor that breaks
        // EITHER half of the idiom (the per-item walk OR the
        // first-type check) fails.
        //
        // A future refactor that achieves the same security guarantee
        // via different code (e.g. a typed wrapper, a different AppKit
        // API) is fine — the test author is expected to update these
        // assertions to match. What we want to catch is the silent
        // drop of the defence with no replacement.
        let requiredTokens: [String] = [
            // The per-item walk: we MUST inspect items individually
            // because pasteboard-level type lists hide the per-item
            // synthesis pattern.
            "pasteboardItems",
            // The "first type wins" check: synthesized types appear
            // AFTER the canonical (explicitly-set) type, so the test
            // for plain-text-as-primary is on `types.first`.
            "types.first",
        ]
        for token in requiredTokens {
            XCTAssertTrue(
                source.contains(token),
                "TerminalView+Paste.swift no longer references '\(token)' — " +
                "the per-item-types-first idiom defends against AppKit's " +
                "`.string` synthesis from richer pasteboard types. " +
                "If you intentionally restructured the defence (e.g. via " +
                "a typed wrapper or a different AppKit API), update this " +
                "test to pin the new shape AND verify the rtf-only no-op " +
                "behavioural test (test_paste_isNoopOrSanitized_when" +
                "OnlyRtfPresent) still passes against the new code."
            )
        }
    }
}
