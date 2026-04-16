#include <metal_stdlib>
using namespace metal;

// Plan 3 Task 2: full-screen quad with a uniform color.
// Subsequent tasks extend this file with per-instance data and atlas sampling.

struct Uniforms {
    float4 clearColor;
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut vertex_solid(uint vid [[vertex_id]]) {
    // Two-triangle fullscreen quad via clip-space corners.
    float2 corners[6] = {
        float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
        float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0)
    };
    VertexOut out;
    out.position = float4(corners[vid], 0.0, 1.0);
    return out;
}

fragment float4 fragment_solid(VertexOut in [[stage_in]],
                               constant Uniforms& u [[buffer(0)]]) {
    return u.clearColor;
}
