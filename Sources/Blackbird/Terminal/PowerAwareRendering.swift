import Foundation

/// Computed target frame rate for the renderer, derived from OS-level
/// power / thermal / visibility state. See `preferredFrameRate(...)`
/// for the decision table.
///
/// Represented as an enum rather than a raw Int so the "pause the
/// render loop entirely" case is impossible to confuse with "render
/// at 0 fps" — the latter would deadlock the MTKView. Callers use
/// `.paused` to flip `MTKView.isPaused` on, and `.fps(n)` to set
/// `preferredFramesPerSecond` and flip `isPaused` off.
public enum TargetFrameRate: Equatable {
    case paused
    case fps(Int)
}

/// Compute the frame rate Blackbird should target given the OS's
/// current state. Pure function so it can be unit-tested without
/// spinning up an AppKit window or NSProcessInfo state.
///
/// Policy:
/// - **Occluded window** → `.paused`. If the user can't see us, we
///   shouldn't compute pixels. `CAMetalLayer.compositor` still holds
///   the previously-presented drawable, so unhiding restores the last
///   frame instantly.
///
///   How rendering resumes: `TerminalView` runs with
///   `enableSetNeedsDisplay = false` and is driven by MTKView's internal
///   `CVDisplayLink`. When `applyPowerAwareFrameRate` flips `isPaused`
///   back to `false`, MTKView's display link resumes on the next vsync
///   and the next draw tick renders the current snapshot. A snapshot
///   change that arrived during occlusion shows up on that first post-
///   un-occlude tick — there's a one-vsync latency floor before the
///   window becomes visible again, which is below perception for a
///   terminal workload. `setNeedsDisplay` is NOT the un-occlude driver
///   (earlier doc drift — `enableSetNeedsDisplay` is off). Audit
///   latency-power F6.
/// - **Low power mode on** → cap at 30. Mirrors Ghostty (Mitchell
///   Hashimoto: "if you're on battery and macOS wants to slow
///   Ghostty down, it can and we respect it"). 30 fps is still smooth
///   for a text workload and saves substantial GPU energy vs 60.
/// - **Thermal state .serious or .critical** → cap at 30. Prevents
///   the terminal from contributing to further thermal pressure
///   when the system is already hot.
/// - **Otherwise** → run at the display's native max (`nativeMaxFPS`),
///   which is 60 on a standard Retina and 120 on ProMotion.
///
/// Never return a value above `nativeMaxFPS` — asking for 120 on a
/// 60 Hz panel is wasteful (MTKView's CVDisplayLink will pin at
/// vblank anyway, but the Metal command-buffer allocator sizes buffers
/// for the stated rate, which we'd rather not oversize).
public func preferredFrameRate(
    isOccluded: Bool,
    isLowPowerMode: Bool,
    thermalState: ProcessInfo.ThermalState,
    nativeMaxFPS: Int
) -> TargetFrameRate {
    if isOccluded { return .paused }
    let cap = max(1, nativeMaxFPS)
    if isLowPowerMode {
        return .fps(min(30, cap))
    }
    switch thermalState {
    case .serious, .critical:
        return .fps(min(30, cap))
    case .nominal, .fair:
        return .fps(cap)
    @unknown default:
        // Future thermal state variants should default to unthrottled
        // rather than aggressively slow: macOS's own QoS system will
        // already be attenuating us via process priority.
        return .fps(cap)
    }
}
