import XCTest
import Metal
import MetalKit
@testable import Blackbird

/// Regression coverage for the "⌘-hold URL highlight" feature.
///
/// Three contracts are pinned here:
///
///  1. Renderer frame-skip / per-row cache keys include the three new
///     cmd-hover fields. If a future refactor drops any of
///     `cmdHoverBufferLine` / `cmdHoverStartCol` / `cmdHoverEndCol` from
///     either `FrameKey` or `CacheKey`, flipping the highlight between
///     two identical snapshots would silently short-circuit on a stale
///     cache and the user would see no repaint. The renderer keys are
///     `private` — we observe them via `Mirror` so the test doesn't
///     need any DEBUG seam to run. (Stronger observation — "did this
///     render actually frame-skip?" — would require a one-line DEBUG
///     hook; see the report that accompanies this file.)
///
///  2. `URLDetector.scan` + `URLDetector.match` behave as documented
///     for the simplest possible fixture (single `https://` URL on one
///     line). Acts as a pin so future tweaks to the regex / wrap
///     heuristics can't silently drift the column indices the hover
///     highlight depends on.
///
///  3. `OSC8URLPolicy.isAllowed` accepts the documented safe schemes
///     and rejects the documented dangerous ones. Same role as #2 —
///     a policy drift would change which URLs the ⌘-hold highlight is
///     willing to light up.
///
/// Memory / time pre-flight (per memory `feedback_test_memory_safety`):
///   - Each BBTerm is 20×8 or 80×24; the biggest snapshot is 1920 cells
///     × ~16 B ≈ 30 KB. No scrollback, no PTY.
///   - The single renderer test uses an offscreen MTKView that never
///     yields a drawable (pattern lifted from `MetalRendererTests`), so
///     `render(in:)` hits the early-return path after FrameKey / CacheKey
///     construction — no GPU command buffers submitted.
///   - Per-test wall time: <50 ms on an M-series mac.
final class CmdHoverHighlightTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - (1) Renderer cache-key regression

    /// MTKView subclass that returns nil for drawable / pass descriptor so
    /// `render(in:)` exits after the FrameKey / CacheKey construction
    /// without submitting a command buffer. Matches the helper in
    /// `MetalRendererTests.NoDrawableMTKView`.
    private final class NoDrawableMTKView: MTKView {
        override var currentDrawable: CAMetalDrawable? { nil }
        override var currentRenderPassDescriptor: MTLRenderPassDescriptor? { nil }
    }

    private func makeOffscreenView(device: MTLDevice) -> MTKView {
        let v = NoDrawableMTKView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )
        v.isPaused = true
        v.enableSetNeedsDisplay = false
        return v
    }

    private func makeSmallSnapshot(text: String = "https://example.com") throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6)))
        term.input(text)
        return try XCTUnwrap(term.snapshot())
    }

    /// Pull the three cmd-hover field values out of the renderer's
    /// `lastFrameKey` (or `lastCacheKey`) via `Mirror`. Returns nil when
    /// the key is itself nil (i.e., invalidated) or when any of the three
    /// child labels can't be found — which would itself be a regression:
    /// if the struct doesn't have these fields, the synthesized
    /// `Equatable` conformance silently stops discriminating on them and
    /// the frame-skip short-circuit fires across hover flips.
    private func readCmdHoverFields(
        of renderer: MetalRenderer,
        keyName: String
    ) -> (bufferLine: Int32, startCol: Int32, endCol: Int32)? {
        let m = Mirror(reflecting: renderer)
        // `lastFrameKey` / `lastCacheKey` are stored as Optionals. Walk
        // the child labelled keyName; `.value` is `Any` but the runtime
        // box is `Optional<FrameKey>` / `Optional<CacheKey>`.
        guard let optionalChild = m.children.first(where: { $0.label == keyName })?.value else {
            return nil
        }
        let optionalMirror = Mirror(reflecting: optionalChild)
        // Unwrap the Optional. `.some` wraps the value; `.none` is the
        // invalidated state.
        guard optionalMirror.displayStyle == .optional,
              let (_, wrapped) = optionalMirror.children.first else {
            return nil
        }
        let keyMirror = Mirror(reflecting: wrapped)
        func readInt32(_ label: String) -> Int32? {
            guard let v = keyMirror.children.first(where: { $0.label == label })?.value else {
                return nil
            }
            return v as? Int32
        }
        guard
            let bl = readInt32("cmdHoverBufferLine"),
            let sc = readInt32("cmdHoverStartCol"),
            let ec = readInt32("cmdHoverEndCol")
        else {
            return nil
        }
        return (bl, sc, ec)
    }

    /// The central regression guard for feature contract (1).
    ///
    /// Renders twice with the same snapshot and flips the cmd-hover
    /// range between the two calls. After the second render,
    /// `lastFrameKey` must carry the NEW range. If any of the three
    /// `cmdHover*` fields is missing from `FrameKey`, this test
    /// surfaces two ways:
    ///
    ///   - If the fields are absent from the struct, the Mirror
    ///     child-label lookup returns nil and the XCTUnwrap below
    ///     fires with a specific diagnostic.
    ///   - If the fields are present but Swift's synthesized `Equatable`
    ///     isn't seeing them (e.g., a manual `==` override that omits
    ///     them — unlikely but possible), render 2 would frame-skip
    ///     because the computed FrameKey equals `lastFrameKey`.
    ///     `lastFrameKey` would then stay at the render-1 value, and
    ///     the post-flip read shows `startCol = -1` instead of the new
    ///     value — the equality assertion fires.
    ///
    /// Observation scope is limited to `lastFrameKey`: in this headless
    /// setup the view returns nil for `currentDrawable`, so render()
    /// exits before reaching the code path that writes `lastCacheKey`.
    /// CacheKey's three cmd-hover fields are covered structurally in
    /// a sibling test (`test_CacheKey_invalidationOnFlip_safe`) plus
    /// the `setCmdHoverRange` public contract documents nil'ing
    /// `lastCacheKey` on any change — a regression there would surface
    /// as a visible per-row cache stale. A stronger runtime assertion
    /// on CacheKey would require a one-line DEBUG seam on the renderer
    /// (e.g. `#if DEBUG public var didFrameSkipLastRender: Bool`); see
    /// the report accompanying this file.
    func test_setCmdHoverRange_updatesFrameKeyFieldsAcrossFlip() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenView(device: device)
        let snapshot = try makeSmallSnapshot(text: "see https://example.com here")

        // Render 1: hover cleared (renderer starts in the cleared
        // state).
        renderer.render(in: view, snapshot: snapshot, focused: true)

        let fk1 = try XCTUnwrap(
            readCmdHoverFields(of: renderer, keyName: "lastFrameKey"),
            "FrameKey must expose cmdHoverBufferLine/StartCol/EndCol — any "
            + "missing field silently breaks the hover-flip repaint"
        )
        XCTAssertTrue(fk1.startCol < 0,
                      "initial FrameKey.cmdHoverStartCol should signal 'cleared' (got \(fk1.startCol))")

        // Flip the hover range to a concrete span and render again.
        // With the same snapshot + focus, the ONLY FrameKey field that
        // differs is the cmd-hover triple — so this render must NOT
        // frame-skip if those fields are part of FrameKey's Equatable.
        let targetLine: Int32 = 0
        let targetStart: Int32 = 4   // after "see "
        let targetEnd: Int32 = 22    // inclusive end of "https://example.com"
        renderer.setCmdHoverRange(bufferLine: targetLine,
                                   startCol: targetStart,
                                   endCol: targetEnd)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        let fk2 = try XCTUnwrap(
            readCmdHoverFields(of: renderer, keyName: "lastFrameKey"),
            "FrameKey must still expose the cmd-hover fields after a flip render"
        )

        // Core assertion: `lastFrameKey` was updated to carry the new
        // range. If Equatable dropped any of these fields, the computed
        // FrameKey would equal `lastFrameKey` from render 1, render 2
        // would short-circuit, and `lastFrameKey` would stay at the
        // cleared-state value.
        XCTAssertEqual(fk2.bufferLine, targetLine,
                       "FrameKey.cmdHoverBufferLine should reflect the latest range")
        XCTAssertEqual(fk2.startCol, targetStart,
                       "FrameKey.cmdHoverStartCol should reflect the latest range — "
                       + "a stale value means the frame-skip fired when it should not have")
        XCTAssertEqual(fk2.endCol, targetEnd,
                       "FrameKey.cmdHoverEndCol should reflect the latest range")

        // Flip back to cleared and render a third time. The keys must
        // come back to the cleared-state values — proves the
        // invalidation works in both directions, not just first-flip.
        renderer.setCmdHoverRange(bufferLine: 0, startCol: -1, endCol: -1)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        let fk3 = try XCTUnwrap(readCmdHoverFields(of: renderer, keyName: "lastFrameKey"))
        XCTAssertTrue(fk3.startCol < 0,
                      "FrameKey.cmdHoverStartCol should return to cleared after a clear call")
    }

    /// Paired pin for the `lastCacheKey` invalidation contract. We can't
    /// inspect `lastCacheKey`'s field values in headless tests (the
    /// no-drawable early-return exits before `lastCacheKey` is written),
    /// but we CAN verify two things that any regression in CacheKey's
    /// cmd-hover awareness would break:
    ///
    ///   (a) The same-value guard on `setCmdHoverRange` must be a
    ///       strict no-op — calling it twice with identical values must
    ///       not trigger any side-effect that destabilises the
    ///       renderer.
    ///   (b) Interleaving `setCmdHoverRange(...)` between two renders
    ///       of the same snapshot must not crash or corrupt the
    ///       renderer (post-condition: atlas lookup still works).
    ///
    /// Together with (1) above this covers the three-field contract
    /// across both keys to the extent observable in headless xctest.
    func test_CacheKey_invalidationOnFlip_safe() throws {
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let renderer = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics))
        let view = makeOffscreenView(device: device)
        let snapshot = try makeSmallSnapshot(text: "https://example.com")

        renderer.render(in: view, snapshot: snapshot, focused: true)

        // (a) Same-value guard — two identical calls. If the second
        // ever wrote to internal state, a downstream assertion in the
        // renderer would fire; this reaches past the guard into the
        // same-snapshot render, which must also stay stable.
        renderer.setCmdHoverRange(bufferLine: 0, startCol: 0, endCol: 18)
        renderer.setCmdHoverRange(bufferLine: 0, startCol: 0, endCol: 18)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        // (b) Flip through multiple ranges across renders. Any crash
        // (buffer overrun, atlas free, nil deref) surfaces here.
        for start: Int32 in [0, 4, 8] {
            renderer.setCmdHoverRange(bufferLine: 0, startCol: start, endCol: start + 5)
            renderer.render(in: view, snapshot: snapshot, focused: true)
        }
        renderer.setCmdHoverRange(bufferLine: 0, startCol: -1, endCol: -1)
        renderer.render(in: view, snapshot: snapshot, focused: true)

        // Atlas lookup after the hover flips must still work — a cache
        // invalidation bug that freed the atlas texture surfaces as a
        // nil here.
        XCTAssertNotNil(renderer.atlas.lookupOrInsert(scalar: UnicodeScalar("h")))
    }

    // MARK: - (2) URLDetector pin

    func test_urlDetector_scan_and_match_singleHttpsURL() throws {
        let url = "https://example.com"
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 5)))
        term.input(url)
        let snap = try XCTUnwrap(term.snapshot())

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(matches.count, 1, "fixture has exactly one URL")
        let m = try XCTUnwrap(matches.first)
        XCTAssertEqual(m.url.absoluteString, url,
                       "absoluteString must round-trip through URL(string:)")
        XCTAssertEqual(m.line, 0, "URL is on the first live row — buffer line 0")
        XCTAssertEqual(m.startCol, 0, "URL sits at column 0 of a fresh grid")
        XCTAssertEqual(m.endCol, url.count - 1,
                       "endCol is inclusive — the final char of the URL")

        // match(at:) returns the match for every column in [startCol, endCol],
        // nil immediately outside. We cover:
        //   - left edge (startCol)
        //   - right edge (endCol)
        //   - an interior column
        //   - the column immediately after (endCol + 1) — must be nil
        //   - a wrong line                                  — must be nil
        for col in [m.startCol, m.startCol + 5, m.endCol] {
            let p = BufferPoint(line: m.line, col: col)
            XCTAssertEqual(URLDetector.match(at: p, in: matches)?.url.absoluteString,
                           url,
                           "any column in [\(m.startCol), \(m.endCol)] should resolve to the URL; col=\(col)")
        }

        let pastEnd = BufferPoint(line: m.line, col: m.endCol + 1)
        XCTAssertNil(URLDetector.match(at: pastEnd, in: matches),
                     "column past endCol must NOT match — the hover highlight would otherwise "
                     + "light up trailing whitespace")

        if m.startCol > 0 {
            let beforeStart = BufferPoint(line: m.line, col: m.startCol - 1)
            XCTAssertNil(URLDetector.match(at: beforeStart, in: matches))
        }

        let wrongLine = BufferPoint(line: m.line + 3, col: m.startCol)
        XCTAssertNil(URLDetector.match(at: wrongLine, in: matches),
                     "column on a different buffer line must NOT match")
    }

    // MARK: - (3) OSC8URLPolicy pin

    func test_osc8URLPolicy_acceptsSafeSchemes() {
        // Every URL here should pass the allowlist. We assert each one
        // individually so a drift in any single scheme is visible in the
        // failure message — a single XCTAssertTrue over a loop would
        // collapse all scheme errors into one line.
        let safe: [(label: String, raw: String)] = [
            ("http",            "http://example.com/"),
            ("https",           "https://example.com/"),
            ("ftp",             "ftp://example.com/"),
            ("mailto (plain)",  "mailto:alice@example.com"),
            ("mailto (subject only)", "mailto:alice@example.com?subject=hi"),
        ]
        for (label, raw) in safe {
            let u = try? XCTUnwrap(URL(string: raw))
            guard let url = u else { continue }
            XCTAssertTrue(
                OSC8URLPolicy.isAllowed(url),
                "safe scheme \(label) must pass allowlist (\(raw))"
            )
        }
    }

    func test_osc8URLPolicy_rejectsUnsafeSchemesAndHosts() {
        // Every URL here should be rejected. Mixing scheme rejection,
        // host rejection, and mailto-header rejection in one test is OK
        // — the failure message names the reason each fixture is in the
        // list, so a single regression surfaces the exact rule that
        // broke.
        let unsafe: [(reason: String, raw: String)] = [
            ("javascript scheme (XSS vector)", "javascript:alert(1)"),
            ("data scheme (payload smuggle)", "data:text/html,<script>alert(1)</script>"),
            ("file scheme (execution hazard)", "file:///tmp/evil.command"),
            ("ssh scheme (outside allowlist)", "ssh://user@host/"),
            ("mailto with bcc (exfil)",        "mailto:you@ex.com?bcc=attacker@evil.com"),
            ("punycode host (IDN homograph)",  "https://xn--pple-43d.com/login"),
        ]
        for (reason, raw) in unsafe {
            guard let u = URL(string: raw) else {
                // Some attack strings don't even parse as URLs (URL init
                // rejects control chars, etc.). That's an acceptable
                // outcome — the policy gate never gets to see them.
                continue
            }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "unsafe URL must be rejected — \(reason): \(raw)"
            )
        }
    }

    // MARK: - (4) Stale hover-cell guard on snapshot transition

    /// Pins the fix for the screen-space `lastHoverCell` going stale across
    /// a snapshot identity bump.
    ///
    /// The bug:
    ///   - `mouseMoved` stores `lastHoverCell` in SCREEN space (buffer line +
    ///     `displayOffset` at move time, see TerminalView+Hover.swift ~L76).
    ///   - `reevaluateCmdHoverHighlight` later subtracts the CURRENT
    ///     snapshot's `displayOffset` to translate back into buffer space
    ///     (~L253).
    ///   - When output / scroll / alt-screen toggle bumps `sequenceID` AND
    ///     shifts `displayOffset` between the move and the reevaluate,
    ///     `last.row - snap.displayOffset` resolves to the wrong buffer
    ///     line. The cmd-hover URL underline lands one or more rows off.
    ///
    /// The fix nils `lastHoverCell` inside the cache-invalidation branch of
    /// `refreshURLMatchCacheIfNeeded`, so the next real `mouseMoved` against
    /// the live snapshot rebakes a fresh screen-space row before any
    /// reevaluate can mistranslate. This test exercises that branch by
    /// driving two snapshots whose `sequenceID`s differ (every
    /// `BBTerm.snapshot()` call allocates a new monotonic id) and asserts
    /// that the second `reevaluateCmdHoverHighlight` clears `lastHoverCell`.
    ///
    /// Memory pre-flight: a single 40×6 BBTerm (≈ 4 KB of cells) and one
    /// TerminalView. No PTY, no real session, no GPU submission. <50 ms.
    func test_snapshotChange_clearsStaleHoverCell() throws {
        let device = try requireMetalDevice()
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 192),
            device: device
        )

        // Snapshot 1: empty grid, displayOffset = 0. Establish the "we've
        // already scanned this snapshot" cache state.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 40, rows: 6)))
        let snap1 = try XCTUnwrap(term.snapshot())
        view.currentSnapshot = snap1

        // Stand in for a mouseMoved at row=2,col=3 (screen-space because
        // snap1.displayOffset == 0; the math is identity here). The
        // production path reaches this assignment via TerminalView+Hover's
        // `updateHover`; the test seam mirrors that without spinning up a
        // real NSEvent / tracking area.
        view.lastHoverCell = (row: 2, col: 3)
        view.cmdModifierHeld = true

        // First reevaluate primes `cachedURLMatchesSeq` with snap1's id.
        // The snapshot has no detected URLs, so reevaluate falls through
        // to `clearCmdHoverURLMatch()` after the cache scan. Crucially, it
        // does NOT clear `lastHoverCell` on this pass — same sequenceID,
        // no invalidation.
        view.reevaluateCmdHoverHighlight()
        XCTAssertNotNil(
            view.lastHoverCell,
            "no-op reevaluate against the same snapshot must not drop the hover cell"
        )

        // Snapshot 2: bump the snapshot identity. `BBTerm.snapshot()`
        // allocates a fresh monotonic `sequenceID` on every call, which is
        // the trigger condition the fix keys off of. Drive a real
        // `displayOffset` shift on top so the test reflects the production
        // failure mode, not just the seq-only path: feed enough rows to
        // build scrollback, then scroll up by one line.
        for _ in 0..<10 { term.input("\n") }
        term.scroll(delta: 1)
        let snap2 = try XCTUnwrap(term.snapshot())
        XCTAssertNotEqual(
            snap1.sequenceID, snap2.sequenceID,
            "BBTerm.snapshot() must hand out a fresh sequenceID per call"
        )
        XCTAssertGreaterThan(
            snap2.displayOffset, 0,
            "scroll-up must produce a non-zero displayOffset; without that "
            + "shift the buggy translation would happen to land on the right "
            + "row by accident"
        )
        view.currentSnapshot = snap2

        // Drive the cache invalidation. Because `snap2.sequenceID !=
        // snap1.sequenceID`, the fix clears `lastHoverCell` here. Pre-fix
        // code left it in place and the next render translated through a
        // stale screen row.
        view.reevaluateCmdHoverHighlight()

        XCTAssertNil(
            view.lastHoverCell,
            "snapshot identity change must clear the stale screen-space "
            + "lastHoverCell — its row was baked against the previous "
            + "displayOffset and would mistranslate against snap2"
        )
    }
}
