#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    float2 cellPosPx;
    float2 uvOrigin;
    float2 uvSize;
    float2 _pad;
};

struct FrameUniforms {
    float2 viewportPx;       // pixel dimensions of the drawable
    float2 cellSizePx;       // per-cell pixel size
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertex_cell(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    const device CellInstance* instances [[buffer(0)]],
    constant FrameUniforms& u [[buffer(1)]]
) {
    // Two-triangle quad corners, CCW order.
    float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    float2 uvs[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };

    CellInstance inst = instances[iid];
    float2 cornerPx = inst.cellPosPx + corners[vid] * u.cellSizePx;

    // Convert pixel space -> clip space: top-left (0,0), bottom-right (viewport).
    float2 ndc;
    ndc.x = (cornerPx.x / u.viewportPx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (cornerPx.y / u.viewportPx.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0, 1);
    out.uv = inst.uvOrigin + uvs[vid] * inst.uvSize;
    return out;
}

fragment float4 fragment_cell(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float coverage = atlas.sample(s, in.uv).r;
    // White glyph on black background.
    return float4(1.0, 1.0, 1.0, coverage);
}

struct CursorUniforms {
    float2 viewportPx;
    float2 cursorPosPx;
    float2 cellSizePx;
    float4 color;
    float strokeWidthPx;
    float filled;           // 1.0 = solid block (focused), 0.0 = outline
    float2 _pad;
};

struct CursorOut {
    float4 position [[position]];
    float2 localPx;
};

vertex CursorOut vertex_cursor(
    uint vid [[vertex_id]],
    constant CursorUniforms& u [[buffer(0)]]
) {
    float2 corners[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1)
    };
    float2 cornerPx = u.cursorPosPx + corners[vid] * u.cellSizePx;
    float2 ndc;
    ndc.x = (cornerPx.x / u.viewportPx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (cornerPx.y / u.viewportPx.y) * 2.0;

    CursorOut out;
    out.position = float4(ndc, 0, 1);
    out.localPx = corners[vid] * u.cellSizePx;
    return out;
}

fragment float4 fragment_cursor(
    CursorOut in [[stage_in]],
    constant CursorUniforms& u [[buffer(0)]]
) {
    float2 p = in.localPx;
    float2 s = u.cellSizePx;
    if (u.filled > 0.5) {
        // Focused: fill the whole cell.
        return u.color;
    }
    // Unfocused: draw only the stroke band.
    bool stroke =
        p.x < u.strokeWidthPx ||
        p.y < u.strokeWidthPx ||
        (s.x - p.x) < u.strokeWidthPx ||
        (s.y - p.y) < u.strokeWidthPx;
    if (!stroke) discard_fragment();
    return u.color;
}
