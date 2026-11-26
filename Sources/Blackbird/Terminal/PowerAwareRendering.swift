import Foundation

/// `.paused` flips `MTKView.isPaused` on; a 0 fps rate would deadlock the MTKView instead.
public enum TargetFrameRate: Equatable {
    case paused
    case fps(Int)
}

private let throttledFPS = 30

/// `TerminalView` runs with `enableSetNeedsDisplay = false`: un-pausing resumes MTKView's
/// display link on the next vsync, and `setNeedsDisplay` is not the un-occlude driver.
public func preferredFrameRate(
    isOccluded: Bool,
    isLowPowerMode: Bool,
    thermalState: ProcessInfo.ThermalState,
    nativeMaxFPS: Int
) -> TargetFrameRate {
    if isOccluded { return .paused }
    let cap = max(1, nativeMaxFPS)
    if isLowPowerMode {
        return .fps(min(throttledFPS, cap))
    }
    switch thermalState {
    case .serious, .critical:
        return .fps(min(throttledFPS, cap))
    case .nominal, .fair:
        return .fps(cap)
    @unknown default:
        return .fps(cap)
    }
}
