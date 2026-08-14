// =============================================================================
// fp32_rnd_inc : IEEE 754 rounding-increment decision (combinational)
// -----------------------------------------------------------------------------
// 接口契约：
//   - g/r/s : guard / round / sticky bits below the kept significand LSB
//   - lsb   : LSB of the kept significand (ties-to-even reference)
//   - sgn   : result sign (used by the directed rounding modes)
//   - rm    : rounding mode, RISC-V encoding (see fp32_defs.vh)
//   - inc   : 1 -> add one ulp to the kept significand
// 实现要点：纯组合 case（带 default），无 latch；由 fp32_mult 例化两份
//           （普通路径与次正规路径各一份），替代软件化的 function 封装。
// =============================================================================

`include "fp32_defs.vh"

module fp32_rnd_inc (
    input  wire       g,
    input  wire       r,
    input  wire       s,
    input  wire       lsb,
    input  wire       sgn,
    input  wire [2:0] rm,
    output reg        inc
);
  always @(*) begin
    case (rm)
      `FP32_RM_RNE: inc = g & (r | s | lsb);     // ties to even
      `FP32_RM_RNA: inc = g;                     // ties away from zero
      `FP32_RM_RTZ: inc = 1'b0;
      `FP32_RM_RDN: inc = sgn & (g | r | s);     // toward -infinity
      `FP32_RM_RUP: inc = ~sgn & (g | r | s);    // toward +infinity
      default:      inc = g & (r | s | lsb);
    endcase
  end
endmodule
