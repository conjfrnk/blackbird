import Foundation
import Combine

/// The window / tab title state for a `TerminalSession`, split out so the
/// session stops owning OSC-title capping + override resolution among its
/// many other concerns.
///
/// Two inputs resolve to one observable title: the shell's OSC 0/2 title
/// (`applyOscTitle`) and the user's manual override (`titleOverride`).
/// `displayTitle` picks the winner; `title` is the `@Published` the UI binds
/// to (`TerminalView` → `window.title`).
///
/// Fully self-contained — holds no reference back to the session (none of the
/// title logic touches the PTY / core / snapshot). NOT `@MainActor`:
/// `applyOscTitle` is driven from the session's event router and `publishTitle`
/// defends against an off-main caller by hopping to main before touching the
/// `@Published`, preserving the session's pre-extraction threading contract
/// exactly (audit L6).
public final class SessionTitleState: ObservableObject {

    /// Effective, observable title for UI binding. Always equals `displayTitle`
    /// — republished whenever the shell emits OSC 0/2 or the user changes
    /// `titleOverride`, so Combine subscribers (e.g., `TerminalView` → `window.title`)
    /// pick up both sources.
    @Published public private(set) var title: String?

    /// Last title the shell emitted via OSC 0/2. Empty before any emit.
    /// Mutated on main thread (see the `bbterm.onEvent` dispatch back to main).
    private var oscTitle: String = ""

    /// User-set manual override. When non-nil and non-empty, the UI shows
    /// this instead of the shell's OSC title. Setting to nil or an empty
    /// string reverts to auto (OSC) mode.
    public var titleOverride: String? {
        didSet {
            // Treat empty string as "clear the override" — matches the
            // Rename alert's empty-field behaviour (see MainWindowController.beginRenameActiveTab).
            if titleOverride?.isEmpty == true {
                // Guard against recursion: only reassign if not already nil.
                if titleOverride != nil {
                    titleOverride = nil
                    return  // didSet will re-fire with nil and publish.
                }
            }
            publishTitle()
        }
    }

    /// The title to display in the window / tab bar. Override wins when set;
    /// otherwise the shell-reported OSC title; otherwise `nil` so the
    /// TerminalView sink keeps the current `window.title` (which the window
    /// controller seeds with the shell basename at session start). Returning
    /// a literal "Terminal" placeholder here used to overwrite the
    /// shell-basename seed the moment a user cleared their rename override
    /// in a session whose shell hadn't emitted OSC 0/2 yet — bare bash/zsh
    /// without a precmd-titler is the common trigger.
    public var displayTitle: String? {
        if let override = titleOverride, !override.isEmpty { return override }
        return oscTitle.isEmpty ? nil : oscTitle
    }

    /// Maximum grapheme-cluster length retained from an OSC 0/2 title.
    /// A hostile remote that emits `\e]0;` + 2 KB of text + `\e\\` would
    /// otherwise feed `TabStripView.truncatedString` a multi-thousand-
    /// character search space on every titlebar redraw — even with the
    /// binary-search truncation, per-frame `NSString.size(withAttributes:)`
    /// scales with layout cost on the full string. 256 graphemes is well
    /// past any legitimate shell-emitted title (`hostname:dir$` style
    /// fits in 80) and keeps the per-frame cost bounded.
    public static let oscTitleMaxGraphemes = 256

    /// Called by the event router when the shell emits OSC 0/2. Keeps
    /// `oscTitle` and the published `title` in sync. Harmless to call with
    /// the same string twice — the `@Published` will still fire, which is
    /// fine; downstream is idempotent.
    public func applyOscTitle(_ newValue: String) {
        oscTitle = Self.cappedOscTitle(newValue)
        publishTitle()
    }

    /// Truncate at `oscTitleMaxGraphemes` so the per-frame pill layout
    /// stays bounded regardless of payload size. Counted in graphemes so
    /// combining marks aren't split across a truncation boundary.
    static func cappedOscTitle(_ value: String) -> String {
        if value.count <= oscTitleMaxGraphemes { return value }
        let prefix = value.prefix(oscTitleMaxGraphemes)
        return String(prefix) + "…"
    }

    /// Recompute `displayTitle` and republish on the `@Published title`
    /// pipeline. UI observes via Combine (`TerminalView.$title.sink` on
    /// `session.titleState`); there's no notification channel — Combine is
    /// canonical. Callers on any thread hop to main if needed. A nil value
    /// means "no real title to set" — the sink falls back to the current
    /// window.title (shell basename) instead of overwriting it with a
    /// placeholder.
    ///
    /// Audit L6: when called off main, recompute `displayTitle` INSIDE
    /// the main-async block rather than capturing a snapshot before the
    /// hop. The two underlying fields (`oscTitle`, `titleOverride`) are
    /// both written from main, so reading them off main is itself a
    /// data race; reading them on main inside the delivery closure
    /// also closes a small ordering window where two rapid title
    /// writes (one from a feed event, one from a `titleOverride`
    /// setter) could interleave their captured snapshots and deliver
    /// the older value last.
    private func publishTitle() {
        if Thread.isMainThread {
            self.title = displayTitle
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.title = self.displayTitle
            }
        }
    }
}
