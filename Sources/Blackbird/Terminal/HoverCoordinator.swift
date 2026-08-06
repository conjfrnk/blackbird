import AppKit
import Foundation
import BBCore
import os

/// Hover + ⌘-held URL highlighting for `TerminalView`, hoisted out of the
/// view's class body + `TerminalView+Hover.swift` so the view stops owning
/// this stateful subsystem among its many concerns. Two sibling concerns share
/// one large piece of state:
///
///   - **OSC 8 hover** — when the pointer rests on a cell carrying an explicit
///     `link_id`, underline every cell with that id and reveal a tooltip after
///     a 500 ms dwell.
///   - **⌘-held regex hover** — holding ⌘ over a regex-detected URL underlines
///     its cell range and flips the cursor to `pointingHand`. A match list
///     cached on `snapshot.sequenceID` keeps the O(rows × cols) scan off the
///     mouse-move hot path.
///
/// The view's NSResponder overrides (`mouseMoved`/`mouseExited`/`flagsChanged`/
/// `cursorUpdate`/`updateTrackingAreas`) stay on the view and forward here via
/// `handleMouseMoved` / `clearHover` / `handleFlagsChanged` /
/// `wantsPointingHandCursor`.
///
/// `unowned let view`: the view owns this controller (`lazy var`), so its
/// lifetime is a strict subset of the view's. The dwell `DispatchWorkItem`
/// captures `[weak self]` (self = this controller), so a late fire after the
/// view (hence this controller) is gone finds `self == nil` and returns before
/// touching `view` — exactly as the old `[weak self]` (self = the view) did.
///
/// NOT moved (deliberately): `hyperlinkResolverOverride` is a DEBUG test seam
/// SHARED with the click path (`resolveClickURL`), so it stays on the view and
/// is read here as `view.hyperlinkResolverOverride`; `hoverTrackingArea` is
/// owned by the view's `updateTrackingAreas` override.
final class HoverCoordinator {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    // MARK: - State

    /// Where the pointer last was, in VIEW-LOCAL coordinates.
    ///
    /// The hovered *cell* is derived from this on demand (`lastHoverCell`)
    /// rather than baked at `mouseMoved` time. A baked screen-space cell goes
    /// stale in two ways the old design had no answer for: the grid can scroll
    /// under a stationary pointer (so the baked row's buffer line moves), and a
    /// TUI can repaint the cell's contents entirely. The pointer's *pixel*
    /// position is the only thing that genuinely doesn't change until the mouse
    /// moves, so it is what we store. Audit issue #30 / R30-4, R30-5.
    private(set) var lastHoverPointInView: CGPoint?

    /// Cell under the pointer, re-derived against the CURRENT snapshot every
    /// time it is read. `nil` when the pointer is outside the view or there is
    /// no snapshot to resolve against.
    var lastHoverCell: (row: Int, col: Int)? {
        guard lastHoverPointInView != nil, let snap = view.currentSnapshot else { return nil }
        // Prefer AppKit's LIVE pointer position over the point we stored at the
        // last `mouseMoved`. The pointer's view-local position changes with no
        // mouse event whenever the view itself moves or resizes underneath it —
        // which this codebase now does routinely (the tab-group frame fan-out,
        // fullscreen transitions, the ⌘-right-drag resize gesture, which
        // delivers `rightMouseDragged` and never `mouseMoved`). The stored
        // point remains the "is the pointer inside at all" marker and the
        // fallback for a windowless view (tests).
        let point: CGPoint = {
            guard let window = view.window else { return lastHoverPointInView! }
            return view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }()
        // `bufferPointFromLocalPoint` CLAMPS out-of-range points into the grid,
        // so without an explicit bounds test a pointer parked in the titlebar
        // band would resolve to row 0 forever — and now re-resolve on every
        // snapshot publish, painting an underline and a tooltip for a cell the
        // click path (`inTextArea`) explicitly refuses to open. An affordance
        // the click gate won't honour is the same defect class as issue #30.
        guard view.bounds.contains(point),
              point.y < view.bounds.height - view.titlebarOnlyTopInset else { return nil }
        let bufferPoint = view.bufferPointFromLocalPoint(point)
        return (row: Int(bufferPoint.line) + snap.displayOffset, col: bufferPoint.col)
    }

