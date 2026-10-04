import AppKit

/// A first responder that wants the Return chords AppKit would otherwise keep
/// for itself. `TerminalView` conforms.
protocol ContextMenuKeyReceiving: AnyObject {
    /// Returns true when the key was delivered; false leaves the event to
    /// AppKit (the standard behavior) so a view that can't act on it doesn't
    /// silently eat it.
    func receiveContextMenuChord(_ event: NSEvent) -> Bool
}

/// Re-routes Ctrl+Return to the focused terminal.
///
/// AppKit treats Ctrl+Return as "show the contextual menu" and handles it
/// inside `NSApplication.sendEvent`, before the window or the first
/// responder's `keyDown` runs. The terminal therefore never saw the key: the
/// right-click menu popped instead and a TUI (Claude Code's Ctrl+Enter send)
/// got nothing. A local event monitor runs first in `sendEvent`, so it can hand
/// the event straight to the view and consume it. Only a focused
/// `ContextMenuKeyReceiving` responder qualifies; text fields (find bar,
/// Settings) keep the standard behavior. Only the key-down is consumed — the
/// matching key-up is delivered to the window normally (verified with real
/// events), so kitty release reporting stays paired.
enum ContextMenuKeyInterceptor {
    private static var monitor: Any?

    /// Idempotent; call once at launch.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event, firstResponder: event.window?.firstResponder)
        }
    }

    /// The monitor body, split out so it is testable without a live monitor.
    /// Returns nil when the receiver took the event, else the event untouched.
    static func route(_ event: NSEvent, firstResponder: NSResponder?) -> NSEvent? {
        guard event.type == .keyDown,
              KeyEventClassifier.isContextMenuKeyChord(
                  keyCode: event.keyCode, modifierFlags: event.modifierFlags
              ),
              let receiver = firstResponder as? ContextMenuKeyReceiving
        else { return event }
        return receiver.receiveContextMenuChord(event) ? nil : event
    }
}
