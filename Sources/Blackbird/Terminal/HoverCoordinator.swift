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

    /// Cell under the pointer on the last `mouseMoved`, used to cancel the
    /// dwell timer as soon as the pointer leaves the current cell. `nil` means
    /// the pointer is outside the grid.
    var lastHoverCell: (row: Int, col: Int)?
    /// Link id under the pointer now, or 0 when the hovered cell has no OSC 8
    /// attribution. The renderer (draw path) and `+Services` (Look Up) READ it;
    /// only this controller writes it (next to the `renderer.setHoveredLinkID`
    /// mirror), hence `private(set)`.
    private(set) var hoveredLinkID: UInt32 = 0
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
    /// "scanned at seq 0" don't collide; per-session ids, audit S6-003).
    var cachedURLMatches: [URLMatch] = []
    var cachedURLMatchesSeq: UInt64?
    // The scheduled tooltip reveal (`hoverTooltipItem`) lives on the VIEW, not
    // here: the view's `deinit` / `viewWillMove` cancel it, and reaching through
    // this controller's `unowned view` during the view's own deinit would trap.
    // This controller schedules/cancels it as `view.hoverTooltipItem`.

    #if DEBUG
    /// Near-miss diagnostics for the ⌘-hover column mapping. Off the hot path.
    private static let hoverLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "hover")
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
    func handleMouseMoved(flags: NSEvent.ModifierFlags, screenRow: Int, col: Int, locationInWindow: NSPoint) {
        // Reconcile ⌘-held state with the live event flags. `flagsChanged`
        // doesn't fire when a key release happens while another window is key
        // (Cmd-Tab release case), so a ⌘-up missed during focus loss would
        // otherwise leave us painting the highlight forever.
        let cmdChanged = syncCmdModifierHeld(fromEventFlags: flags)
        updateHover(screenRow: screenRow, col: col, locationInWindow: locationInWindow)
        // Run the ⌘-hover pass when either the modifier flipped OR the hover
        // cell moved. `updateHover` already updates `lastHoverCell`.
        if cmdChanged || cmdModifierHeld {
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

    private func updateHover(screenRow: Int, col: Int, locationInWindow: NSPoint) {
        // Resolve the OSC 8 link id for the cell under the pointer. A
        // test-supplied fake may override; otherwise consult the live snapshot.
        // `linkID` bounds-checks internally, so an out-of-grid coordinate just
        // returns 0 (which clears the hover).
        //
        // Gate on `OSC8URLPolicy` so cells whose OSC 8 target fails the scheme
        // allowlist (javascript:, data:, custom handlers) don't paint a hover
        // underline or fire a tooltip. The click path is already blocked
        // upstream — showing an affordance for a no-op click would mislead.
        let newLinkID: UInt32 = {
            #if DEBUG
            if let override = view.hyperlinkResolverOverride {
                // Fakes answer via osc8URL — collapse URL presence into a
                // stable non-zero id so the renderer underline path still
                // fires without a real link-id table in tests.
                return override.osc8URL(row: screenRow, col: col) != nil ? UInt32(bitPattern: Int32(-1)) : 0
            }
            #endif
            guard let snap = view.currentSnapshot else { return 0 }
            let id = snap.linkID(row: screenRow, col: col)
            guard id != 0,
                  let raw = snap.linkURL(id: id),
                  let url = URL(string: raw),
                  OSC8URLPolicy.isAllowed(url)
            else { return 0 }
            return id
        }()

        // Same cell as last move → nothing to update except the tooltip
        // position is already correct. Bail to avoid timer churn.
        if let last = lastHoverCell, last.row == screenRow, last.col == col {
            return
        }
        lastHoverCell = (row: screenRow, col: col)

        if newLinkID != hoveredLinkID {
            hoveredLinkID = newLinkID
            // Redraw so the accent underline picks up / drops off the cells
            // sharing the new hovered id.
            view.needsDisplay = true
        }

        // Reset any pending tooltip when the pointer moves to a different cell.
        // Production matches VS Code / iTerm2 feel: tooltip appears only after
        // a steady dwell.
        view.hoverTooltipItem?.cancel()
        view.hoverTooltipItem = nil
        dismissHoverTooltip()

        guard newLinkID != 0 else { return }

        // Resolve the URL so the tooltip shows the href, not just "there is a
        // link here". For the test fake this goes through osc8URL; for
        // production it's the snapshot's link table.
        let resolvedURLString: String? = {
            #if DEBUG
            if let override = view.hyperlinkResolverOverride {
                return override.osc8URL(row: screenRow, col: col)?.absoluteString
            }
            #endif
            return view.currentSnapshot?.linkURL(id: newLinkID)
        }()
        guard let urlString = resolvedURLString else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHoverTooltip(urlString: urlString, anchor: locationInWindow)
        }
        view.hoverTooltipItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// The view's `mouseExited` override forwards here.
    func clearHover() {
        lastHoverCell = nil
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
    }

    /// Refresh the regex-URL match cache when the current snapshot has a new
    /// sequence id. Called only on the ⌘-hover fast path so the O(rows × cols)
    /// scan runs at most once per snapshot instead of once per `mouseMoved`
    /// delivery. Audit cwd-hyperlink F7.
    private func refreshURLMatchCacheIfNeeded() {
        guard let snap = view.currentSnapshot else {
            cachedURLMatches = []
            cachedURLMatchesSeq = nil
            // Snapshot disappeared — drop the hover cell too. Its row was
            // computed against the now-vanished snapshot's displayOffset and
            // would mis-translate against any successor.
            lastHoverCell = nil
            return
        }
        if cachedURLMatchesSeq != snap.sequenceID {
            // Only a *replacement* invalidates the previously-baked hover row,
            // not the initial population on a fresh view (where mouseMoved may
            // have already primed lastHoverCell against this very snapshot
            // before any cmd-hover refresh ran).
            let cacheWasPopulated = (cachedURLMatchesSeq != nil)
            cachedURLMatches = URLDetector.scan(snapshot: snap)
            cachedURLMatchesSeq = snap.sequenceID
            if cacheWasPopulated {
                // `lastHoverCell.row` is screen-space — it was baked against
                // the PREVIOUS snapshot's displayOffset at mouseMoved time.
                // When the snapshot identity changes, that baked offset goes
                // stale: any successor whose displayOffset shifted makes
                // `last.row - snap.displayOffset` resolve to a buffer line one
                // or more rows off, and the cmd-hover underline lands on the
                // wrong row. The next real mouseMoved repopulates this against
                // the live snapshot; dropping it here is the safe fallback for
                // the in-between reevaluate calls (flagsChanged, snapshot
                // updates) that don't pass a fresh event.
                lastHoverCell = nil
            }
        }
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
        lastHoverCell = nil
        cachedURLMatches = []
        cachedURLMatchesSeq = nil
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
        guard hoveredLinkID != 0 else { return }
        hoveredLinkID = 0
        // Push the cleared id straight to the renderer so the next frame drops
        // the underline even before the usual draw-path plumbing runs.
        view.renderer.setHoveredLinkID(0)
        view.needsDisplay = true
    }

    private func showHoverTooltip(urlString: String, anchor: NSPoint) {
        guard let window = view.window else { return }
        // Scrub before truncation. A hostile remote can stuff a U+202E into the
        // OSC 8 href; `URL(string:)` percent-encodes it so the click target
        // stays the literal hostile host, but raw rendering in NSTextField
        // would visually flip the rest of the line — defeating "hover-to-
        // verify". Same scrub policy as paste, plus dropping TAB/LF/CR.
        // H3: redact `user:pass@` credentials BEFORE the C0/bidi scrub. Even
        // though `OSC8URLPolicy.isAllowed` rejects credential URLs at the click
        // gate, the tooltip surfaces the href on dwell; this is defence-in-
        // depth so embedded credentials never leak to the AX API / screen
        // capture if any future path surfaces a tooltip without the gate.
        let redacted = OSC8URLPolicy.redactCredentialsForDisplay(urlString)
        let scrubbed = PasteSanitizer.scrubURLForDisplay(redacted)
        // Clamp the displayed URL. A misbehaving remote could stuff megabytes
        // of OSC 8 target into the link table; sizing an NSTextField against it
        // would hang the UI. 512 chars covers every realistic URL; truncating
        // AFTER scrub means a bidi byte can't hide past the ellipsis.
        let maxDisplay = 512
        let display = scrubbed.count > maxDisplay
            ? String(scrubbed.prefix(maxDisplay)) + "…"
            : scrubbed
        // Convert the view-local anchor to screen space; the controller anchors
        // the panel just below-right of it.
        let screenPoint = window.convertPoint(toScreen: anchor)
        view.tooltipController.show(text: display, near: screenPoint)
    }

    private func dismissHoverTooltip() {
        view.tooltipController.dismiss()
    }
}
