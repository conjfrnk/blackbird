import Metal
import MetalKit

/// Owns the Metal rendering pipeline for a single TerminalView. Stateful: the
/// caller (TerminalView's MTKView delegate) calls `render(in:)` each frame.
///
/// Plan 3 Task 1 scope: clears the drawable to black via MTKView's clearColor.
/// Subsequent tasks add shader pipeline, glyph atlas, per-cell instancing.
public final class MetalRenderer {

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue

    public init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
    }

    /// Issue a single frame's draw commands for `view`. No-op if the view has
    /// no current drawable (window not yet on screen).
    public func render(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        // Plan 3 Task 1: just clear. Future tasks insert real geometry here.
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
