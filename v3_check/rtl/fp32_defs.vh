// =============================================================================
// fp32_defs.vh : shared constants for the fp32_mult datapath
// =============================================================================
`ifndef FP32_DEFS_VH
`define FP32_DEFS_VH

// rounding modes (RISC-V rm field encoding)
`define FP32_RM_RNE 3'b000   // round to nearest, ties to even
`define FP32_RM_RTZ 3'b001   // round toward zero
`define FP32_RM_RDN 3'b010   // round down (toward -infinity)
`define FP32_RM_RUP 3'b011   // round up (toward +infinity)
`define FP32_RM_RNA 3'b100   // round to nearest, ties away from zero

// ----------------------------------------------------------------------------
// data-type ids (fmt[4:0]); the 32-bit container holds the value right-aligned:
// FP: sign[31], exponent[30:31-EW], fraction[F-1:0]; INT: value[N-1:0]
// ----------------------------------------------------------------------------
`define FP32_FMT_FP32    5'd0    // IEEE binary32      : 1/8/23,  bias 127
`define FP32_FMT_FP16    5'd1    // IEEE binary16      : 1/5/10,  bias 15
`define FP32_FMT_BF16    5'd2    // bfloat16           : 1/8/7,   bias 127
`define FP32_FMT_TF32    5'd3    // TensorFloat-32     : 1/8/10,  bias 127
`define FP32_FMT_BF32    5'd4    // bfloat32           : 1/8/15,  bias 127
`define FP32_FMT_E5M2    5'd5    // FP8 (OCP E5M2)     : 1/5/2,   bias 15
`define FP32_FMT_E4M3    5'd6    // FP8 (OCP E4M3FN)   : 1/4/3,   bias 7 (no Inf)
`define FP32_FMT_E2M1    5'd7    // FP4 (OCP E2M1)     : 1/2/1,   bias 1
`define FP32_FMT_INT4U   5'd8    // unsigned 4-bit  -> 8-bit  product
`define FP32_FMT_INT4S   5'd9    // signed   4-bit  -> 8-bit  product
`define FP32_FMT_INT8U   5'd10   // unsigned 8-bit  -> 16-bit product
`define FP32_FMT_INT8S   5'd11   // signed   8-bit  -> 16-bit product
`define FP32_FMT_INT16U  5'd12   // unsigned 16-bit -> 32-bit product
`define FP32_FMT_INT16S  5'd13   // signed   16-bit -> 32-bit product

// packed (SIMD) modes: lanes right-aligned in the 32-bit containers,
// per-lane layout identical to the scalar format (sign/exp/frac at the
// lane's own bit positions). Lane i of a/b at bits [i*LW +: LW].
`define FP32_FMT_FP16X2    5'd14  // 2 x FP16        (LW 16)
`define FP32_FMT_BF16X2    5'd15  // 2 x BF16        (LW 16)
`define FP32_FMT_E4M3X4    5'd16  // 4 x FP8 E4M3FN  (LW 8)
`define FP32_FMT_E5M2X4    5'd17  // 4 x FP8 E5M2    (LW 8)
`define FP32_FMT_E2M1X4    5'd18  // 4 x FP4 E2M1    (LW 4)
`define FP32_FMT_INT8UX4   5'd19  // 4 x INT8U  -> 4x16-bit products
`define FP32_FMT_INT8SX4   5'd20  // 4 x INT8S  -> 4x16-bit products
`define FP32_FMT_INT4UX4   5'd21  // 4 x INT4U  -> 4x8-bit  products
`define FP32_FMT_INT4SX4   5'd22  // 4 x INT4S  -> 4x8-bit  products

`endif