    /// The cell the current `hoveredLinkID` / tooltip state was resolved for.
    /// Distinct from `lastHoverCell`: that one moves with the grid, this one
    /// records what we last *resolved*, so a pointer that stays in the same
    /// cell doesn't re-arm the dwell tooltip on every repaint.
    private var resolvedHoverCell: (row: Int, col: Int)?

    /// Link id under the pointer now, or 0 when the hovered cell has no OSC 8
    /// attribution. The renderer (draw path) and `+Services` (Look Up) READ it;
    /// only this controller writes it (next to the `renderer.setHoveredLinkID`
    /// mirror), hence `private(set)`.
    ///
    /// **Only ever valid for `view.currentSnapshot`.** The Rust core assigns
    /// link ids per snapshot, in grid-scan order over the distinct URIs on
    /// screen (`core/src/snapshot.rs`), so the same numeric id can mean a
    /// different URL one frame later. `handleSnapshotPublished()` re-resolves
    /// it on every publish for exactly that reason.
    private(set) var hoveredLinkID: UInt32 = 0

    /// The href the current `hoveredLinkID` resolves to, after the
    /// `OSC8URLPolicy` gate. Kept alongside the id so re-resolution can tell
    /// "same link, renumbered" (no UI churn) from "different link" (repaint,
    /// re-arm affordances), and so `TerminalView+Services`' Look Up / Quick
    /// Look surface reads a policy-checked URL instead of re-resolving a
    /// possibly-stale id against a newer snapshot.
    private(set) var hoveredLinkURLString: String?

    /// Last value pushed to AppKit's cursor machinery, so we only invalidate
    /// cursor rects when the answer actually flips. AppKit dispatches
    /// `cursorUpdate(with:)` on tracking-area entry/exit — not on every move
    /// inside the area — so without an explicit invalidation the pointing hand
    /// never appears when a link slides under a resting pointer, and sticks
    /// after the pointer leaves one.
    private var lastWantsPointingHandCursor = false
    /// Latched ⌘-modifier state. Updated via `flagsChanged`, reconciled against
    /// `NSEvent.modifierFlags` on every `mouseMoved`, force-cleared on
    /// `didResignKeyNotification`. Read on the snapshot-update path; the test
    /// seam writes it, so it stays settable.
    var cmdModifierHeld: Bool = false
    /// The regex match under the cursor while ⌘ is held; lets clear/cursor/
    /// renderer coordinate without re-running the scan. Internal-only (read via
    /// `wantsPointingHandCursor`), hence `private`.
    private var cmdHoverURLMatch: URLMatch?
    /// URL match list for the current snapshot, rebuilt only when
    /// `snapshot.sequenceID` changes (`Optional` seq so "never scanned" and
    /// "scanned at seq 0" don't collide; per-session ids, audit S6-003). The
    /// two fields are one invariant — keyed cache — so they move together;
    /// `private(set)` + `invalidateURLMatchCache()` keep the pair from drifting
    /// apart at a caller that clears one and forgets the other.
    private(set) var cachedURLMatches: [URLMatch] = []
    private(set) var cachedURLMatchesSeq: UInt64?

    /// Drop the URL-match cache (both fields together) so the next ⌘-hover scan
    /// repopulates. Used by the session-rebind paths (per-session sequence ids
    /// can collide, audit F-S5-018) and the internal reset paths.
    func invalidateURLMatchCache() {
        cachedURLMatches = []
        cachedURLMatchesSeq = nil
    }
    // The scheduled tooltip reveal (`hoverTooltipItem`) lives on the VIEW, not
    // here: the view's `deinit` / `viewWillMove` cancel it, and reaching through
    // this controller's `unowned view` during the view's own deinit would trap.
    // This controller schedules/cancels it as `view.hoverTooltipItem`.

