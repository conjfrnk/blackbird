import AppKit
import Darwin
import os

/// Private CoreGraphics API for setting the gaussian blur applied to content
/// BEHIND a window. Used by iTerm2, Terminal.app, Safari, and others since
/// ~10.7. Not in any public header — resolve via `dlsym` at launch so the
/// app links cleanly without a bridging header.
///
/// If the symbol ever disappears (Apple could pull it), the app still runs;
/// blur calls become no-ops.
private let blurLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "windowBlur")

/// One-shot diagnostic gate for non-zero CGS return codes. The private API
/// can fail per-call (entitlement / SIP changes, future macOS ABI drift);
/// without a log the symptom is "blur silently doesn't apply" and the
/// operator has no way to tell the symbol resolved-but-rejected from the
/// dlsym-missed-it case. Gate behind a single fire so a broken-entitlement
/// state doesn't flood the unified log on every window create. L-5 audit fix.
private let didLogBlurRC = OSAllocatedUnfairLock(initialState: false)

private let cgsBlur: ((_ windowNumber: Int) -> (Int32) -> Void)? = {
    let handle = dlopen(nil, RTLD_NOW)
    guard let getConn = dlsym(handle, "CGSMainConnectionID") else { return nil }
    guard let setBlur = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
    let getConnFn = unsafeBitCast(getConn, to: (@convention(c) () -> UInt32).self)
    let setBlurFn = unsafeBitCast(setBlur, to: (@convention(c) (UInt32, UInt32, Int32) -> Int32).self)
    return { windowNumber in
        let conn = getConnFn()
        let wid = UInt32(windowNumber)
        return { radius in
            let rc = setBlurFn(conn, wid, radius)
            if rc != 0 {
                didLogBlurRC.withLock { logged in
                    if !logged {
                        logged = true
                        blurLogger.warning("CGSSetWindowBackgroundBlurRadius returned \(rc, privacy: .public) — entitlement may have changed; window blur unavailable")
                    }
                }
            }
        }
    }
}()

extension NSWindow {
    /// Apply a gaussian blur to content behind this window. Radius 0 disables
    /// the blur. No-op when the window hasn't been ordered in yet
    /// (`windowNumber <= 0`) or when the private CGS symbol is unavailable.
    func setBackgroundBlurRadius(_ radius: Int) {
        guard windowNumber > 0, let blur = cgsBlur else { return }
        blur(windowNumber)(Int32(radius))
    }
}
