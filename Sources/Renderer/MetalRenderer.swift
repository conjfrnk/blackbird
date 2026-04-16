import Metal
import MetalKit
import AppKit

public final class MetalRenderer {

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    public let atlas: GlyphAtlas
    public let metrics: CellMetrics

    // Preallocated instance buffer. Growable via reallocateInstanceBuffer.
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int

    public init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        guard let library = device.makeDefaultLibrary() else { return nil }
        guard let vertexFn = library.makeFunction(name: "vertex_cell"),
              let fragmentFn = library.makeFunction(name: "fragment_cell") else { return nil }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFn
        desc.fragmentFunction = fragmentFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }

        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        guard let atlas = GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 1024) else {
            return nil
        }

        // Start with space for a full 200x80 grid; grow as needed.
        let startCap = 200 * 80
        guard let buf = device.makeBuffer(
            length: startCap * MemoryLayout<CellInstance>.stride,
            options: [.storageModeShared]
        ) else { return nil }

        self.device = device
        self.commandQueue = queue
        self.pipelineState = pso
        self.atlas = atlas
        self.metrics = metrics
        self.instanceBuffer = buf
        self.instanceCapacity = startCap
    }

    /// Write cell instance data into `instanceBuffer`. Returns the count
    /// of instances actually written (= non-empty cells).
    @discardableResult
    private func buildInstances(snapshot: BBSnapshot) -> Int {
        let needed = snapshot.cols * snapshot.rows
        if needed > instanceCapacity {
            let newCap = max(needed, instanceCapacity * 2)
            if let newBuf = device.makeBuffer(
                length: newCap * MemoryLayout<CellInstance>.stride,
                options: [.storageModeShared]
            ) {
                instanceBuffer = newBuf
                instanceCapacity = newCap
            }
        }

        let ptr = instanceBuffer.contents().assumingMemoryBound(to: CellInstance.self)
        var count = 0
        let cellW = Float(metrics.cellWidth)
        let cellH = Float(metrics.cellHeight)

        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                guard let ch = snapshot.character(at: col, row: row), ch != " " else { continue }
                guard let scalar = String(ch).unicodeScalars.first else { continue }
                guard let entry = atlas.lookupOrInsert(scalar: scalar) else { continue }
                ptr[count] = CellInstance(
                    cellPosPx: SIMD2<Float>(Float(col) * cellW, Float(row) * cellH),
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    _pad: .zero
                )
                count += 1
            }
        }
        return count
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        if let snap = snapshot {
            let instanceCount = buildInstances(snapshot: snap)
            if instanceCount > 0 {
                var uniforms = FrameUniforms(
                    viewportPx: SIMD2<Float>(Float(view.drawableSize.width),
                                             Float(view.drawableSize.height)),
                    cellSizePx: SIMD2<Float>(Float(metrics.cellWidth),
                                             Float(metrics.cellHeight))
                )
                encoder.setRenderPipelineState(pipelineState)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<FrameUniforms>.size, index: 1)
                encoder.setFragmentTexture(atlas.texture, index: 0)
                encoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: instanceCount
                )
            }
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

struct FrameUniforms {
    var viewportPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
}
