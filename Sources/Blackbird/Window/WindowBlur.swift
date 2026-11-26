import AppKit
import Darwin
import os

private let blurLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "windowBlur")

private let didLogBlurRC = OSAllocatedUnfairLock(initialState: false)

// Private CoreGraphics API, not in any public header: resolved via `dlsym`, and blur is a no-op if the symbol is missing.
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
    /// Radius 0 disables the blur.
    func setBackgroundBlurRadius(_ radius: Int) {
        guard windowNumber > 0, let blur = cgsBlur else { return }
        blur(windowNumber)(Int32(radius))
    }
}
