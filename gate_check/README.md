# gate_check：DC 门级网表功能验证（VCS 全量黄金回放）

对 `synth/dc/outputs/fp32_mult.v`（compile_ultra 门级网表）用商业仿真器做
**全部 2,421,115 条黄金向量的逐拍回放比对**，结果 **0 mismatch**（CPU ~148 s）。

## 复现步骤

```sh
# 1. 拷入网表与 SMIC28 功能模型（网表与 synth/dc/outputs 同源）
cp ../synth/dc/outputs/fp32_mult.v rtl/fp32_mult_net.v
cp /home/public/PDK/SMIC28/STDcell/SCC28NHKCP_HDC35P140_RVT_V0p2/verilog/scc28nhkcp_hdc35p140_rvt.v rtl/
cp ../tb/golden.txt tb/            # 或 cd .. && python3 tb/gen_golden.py

# 2. 生成回放向量（stim_full.hex / exp_full.hex）
python3 make_full.py

# 3. VCS 编译 + 运行（宿主 glibc 不兼容时经 snps-centos7 兼容层）
/home/public/app/synopsys/compat/bin/vcs -full64 -sverilog +define+functional \
    iv_tb_full.v rtl/fp32_mult_net.v rtl/scc28nhkcp_hdc35p140_rvt.v -o simv_full
/home/public/app/synopsys/compat/bin/snps-centos7 ./simv_full

# 期望输出:
#   VCS GATE CHECK: 2421115 vectors, 0 mismatches
#   GATE-LEVEL GOLDEN REPLAY PASSED
```

## 调试经验（见 docs/SYNTH_DC.md §4）

- pip 版 verilator 5.38 的 UDP 原语在同一边沿内按顺序求值，会把移位链一拍
  推进多级（r1/r2 同拍翻转、out_valid 提前 2 拍）——**门级仿真勿用**；
- iverilog 语义正确但 vvp 对 1.5 万单元网表太慢，仅适合小样本自检
  （`iv_tb.v` + `stim_small.hex`，2000 条已通过）。
