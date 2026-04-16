import simd

/// Per-cell instance data uploaded to the GPU each frame. 32-byte stride.
/// Field order must match the `CellInstance` struct in Shaders.metal.
/// `_pad` reserved for fg/bg colors (Plan 5 wires the palette).
struct CellInstance {
    var cellPosPx: SIMD2<Float>   //  8 bytes
    var uvOrigin: SIMD2<Float>    //  8 bytes
    var uvSize: SIMD2<Float>      //  8 bytes
    var _pad: SIMD2<Float>        //  8 bytes reserved
}
