import Metal
import MetalKit

public final class MetalRenderer {

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState

    public init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        guard let library = device.makeDefaultLibrary() else {
            // Xcode compiles .metal files into the default library automatically.
            return nil
        }
        guard let vertexFn = library.makeFunction(name: "vertex_solid"),
              let fragmentFn = library.makeFunction(name: "fragment_solid")
        else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pso
    }

    public func render(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        var uniforms = Uniforms(clearColor: SIMD4<Float>(0.04, 0.04, 0.04, 1.0))
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

struct Uniforms {
    var clearColor: SIMD4<Float>
}
