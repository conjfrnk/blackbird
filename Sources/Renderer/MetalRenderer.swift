import Metal
import MetalKit
import AppKit

public final class MetalRenderer {

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let cursorPipelineState: MTLRenderPipelineState
    public let atlas: GlyphAtlas
    public let metrics: CellMetrics

    // Preallocated instance buffer. Growable via reallocateInstanceBuffer.
    private var instanceBuffer: MTLBuffer
    private var instanceCapacity: Int

    public init?(device: MTLDevice, metrics: CellMetrics, scale: CGFloat = 2.0) {
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

        guard let cursorVertex = library.makeFunction(name: "vertex_cursor"),
              let cursorFragment = library.makeFunction(name: "fragment_cursor") else { return nil }
        let cursorDesc = MTLRenderPipelineDescriptor()
        cursorDesc.vertexFunction = cursorVertex
        cursorDesc.fragmentFunction = cursorFragment
        cursorDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        // Cursor is opaque white — no blending.
        guard let cursorPSO = try? device.makeRenderPipelineState(descriptor: cursorDesc) else { return nil }

        guard let atlas = GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: 1024, scale: scale) else {
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
        self.cursorPipelineState = cursorPSO
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
        let cellsPtr = snapshot.cellsPointer

        for row in 0..<snapshot.rows {
            for col in 0..<snapshot.cols {
                let idx = row * snapshot.cols + col
                let cell = cellsPtr[idx]
                let scalar = cell.ch
                let fg = Self.rgbToSIMD(cell.fg)
                let bg = Self.rgbToSIMD(cell.bg)
                let hasBg = cell.bg != 0x000000  // non-black bg → need to render the cell

                // Render cell if it has a glyph OR a non-default background.
                if scalar != 0 && scalar != 0x20 /* space */ {
                    if let us = Unicode.Scalar(scalar),
                       let entry = atlas.lookupOrInsert(scalar: us) {
                        ptr[count] = CellInstance(
                            cellPosPx: SIMD2<Float>(Float(col) * cellW, Float(row) * cellH),
                            uvOrigin: entry.uvOrigin,
                            uvSize: entry.uvSize,
                            fgColor: fg,
                            bgColor: bg
                        )
                        count += 1
                    }
                } else if hasBg {
                    // Space with colored background (status lines, vim highlights).
                    // Draw a full-cell quad with zero coverage → pure bg fill.
                    ptr[count] = CellInstance(
                        cellPosPx: SIMD2<Float>(Float(col) * cellW, Float(row) * cellH),
                        uvOrigin: .zero,
                        uvSize: .zero,
                        fgColor: fg,
                        bgColor: bg
                    )
                    count += 1
                }
            }
        }
        return count
    }

    private static func rgbToSIMD(_ rgb: UInt32) -> SIMD4<Float> {
        let r = Float((rgb >> 16) & 0xFF) / 255.0
        let g = Float((rgb >> 8) & 0xFF) / 255.0
        let b = Float(rgb & 0xFF) / 255.0
        return SIMD4<Float>(r, g, b, 1.0)
    }

    public func render(in view: MTKView, snapshot: BBSnapshot?, focused: Bool) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        if let snap = snapshot {
            // Viewport in points, not pixels. NDC conversion in the shader
            // divides point positions by point viewport, giving a scale-
            // independent result that the hardware rasterizes to the drawable's
            // pixel space. Text stays at its absolute cell-sized position as
            // the window grows/shrinks, with empty space on the right/bottom
            // when the grid hasn't caught up yet (which synchronous
            // session.resize now eliminates).
            let viewportPoints = SIMD2<Float>(
                Float(view.bounds.size.width),
                Float(view.bounds.size.height)
            )
            _ = snap
            let cellSizePoints = SIMD2<Float>(
                Float(metrics.cellWidth),
                Float(metrics.cellHeight)
            )
            let instanceCount = buildInstances(snapshot: snap)
            if instanceCount > 0 {
                var uniforms = FrameUniforms(
                    viewportPx: viewportPoints,
                    cellSizePx: cellSizePoints
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
            // Cursor position in viewport rows. When the user is scrolled back
            // into history (displayOffset > 0), the live cursor_row is offset
            // downward on-screen by that amount: rows 0..displayOffset-1 show
            // scrollback, and the live grid starts at screen row displayOffset.
            // If the resulting row falls below the viewport, the live cursor
            // isn't visible and we skip drawing it — scrolling back should
            // never show a phantom cursor on a scrollback line.
            let screenCursorRow = snap.cursorRow + snap.displayOffset
            if snap.cursorVisible,
               snap.cursorCol < snap.cols,
               screenCursorRow < snap.rows {
                var cu = CursorUniforms(
                    viewportPx: viewportPoints,
                    cursorPosPx: SIMD2<Float>(Float(snap.cursorCol) * Float(metrics.cellWidth),
                                              Float(screenCursorRow) * Float(metrics.cellHeight)),
                    cellSizePx: cellSizePoints,
                    color: SIMD4<Float>(1, 1, 1, 1),
                    strokeWidthPx: 1.0,
                    filled: focused ? 1.0 : 0.0,
                    _pad: .zero
                )
                encoder.setRenderPipelineState(cursorPipelineState)
                encoder.setVertexBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
                encoder.setFragmentBytes(&cu, length: MemoryLayout<CursorUniforms>.size, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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

struct CursorUniforms {
    var viewportPx: SIMD2<Float>
    var cursorPosPx: SIMD2<Float>
    var cellSizePx: SIMD2<Float>
    var color: SIMD4<Float>
    var strokeWidthPx: Float
    var filled: Float       // 1.0 = solid block (window focused), 0.0 = outline
    var _pad: SIMD2<Float>
}
