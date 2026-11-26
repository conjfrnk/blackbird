import AppKit
import Foundation

/// Main-thread only.
final class BellController {

    private final class FlashView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            layer?.backgroundColor = gridOverlayTint
        }
    }

    private let flashView: FlashView = {
        let v = FlashView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor = v.gridOverlayTint
        v.alphaValue = 0
        return v
    }()

    private var lastBellCounter: UInt64 = 0

    static let suppressed =
        ProcessInfo.processInfo.environment["BB_SUPPRESS_BELL"] == "1"

    /// Z-order follows call order: subviews the caller adds after this sit above the flash.
    func attach(to host: NSView) {
        flashView.frame = host.bounds
        flashView.autoresizingMask = [.width, .height]
        host.addSubview(flashView)
    }

    /// Called on session rebind so the first BEL of a new session always flashes.
    func resetCounter() {
        lastBellCounter = 0
    }

    func handleBellCounter(_ counter: UInt64) {
        guard counter > lastBellCounter else { return }
        lastBellCounter = counter
        flash()
    }

    private func flash() {
        let style = Preferences.shared.bell
        if style.sounds && !Self.suppressed {
            NSSound.beep()
        }
        guard style.flashes else { return }
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

    func ring() {
        guard !Self.suppressed else { return }
        NSSound.beep()
    }
}
