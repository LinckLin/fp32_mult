// =============================================================================
// fp32_mult : 6-stage pipelined multi-format multiplier with SIMD packing
//   (S3-split variant: S3a merge+LZ+shift, S3b align+extract)
//   FP (IEEE 754 semantics): FP32, FP16, BF16, TF32, BF32, FP8-E5M2,
//                            FP8-E4M3FN, FP4-E2M1
//   INT (wrap): INT4/INT8/INT16, signed/unsigned
//   SIMD (packed, same datapath): FP16x2, BF16x2, FP8-E4M3x4, FP8-E5M2x4,
//                                 FP4-E2M1x4, INT8U/Sx4, INT4U/Sx4
// -----------------------------------------------------------------------------
// 接口契约：
//   - 输入侧：in_valid 拉高后 a/b/fmt/rm 保持稳定，直到 in_ready 同拍握手。
//   - 输出侧：out_valid 与 result/fflags 同拍有效；out_ready 拉低时全
//     流水线冻结；握手 = out_valid & out_ready 同拍为真。
//   - 容器：标量 32 位右对齐；SIMD 把 K 个 lane 右对齐打包进 32 位
//     （lane i 在 [i*LW +: LW]，LW=16/8/4），每 lane 位布局与对应标量
//     格式一致。result[63:0]：标量在 [31:0]；FP16x2/BF16x2 于 [31:0]、
//     FP8x4 于 [31:0]、FP4x4 于 [15:0]；INT8x4 为 4x16 位于 [63:0]；
//     INT4x4 为 4x8 位于 [31:0]。fflags[15:0] = 4 lane x 4 位，lane i 在
//     [4i+3:4i]（2-lane 模式只用低 8 位）；标量在 [3:0]。
//   - rm 对 INT 无效；INT 不置异常标志。
// 实现要点（最大硬件复用 + SIMD）：
//   - 24x24 阵列重构为 4 个 12x12 子乘器（总门数不变）：标量合并为 48 位
//     积；2-lane 用对角子乘器；4-lane 每个子乘器独立算一路。
//   - SIMD lane 数据通路 = 标量 S1/S3/S4/S5 的微型化（24/12 位宽），公式
//     同构：E3 = E+1-lz、次正规移位 k = 13-E3、舍入复用 fp32_rnd_inc，
//     经 generate 结构性复制，无新增算术模块。
//   - 5 级流水、吞吐 1 组/拍（SIMD 下 1 组 = K 个结果）。
//   - 控制 FF 异步低复位；数据 FF 不复位。
//   - 可综合 Verilog-2001：无 logic/always_ff/function/task/procedural for。
// =============================================================================

