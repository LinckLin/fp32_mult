# Transform the declaration-reordered fp32_mult.v into the 6-stage (S3 split)
# variant. Run from synth/dc/inputs/:  python3 make_v2.py
import sys, re
SRC = "rtl/fp32_mult.v"
DST = "rtl_v2/fp32_mult.v"
src = open(SRC).read()

reps = []

# T1: new r3a register declarations
reps.append((
"  reg [63:0] r5_result;\n  reg [15:0] r5_fflags;",
"  reg [63:0] r5_result;\n  reg [15:0] r5_fflags;\n\n  // ---- 6-stage variant: S3a stage registers ----\n  reg        r3a_valid;\n  reg [47:0] r3a_prod;\n  reg [47:0] r3a_psh;\n  reg signed [9:0] r3a_exp;\n  reg [5:0]  r3a_align_sh;\n  reg        r3a_is_int;\n  reg        r3a_any_nan, r3a_any_inf, r3a_any_zero, r3a_zero_inf, r3a_nv;\n  reg [31:0] r3a_nan_res;\n  reg        r3a_rs;\n  reg [2:0]  r3a_rm;\n  reg [4:0]  r3a_f, r3a_n, r3a_lw;\n  reg [3:0]  r3a_ew;\n  reg        r3a_is_signed, r3a_no_inf, r3a_packed;\n  reg [2:0]  r3a_nlanes;\n  reg [4:0]  r3a_lane_f;\n  reg [3:0]  r3a_lane_ew;\n  reg        r3a_lane_no_inf, r3a_lane_is_int, r3a_lane_signed;\n  reg [23:0] r3a_lane_pn [0:3];\n  reg [23:0] r3a_lane_prod [0:3];\n  reg signed [9:0] r3a_lane_exp [0:3];\n  reg [5:0]  r3a_lane_f6 [0:3];\n  reg [10:0] r3a_lane_pl [0:3];\n  reg [4:0]  r3a_ln_f [0:3];\n  reg        r3a_ln_is_int [0:3];"
))

# T2: valid chain
reps.append((
"      r3_valid <= 1'b0;\n      r4_valid <= 1'b0;",
"      r3a_valid <= 1'b0;\n      r3_valid <= 1'b0;\n      r4_valid <= 1'b0;"
))
reps.append((
"      r3_valid <= r2_valid;\n      r4_valid <= r3_valid;",
"      r3a_valid <= r2_valid;\n      r3_valid <= r3a_valid;\n      r4_valid <= r3_valid;"
))

# T3: scalar S3 -> S3a/S3b
reps.append((
"  wire [47:0] s3_psh    = s3_prod << s3_lz;\n  wire [47:0] s3_align  = s3_psh >> r2_align_sh;\n  wire [47:0] r3_psh_nxt = r2_is_int ? s3_prod : s3_align;\n  wire [23:0] r3_m_nxt   = r3_psh_nxt[47:24];\n  wire        r3_g_nxt   = r3_psh_nxt[23];\n  wire        r3_r_nxt   = r3_psh_nxt[22];\n  wire        r3_s_nxt   = |r3_psh_nxt[21:0];\n  wire signed [9:0] r3_exp_nxt = r2_exp_sum + 10'sd1 - $signed({4'b0, s3_lz});",
"  wire [47:0] s3_psh    = s3_prod << s3_lz;\n\n  // ---- 6-stage: S3a registers (merge + LZ + left-shift + params hold) ----\n  always @(posedge clk) begin\n    if (!stall) begin\n      r3a_prod     <= s3_prod;\n      r3a_psh      <= s3_psh;\n      r3a_exp      <= r2_exp_sum + 10'sd1 - $signed({4'b0, s3_lz});\n      r3a_align_sh <= r2_align_sh;\n      r3a_is_int   <= r2_is_int;\n      r3a_any_nan  <= r2_any_nan;\n      r3a_any_inf  <= r2_any_inf;\n      r3a_any_zero <= r2_any_zero;\n      r3a_zero_inf <= r2_zero_inf;\n      r3a_nv       <= r2_nv;\n      r3a_nan_res  <= r2_nan_res;\n      r3a_rs       <= r2_rs;\n      r3a_rm       <= r2_rm;\n      r3a_f        <= r2_f;\n      r3a_ew       <= r2_ew;\n      r3a_n        <= r2_n;\n      r3a_is_signed <= r2_is_signed;\n      r3a_no_inf   <= r2_no_inf;\n      r3a_packed   <= r2_packed;\n      r3a_nlanes   <= r2_nlanes;\n      r3a_lw       <= r2_lw;\n      r3a_lane_f   <= r2_lane_f;\n      r3a_lane_ew  <= r2_lane_ew;\n      r3a_lane_no_inf <= r2_lane_no_inf;\n      r3a_lane_is_int <= r2_lane_is_int;\n      r3a_lane_signed <= r2_lane_signed;\n    end\n  end\n\n  // ---- 6-stage: S3b comb (format align + g/r/s extract) ----\n  wire [47:0] s3_align  = r3a_psh >> r3a_align_sh;\n  wire [47:0] r3_psh_nxt = r3a_is_int ? r3a_prod : s3_align;\n  wire [23:0] r3_m_nxt   = r3_psh_nxt[47:24];\n  wire        r3_g_nxt   = r3_psh_nxt[23];\n  wire        r3_r_nxt   = r3_psh_nxt[22];\n  wire        r3_s_nxt   = |r3_psh_nxt[21:0];\n  wire signed [9:0] r3_exp_nxt = r3a_exp;"
))