    #if DEBUG
    /// Near-miss diagnostics for the ⌘-hover column mapping. Off the hot path.
    private static let hoverLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "hover")

    /// Place the pointer at a view-local point without synthesizing an
    /// `NSEvent` / tracking area. Mirrors exactly what `handleMouseMoved`
    /// stores, so tests exercise the same derivation production does.
    func setHoverPointForTests(_ point: CGPoint?) {
        lastHoverPointInView = point
    }
    #endif

    /// True when the pointer is over something clickable (OSC 8 link always, or
    /// a regex URL while ⌘ is held) — drives the view's `cursorUpdate` to show
    /// `pointingHand`.
    var wantsPointingHandCursor: Bool {
        hoveredLinkID != 0 || cmdHoverURLMatch != nil
    }

    // MARK: - Mouse / flags entry points (called by the view's overrides)

    /// The hover half of the view's `mouseMoved` override (the view also drives
    /// `reportPointerMotionIfNeeded`, a separate mouse-reporting concern).
    func handleMouseMoved(flags: NSEvent.ModifierFlags, locationInWindow: NSPoint) {
        // Reconcile ⌘-held state with the live event flags. `flagsChanged`
        // doesn't fire when a key release happens while another window is key
        // (Cmd-Tab release case), so a ⌘-up missed during focus loss would
        // otherwise leave us painting the highlight forever.
        let cmdChanged = syncCmdModifierHeld(fromEventFlags: flags)
        lastHoverPointInView = view.convert(locationInWindow, from: nil)
        // Derive the cell the SAME way every other reader does, rather than
        // taking the caller's mapping of this event. The two can disagree —
        // `lastHoverCell` reads AppKit's live pointer position, which is ahead
        // of an event that has been sitting in the queue — and then the OSC 8
        // half of the hover would resolve against one cell while the ⌘-regex
        // half resolved against another.
        guard let cell = lastHoverCell else {
            clearHoverDerivedState()
            return
        }
        updateHover(screenRow: cell.row, col: cell.col, tooltipAnchor: locationInWindow)
        // Run the ⌘-hover pass when either the modifier flipped OR the hover
        // cell moved.
        if cmdChanged || cmdModifierHeld {
            reevaluateCmdHoverHighlight()
        }
    }

    /// Called from `TerminalView.render(snapshot:)` after `currentSnapshot` has
    /// been swapped. Re-resolves every piece of hover state against the new
    /// grid without needing a pointer movement:
    ///
    ///   - the OSC 8 link under the pointer (its id renumbers per snapshot, and
    ///     a repainting TUI or scrolling output changes what's under a
    ///     stationary pointer);
    ///   - the ⌘-held regex-URL highlight.
    ///
    /// Deliberately does NOT re-arm the dwell tooltip: content moving under a
    /// still pointer shouldn't pop a tooltip the user didn't aim for, and a
    /// TUI repainting at frame rate would make it flicker. A tooltip already on
    /// screen for a link that changed is dismissed.
    func handleSnapshotPublished() {
        guard let cell = lastHoverCell else {
            // Pointer is outside the grid (or there's no snapshot): drop any
            // affordance still painted for the old one.
            clearHoveredLink()
            if cmdModifierHeld { reevaluateCmdHoverHighlight() }
            return
        }
        updateHover(screenRow: cell.row, col: cell.col, tooltipAnchor: nil)
        if cmdModifierHeld {
            reevaluateCmdHoverHighlight()
        }
    }

    /// The view's `flagsChanged` override forwards here.
    func handleFlagsChanged(flags: NSEvent.ModifierFlags) {
        guard syncCmdModifierHeld(fromEventFlags: flags) else { return }
        reevaluateCmdHoverHighlight()
        // Cursor should refresh immediately when the modifier changes (AppKit's
        // cursorUpdate normally fires on mouse movement).
        view.window?.invalidateCursorRects(for: view)
    }

    /// Resolve the OSC 8 link under `(screenRow, col)` against the LIVE
    /// snapshot and reconcile every affordance that depends on it: the accent
    /// underline (via `hoveredLinkID`), the pointing-hand cursor, and the dwell
    /// tooltip.
    ///
    /// `tooltipAnchor` is the window-space point to hang a *new* dwell tooltip
    /// from — non-nil only when a real pointer movement drove this call. A
    /// content-driven refresh (`handleSnapshotPublished`) passes nil: it may
    /// dismiss a tooltip whose link went away, but never pops one the user
    /// didn't aim at.
    ///
    /// Unlike the old shape, this does NOT early-return when the cell is
    /// unchanged. Re-resolving on an unchanged cell is the entire point on the
    /// snapshot path — the id renumbers per snapshot and the cell's contents
    /// can change under a stationary pointer. The unchanged-cell case is
    /// instead kept cheap by comparing the resolved *href* and doing nothing
    /// when it matches.
    private func updateHover(screenRow: Int, col: Int, tooltipAnchor: NSPoint?) {
        // Resolve the OSC 8 link id + href for the cell under the pointer. A
        // test-supplied fake may override; otherwise consult the live snapshot.
        // `linkID` bounds-checks internally, so an out-of-grid coordinate just
        // returns 0 (which clears the hover).
        //
        // Gate on `OSC8URLPolicy` so cells whose OSC 8 target fails the scheme
        // allowlist (javascript:, data:, custom handlers) don't paint a hover
        // underline or fire a tooltip. The click path is already blocked
        // upstream — showing an affordance for a no-op click would mislead.
        let resolved: (id: UInt32, urlString: String?) = {
            #if DEBUG
            if let override = view.hyperlinkResolverOverride {
                // Fakes answer via osc8URL — collapse URL presence into a
                // stable non-zero id so the renderer underline path still
                // fires without a real link-id table in tests.
                guard let url = override.osc8URL(row: screenRow, col: col) else { return (0, nil) }
                return (UInt32(bitPattern: Int32(-1)), url.absoluteString)
            }
            #endif
            guard let snap = view.currentSnapshot else { return (0, nil) }
            let id = snap.linkID(row: screenRow, col: col)
            guard id != 0,
                  let raw = snap.linkURL(id: id),
                  let url = URL(string: raw),
                  OSC8URLPolicy.isAllowed(url)
            else { return (0, nil) }
            return (id, raw)
        }()

        let cellChanged = resolvedHoverCell.map { $0.row != screenRow || $0.col != col } ?? true
        let hrefChanged = resolved.urlString != hoveredLinkURLString
        resolvedHoverCell = (row: screenRow, col: col)

        if resolved.id != hoveredLinkID {
            hoveredLinkID = resolved.id
            // Push straight to the renderer as well as marking the view dirty:
            // the draw path mirrors this every frame, but a cleared id must
            // drop the underline even if no frame is scheduled in between.
            view.renderer.setHoveredLinkID(UInt16(truncatingIfNeeded: resolved.id))
            view.needsDisplay = true
        }
        hoveredLinkURLString = resolved.urlString
        refreshPointingHandCursorIfNeeded()

        // Nothing about the link changed and the pointer is in the same cell →
        // leave any in-flight dwell alone. This is the hot path on a repainting
        // TUI: it must not cancel and re-arm the tooltip 120 times a second.
        guard cellChanged || hrefChanged else { return }

        // The link under the pointer changed (or the pointer moved): any
        // pending or visible tooltip now describes the wrong thing.
        view.hoverTooltipItem?.cancel()
        view.hoverTooltipItem = nil
        dismissHoverTooltip()

        // Arm a fresh dwell only for real pointer movement. Production matches
        // VS Code / iTerm2 feel: the tooltip appears after a steady dwell on a
        // link the user pointed at.
        guard let anchor = tooltipAnchor, let urlString = resolved.urlString else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHoverTooltip(urlString: urlString, anchor: anchor)
        }
        view.hoverTooltipItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Invalidate AppKit's cursor rects when — and only when — the answer to
    /// "is the pointer over something clickable" flips. AppKit dispatches
    /// `cursorUpdate(with:)` on tracking-area entry/exit, so without this the
    /// pointing hand never appears for a link that slid under a resting pointer
    /// (and sticks after the pointer leaves one).
    private func refreshPointingHandCursorIfNeeded() {
        let wants = wantsPointingHandCursor
        guard wants != lastWantsPointingHandCursor else { return }
        lastWantsPointingHandCursor = wants
        view.window?.invalidateCursorRects(for: view)
    }

    /// The view's `mouseExited` override forwards here: the pointer is gone,
    /// so everything goes, including its position.
    func clearHover() {
        lastHoverPointInView = nil
        clearHoverDerivedState()
    }

    /// Drop everything DERIVED from the pointer position while keeping the
    /// position itself. This is what a scroll wants: the grid moved under a
    /// pointer that is still there, so the affordances for the old content are
    /// wrong, but the next snapshot publish must be able to re-resolve what is
    /// under the pointer now. Nil-ing the position here instead (as the scroll
    /// path used to, via `clearHover()`) left `lastHoverCell` permanently nil —
    /// AppKit delivers no `mouseMoved` for a scroll — so one wheel notch
    /// switched the whole hover subsystem off until the user physically moved
    /// the mouse. In Claude Code the wheel is forwarded to the TUI and repaints
    /// the screen, which makes that the single most common way content changes
    /// under a resting pointer.
    func clearHoverDerivedState() {
        resolvedHoverCell = nil
        cancelHoverTooltip()
        clearHoveredLink()
        clearCmdHoverURLMatch()
    }

    // MARK: - ⌘-held regex URL highlight

    /// Drop the ⌘-hover underline and tell the renderer so the next frame
    /// repaints cleanly. Separate from `clearHoveredLink` (OSC 8 hover) because
    /// the two states live independently — an OSC 8 cell under the pointer
    /// keeps its underline even when ⌘ is released, and vice versa.
    ///
    /// Unconditionally calls through to `setCmdHoverRange` even when the local
    /// `cmdHoverURLMatch` is already nil: the renderer's dedup guard makes the
    /// no-op free, and skipping the call would trap a renderer-state desync if
    /// our local state ever drifted (e.g., a direct test setter). Only the
    /// `needsDisplay` nudge is gated on "something actually changed locally".
    func clearCmdHoverURLMatch() {
        let wasSet = cmdHoverURLMatch != nil
        cmdHoverURLMatch = nil
        view.renderer.setCmdHoverRange(bufferLine: 0, startCol: -1, endCol: -1)
        if wasSet { view.needsDisplay = true }
        // `cmdHoverURLMatch` is the OTHER disjunct of `wantsPointingHandCursor`.
        // Refreshing the cursor cache only from the OSC 8 side let it latch
        // `true` here and then suppress the invalidation for a subsequent real
        // OSC 8 hover — leaving an I-beam over a live, underlined link, which
        // is the exact affordance bug this cache exists to fix.
        refreshPointingHandCursorIfNeeded()
    }

    /// Refresh the regex-URL match cache when the current snapshot has a new
    /// sequence id. Called only on the ⌘-hover fast path so the O(rows × cols)
    /// scan runs at most once per snapshot instead of once per `mouseMoved`
    /// delivery. Audit cwd-hyperlink F7.
    private func refreshURLMatchCacheIfNeeded() {
        guard let snap = view.currentSnapshot else {
            invalidateURLMatchCache()
            return
        }
        guard cachedURLMatchesSeq != snap.sequenceID else { return }
        // No damage-based skip here, deliberately. It is tempting — this now
        // runs on every publish while ⌘ is held, and the scan is
        // O(rows × cols) — but any such skip has to reason about "row R is
        // unchanged since the scan", and the publish path legitimately DROPS
        // snapshots (`SnapshotCoalescer`'s latest-wins slot). Damage is drained
        // per snapshot taken, not per snapshot published, so the damage a
        // dropped snapshot carried is simply gone and the induction has holes
        // exactly where a repainting TUI is busiest. A stale cache there would
        // paint the ⌘-hover underline for a URL that is no longer under the
        // pointer — the same "affordance the click won't honour" defect class
        // as issue #30 itself. The scan is ~0.3–1 ms at a typical grid and only
        // runs while the user is physically holding ⌘.
        cachedURLMatches = URLDetector.scan(snapshot: snap)
        cachedURLMatchesSeq = snap.sequenceID
        // No hover state is dropped here any more. The old shape nil'd
        // `lastHoverCell` on every snapshot replacement because the cell was a
        // screen-space row baked at mouseMoved time against the *previous*
        // snapshot's displayOffset. `lastHoverCell` is now derived from the
        // pointer's pixel position against the CURRENT snapshot on every read,
        // so the staleness that motivated the nil-ing cannot occur — and the
        // nil-ing itself was a bug: under a screen that repaints continuously
        // (a TUI, `tail -f`, a build log) the ⌘-hover underline was cleared on
        // the next publish and never came back until the pointer moved.
    }

    /// Resolve the regex URL under the current hover cell (if any) and push its
    /// cell range to the renderer as a ⌘-hover highlight. OSC 8 wins on cells
    /// with an explicit link id — the existing hover underline and tooltip
    /// already handle those, and re-painting them here would double the redraw.
    ///
    /// Called whenever the hover cell, current snapshot, or `cmdModifierHeld`
    /// changes. Safe to call with no snapshot, no hover cell, or no window
    /// focus — it only pushes updates to the renderer when the resolved range
    /// differs from what the renderer already knows.
    func reevaluateCmdHoverHighlight() {
        guard cmdModifierHeld,
              let last = lastHoverCell,
              let snap = view.currentSnapshot
        else {
            clearCmdHoverURLMatch()
            return
        }
        // OSC 8 cells already carry their own hover affordance; skip the regex
        // overlay so we don't paint two underlines on the same run.
        if snap.linkID(row: last.row, col: last.col) != 0 {
            clearCmdHoverURLMatch()
            return
        }
        refreshURLMatchCacheIfNeeded()
        let bufferLine = Int32(last.row - snap.displayOffset)
        let point = BufferPoint(line: bufferLine, col: last.col)
        guard let match = URLDetector.match(at: point, in: cachedURLMatches) else {
            #if DEBUG
            // Diagnosability: this branch silently clears. If the cache is
            // populated for this buffer line but no match covers the pointer
            // cell, the user experience is "highlight flickers off for no
            // apparent reason" — log the near-miss so a future column-mapping
            // or wrap-join regression is observable instead of invisible.
            if !cachedURLMatches.isEmpty,
               cachedURLMatches.contains(where: { $0.line == bufferLine }) {
                Self.hoverLogger.debug(
                    "cmd-hover: cache populated for line \(bufferLine, privacy: .public) but match(at:) miss at col \(last.col, privacy: .public)"
                )
            }
            #endif
            clearCmdHoverURLMatch()
            return
        }
        guard OSC8URLPolicy.isAllowed(match.url) else {
            // Policy reject (non-http/https/ftp/mailto). Intentional — don't
            // log; matches `resolveClickURL`'s silent drop.
            clearCmdHoverURLMatch()
            return
        }
        // Same cell range as last time → nothing to push. Prevents needsDisplay
        // churn on every intra-URL pointer move.
        if let existing = cmdHoverURLMatch,
           existing.line == match.line,
           existing.startCol == match.startCol,
           existing.endCol == match.endCol {
            return
        }
        cmdHoverURLMatch = match
        view.renderer.setCmdHoverRange(
            bufferLine: match.line,
            startCol: Int32(match.startCol),
            endCol: Int32(match.endCol)
        )
        view.needsDisplay = true
        refreshPointingHandCursorIfNeeded()
    }

    /// Sync `cmdModifierHeld` with the latest modifier state. Called from
    /// `handleFlagsChanged` (fast path) and `handleMouseMoved` (reconcile path).
    /// Returns `true` when the state actually changed so callers can drive
    /// re-evaluation.
    @discardableResult
    func syncCmdModifierHeld(fromEventFlags flags: NSEvent.ModifierFlags) -> Bool {
        let nowHeld = flags.contains(.command)
        guard nowHeld != cmdModifierHeld else { return false }
        cmdModifierHeld = nowHeld
        return true
    }

    /// Clear all modifier / hover state. Called when the window resigns key
    /// (tab switch, Cmd-Tab to another app) so stale "⌘ held" state from a
    /// missed flagsChanged can't survive focus boundaries. Also drops
    /// `lastHoverCell` and the URL-match cache so the next `mouseMoved` after
    /// focus regain re-resolves from scratch.
    func resetModifierAndHoverState() {
        cmdModifierHeld = false
        lastHoverPointInView = nil
        resolvedHoverCell = nil
        invalidateURLMatchCache()
        clearCmdHoverURLMatch()
        clearHoveredLink()
        cancelHoverTooltip()
    }

    /// Cancel any pending tooltip reveal and drop the tooltip panel if it's up.
    /// Does NOT clear the accent underline / hovered-link id — that belongs to
    /// `clearHoveredLink()`. Called from keyDown so typing dismisses the dwell
    /// tooltip without simultaneously stripping the underline off the link the
    /// user is still hovering.
    func cancelHoverTooltip() {
        view.hoverTooltipItem?.cancel()
        view.hoverTooltipItem = nil
        dismissHoverTooltip()
    }

    /// Drop the accent underline + hovered-link id and force a repaint. Called
    /// from `clearHover` (mouseExited / scroll-invalidates-cache) and the
    /// view's `deinit`. Decoupled from the tooltip so keyDown can dismiss the
    /// tooltip alone without disturbing the underline.
    func clearHoveredLink() {
        hoveredLinkURLString = nil
        defer { refreshPointingHandCursorIfNeeded() }
        guard hoveredLinkID != 0 else { return }
        hoveredLinkID = 0
        // Push the cleared id straight to the renderer so the next frame drops
        // the underline even before the usual draw-path plumbing runs.
        view.renderer.setHoveredLinkID(0)
        view.needsDisplay = true
    }

    /// The href under the pointer, policy-checked and resolved against the
    /// snapshot that is on screen right now — the only safe input for any
    /// surface that displays or dispatches it (`TerminalView+Services`' Look Up
    /// / Quick Look preview). Reading `hoveredLinkID` and re-resolving it
    /// against `currentSnapshot` is NOT equivalent: link ids are per-snapshot,
    /// so a stale id can name a different URL — one that never passed
    /// `OSC8URLPolicy`.
    func hoveredLinkURL() -> URL? {
        guard let urlString = hoveredLinkURLString,
              let url = URL(string: urlString),
              OSC8URLPolicy.isAllowed(url)
        else { return nil }
        return url
    }

    /// The one place a hostile-supplied href is turned into something safe to
    /// put on screen: credential redaction, then the C0/bidi scrub, then a
    /// length clamp. Shared by the dwell tooltip and the Force-Touch preview so
    /// a change to the policy can't reach one surface and miss the other.
    static func displayString(forHref urlString: String) -> String {
        // Scrub before truncation. A hostile remote can stuff a U+202E into the
        // OSC 8 href; `URL(string:)` percent-encodes it so the click target
        // stays the literal hostile host, but raw rendering in NSTextField
        // would visually flip the rest of the line — defeating "hover-to-
        // verify". Same scrub policy as paste, plus dropping TAB/LF/CR.
        // H3: redact `user:pass@` credentials BEFORE the C0/bidi scrub. Even
        // though `OSC8URLPolicy.isAllowed` rejects credential URLs at the click
        // gate, this is defence-in-depth so embedded credentials never leak to
        // the AX API / screen capture if any future path surfaces a href
        // without the gate.
        let redacted = OSC8URLPolicy.redactCredentialsForDisplay(urlString)
        let scrubbed = PasteSanitizer.scrubURLForDisplay(redacted)
        // Clamp the displayed URL. A misbehaving remote could stuff megabytes
        // of OSC 8 target into the link table; sizing an NSTextField against it
        // would hang the UI. 512 chars covers every realistic URL; truncating
        // AFTER scrub means a bidi byte can't hide past the ellipsis.
        let maxDisplay = 512
        return scrubbed.count > maxDisplay
            ? String(scrubbed.prefix(maxDisplay)) + "…"
            : scrubbed
    }

    private func showHoverTooltip(urlString: String, anchor: NSPoint) {
        guard let window = view.window else { return }
        let display = Self.displayString(forHref: urlString)
        // Convert the view-local anchor to screen space; the controller anchors
        // the panel just below-right of it.
        let screenPoint = window.convertPoint(toScreen: anchor)
        view.tooltipController.show(text: display, near: screenPoint)
    }

    private func dismissHoverTooltip() {
        view.tooltipController.dismiss()
    }
}