`include "fp32_defs.vh"

module fp32_mult (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [4:0]  fmt,
    input  wire [2:0]  rm,
    input  wire        out_ready,
    output wire        in_ready,
    output wire        out_valid,
    output wire [63:0] result,
    output wire [15:0] fflags
);

  wire stall    = out_valid & ~out_ready;
  assign in_ready = ~stall;

  // ==========================================================================
  // Pipeline registers
  // ==========================================================================
  reg        r1_valid, r2_valid, r3_valid, r4_valid, r5_valid;
  reg        r1_any_nan, r1_any_inf, r1_any_zero, r1_zero_inf, r1_nv;
  reg [31:0] r1_nan_res;
  reg        r1_rs;
  reg [23:0] r1_sig_a, r1_sig_b;
  reg signed [9:0] r1_exp_sum;
  reg [2:0]  r1_rm;
  reg [4:0]  r1_f, r1_n, r1_lw;
  reg [3:0]  r1_ew;
  reg [5:0]  r1_align_sh;
  reg        r1_is_int, r1_is_signed, r1_no_inf, r1_packed;
  reg [2:0]  r1_nlanes;
  reg [4:0]  r1_lane_f;
  reg [3:0]  r1_lane_ew;
  reg        r1_lane_no_inf, r1_lane_is_int, r1_lane_signed;
  reg        r2_any_nan, r2_any_inf, r2_any_zero, r2_zero_inf, r2_nv;
  reg [31:0] r2_nan_res;
  reg        r2_rs;
  reg signed [9:0] r2_exp_sum;
  reg [2:0]  r2_rm;
  reg [3:0]  r2_ew;
  reg [4:0]  r2_f, r2_n, r2_lw;
  reg [5:0]  r2_align_sh;
  reg        r2_is_int, r2_is_signed, r2_no_inf, r2_packed;
  reg [2:0]  r2_nlanes;
  reg [4:0]  r2_lane_f;
  reg [3:0]  r2_lane_ew;
  reg        r2_lane_no_inf, r2_lane_is_int, r2_lane_signed;
  reg        r3_any_nan, r3_any_inf, r3_any_zero, r3_zero_inf, r3_nv;
  reg [31:0] r3_nan_res;
  reg        r3_rs;
  reg signed [9:0] r3_exp;
  reg [23:0] r3_m;
  reg        r3_g, r3_r, r3_s;
  reg [47:0] r3_psh;
  reg [2:0]  r3_rm;
  reg [3:0]  r3_ew;
  reg [4:0]  r3_f, r3_n, r3_lw;
  reg        r3_is_int, r3_is_signed, r3_no_inf, r3_packed;
  reg [2:0]  r3_nlanes;
  reg [4:0]  r3_lane_f;
  reg [3:0]  r3_lane_ew;
  reg        r3_lane_no_inf, r3_lane_is_int, r3_lane_signed;
  reg        r4_any_nan, r4_any_inf, r4_any_zero, r4_zero_inf, r4_nv;
  reg [31:0] r4_nan_res;
  reg        r4_rs;
  reg signed [9:0] r4_exp;
  reg [23:0] r4_m;
  reg        r4_g, r4_r, r4_s;
  /* verilator lint_off UNUSEDSIGNAL */  // r4_psh[47:32] unused by INT results
  reg [47:0] r4_psh;
  /* verilator lint_on UNUSEDSIGNAL */
  reg [22:0] r4_fpre;
  reg        r4_sg, r4_sr, r4_ss;
  reg        r4_inc_n, r4_inc_s;
  reg [2:0]  r4_rm;
  reg [3:0]  r4_ew;
  reg [4:0]  r4_f, r4_n, r4_lw;
  reg        r4_is_int, r4_is_signed, r4_no_inf, r4_packed;
  reg [2:0]  r4_nlanes;
  reg [4:0]  r4_lane_f;
  reg [3:0]  r4_lane_ew;
  reg        r4_lane_no_inf, r4_lane_is_int, r4_lane_signed;
  reg [63:0] r5_result;
  reg [15:0] r5_fflags;

  // ---- 6-stage variant: S3a stage registers ----
  reg        r3a_valid;
  reg [47:0] r3a_prod;
  reg [47:0] r3a_psh;
  reg signed [9:0] r3a_exp;
  reg [5:0]  r3a_align_sh;
  reg        r3a_is_int;
  reg        r3a_any_nan, r3a_any_inf, r3a_any_zero, r3a_zero_inf, r3a_nv;
  reg [31:0] r3a_nan_res;
  reg        r3a_rs;
  reg [2:0]  r3a_rm;
  reg [4:0]  r3a_f, r3a_n, r3a_lw;
  reg [3:0]  r3a_ew;
  reg        r3a_is_signed, r3a_no_inf, r3a_packed;
  reg [2:0]  r3a_nlanes;
  reg [4:0]  r3a_lane_f;
  reg [3:0]  r3a_lane_ew;
  reg        r3a_lane_no_inf, r3a_lane_is_int, r3a_lane_signed;
  reg [23:0] r3a_lane_pn [0:3];
  reg [23:0] r3a_lane_prod [0:3];
  reg signed [9:0] r3a_lane_exp [0:3];
  reg [5:0]  r3a_lane_f6 [0:3];
  reg [10:0] r3a_lane_pl [0:3];
  reg [4:0]  r3a_ln_f [0:3];
  reg        r3a_ln_is_int [0:3];



  // ==========================================================================
  // Mode decode (scalar + packed parameter LUTs)
  // ==========================================================================
  reg [4:0]  s1_f;
  reg [3:0]  s1_ew;
  reg [8:0]  s1_bias;
  reg [5:0]  s1_align_sh;
  reg        s1_is_int;
  reg        s1_is_signed;
  reg [4:0]  s1_n;
  reg        s1_no_inf;
  reg        s1_nan_full;
  reg [23:0] s1_imask;

  reg        s1_packed;
  reg [2:0]  s1_nlanes;
  reg [4:0]  s1_lw;
  reg [4:0]  s1_lane_f;
  reg [3:0]  s1_lane_ew;
  reg [8:0]  s1_lane_bias;
  reg        s1_lane_no_inf;
  reg        s1_lane_is_int;
  reg        s1_lane_signed;

  always @(*) begin
    s1_f = 5'd23; s1_ew = 4'd8; s1_bias = 9'd127;
    s1_align_sh = 6'd0; s1_is_int = 1'b0; s1_is_signed = 1'b0;
    s1_n = 5'd0; s1_no_inf = 1'b0; s1_nan_full = 1'b0; s1_imask = 24'b0;
    s1_packed = 1'b0; s1_nlanes = 3'd0; s1_lw = 5'd0;
    s1_lane_f = 5'd0; s1_lane_ew = 4'd0; s1_lane_bias = 9'd0;
    s1_lane_no_inf = 1'b0; s1_lane_is_int = 1'b0; s1_lane_signed = 1'b0;
    case (fmt)
      `FP32_FMT_FP16:  begin s1_f = 5'd10; s1_ew = 4'd5;  s1_bias = 9'd15;  s1_align_sh = 6'd13; end
      `FP32_FMT_BF16:  begin s1_f = 5'd7;  s1_ew = 4'd8;  s1_bias = 9'd127; s1_align_sh = 6'd16; end
      `FP32_FMT_TF32:  begin s1_f = 5'd10; s1_ew = 4'd8;  s1_bias = 9'd127; s1_align_sh = 6'd13; end
      `FP32_FMT_BF32:  begin s1_f = 5'd15; s1_ew = 4'd8;  s1_bias = 9'd127; s1_align_sh = 6'd8;  end
      `FP32_FMT_E5M2:  begin s1_f = 5'd2;  s1_ew = 4'd5;  s1_bias = 9'd15;  s1_align_sh = 6'd21; end
      `FP32_FMT_E4M3:  begin s1_f = 5'd3;  s1_ew = 4'd4;  s1_bias = 9'd7;   s1_align_sh = 6'd20; s1_no_inf = 1'b1; s1_nan_full = 1'b1; end
      `FP32_FMT_E2M1:  begin s1_f = 5'd1;  s1_ew = 4'd2;  s1_bias = 9'd1;   s1_align_sh = 6'd22; end
      `FP32_FMT_INT4U: begin s1_f = 5'd0; s1_ew = 4'd0; s1_bias = 9'd0; s1_align_sh = 6'd0; s1_is_int = 1'b1; s1_n = 5'd4;  s1_imask = 24'h00000F; end
      `FP32_FMT_INT4S: begin s1_f = 5'd0; s1_ew = 4'd0; s1_bias = 9'd0; s1_align_sh = 6'd0; s1_is_int = 1'b1; s1_is_signed = 1'b1; s1_n = 5'd4;  s1_imask = 24'h00000F; end
      `FP32_FMT_INT8U: begin s1_f = 5'd0; s1_ew = 4'd0; s1_bias = 9'd0; s1_align_sh = 6'd0; s1_is_int = 1'b1; s1_n = 5'd8;  s1_imask = 24'h0000FF; end
      `FP32_FMT_INT8S: begin s1_f = 5'd0; s1_ew = 4'd0; s1_bias = 9'd0; s1_align_sh = 6'd0; s1_is_int = 1'b1; s1_is_signed = 1'b1; s1_n = 5'd8;  s1_imask = 24'h0000FF; end
      `FP32_FMT_INT16U: begin s1_f = 5'd0; s1_ew = 4'd0; s1_bias = 9'd0; s1_align_sh = 6'd0; s1_is_int = 1'b1; s1_n = 5'd16; s1_imask = 24'h00FFFF; end
      `FP32_FMT_INT16S: begin s1_f = 5'd0; s1_ew = 4'd0; s1_bias = 9'd0; s1_align_sh = 6'd0; s1_is_int = 1'b1; s1_is_signed = 1'b1; s1_n = 5'd16; s1_imask = 24'h00FFFF; end
      `FP32_FMT_FP16X2:  begin s1_packed = 1'b1; s1_nlanes = 3'd2; s1_lw = 5'd16; s1_lane_f = 5'd10; s1_lane_ew = 4'd5;  s1_lane_bias = 9'd15;  end
      `FP32_FMT_BF16X2:  begin s1_packed = 1'b1; s1_nlanes = 3'd2; s1_lw = 5'd16; s1_lane_f = 5'd7;  s1_lane_ew = 4'd8;  s1_lane_bias = 9'd127; end
      `FP32_FMT_E4M3X4:  begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd8;  s1_lane_f = 5'd3;  s1_lane_ew = 4'd4;  s1_lane_bias = 9'd7;   s1_lane_no_inf = 1'b1; end
      `FP32_FMT_E5M2X4:  begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd8;  s1_lane_f = 5'd2;  s1_lane_ew = 4'd5;  s1_lane_bias = 9'd15;  end
      `FP32_FMT_E2M1X4:  begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd4;  s1_lane_f = 5'd1;  s1_lane_ew = 4'd2;  s1_lane_bias = 9'd1;   end
      `FP32_FMT_INT8UX4: begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd8;  s1_lane_is_int = 1'b1; end
      `FP32_FMT_INT8SX4: begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd8;  s1_lane_is_int = 1'b1; s1_lane_signed = 1'b1; end
      `FP32_FMT_INT4UX4: begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd4;  s1_lane_is_int = 1'b1; end
      `FP32_FMT_INT4SX4: begin s1_packed = 1'b1; s1_nlanes = 3'd4; s1_lw = 5'd4;  s1_lane_is_int = 1'b1; s1_lane_signed = 1'b1; end
      default: begin end
    endcase
  end

  // ==========================================================================
  // S1 scalar unpack
  // ==========================================================================
  wire [7:0]  a_exp_sh = 8'(a >> (6'd31 - {2'b0, s1_ew}));
  wire [7:0]  b_exp_sh = 8'(b >> (6'd31 - {2'b0, s1_ew}));
  wire [7:0]  a_exp_f  = a_exp_sh[7:0] & ((8'd1 << {4'b0, s1_ew}) - 8'd1);
  wire [7:0]  b_exp_f  = b_exp_sh[7:0] & ((8'd1 << {4'b0, s1_ew}) - 8'd1);
  wire [31:0] a_frac   = a & ((32'd1 << {27'b0, s1_f}) - 32'd1);
  wire [31:0] b_frac   = b & ((32'd1 << {27'b0, s1_f}) - 32'd1);

  wire a_exp_all   = (a_exp_f == ((8'd1 << {4'b0, s1_ew}) - 8'd1)) & ~s1_is_int;
  wire b_exp_all   = (b_exp_f == ((8'd1 << {4'b0, s1_ew}) - 8'd1)) & ~s1_is_int;
  wire a_exp_zero  = (a_exp_f == 8'd0) & ~s1_is_int;
  wire b_exp_zero  = (b_exp_f == 8'd0) & ~s1_is_int;
  wire a_frac_zero = (a_frac == 32'd0);
  wire b_frac_zero = (b_frac == 32'd0);
  wire a_frac_all  = (a_frac == ((32'd1 << {27'b0, s1_f}) - 32'd1));
  wire b_frac_all  = (b_frac == ((32'd1 << {27'b0, s1_f}) - 32'd1));

  wire a_is_nan = ~s1_is_int & (s1_no_inf ? (a_exp_all & a_frac_all)
                                          : (a_exp_all & ~a_frac_zero));
  wire b_is_nan = ~s1_is_int & (s1_no_inf ? (b_exp_all & b_frac_all)
                                          : (b_exp_all & ~b_frac_zero));
  wire a_is_inf = ~s1_is_int & ~s1_no_inf & a_exp_all & a_frac_zero;
  wire b_is_inf = ~s1_is_int & ~s1_no_inf & b_exp_all & b_frac_zero;
  wire a_is_zero = a_exp_zero & a_frac_zero;
  wire b_is_zero = b_exp_zero & b_frac_zero;

  wire [4:0] s1_qidx = (s1_f == 5'd0) ? 5'd0 : (s1_f - 5'd1);
  wire a_quiet = a_frac[s1_qidx];
  wire b_quiet = b_frac[s1_qidx];
  wire a_is_snan = a_is_nan & ~a_quiet;
  wire b_is_snan = b_is_nan & ~b_quiet;

  wire [23:0] a_mag_pre = a[23:0] & s1_imask;
  wire [23:0] b_mag_pre = b[23:0] & s1_imask;
  wire [4:0]  s1_sidx   = (s1_n == 5'd0) ? 5'd0 : (s1_n - 5'd1);
  wire a_is_neg = s1_is_signed & a[s1_sidx];
  wire b_is_neg = s1_is_signed & b[s1_sidx];
  wire [23:0] s1_mag_a = a_is_neg ? ((~a_mag_pre) + 24'd1) & s1_imask : a_mag_pre;
  wire [23:0] s1_mag_b = b_is_neg ? ((~b_mag_pre) + 24'd1) & s1_imask : b_mag_pre;

  wire [23:0] s1_sig_a = (a_exp_zero ? 24'h000000 : 24'h800000)
                       | 24'(a_frac << (6'd23 - {1'b0, s1_f}));
  wire [23:0] s1_sig_b = (b_exp_zero ? 24'h000000 : 24'h800000)
                       | 24'(b_frac << (6'd23 - {1'b0, s1_f}));
  wire [23:0] r1_sig_a_nxt = s1_is_int ? s1_mag_a : s1_sig_a;
  wire [23:0] r1_sig_b_nxt = s1_is_int ? s1_mag_b : s1_sig_b;
  wire [7:0]  a_expu = a_exp_zero ? 8'd1 : a_exp_f;
  wire [7:0]  b_expu = b_exp_zero ? 8'd1 : b_exp_f;

  wire signed [9:0] r1_exp_sum_nxt = s1_is_int
      ? 10'sd0
      : ($signed({1'b0, a_expu}) + $signed({1'b0, b_expu}) - $signed({1'b0, s1_bias}));

  wire r1_rs_nxt = s1_is_int ? (s1_is_signed & (a[s1_sidx] ^ b[s1_sidx]))
                             : (a[31] ^ b[31]);
  wire s1_any_snan      = a_is_snan | b_is_snan;
  wire r1_any_nan_nxt   = ~s1_is_int & (a_is_nan | b_is_nan);
  wire r1_any_inf_nxt   = ~s1_is_int & (a_is_inf | b_is_inf);
  wire r1_any_zero_nxt  = ~s1_is_int & (a_is_zero | b_is_zero);
  wire r1_zero_inf_nxt  = ~s1_is_int & ((a_is_zero & b_is_inf) | (a_is_inf & b_is_zero));
  wire r1_nv_nxt        = ~s1_is_int & (s1_any_snan | r1_zero_inf_nxt);

  wire [31:0] s1_payload = (a_is_nan ? a_frac : b_frac)
                         & ((32'd1 << {27'b0, s1_f}) - 32'd1);
  wire [31:0] s1_exp_all_pat = ((32'd1 << {28'b0, s1_ew}) - 32'd1)
                             << (6'd31 - {2'b0, s1_ew});
  wire [31:0] s1_qbit_pat = (s1_f == 5'd0) ? 32'b0
                                           : (32'd1 << ({27'b0, s1_f} - 32'd1));
  wire [31:0] s1_payload_pat = s1_payload & (s1_qbit_pat - 32'd1);
  wire [31:0] r1_nan_res_nxt =
      r1_any_nan_nxt
          ? ({31'b0, r1_rs_nxt} << 31) | s1_exp_all_pat | s1_qbit_pat | s1_payload_pat
          : ({31'b0, r1_rs_nxt} << 31) | s1_exp_all_pat | s1_qbit_pat
            | (s1_nan_full ? (s1_qbit_pat - 32'd1) : 32'b0);

  // ==========================================================================
  // SIMD lanes: 4 structurally replicated mini-pipelines (generate)
  // ==========================================================================
  wire [15:0] lane_res     [0:3];
  wire [3:0]  lane_fl      [0:3];

  reg [11:0] r1_lane_sig_a [0:3];
  reg [11:0] r1_lane_sig_b [0:3];
  reg signed [9:0] r1_lane_exp [0:3];
  reg [5:0]  r1_lane_f6   [0:3];
  reg [10:0] r1_lane_pl   [0:3];
  reg signed [9:0] r2_lane_exp [0:3];
  reg [5:0]  r2_lane_f6   [0:3];
  reg [10:0] r2_lane_pl   [0:3];
  reg [23:0] r3_lane_pa   [0:3];
  reg [11:0] r3_lane_m    [0:3];
  reg [2:0]  r3_lane_grs  [0:3];
  reg signed [9:0] r3_lane_exp [0:3];
  reg [5:0]  r3_lane_f6   [0:3];
  reg [10:0] r3_lane_pl   [0:3];
  reg [15:0] r3_lane_prod [0:3];
  reg [11:0] r4_lane_m    [0:3];
  reg [2:0]  r4_lane_grs  [0:3];
  reg signed [9:0] r4_lane_exp [0:3];
  reg [10:0] r4_lane_fpre [0:3];
  reg [2:0]  r4_lane_sss  [0:3];
  reg [1:0]  r4_lane_inc  [0:3];
  reg [5:0]  r4_lane_f6   [0:3];
  reg [10:0] r4_lane_pl   [0:3];
  reg [15:0] r4_lane_prod [0:3];

  // S2: four 12x12 sub-multipliers, mode-muxed (same total gates as before)
  reg [11:0] s2_ta [0:3];
  reg [11:0] s2_tb [0:3];
  reg  [23:0] r2_tile [0:3];

  always @(*) begin
    if (r1_packed) begin
      s2_ta[0] = r1_lane_sig_a[0]; s2_tb[0] = r1_lane_sig_b[0];
      s2_ta[1] = r1_lane_sig_a[1]; s2_tb[1] = r1_lane_sig_b[1];
      s2_ta[2] = r1_lane_sig_a[2]; s2_tb[2] = r1_lane_sig_b[2];
      s2_ta[3] = r1_lane_sig_a[3]; s2_tb[3] = r1_lane_sig_b[3];
    end else begin
      s2_ta[0] = r1_sig_a[11:0];  s2_tb[0] = r1_sig_b[11:0];
      s2_ta[1] = r1_sig_a[11:0];  s2_tb[1] = r1_sig_b[23:12];
      s2_ta[2] = r1_sig_a[23:12]; s2_tb[2] = r1_sig_b[11:0];
      s2_ta[3] = r1_sig_a[23:12]; s2_tb[3] = r1_sig_b[23:12];
    end
  end

  genvar gi;
  generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_lane

      // ---------------- S1: per-lane decode ----------------
      wire [4:0] ln_lw    = s1_lw;
      wire [5:0] ln_sh    = gi * s1_lw;
      wire [15:0] ln_mask = (16'd1 << {11'b0, ln_lw}) - 16'd1;
      wire [15:0] ln_ash  = 16'(a >> ln_sh);
      wire [15:0] ln_bsh  = 16'(b >> ln_sh);
      wire [15:0] ln_a    = ln_ash & ln_mask;
      wire [15:0] ln_b    = ln_bsh & ln_mask;
      wire [3:0]  ln_sidx = (ln_lw == 5'd0) ? 4'd0 : ln_lw[3:0] - 4'd1;
      wire [5:0]  ln_esh  = {1'b0, ln_lw} - {1'b0, s1_lane_ew} - 6'd1;   // LW-1-EW
      wire [7:0]  ln_axsh = 8'(ln_a >> ln_esh);
      wire [7:0]  ln_bxsh = 8'(ln_b >> ln_esh);
      wire [7:0]  ln_aexp = ln_axsh & ((8'd1 << {4'b0, s1_lane_ew}) - 8'd1);
      wire [7:0]  ln_bexp = ln_bxsh & ((8'd1 << {4'b0, s1_lane_ew}) - 8'd1);
      wire [15:0] ln_afr  = ln_a & ((16'd1 << {11'b0, s1_lane_f}) - 16'd1);
      wire [15:0] ln_bfr  = ln_b & ((16'd1 << {11'b0, s1_lane_f}) - 16'd1);

      wire ln_rs         = ln_a[ln_sidx] ^ ln_b[ln_sidx];
      wire ln_aexp_all   = (ln_aexp == ((8'd1 << {4'b0, s1_lane_ew}) - 8'd1)) & ~s1_lane_is_int;
      wire ln_bexp_all   = (ln_bexp == ((8'd1 << {4'b0, s1_lane_ew}) - 8'd1)) & ~s1_lane_is_int;
      wire ln_aexp_zero  = (ln_aexp == 8'd0) & ~s1_lane_is_int;
      wire ln_bexp_zero  = (ln_bexp == 8'd0) & ~s1_lane_is_int;
      wire ln_afr_zero   = (ln_afr == 16'd0);
      wire ln_bfr_zero   = (ln_bfr == 16'd0);
      wire ln_afr_all    = (ln_afr == ((16'd1 << {11'b0, s1_lane_f}) - 16'd1));
      wire ln_bfr_all    = (ln_bfr == ((16'd1 << {11'b0, s1_lane_f}) - 16'd1));
      wire ln_ais_nan    = ~s1_lane_is_int & (s1_lane_no_inf ? (ln_aexp_all & ln_afr_all)
                                                             : (ln_aexp_all & ~ln_afr_zero));
      wire ln_bis_nan    = ~s1_lane_is_int & (s1_lane_no_inf ? (ln_bexp_all & ln_bfr_all)
                                                             : (ln_bexp_all & ~ln_bfr_zero));
      wire ln_ais_inf    = ~s1_lane_is_int & ~s1_lane_no_inf & ln_aexp_all & ln_afr_zero;
      wire ln_bis_inf    = ~s1_lane_is_int & ~s1_lane_no_inf & ln_bexp_all & ln_bfr_zero;
      wire ln_ais_zero   = ln_aexp_zero & ln_afr_zero;
      wire ln_bis_zero   = ln_bexp_zero & ln_bfr_zero;
      wire [3:0] ln_qidx = (s1_lane_f == 5'd0) ? 4'd0 : s1_lane_f[3:0] - 4'd1;
      wire ln_aquiet     = ln_afr[ln_qidx];
      wire ln_bquiet     = ln_bfr[ln_qidx];
      wire ln_any_snan   = (ln_ais_nan & ~ln_aquiet) | (ln_bis_nan & ~ln_bquiet);
      wire ln_any_nan    = ~s1_lane_is_int & (ln_ais_nan | ln_bis_nan);
      wire ln_any_inf    = ~s1_lane_is_int & (ln_ais_inf | ln_bis_inf);
      wire ln_any_zero   = ~s1_lane_is_int & (ln_ais_zero | ln_bis_zero);
      wire ln_zero_inf   = ~s1_lane_is_int & ((ln_ais_zero & ln_bis_inf) | (ln_ais_inf & ln_bis_zero));
      wire ln_nv         = ~s1_lane_is_int & (ln_any_snan | ln_zero_inf);
      wire [10:0] ln_pl  = 11'((ln_ais_nan ? ln_afr : ln_bfr)
                           & ((16'd1 << {11'b0, s1_lane_f}) - 16'd1));

      wire ln_aneg  = s1_lane_signed & ln_a[ln_sidx];
      wire ln_bneg  = s1_lane_signed & ln_b[ln_sidx];
      wire [11:0] ln_maga = ln_aneg ? ((~ln_a[11:0] + 12'd1) & ln_mask[11:0]) : ln_a[11:0];
      wire [11:0] ln_magb = ln_bneg ? ((~ln_b[11:0] + 12'd1) & ln_mask[11:0]) : ln_b[11:0];
      wire [11:0] ln_siga = s1_lane_is_int ? ln_maga
                            : ((ln_aexp_zero ? 12'b0 : 12'h800)
                               | 12'({2'b0, ln_afr[9:0]} << (6'd11 - {1'b0, s1_lane_f})));
      wire [11:0] ln_sigb = s1_lane_is_int ? ln_magb
                            : ((ln_bexp_zero ? 12'b0 : 12'h800)
                               | 12'({2'b0, ln_bfr[9:0]} << (6'd11 - {1'b0, s1_lane_f})));
      wire [7:0] ln_aexpu = ln_aexp_zero ? 8'd1 : ln_aexp;
      wire [7:0] ln_bexpu = ln_bexp_zero ? 8'd1 : ln_bexp;
      wire signed [9:0] ln_exp_sum = s1_lane_is_int
          ? 10'sd0
          : ($signed({1'b0, ln_aexpu}) + $signed({1'b0, ln_bexpu}) - $signed({1'b0, s1_lane_bias}));

      // ---------------- S1 -> S2 registers ----------------
      always @(posedge clk) begin
        if (!stall) begin
          r1_lane_sig_a[gi] <= ln_siga;
          r1_lane_sig_b[gi] <= ln_sigb;
          r1_lane_exp[gi]   <= ln_exp_sum;
          r1_lane_f6[gi]    <= {ln_rs, ln_any_nan, ln_any_inf, ln_any_zero, ln_zero_inf, ln_nv};
          r1_lane_pl[gi]    <= ln_pl[10:0];
          r2_lane_exp[gi]   <= r1_lane_exp[gi];
          r2_lane_f6[gi]    <= r1_lane_f6[gi];
          r2_lane_pl[gi]    <= r1_lane_pl[gi];
        end
      end

      // ---------------- S3: per-lane normalize ----------------
      wire [23:0] ln_prod = r2_tile[gi];

      wire [3:0] ln_lz8_0 = ln_prod[ 7] ? 4'd0 : ln_prod[ 6] ? 4'd1 :
                            ln_prod[ 5] ? 4'd2 : ln_prod[ 4] ? 4'd3 :
                            ln_prod[ 3] ? 4'd4 : ln_prod[ 2] ? 4'd5 :
                            ln_prod[ 1] ? 4'd6 : ln_prod[ 0] ? 4'd7 : 4'd8;
      wire [3:0] ln_lz8_1 = ln_prod[15] ? 4'd0 : ln_prod[14] ? 4'd1 :
                            ln_prod[13] ? 4'd2 : ln_prod[12] ? 4'd3 :
                            ln_prod[11] ? 4'd4 : ln_prod[10] ? 4'd5 :
                            ln_prod[ 9] ? 4'd6 : ln_prod[ 8] ? 4'd7 : 4'd8;
      wire [3:0] ln_lz8_2 = ln_prod[23] ? 4'd0 : ln_prod[22] ? 4'd1 :
                            ln_prod[21] ? 4'd2 : ln_prod[20] ? 4'd3 :
                            ln_prod[19] ? 4'd4 : ln_prod[18] ? 4'd5 :
                            ln_prod[17] ? 4'd6 : ln_prod[16] ? 4'd7 : 4'd8;
      wire ln_g0 = |ln_prod[ 7: 0];
      wire ln_g1 = |ln_prod[15: 8];
      wire ln_g2 = |ln_prod[23:16];
      wire [4:0] ln_lz = ln_g2 ? {1'b0, ln_lz8_2}
                       : ln_g1 ? 5'd8 + {1'b0, ln_lz8_1}
                       : ln_g0 ? 5'd16 + {1'b0, ln_lz8_0}
                       : 5'd24;

      wire [23:0] ln_pn    = ln_prod << ln_lz;

      // ---- 6-stage: S3a per-lane registers (shift + params hold) ----
      always @(posedge clk) begin
        if (!stall) begin
          r3a_lane_pn[gi]   <= ln_pn;
          r3a_lane_prod[gi] <= ln_prod;
          r3a_lane_exp[gi]  <= r2_lane_exp[gi] + 10'sd1 - $signed({5'b0, ln_lz});
          r3a_lane_f6[gi]   <= r2_lane_f6[gi];
          r3a_lane_pl[gi]   <= r2_lane_pl[gi];
          r3a_ln_f[gi]      <= r2_lane_f;
          r3a_ln_is_int[gi] <= r2_lane_is_int;
        end
      end

      // ---- 6-stage: S3b per-lane comb (align + extract) ----
      wire [23:0] ln_pa    = r3a_lane_pn[gi] >> (6'd11 - {1'b0, r3a_ln_f[gi]});
      wire [11:0] ln_m     = ln_pa[23:12];
      wire        ln_g     = ln_pa[11];
      wire        ln_r     = ln_pa[10];
      wire        ln_s     = |ln_pa[9:0];

      always @(posedge clk) begin
        if (!stall) begin
          r3_lane_pa[gi]   <= r3a_ln_is_int[gi] ? r3a_lane_prod[gi] : ln_pa;
          r3_lane_m[gi]    <= ln_m;
          r3_lane_grs[gi]  <= {ln_g, ln_r, ln_s};
          r3_lane_exp[gi]  <= r3a_lane_exp[gi];
          r3_lane_f6[gi]   <= r3a_lane_f6[gi];
          r3_lane_pl[gi]   <= r3a_lane_pl[gi];
          r3_lane_prod[gi] <= r3a_lane_prod[gi][15:0];
        end
      end

      // ---------------- S4: per-lane round ----------------
      wire [7:0] ln_k  = 8'd13 - r3_lane_exp[gi][7:0];
      wire [4:0] ln_ks = (ln_k >= 8'd24) ? 5'd0 : ln_k[4:0];
      wire [10:0] ln_fpre = (ln_k >= 8'd24) ? 11'b0
                            : 11'((r3_lane_pa[gi] >> ln_ks) & ((24'd1 << {19'b0, r3_lane_f}) - 24'd1));
      wire [4:0] ln_kg = (ln_k >= 8'd1 && ln_k <= 8'd24) ? (ln_k[4:0] - 5'd1) : 5'd0;
      wire [4:0] ln_kr = (ln_k >= 8'd2 && ln_k <= 8'd25) ? (ln_k[4:0] - 5'd2) : 5'd0;
      wire ln_sg = (ln_k >= 8'd1 && ln_k <= 8'd24) ? r3_lane_pa[gi][ln_kg] : 1'b0;
      wire ln_sr = (ln_k >= 8'd2 && ln_k <= 8'd25) ? r3_lane_pa[gi][ln_kr] : 1'b0;
      wire ln_ss = (ln_k <= 8'd26)
                   ? |({1'b0, r3_lane_pa[gi]} & ((25'd1 << (ln_k[4:0] - 5'd2)) - 25'd1))
                   : 1'b1;
      wire ln_inc_n;
      wire ln_inc_s;
      fp32_rnd_inc u_rnd_n (
          .g   (r3_lane_grs[gi][2]),
          .r   (r3_lane_grs[gi][1]),
          .s   (r3_lane_grs[gi][0]),
          .lsb (r3_lane_m[gi][0]),
          .sgn (r3_lane_f6[gi][5]),
          .rm  (r3_rm),
          .inc (ln_inc_n)
      );
      fp32_rnd_inc u_rnd_s (
          .g   (ln_sg),
          .r   (ln_sr),
          .s   (ln_ss),
          .lsb (ln_fpre[0]),
          .sgn (r3_lane_f6[gi][5]),
          .rm  (r3_rm),
          .inc (ln_inc_s)
      );

      always @(posedge clk) begin
        if (!stall) begin
          r4_lane_m[gi]    <= r3_lane_m[gi];
          r4_lane_grs[gi]  <= r3_lane_grs[gi];
          r4_lane_exp[gi]  <= r3_lane_exp[gi];
          r4_lane_fpre[gi] <= ln_fpre;
          r4_lane_sss[gi]  <= {ln_sg, ln_sr, ln_ss};
          r4_lane_inc[gi]  <= {ln_inc_n, ln_inc_s};
          r4_lane_f6[gi]   <= r3_lane_f6[gi];
          r4_lane_pl[gi]   <= r3_lane_pl[gi];
          r4_lane_prod[gi] <= r3_lane_prod[gi];
        end
      end

      // ---------------- S5: per-lane pack ----------------
      wire [12:0] ln_mr    = {1'b0, r4_lane_m[gi]} + {12'b0, r4_lane_inc[gi][1]};
      wire        ln_carry = ln_mr[r4_lane_f[3:0] + 4'd1];
      wire signed [9:0] ln_ef = r4_lane_exp[gi] + $signed({9'b0, ln_carry});
      wire [11:0] ln_fm   = (12'd1 << {7'b0, r4_lane_f}) - 12'd1;
      wire [11:0] ln_frac = ln_carry ? 12'b0 : (ln_mr[11:0] & ln_fm);
      wire [11:0] ln_fsub = {1'b0, r4_lane_fpre[gi]} + {11'b0, r4_lane_inc[gi][0]};
      wire        ln_scarry = ln_fsub[r4_lane_f[3:0]];
      wire [11:0] ln_ffrac = ln_fsub & ln_fm;
      wire [7:0]  ln_thr   = (8'd1 << {4'b0, r4_lane_ew}) - 8'd1;
      wire        ln_of    = (ln_ef > $signed({2'b0, ln_thr})) ||
                             (ln_ef == $signed({2'b0, ln_thr}) &&
                              (~r4_lane_no_inf | (ln_frac == ln_fm)));

      wire [4:0]  ln_lw4   = r4_lw;
      wire [5:0]  ln_exp_sh = {1'b0, ln_lw4} - {1'b0, r4_lane_ew} - 6'd1;   // LW-1-EW
      wire [15:0] ln_inf_pat = ({15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1))
                             | ({8'b0, ln_thr} << ln_exp_sh);
      wire [15:0] ln_max_pat = ({15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1))
                             | ({8'b0, ln_thr - 8'd1} << ln_exp_sh) | {4'b0, ln_fm};
      wire [15:0] ln_qbit  = (r4_lane_f == 5'd0) ? 16'd0
                                                : (16'd1 << ({11'b0, r4_lane_f} - 16'd1));
      wire [15:0] ln_nan_pat = ({15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1))
                             | ({8'b0, ln_thr} << ln_exp_sh)
                             | (r4_lane_no_inf ? {4'b0, ln_fm}
                                               : (ln_qbit | ({5'b0, r4_lane_pl[gi]} & (ln_qbit - 16'd1))));
      wire [15:0] ln_mn_pat = ({15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1))
                            | (16'd1 << ln_exp_sh);

      reg [15:0] ln_res;
      reg [3:0]  ln_fl;
      always @(*) begin
        ln_res = 16'b0;
        ln_fl  = 4'b0;
        if (r4_lane_is_int) begin
          ln_res = (r4_lane_signed & r4_lane_f6[gi][5])
                   ? (16'd0 - r4_lane_prod[gi]) : r4_lane_prod[gi];
        end else if (r4_lane_f6[gi][4] | r4_lane_f6[gi][1]) begin
          ln_res = ln_nan_pat;
          ln_fl  = {r4_lane_f6[gi][0], 3'b0};
        end else if (r4_lane_f6[gi][3]) begin
          ln_res = ln_inf_pat;
        end else if (r4_lane_f6[gi][2]) begin
          ln_res = {15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1);
        end else if (r4_lane_exp[gi] <= 10'sd0) begin
          ln_fl = {1'b0, 1'b0, |r4_lane_sss[gi], |r4_lane_sss[gi]};
          if (ln_scarry) ln_res = ln_mn_pat;
          else           ln_res = ({15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1)) | {4'b0, ln_ffrac};
        end else begin
          ln_fl = {1'b0, 1'b0, 1'b0,
                   r4_lane_grs[gi][2] | r4_lane_grs[gi][1] | r4_lane_grs[gi][0]};
          if (ln_of) begin
            ln_fl[2:0] = 3'b101;
            if (r4_lane_no_inf) begin
              ln_res = ln_nan_pat;
            end else begin
              case (r4_rm)
                `FP32_RM_RTZ: ln_res = ln_max_pat;
                `FP32_RM_RDN: ln_res = r4_lane_f6[gi][5] ? ln_inf_pat : ln_max_pat;
                `FP32_RM_RUP: ln_res = r4_lane_f6[gi][5] ? ln_max_pat : ln_inf_pat;
                default:      ln_res = ln_inf_pat;
              endcase
            end
          end else begin
            ln_res = ({15'b0, r4_lane_f6[gi][5]} << (ln_lw4 - 5'd1))
                   | ({8'b0, ln_ef[7:0]} << ln_exp_sh) | {4'b0, ln_frac};
          end
        end
      end

      assign lane_res[gi] = ln_res;
      assign lane_fl[gi]  = ln_fl;

    end
  endgenerate

  // ==========================================================================
  // S3 scalar: merge the four sub-multipliers, LZ-normalize (unchanged math)
  // ==========================================================================
  wire [47:0] s3_prod = ({24'b0, r2_tile[3]} << 24)
                      + (({24'b0, r2_tile[2]} + {24'b0, r2_tile[1]}) << 12)
                      + {24'b0, r2_tile[0]};

  wire [3:0] s3_lz8_0 = s3_prod[ 7] ? 4'd0 : s3_prod[ 6] ? 4'd1 :
                        s3_prod[ 5] ? 4'd2 : s3_prod[ 4] ? 4'd3 :
                        s3_prod[ 3] ? 4'd4 : s3_prod[ 2] ? 4'd5 :
                        s3_prod[ 1] ? 4'd6 : s3_prod[ 0] ? 4'd7 : 4'd8;
  wire [3:0] s3_lz8_1 = s3_prod[15] ? 4'd0 : s3_prod[14] ? 4'd1 :
                        s3_prod[13] ? 4'd2 : s3_prod[12] ? 4'd3 :
                        s3_prod[11] ? 4'd4 : s3_prod[10] ? 4'd5 :
                        s3_prod[ 9] ? 4'd6 : s3_prod[ 8] ? 4'd7 : 4'd8;
  wire [3:0] s3_lz8_2 = s3_prod[23] ? 4'd0 : s3_prod[22] ? 4'd1 :
                        s3_prod[21] ? 4'd2 : s3_prod[20] ? 4'd3 :
                        s3_prod[19] ? 4'd4 : s3_prod[18] ? 4'd5 :
                        s3_prod[17] ? 4'd6 : s3_prod[16] ? 4'd7 : 4'd8;
  wire [3:0] s3_lz8_3 = s3_prod[31] ? 4'd0 : s3_prod[30] ? 4'd1 :
                        s3_prod[29] ? 4'd2 : s3_prod[28] ? 4'd3 :
                        s3_prod[27] ? 4'd4 : s3_prod[26] ? 4'd5 :
                        s3_prod[25] ? 4'd6 : s3_prod[24] ? 4'd7 : 4'd8;
  wire [3:0] s3_lz8_4 = s3_prod[39] ? 4'd0 : s3_prod[38] ? 4'd1 :
                        s3_prod[37] ? 4'd2 : s3_prod[36] ? 4'd3 :
                        s3_prod[35] ? 4'd4 : s3_prod[34] ? 4'd5 :
                        s3_prod[33] ? 4'd6 : s3_prod[32] ? 4'd7 : 4'd8;
  wire [3:0] s3_lz8_5 = s3_prod[47] ? 4'd0 : s3_prod[46] ? 4'd1 :
                        s3_prod[45] ? 4'd2 : s3_prod[44] ? 4'd3 :
                        s3_prod[43] ? 4'd4 : s3_prod[42] ? 4'd5 :
                        s3_prod[41] ? 4'd6 : s3_prod[40] ? 4'd7 : 4'd8;

  wire s3_g0 = |s3_prod[ 7: 0];
  wire s3_g1 = |s3_prod[15: 8];
  wire s3_g2 = |s3_prod[23:16];
  wire s3_g3 = |s3_prod[31:24];
  wire s3_g4 = |s3_prod[39:32];
  wire s3_g5 = |s3_prod[47:40];

  wire [5:0] s3_lz = s3_g5 ? {2'b0, s3_lz8_5}
                   : s3_g4 ? 6'd8  + {2'b0, s3_lz8_4}
                   : s3_g3 ? 6'd16 + {2'b0, s3_lz8_3}
                   : s3_g2 ? 6'd24 + {2'b0, s3_lz8_2}
                   : s3_g1 ? 6'd32 + {2'b0, s3_lz8_1}
                   : s3_g0 ? 6'd40 + {2'b0, s3_lz8_0}
                   : 6'd48;

  wire [47:0] s3_psh    = s3_prod << s3_lz;

  // ---- 6-stage: S3a registers (merge + LZ + left-shift + params hold) ----
  always @(posedge clk) begin
    if (!stall) begin
      r3a_prod     <= s3_prod;
      r3a_psh      <= s3_psh;
      r3a_exp      <= r2_exp_sum + 10'sd1 - $signed({4'b0, s3_lz});
      r3a_align_sh <= r2_align_sh;
      r3a_is_int   <= r2_is_int;
      r3a_any_nan  <= r2_any_nan;
      r3a_any_inf  <= r2_any_inf;
      r3a_any_zero <= r2_any_zero;
      r3a_zero_inf <= r2_zero_inf;
      r3a_nv       <= r2_nv;
      r3a_nan_res  <= r2_nan_res;
      r3a_rs       <= r2_rs;
      r3a_rm       <= r2_rm;
      r3a_f        <= r2_f;
      r3a_ew       <= r2_ew;
      r3a_n        <= r2_n;
      r3a_is_signed <= r2_is_signed;
      r3a_no_inf   <= r2_no_inf;
      r3a_packed   <= r2_packed;
      r3a_nlanes   <= r2_nlanes;
      r3a_lw       <= r2_lw;
      r3a_lane_f   <= r2_lane_f;
      r3a_lane_ew  <= r2_lane_ew;
      r3a_lane_no_inf <= r2_lane_no_inf;
      r3a_lane_is_int <= r2_lane_is_int;
      r3a_lane_signed <= r2_lane_signed;
    end
  end

  // ---- 6-stage: S3b comb (format align + g/r/s extract) ----
  wire [47:0] s3_align  = r3a_psh >> r3a_align_sh;
  wire [47:0] r3_psh_nxt = r3a_is_int ? r3a_prod : s3_align;
  wire [23:0] r3_m_nxt   = r3_psh_nxt[47:24];
  wire        r3_g_nxt   = r3_psh_nxt[23];
  wire        r3_r_nxt   = r3_psh_nxt[22];
  wire        r3_s_nxt   = |r3_psh_nxt[21:0];
  wire signed [9:0] r3_exp_nxt = r3a_exp;

  // ==========================================================================
  // S4 scalar: rounding decisions + subnormal alignment
  // ==========================================================================
  wire [7:0] s4_k = 8'd25 - r3_exp[7:0];
  wire [22:0] r4_fpre_nxt = (s4_k >= 8'd48) ? 23'b0 : 23'(r3_psh >> s4_k[5:0]);
  wire [5:0] s4_idx_g = (s4_k >= 8'd1 && s4_k <= 8'd48) ? (s4_k[5:0] - 6'd1) : 6'd0;
  wire [5:0] s4_idx_r = (s4_k >= 8'd2 && s4_k <= 8'd49) ? (s4_k[5:0] - 6'd2) : 6'd0;
  wire r4_sg_nxt = (s4_k >= 8'd1 && s4_k <= 8'd48) ? r3_psh[s4_idx_g] : 1'b0;
  wire r4_sr_nxt = (s4_k >= 8'd2 && s4_k <= 8'd49) ? r3_psh[s4_idx_r] : 1'b0;
  wire r4_ss_nxt = (s4_k <= 8'd50)
                   ? |(r3_psh & ((48'd1 << (s4_k[5:0] - 6'd2)) - 48'd1))
                   : |r3_psh;

  wire r4_inc_n_nxt;
  wire r4_inc_s_nxt;
  fp32_rnd_inc u_rnd_n (
      .g   (r3_g), .r   (r3_r), .s   (r3_s),
      .lsb (r3_m[0]), .sgn (r3_rs), .rm  (r3_rm), .inc (r4_inc_n_nxt)
  );
  fp32_rnd_inc u_rnd_s (
      .g   (r4_sg_nxt), .r   (r4_sr_nxt), .s   (r4_ss_nxt),
      .lsb (r4_fpre_nxt[0]), .sgn (r3_rs), .rm  (r3_rm), .inc (r4_inc_s_nxt)
  );

  // ==========================================================================
  // S5 scalar: exponent fix, overflow/subnormal handling, special resolve
  // ==========================================================================
  /* verilator lint_off UNUSEDSIGNAL */  // s5_mr[23] is the implicit leading 1
  wire [24:0] s5_mr = {1'b0, r4_m} + {24'b0, r4_inc_n};
  /* verilator lint_on UNUSEDSIGNAL */
  wire s5_mcarry = s5_mr[{27'b0, r4_f} + 32'd1];
  wire signed [9:0] s5_expn = r4_exp + $signed({9'b0, s5_mcarry});
  wire [31:0] s5_mfrac = s5_mcarry ? 32'b0
                                   : ({7'b0, s5_mr} & ((32'd1 << {27'b0, r4_f}) - 32'd1));
  wire [23:0] s5_fsub  = {1'b0, r4_fpre} + {23'b0, r4_inc_s};
  wire        s5_scarry = s5_fsub[r4_f];
  wire [31:0] s5_ffrac  = {8'b0, s5_fsub} & ((32'd1 << {27'b0, r4_f}) - 32'd1);

  wire [7:0]  s5_thr        = (8'd1 << {4'b0, r4_ew}) - 8'd1;
  wire [31:0] s5_exp_all_pat = ((32'd1 << {28'b0, r4_ew}) - 32'd1)
                             << (6'd31 - {2'b0, r4_ew});
  wire [31:0] s5_max_exp_pat = ((32'd1 << {28'b0, r4_ew}) - 32'd2)
                             << (6'd31 - {2'b0, r4_ew});
  wire [31:0] s5_mant_all_pat = (32'd1 << {27'b0, r4_f}) - 32'd1;
  wire [31:0] s5_inf_pat = ({31'b0, r4_rs} << 31) | s5_exp_all_pat;
  wire [31:0] s5_max_pat = ({31'b0, r4_rs} << 31) | s5_max_exp_pat | s5_mant_all_pat;
  wire [31:0] s5_nan_pat = ({31'b0, r4_rs} << 31) | s5_exp_all_pat | s5_mant_all_pat;

  reg        s5_of;
  reg        s5_uf;
  reg        s5_nx;
  reg [31:0] s5_res;
  always @(*) begin
    s5_of = 1'b0;
    s5_uf = 1'b0;
    s5_nx = 1'b0;
    s5_res = 32'b0;
    if (r4_exp <= 10'sd0) begin
      s5_nx = r4_sg | r4_sr | r4_ss;
      s5_uf = s5_nx;
      if (s5_scarry) begin
        s5_res = ({31'b0, r4_rs} << 31) | (32'd1 << (6'd31 - {2'b0, r4_ew}));
      end else begin
        s5_res = ({31'b0, r4_rs} << 31) | s5_ffrac;
      end
    end else begin
      s5_nx = r4_g | r4_r | r4_s;
      if (s5_expn > $signed({2'b0, s5_thr}) ||
          (s5_expn == $signed({2'b0, s5_thr}) &&
           (~r4_no_inf | (s5_mfrac == s5_mant_all_pat)))) begin
        s5_of = 1'b1;
        s5_nx = 1'b1;
        if (r4_no_inf) begin
          s5_res = s5_nan_pat;
        end else begin
          case (r4_rm)
            `FP32_RM_RTZ: s5_res = s5_max_pat;
            `FP32_RM_RDN: s5_res = r4_rs ? s5_inf_pat : s5_max_pat;
            `FP32_RM_RUP: s5_res = r4_rs ? s5_max_pat : s5_inf_pat;
            default:      s5_res = s5_inf_pat;
          endcase
        end
      end else begin
        s5_res = ({31'b0, r4_rs} << 31)
               | ({24'b0, s5_expn[7:0]} << (6'd31 - {2'b0, r4_ew}))
               | s5_mfrac;
      end
    end
  end

  reg [31:0] s5_int_pre;
  always @(*) begin
    case (r4_n)
      5'd4:  s5_int_pre = r4_is_signed ? {{24{r4_psh[7]}},  r4_psh[7:0]}
                                       : {24'b0, r4_psh[7:0]};
      5'd8:  s5_int_pre = r4_is_signed ? {{16{r4_psh[15]}}, r4_psh[15:0]}
                                       : {16'b0, r4_psh[15:0]};
      default: s5_int_pre = r4_psh[31:0];
    endcase
  end
  wire [31:0] s5_int_res = (r4_is_signed & r4_rs) ? (32'd0 - s5_int_pre)
                                                  : s5_int_pre;

  reg [31:0] s5_final_res;
  reg [4:0]  s5_fflags;
  always @(*) begin
    if (r4_is_int) begin
      s5_final_res = s5_int_res;
      s5_fflags    = 5'b0;
    end else if (r4_any_nan | r4_zero_inf) begin
      s5_final_res = r4_nan_res;
      s5_fflags    = {r4_nv, 4'b0};
    end else if (r4_any_inf) begin
      s5_final_res = s5_inf_pat;
      s5_fflags    = 5'b0;
    end else if (r4_any_zero) begin
      s5_final_res = {r4_rs, 31'b0};
      s5_fflags    = 5'b0;
    end else begin
      s5_final_res = s5_res;
      s5_fflags    = {1'b0, 1'b0, s5_of, s5_uf, s5_nx};
    end
  end

  // ==========================================================================
  // Output assembly
  // ==========================================================================
  reg [63:0] r5_result_nxt;
  reg [15:0] r5_fflags_nxt;
  always @(*) begin
    r5_result_nxt = 64'b0;
    r5_fflags_nxt = 16'b0;
    if (r4_packed) begin
      if (r4_lane_is_int && (r4_lw == 5'd8)) begin
        // INT8x4: four 16-bit products
        r5_result_nxt = {lane_res[3], lane_res[2], lane_res[1], lane_res[0]};
      end else if (r4_lane_is_int) begin
        // INT4x4: four 8-bit products
        r5_result_nxt = {32'b0, lane_res[3][7:0], lane_res[2][7:0],
                         lane_res[1][7:0], lane_res[0][7:0]};
      end else begin
        case (r4_lw)
          5'd16: r5_result_nxt = {32'b0, lane_res[1], lane_res[0]};          // FP16x2/BF16x2
          5'd8:  r5_result_nxt = {32'b0, lane_res[3][7:0], lane_res[2][7:0],
                                  lane_res[1][7:0], lane_res[0][7:0]};       // FP8x4
          5'd4:  r5_result_nxt = {48'b0, lane_res[3][3:0], lane_res[2][3:0],
                                  lane_res[1][3:0], lane_res[0][3:0]};       // FP4x4
          default: r5_result_nxt = 64'b0;
        endcase
      end
      r5_fflags_nxt = (r4_nlanes == 3'd2)
                      ? {8'b0, lane_fl[1], lane_fl[0]}
                      : {lane_fl[3], lane_fl[2], lane_fl[1], lane_fl[0]};
    end else begin
      r5_result_nxt = {32'b0, s5_final_res};
      r5_fflags_nxt = {11'b0, s5_fflags};
    end
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      r1_valid <= 1'b0;
      r2_valid <= 1'b0;
      r3a_valid <= 1'b0;
      r3_valid <= 1'b0;
      r4_valid <= 1'b0;
      r5_valid <= 1'b0;
    end else if (!stall) begin
      r1_valid <= in_valid;
      r2_valid <= r1_valid;
      r3a_valid <= r2_valid;
      r3_valid <= r3a_valid;
      r4_valid <= r3_valid;
      r5_valid <= r4_valid;
    end
  end

  always @(posedge clk) begin
    if (!stall) begin
      r1_any_nan  <= r1_any_nan_nxt;
      r1_any_inf  <= r1_any_inf_nxt;
      r1_any_zero <= r1_any_zero_nxt;
      r1_zero_inf <= r1_zero_inf_nxt;
      r1_nv       <= r1_nv_nxt;
      r1_nan_res  <= r1_nan_res_nxt;
      r1_rs       <= r1_rs_nxt;
      r1_sig_a    <= r1_sig_a_nxt;
      r1_sig_b    <= r1_sig_b_nxt;
      r1_exp_sum  <= r1_exp_sum_nxt;
      r1_rm       <= rm;
      r1_f        <= s1_f;
      r1_ew       <= s1_ew;
      r1_n        <= s1_n;
      r1_align_sh <= s1_align_sh;
      r1_is_int   <= s1_is_int;
      r1_is_signed <= s1_is_signed;
      r1_no_inf   <= s1_no_inf;
      r1_packed   <= s1_packed;
      r1_nlanes   <= s1_nlanes;
      r1_lw       <= s1_lw;
      r1_lane_f   <= s1_lane_f;
      r1_lane_ew  <= s1_lane_ew;
      r1_lane_no_inf <= s1_lane_no_inf;
      r1_lane_is_int <= s1_lane_is_int;
      r1_lane_signed <= s1_lane_signed;

      r2_tile[0] <= s2_ta[0] * s2_tb[0];
      r2_tile[1] <= s2_ta[1] * s2_tb[1];
      r2_tile[2] <= s2_ta[2] * s2_tb[2];
      r2_tile[3] <= s2_ta[3] * s2_tb[3];
      r2_any_nan  <= r1_any_nan;
      r2_any_inf  <= r1_any_inf;
      r2_any_zero <= r1_any_zero;
      r2_zero_inf <= r1_zero_inf;
      r2_nv       <= r1_nv;
      r2_nan_res  <= r1_nan_res;
      r2_rs       <= r1_rs;
      r2_exp_sum  <= r1_exp_sum;
      r2_rm       <= r1_rm;
      r2_f        <= r1_f;
      r2_ew       <= r1_ew;
      r2_n        <= r1_n;
      r2_align_sh <= r1_align_sh;
      r2_is_int   <= r1_is_int;
      r2_is_signed <= r1_is_signed;
      r2_no_inf   <= r1_no_inf;
      r2_packed   <= r1_packed;
      r2_nlanes   <= r1_nlanes;
      r2_lw       <= r1_lw;
      r2_lane_f   <= r1_lane_f;
      r2_lane_ew  <= r1_lane_ew;
      r2_lane_no_inf <= r1_lane_no_inf;
      r2_lane_is_int <= r1_lane_is_int;
      r2_lane_signed <= r1_lane_signed;

      r3_any_nan <= r3a_any_nan;
      r3_any_inf <= r3a_any_inf;
      r3_any_zero <= r3a_any_zero;
      r3_zero_inf <= r3a_zero_inf;
      r3_nv <= r3a_nv;
      r3_nan_res <= r3a_nan_res;
      r3_rs <= r3a_rs;
      r3_exp      <= r3_exp_nxt;
      r3_m        <= r3_m_nxt;
      r3_g        <= r3_g_nxt;
      r3_r        <= r3_r_nxt;
      r3_s        <= r3_s_nxt;
      r3_psh      <= r3_psh_nxt;
      r3_rm <= r3a_rm;
      r3_f <= r3a_f;
      r3_ew <= r3a_ew;
      r3_n <= r3a_n;
      r3_is_int <= r3a_is_int;
      r3_is_signed <= r3a_is_signed;
      r3_no_inf <= r3a_no_inf;
      r3_packed <= r3a_packed;
      r3_nlanes <= r3a_nlanes;
      r3_lw <= r3a_lw;
      r3_lane_f <= r3a_lane_f;
      r3_lane_ew <= r3a_lane_ew;
      r3_lane_no_inf <= r3a_lane_no_inf;
      r3_lane_is_int <= r3a_lane_is_int;
      r3_lane_signed <= r3a_lane_signed;

      r4_any_nan  <= r3_any_nan;
      r4_any_inf  <= r3_any_inf;
      r4_any_zero <= r3_any_zero;
      r4_zero_inf <= r3_zero_inf;
      r4_nv       <= r3_nv;
      r4_nan_res  <= r3_nan_res;
      r4_rs       <= r3_rs;
      r4_exp      <= r3_exp;
      r4_m        <= r3_m;
      r4_g        <= r3_g;
      r4_r        <= r3_r;
      r4_s        <= r3_s;
      r4_psh      <= r3_psh;
      r4_fpre     <= r4_fpre_nxt;
      r4_sg       <= r4_sg_nxt;
      r4_sr       <= r4_sr_nxt;
      r4_ss       <= r4_ss_nxt;
      r4_inc_n    <= r4_inc_n_nxt;
      r4_inc_s    <= r4_inc_s_nxt;
      r4_rm       <= r3_rm;
      r4_f        <= r3_f;
      r4_ew       <= r3_ew;
      r4_n        <= r3_n;
      r4_is_int   <= r3_is_int;
      r4_is_signed <= r3_is_signed;
      r4_no_inf   <= r3_no_inf;
      r4_packed   <= r3_packed;
      r4_nlanes   <= r3_nlanes;
      r4_lw       <= r3_lw;
      r4_lane_f   <= r3_lane_f;
      r4_lane_ew  <= r3_lane_ew;
      r4_lane_no_inf <= r3_lane_no_inf;
      r4_lane_is_int <= r3_lane_is_int;
      r4_lane_signed <= r3_lane_signed;

      r5_result   <= r5_result_nxt;
      r5_fflags   <= r5_fflags_nxt;
    end
  end

  assign out_valid = r5_valid;
  assign result    = r5_result;
  assign fflags    = r5_fflags;

endmodule
