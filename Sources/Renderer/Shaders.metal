#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    float2 cellPosPx;
    float2 quadSizePx;    // per-cell quad size: cellSizePx for narrow, 2x for wide (CJK, emoji)
    float2 uvOrigin;
    float2 uvSize;
    float4 fgColor;
    float4 bgColor;
    uint4  attrs;         // .x = attribute bitmask (bit 0 = link hover underline); rest reserved/padding
};

struct FrameUniforms {
    float2 viewportPx;
    float2 cellSizePx;
    float4 accentColor;   // sRGB RGBA underline colour for accent attributes
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 fgColor;
    float4 bgColor;
    float4 accentColor;   // plumbed in via uniform, stamped per-vertex for the fragment
    uint   flags;
    float2 localPx;       // position within the cell's quad, in points
    float2 quadSizePx;    // cell quad size (same for all 6 verts per instance)
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
    float2 cornerPx = inst.cellPosPx + corners[vid] * inst.quadSizePx;

    // Convert pixel space -> clip space: top-left (0,0), bottom-right (viewport).
    float2 ndc;
    ndc.x = (cornerPx.x / u.viewportPx.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (cornerPx.y / u.viewportPx.y) * 2.0;

    VertexOut out;
    out.position = float4(ndc, 0, 1);
    out.uv = inst.uvOrigin + uvs[vid] * inst.uvSize;
    out.fgColor = inst.fgColor;
    out.bgColor = inst.bgColor;
    out.accentColor = u.accentColor;
    out.flags = inst.attrs.x;
    out.localPx = corners[vid] * inst.quadSizePx;
    out.quadSizePx = inst.quadSizePx;
    return out;
}

fragment float4 fragment_cell(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    float coverage = atlas.sample(s, in.uv).r;
    // Blend fg glyph over bg. coverage = 0 → pure bg, coverage = 1 → pure fg.
    float4 base = mix(in.bgColor, in.fgColor, coverage);

    // Accent-coloured underline for attribute bit 0 (currently the OSC 8
    // hover highlight). Drawn as a 2-point band along the bottom of the
    // cell, fully opaque accent — sits over whatever glyph/bg came before.
    if ((in.flags & 1u) != 0u) {
        float distFromBottom = in.quadSizePx.y - in.localPx.y;
        if (distFromBottom <= 2.0) {
            return in.accentColor;
        }
    }
    return base;
}

struct CursorUniforms {
    float2 viewportPx;
    float2 cursorPosPx;
    float2 cellSizePx;
    float4 color;
    float strokeWidthPx;
    float filled;           // 1.0 = solid (focused), 0.0 = outline (block only)
    uint  shape;            // 0 = block, 1 = bar, 2 = underline, 3 = hidden
    float _pad;
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
    // DECSCUSR shape dispatch. Shape 3 (hidden) never reaches the shader —
    // the CPU path skips the draw entirely.
    // Bar: 2-pixel vertical column on the left edge of the cell.
    if (u.shape == 1u) {
        if (p.x >= 2.0) discard_fragment();
        return u.color;
    }
    // Underline: 2-pixel horizontal band at the bottom of the cell.
    if (u.shape == 2u) {
        if ((s.y - p.y) >= 2.0) discard_fragment();
        return u.color;
    }
    // Block (shape == 0). Focused = solid; unfocused = outline stroke.
    if (u.filled > 0.5) {
        return u.color;
    }
    bool stroke =
        p.x < u.strokeWidthPx ||
        p.y < u.strokeWidthPx ||
        (s.x - p.x) < u.strokeWidthPx ||
        (s.y - p.y) < u.strokeWidthPx;
    if (!stroke) discard_fragment();
    return u.color;
}
