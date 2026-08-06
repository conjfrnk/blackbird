import AppKit

/// Which sibling windows of a native tab group need the front window's frame
/// pushed onto them, when the front window settles at a new size.
///
/// ## Why this exists
///
/// macOS native tabs are separate `NSWindow`s in one `NSWindowTabGroup`, and
/// AppKit applies a group resize to a *background* tab lazily — at the instant
/// that tab is next selected, not when the resize happens. (Verified with
/// standalone AppKit probes: a sibling's `setFrameSize` fires on `select`,
/// never before, however long you wait.) Since `TerminalView.setFrameSize` is
/// the only route to a PTY winsize change, every background tab keeps a stale
/// `TIOCSWINSZ` until it is cycled to: `stty size` lies, programs still
/// producing output hard-wrap at the old width *into scrollback permanently*,
/// and alt-screen TUIs (vim, htop, Claude Code) never receive `SIGWINCH`.
/// That's issue #29.
///
/// Pushing the frame — rather than computing each sibling's grid centrally —
/// is deliberate: per-tab text size means `TerminalView.metrics` differs per
/// view, so the same pixel frame legitimately yields different `(cols, rows)`
/// per tab. Letting each sibling's own `setFrameSize` → `propagateResize` run
/// keeps that correct for free. It also makes the later tab switch *cheaper*:
/// a pre-sized tab does zero frame work when selected.
///
/// The decision is factored out here as a pure function over plain windows so
/// it can be unit-tested without a live tab group — merged tab-group members
/// are hazardous in the xctest host (see CLAUDE.md's test-authoring rules).
enum TabFrameSync {

    /// The members of `groupWindows` that should receive `frame`.
    ///
    /// Excluded:
    ///   - `front` itself — it already has the frame; re-setting it would
    ///     recurse through `windowDidResize`.
    ///   - windows already at exactly `frame` — makes a repeated fan-out free,
    ///     which matters because the trailing debounce can fire after the
    ///     end-of-live-resize push already ran.
    ///   - miniaturized windows — AppKit restores a deminiaturizing tab into
    ///     the group's current frame on its own, and poking the frame of a
    ///     window in the Dock is the kind of AppKit state-mutation this
    ///     codebase has scars from (RCA docs/rca-tab-behaviors-2026-07-01.md).
    ///
    /// Order is preserved so the push order matches the group's own order.
    static func targets(front: NSWindow, frame: NSRect, groupWindows: [NSWindow]) -> [NSWindow] {
        groupWindows.filter { window in
            window !== front
                && !window.isMiniaturized
                && window.frame != frame
        }
    }
}
