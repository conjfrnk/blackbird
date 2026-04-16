import simd

/// Per-cell instance data uploaded to the GPU each frame. 48-byte stride.
/// Field order must match the `CellInstance` struct in Shaders.metal exactly.
struct CellInstance {
    var cellPosPx: SIMD2<Float>   //  8 bytes — cell position in points
    var uvOrigin: SIMD2<Float>    //  8 bytes — glyph UV in atlas
    var uvSize: SIMD2<Float>      //  8 bytes
    var fgColor: SIMD4<Float>     // 16 bytes — RGBA foreground
    var bgColor: SIMD4<Float>     // 16 bytes — RGBA background
}
