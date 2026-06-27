import AppKit
import Foundation

/// The terminal bell for `TerminalView`, split out so the view stops owning the
/// flash-overlay subview + the visual/audible bell plumbing among its many
/// concerns.
///
/// Two independent bells share the "bell" theme:
///   - VISUAL: a transparent white `FlashView` overlay pulsed on every shell
///     BEL (driven by `session.$bellCounter`, de-duped against `lastBellCounter`,
///     gated on `Preferences.bell == .visual`).
///   - AUDIBLE: `NSSound.beep()` for unhandled-key / prompt-nav no-op feedback,
///     muted under the test harness (`BB_SUPPRESS_BELL`).
///
/// Self-contained — no back-reference to the view. `attach(to:)` installs the
/// overlay once (from the view's init); everything else operates on
/// controller-owned state. All calls are main-thread (the `$bellCounter` sink
/// receives on main; the key/prompt callers are main-thread UI), matching the
/// pre-extraction contract.
final class BellController {

    /// Transparent overlay that pulses on a visual bell. Pass-through hit
    /// testing so it never swallows mouse events destined for the grid.
    private final class FlashView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    private let flashView: FlashView = {
        let v = FlashView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.25).cgColor
        v.alphaValue = 0
        return v
    }()

    private var lastBellCounter: UInt64 = 0

    /// Suppress audible beeps under the test harness (CI / lint set
    /// `BB_SUPPRESS_BELL`) so an automated full-suite run doesn't emit a stream
    /// of system beeps. Read once; production and Xcode Cmd-U runs (env unset)
    /// ring normally. The VISUAL flash is NOT suppressed by this — it's gated
    /// only on the user's `Preferences.bell` choice.
    static let suppressed =
        ProcessInfo.processInfo.environment["BB_SUPPRESS_BELL"] == "1"

    /// Install the flash overlay into `host` (one-time, from the view's init).
    /// `autoresizingMask` makes it track the host's size, so no per-`layout()`
    /// repositioning is needed. The caller controls z-order by where it calls
    /// this (the drop-target ring is added after, so it sits on top).
    func attach(to host: NSView) {
        flashView.frame = host.bounds
        flashView.autoresizingMask = [.width, .height]
        host.addSubview(flashView)
    }

    /// Reset the de-dup counter on session rebind so the first BEL of a new
    /// session always flashes.
    func resetCounter() {
        lastBellCounter = 0
    }

    /// Drive the visual flash from a fresh `session.$bellCounter` value,
    /// de-duped so a republished-but-unchanged counter doesn't re-pulse.
    func handleBellCounter(_ counter: UInt64) {
        guard counter > lastBellCounter else { return }
        lastBellCounter = counter
        flash()
    }

    private func flash() {
        guard Preferences.shared.bell == .visual else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            flashView.animator().alphaValue = 1.0
        } completionHandler: { [weak self] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                self?.flashView.animator().alphaValue = 0
            }
        }
    }

    /// Ring the system "no-op feedback" bell, unless suppressed under test.
    func ring() {
        guard !Self.suppressed else { return }
        NSSound.beep()
    }
}
