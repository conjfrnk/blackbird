import AppKit
import Carbon.HIToolbox
import Combine

/// Polls `IsSecureEventInputEnabled()` at 1 Hz while the window is key.
/// Publishes `isSecureInputActive` for any subscriber (e.g. the titlebar
/// indicator view). The global flag reflects *any* process holding
/// secure-input mode — we don't distinguish ownership, matching Terminal.app.
public final class SecureInputPoller {

    /// `true` when `IsSecureEventInputEnabled()` returns a non-zero value.
    @Published public private(set) var isSecureInputActive: Bool = false

    private var timer: Timer?

    public init() {}

    /// Start polling. Calls `refresh()` immediately so already-secure
    /// sessions show the lock without a 1 s delay. No-op if already running.
    public func start() {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop polling and invalidate the timer.
    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Read the OS global and update `isSecureInputActive` only on change.
    private func refresh() {
        let active = IsSecureEventInputEnabled()
        if active != isSecureInputActive {
            isSecureInputActive = active
        }
    }

    #if DEBUG
    /// Test hook: lets tests flip state without invoking the Carbon API.
    /// Release builds omit this surface entirely — Connor's rule for all
    /// test-only hooks.
    public func _injectSecureStateForTests(_ active: Bool) {
        isSecureInputActive = active
    }
    #endif
}

/// A 16×16 titlebar accessory icon that appears (unhides) whenever
/// `SecureInputPoller.isSecureInputActive` is true. Shows a `lock.fill`
/// SF Symbol at 12 pt in `.secondaryLabelColor`.
public final class SecureInputIndicatorView: NSView {

    private let imageView: NSImageView

    public init() {
        let frame = NSRect(x: 0, y: 0, width: 16, height: 16)
        let iv = NSImageView(frame: NSRect(x: 2, y: 2, width: 12, height: 12))
        if let symbol = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil) {
            iv.image = symbol
        }
        iv.contentTintColor = .secondaryLabelColor
        iv.imageScaling = .scaleProportionallyUpOrDown
        self.imageView = iv
        super.init(frame: frame)
        addSubview(iv)
        toolTip = "Secure keyboard entry is enabled"
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Set visibility: `true` shows the lock icon; `false` hides it.
    public func setActive(_ active: Bool) {
        isHidden = !active
    }
}
