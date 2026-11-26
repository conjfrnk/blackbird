import Metal

public protocol GPUDeviceProperties: AnyObject {
    /// Always false on Apple Silicon: the SoC GPU reports as non-low-power.
    var isLowPower: Bool { get }

    /// True for eGPUs; unplugging one mid-session tears down the MTLDevice and all resources.
    var isRemovable: Bool { get }
}

/// nil means "use the system default"; Apple Silicon and Macs with no iGPU land there.
public func chooseGPU<D: GPUDeviceProperties>(from devices: [D]) -> D? {
    devices.first(where: { $0.isLowPower && !$0.isRemovable })
}

public func preferredMetalDevice() -> MTLDevice? {
    let devices = MTLCopyAllDevices()
    let wrapped: [AnyMetalDevice] = devices.map(AnyMetalDevice.init)
    if let pick = chooseGPU(from: wrapped) {
        return pick.device
    }
    return MTLCreateSystemDefaultDevice()
}

/// `MTLDevice.isLowPower` / `.isRemovable` are deprecated in the macOS 27 SDK: x86_64 slice only.
final class AnyMetalDevice: GPUDeviceProperties {
    let device: MTLDevice
    init(_ device: MTLDevice) { self.device = device }
    #if arch(x86_64)
    var isLowPower: Bool { device.isLowPower }
    var isRemovable: Bool { device.isRemovable }
    #else
    var isLowPower: Bool { false }
    var isRemovable: Bool { false }
    #endif
}
