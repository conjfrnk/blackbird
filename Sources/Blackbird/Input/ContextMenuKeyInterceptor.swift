import AppKit

protocol ContextMenuKeyReceiving: AnyObject {
    func receiveContextMenuChord(_ event: NSEvent) -> Bool
}

/// AppKit handles Ctrl+Return ("show the contextual menu") inside `NSApplication.sendEvent`, before any
/// `keyDown`; a local monitor runs first. Only the key-down is consumed, so kitty release reporting stays paired.
enum ContextMenuKeyInterceptor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            route(event, firstResponder: event.window?.firstResponder)
        }
    }

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