# T5: lane S3 -> S3a/S3b
reps.append((
"      wire [23:0] ln_pn    = ln_prod << ln_lz;\n      wire [23:0] ln_pa    = ln_pn >> (6'd11 - {1'b0, r2_lane_f});\n      wire [11:0] ln_m     = ln_pa[23:12];\n      wire        ln_g     = ln_pa[11];\n      wire        ln_r     = ln_pa[10];\n      wire        ln_s     = |ln_pa[9:0];\n      wire signed [9:0] ln_e3 = r2_lane_exp[gi] + 10'sd1 - $signed({5'b0, ln_lz});\n\n      always @(posedge clk) begin\n        if (!stall) begin\n          r3_lane_pa[gi]   <= r2_lane_is_int ? ln_prod : ln_pa;\n          r3_lane_m[gi]    <= ln_m;\n          r3_lane_grs[gi]  <= {ln_g, ln_r, ln_s};\n          r3_lane_exp[gi]  <= ln_e3;\n          r3_lane_f6[gi]   <= r2_lane_f6[gi];\n          r3_lane_pl[gi]   <= r2_lane_pl[gi];\n          r3_lane_prod[gi] <= ln_prod[15:0];\n        end\n      end",
"      wire [23:0] ln_pn    = ln_prod << ln_lz;\n\n      // ---- 6-stage: S3a per-lane registers (shift + params hold) ----\n      always @(posedge clk) begin\n        if (!stall) begin\n          r3a_lane_pn[gi]   <= ln_pn;\n          r3a_lane_prod[gi] <= ln_prod;\n          r3a_lane_exp[gi]  <= r2_lane_exp[gi] + 10'sd1 - $signed({5'b0, ln_lz});\n          r3a_lane_f6[gi]   <= r2_lane_f6[gi];\n          r3a_lane_pl[gi]   <= r2_lane_pl[gi];\n          r3a_ln_f[gi]      <= r2_lane_f;\n          r3a_ln_is_int[gi] <= r2_lane_is_int;\n        end\n      end\n\n      // ---- 6-stage: S3b per-lane comb (align + extract) ----\n      wire [23:0] ln_pa    = r3a_lane_pn[gi] >> (6'd11 - {1'b0, r3a_ln_f[gi]});\n      wire [11:0] ln_m     = ln_pa[23:12];\n      wire        ln_g     = ln_pa[11];\n      wire        ln_r     = ln_pa[10];\n      wire        ln_s     = |ln_pa[9:0];\n\n      always @(posedge clk) begin\n        if (!stall) begin\n          r3_lane_pa[gi]   <= r3a_ln_is_int[gi] ? r3a_lane_prod[gi] : ln_pa;\n          r3_lane_m[gi]    <= ln_m;\n          r3_lane_grs[gi]  <= {ln_g, ln_r, ln_s};\n          r3_lane_exp[gi]  <= r3a_lane_exp[gi];\n          r3_lane_f6[gi]   <= r3a_lane_f6[gi];\n          r3_lane_pl[gi]   <= r3a_lane_pl[gi];\n          r3_lane_prod[gi] <= r3a_lane_prod[gi][15:0];\n        end\n      end"
))

# T6: header comment
reps.append((
"// fp32_mult : 5-stage pipelined multi-format multiplier with SIMD packing",
"// fp32_mult : 6-stage pipelined multi-format multiplier with SIMD packing\n//   (S3-split variant: S3a merge+LZ+shift, S3b align+extract)"
))

out = src
for i,(old,new) in enumerate(reps):
    n = out.count(old)
    if n != 1:
        print("FAIL rep %d: '%s...' occurs %d times" % (i, old[:50], n))
        sys.exit(1)
    out = out.replace(old, new)

# T4: regex: r3_* <= r2_* param passthroughs -> r3a_*
pat = re.compile(r"(\s*)(r3_\w+)\s+<= (r2_\w+);")
out2, n4 = pat.subn(lambda m: m.group(1) + m.group(2) + " <= " + "r3a_" + m.group(3)[3:] + ";", out)
print("T4 regex rewrote", n4, "passthrough assignments")
out = out2

open(DST,"w").write(out)
print("all replacements applied OK; lines:", out.count("\n")+1)
