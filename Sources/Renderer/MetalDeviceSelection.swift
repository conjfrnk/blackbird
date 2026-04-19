import Metal

/// Abstract GPU capabilities we care about when picking a device.
/// Mirrors the subset of `MTLDevice` properties `chooseGPU` consults
/// so the algorithm is testable with plain structs — `MTLDevice`
/// itself can't be fabricated in tests without a real system GPU.
public protocol GPUDeviceProperties: AnyObject {
    /// True for integrated GPUs (share system memory, lower power).
    /// Always false on Apple Silicon (the sole SoC GPU is reported as
    /// non-low-power even though it's effectively integrated); on Intel
    /// Macs, true for the Iris / UHD and false for the Radeon Pro.
    var isLowPower: Bool { get }

    /// True for external (eGPU) devices on a Thunderbolt enclosure.
    /// Avoid these for the terminal window: the user may unplug them
    /// mid-session, which tears down the MTLDevice and all resources.
    var isRemovable: Bool { get }
}

extension MTLDevice {
    // `MTLDevice` is already `AnyObject` since it's a Protocol-typed
    // class-only protocol, so this conformance is zero-cost. Swift 6
    // requires explicit conformance for protocol-typed method dispatch.
}

/// Pick the preferred GPU from a list, favoring integrated + internal.
/// Pure function on the abstracted properties so the selection policy
/// is exhaustively testable without needing a real `MTLDevice`.
///
/// Policy:
/// 1. Prefer a non-removable low-power (integrated) GPU when one
///    exists — matches Ghostty's strategy and avoids Alacritty's
///    known Intel-laptop dGPU pinning.
/// 2. Otherwise return nil so the caller falls back to the system
///    default. We don't try to second-guess beyond step 1 — a Mac
///    Pro / iMac Pro may have multiple discrete GPUs and the system
///    default is correct there.
public func chooseGPU<D: GPUDeviceProperties>(from devices: [D]) -> D? {
    devices.first(where: { $0.isLowPower && !$0.isRemovable })
}

/// Return the Metal device Blackbird prefers for the terminal window.
/// Wraps `chooseGPU` with live `MTLCopyAllDevices()` results and a
/// `MTLCreateSystemDefaultDevice()` fallback. Returns nil only when
/// the host has no Metal device at all.
public func preferredMetalDevice() -> MTLDevice? {
    let devices = MTLCopyAllDevices()
    // `MTLDevice` is `AnyObject`-conforming but Swift can't see the
    // protocol-typed cast through the array without a bridge. We
    // conform `MTLDevice` to `GPUDeviceProperties` by inspection —
    // the protocol's two properties are already on `MTLDevice` with
    // the same names and signatures.
    let wrapped: [AnyMetalDevice] = devices.map(AnyMetalDevice.init)
    if let pick = chooseGPU(from: wrapped) {
        return pick.device
    }
    return MTLCreateSystemDefaultDevice()
}

/// Thin wrapper so Swift's protocol-typed dispatch picks up
/// `isLowPower` / `isRemovable` via `GPUDeviceProperties` on arbitrary
/// `MTLDevice` values. Holds a strong reference — the wrapper's
/// lifetime is bounded to the `chooseGPU` call stack, well within any
/// reasonable `MTLCopyAllDevices` array lifetime.
final class AnyMetalDevice: GPUDeviceProperties {
    let device: MTLDevice
    init(_ device: MTLDevice) { self.device = device }
    var isLowPower: Bool { device.isLowPower }
    var isRemovable: Bool { device.isRemovable }
}
