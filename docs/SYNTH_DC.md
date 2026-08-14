# fp32_mult DC 综合报告：理论上限与优化分析

> 环境：Design Compiler O-2018.06-SP1（DC Ultra），SMIC28 SCC28NHKCP_HDC35P140_RVT，
> **tt / 0.8V / 25°C**（basic.db）。流程复制自 `~/project/newff` 的 DC 运行方式：
> `analyze/elaborate -> link -> uniquify -> source SDC -> group_path ->
> compile_ultra -no_autoungroup [-incremental]`，约束同 newff/backend/sdc 风格。
> 复现：`cd synth/dc && make dc`（周期扫描脚本 script/dc_sweep.tcl）。

## 1. 基线综合结果（5 级流水，原 RTL）

### 1.1 Fmax 扫描（compile_ultra + 逐轮收紧时钟）

| 周期 (ns) | WNS (ns) | 面积 (µm²) | 单元数 |
|-----------|----------|-----------|--------|
| 1.00 | +0.000 | 10,078 | 14,756 |
| 0.80 | −0.118 | 10,858 | 15,207 |
| 0.65 | −0.265 | 11,055 | 15,409 |
| 0.55 | −0.365 | 11,136 | 15,460 |
| 0.48 | −0.426 | 11,196 | 15,473 |
| 0.42 | −0.484 | 11,202 | 15,494 |
| 0.38 | −0.524 | 11,124 | 15,479 |

各点 "周期 − WNS" 高度一致（0.90~0.92 ns），**理论上限 Fmax ≈ 1/(0.90ns) ≈
1.11 GHz**；1.0 ns（1 GHz）约束下面积 10,078 µm²、1,597 个 FF、14,756 单元，
与 FPGA 版 FF 数（1,616）吻合。功耗（0.38ns 时钟标注、默认翻转率）：
内部 3.22 mW + 开关 15.8 mW + 漏电 31.9 µW ≈ **19 mW**。

### 1.2 关键路径分布（0.8ns 约束，300 条最差端点按流水级分桶）

| 级 | 最差 slack | 结论 |
|----|-----------|------|
| **S3_norm（合并加法+LZ+双桶形移位+粘滞）** | **−0.120** | 关键路径 |
| S5_pack（阶码修正+打包 mux） | −0.110 | 次关键 |
| S2_mul（12×12 子乘器） | −0.110 | 次关键 |
| S3_lane（lane 归一化） | −0.110 | 次关键 |
| S4_round | −0.080 | 非关键 |

最差单路径：`r2_tile[1][4] → r3_s`，0.83 ns（0.8ns 约束下），44 级逻辑，
由 48 位合并加法器（XOR 链）+ 前导零计数 + 移位器 + 22 位 OR 构成。
**注意与 FPGA 结论不同**：DESIGN.md 称 S4 是关键路径（iCE40 上），
ASIC 单元库里 S3/S2/S5 才是瓶颈，S4 反而不在最差之列——器件结构不同，
瓶颈位置会迁移。

### 1.3 关于"理论平衡"的判断

把 0.8ns 下各段端点 slack 摊开看：S3≈0.90ns、S2≈0.90ns、S5≈0.90ns、
S4≈0.80ns——**5 级已经相当均衡**。实验证据：对同一 RTL 打开寄存器重定时
（`set_optimize_registers true`，dc_retime），Fmax 1.096 GHz（vs 1.106），
**几乎零收益**——重定时能搬的余量已经被手工平衡吃掉了。

## 2. 优化实验 V2：S3 切分为两级（6 级流水）

按 DESIGN.md 的提示把 S3 拆成 S3a（合并+LZ+左移）与 S3b（对齐+提取），
声明块按要求前移；**tb 全量验证通过**（242 万黄金向量回放、FPU 交叉、
穷举、随机、吞吐，latency=6，吞吐 1 组/拍不变）。

| | 基线 5 级 | V2 6 级（S3 切分） |
|--|----------|-------------------|
| Fmax | ≈1.11 GHz | **≈1.31 GHz（+19%）** |
| 面积 @1.0ns | 10,078 µm² | 11,116 µm²（+10%） |
| 面积 @极限 | 11,124 µm² | 13,422 µm²（+21%） |
| FF | 1,597 | 2,084 |
| 关键级 | S3 = 0.90 ns | S2/S3a/S5 ≈ 0.76 ns |
| 延迟 | 5 | 6 |

V2 切分后 S3 不再是墙，新墙变成 **S2 乘法器（r1_packed → r2_tile[23]，
乘阵列进位链）、S3a（合并+移位 0.67ns/31 级）、S5 打包**，三者同时压在
≈0.76 ns。**单切一级已经不够了**：乘法器与打包级成为共同瓶颈。

## 2.5 优化实验 V3：时序 + 功耗优化（7 级流水，rtl_v3）

在 V2 基础上把**时序层和功耗层**的优化全部落地（RTL：synth/dc/inputs/rtl_v3/，
功能验证 v3_check/ 全量通过：242 万黄金回放 + FPU 交叉 + 穷举 + 2M 随机 +
吞吐，latency=7、1 结果/拍）：

| 时序改动 | 效果 |
|----------|------|
| S2 拆成 S2a(4×6×6 部分积)+S2b(加法树)：流水化 12×12 乘法器 | 乘阵列进位链不再是墙 |
| S3a 去掉左移(只留合并+LZ+阶码)；S3b 用**合并双向移位**(lz−align_sh) | 砍掉一级串行桶形移位 |
| S4a 只做 fpre 移位+sg/sr+**粘滞掩码**(48b 掩码+AND 寄存)，OR 树移到 S5 | S4 锥减半 |
| S5 合并舍入增量(把 rnd_inc+两个增量加法器从 S4 挪入 S5 级) | 打包级只差纯 mux |

| 功耗改动 | 说明 |
|----------|------|
| P1:2-lane 模式冻结闲置子乘器(FP16x2/BF16x2 时 tile2/3 输入强制 0) | 阵列是功耗大户,4 路只用了 2 路时白烧一半 |
| P2:INT 模式旁路 LZ+移位锥(s3_prod_lz/ln_prod_lz 强制 0) | INT 结果从不消费 LZ/移位输出 |
| P3:DC 时钟门控(set_clock_gating_style {integrated} -control_point after + compile_ultra -gate_clock) | 库里有 ICG(**CLKLANAQV2~16**,postcontrol 型);DC 给 1 组寄存器(r2a_pp/r4_valid)插了 CLKLANAQV2,其余已有 stall-enable 等效门控;CG 网表 242 万门级回放 0 mismatch;PT-PX 实测总功耗 −0.2%(编译噪声级,收益有限,见 §4.5) |

实测结果（SMIC28 RVT, tt/0.8V/25°C）：

| | 基线 5 级 | V2 6 级 | **V3 7 级** |
|--|----------|---------|------------|
| Fmax | ≈1.11 GHz | ≈1.31 GHz | **≈1.36 GHz(+23% vs 基线)** |
| 面积@1.0ns | 10,078 µm² | 11,116 µm² | 12,377 µm² |
| FF | 1,597 | 2,084 | 2,466 |
| **功耗@1GHz(PrimeTime PX+SAIF)** | **8.80 mW** | **11.18 mW** | **12.24 mW(+9% vs V2)** |
| 每运算能量@各自 Fmax | **7.96 pJ** | 8.51 pJ | 8.99 pJ |

**功耗的诚实结论（PrimeTime PX 实测，见 §4.5）**：

- P1/P2 门控**确实有效**：SIMD 密集负载(FP16x2/BF16x2/INT8x4)下 V3 的
  **开关功耗比 V2 低 15%**(5.11 vs 6.02 µW@10MHz 仿真时钟,PT-PX 实测);
- 但深流水线代价更大:+382 FF、+652 单元使 V3 内部功耗上升,总功耗
  V3 ≈ V2×1.09(混合负载)/×1.09(SIMD 负载);
- 折合每运算能量:基线 7.96 pJ 最省,V3 为 8.99 pJ——**频率收益(±23%)是用
  ~13% 的能耗换来的**;
- P3 时钟门控在本库视图无法评估(basic.db 无集成 ICG 单元,PWR-191)。

**V3 剩下的墙**(0.25ns 约束、300 条端点分桶):
- S5 合并级(rnd_inc→增量加法→打包 mux,0.73ns)
- S3a(48 位合并加法+LZ+阶码加法,0.73ns)
- lane S4a(掩码+AND 锥,0.73ns)

再往上需要:S5 再切一级(增量加法与打包 mux 分拍)、S3a 再切一级(合并与 LZ 分拍)
——预计 9 级 ≈1.6~1.8 GHz,代价是每级 +1 拍延迟与 ~10% 面积。

## 3. 还有哪些优化空间（按性价比排序）

> 第 1~3 条已在 V3 落地（见 §2.5），但 V3 的 S3a/S5/lane-S4a 仍是 ≈0.73ns
> 的墙，继续往下切的路线：

1. **S5 再切一级（增量加法与打包 mux 分拍）**。V3 的 S5 级 =
   rnd_inc→mr/fsub 增量加法→carry→阶码修正→打包 mux，实测 0.73ns。
   把增量加法结果（mr/carry/ef/fsub/scarry）寄存器化、打包只留纯 mux
   （≈0.35ns），配 +1 拍。
2. **S3a 再切一级（合并加法与 LZ/阶码分拍）**。V3 的 S3a =
   48 位合并加法 + LZ + 阶码加法，实测 0.73ns。把 48 位乘积寄存器化后
   LZ+阶码独立成拍（≈0.4ns）。这两刀下去预期 **9 级 ≈1.6~1.8 GHz**。
3. **S4 代数化简（与 lz 解耦）**。S4 的 `>>k` 移位量 k=25−E3、E3=E+1−lz，
   代入可得 fpre 移位量 `47−E−F`、guard/round/sticky 在乘积域的位置
   `46−E−F / 45−E−F`——**与 lz 无关**，可直接由 48 位乘积 p 并行提取，
   彻底断开 S3→S4 的 lz 依赖链（lane S4a 掩码锥同样适用）。
4. **格式参数化**。当前 fmt 是运行时可编程参数，所有移位都是全可变
   barrel。若按格式例化固定参数实例（per-format 特化），移位变成静态
   布线，S1/S3 延迟大幅下降——代价是失去"单数据通路全复用"的面积优势。
5. **int 路径旁路**。INT 乘法不需要 LZ/归一化/舍入，却与 FP 共用
   S3/S4 深通路（mux 后的 psh 直通）。把 INT 结果在 S2 后直接打包、
   S3/S4 只服务 FP，可缩短 INT 延迟但会加宽 mux。
6. **综合前端兼容性（已修复的工程问题，供其他工具链参考）**：
   - RTL 大量使用 Verilog-2001 尺寸转换 `8'(...)` 等，DC PRESTO 的
     verilog 模式不支持（VER-720），需按 **sverilog** 分析；
   - 流水寄存器声明必须前置于使用点（PRESTO 不解析前向引用，VER-956），
     **已在上游 rtl/fp32_mult.v 修正**（纯文本重排，回归全过）；
   - tb 的 `fpu_rounding_probe()` 在 GCC 下被常量折叠导致 Linux 上
     `make sim` 误报 FATAL——**已在上游 tb 修正**（volatile double 源头）。

## 4. 门级验证（商业仿真器 VCS 全量回放）

DC 网表（0.38ns 约束版，SMIC28 stdcell 功能模型）经 **VCS O-2018.09**
（snps-centos7 兼容层运行）对**全部 2,421,115 条黄金向量**逐拍回放比对：

```
  ... 2000000 / 2421115 vectors checked, 0 mismatches
VCS GATE CHECK: 2421115 vectors, 0 mismatches
GATE-LEVEL GOLDEN REPLAY PASSED   (CPU 147.85 s)
```

零失配，证明 compile_ultra 网表与 RTL 功能完全等价。仿真脚本
`gate_check/iv_tb_full.v`（stim/exp 由 `make_full.py` 从 golden 生成）。

调试过程记录（对后续门级仿真有用）：

- pip 版 verilator 5.38 的 UDP 原语在同一边沿内按顺序求值，会把移位链
  一拍推进多级（r1/r2 同拍翻转、out_valid 提前 2 拍）——**门级仿真勿用**；
- iverilog 语义正确但 vvp 对 1.5 万单元网表太慢（10 万条要几十分钟），
  只用于 2000 条快速自检；
- VCS 二进制需经 `snps-centos7` 兼容层运行（宿主 glibc 不兼容）。

## 4.5 功耗分析（PrimeTime PX + VCS SAIF 活动率反标）

功耗签核用 **PrimeTime PX**（pt_shell）而非 DC 的 report_power：读入 DC 门级
网表 + SMIC28 liberty，用 **VCS 门级仿真的 SAIF 切换活动率**反标（100% 网络
覆盖），按 1.0ns 时钟报告平均功耗。复现（每个 synth/dc*/ 目录）：

```sh
export SYNOPSYS_LC_ROOT=/home/public/app/synopsys/lc/O-2018.06-SP1   # 否则 PT-063
SAIF_FILE=../../gate_check/saif_v3/dut_toggle.saif \
  pt_shell -no_init -f script/pt_power.tcl
```

SAIF 采集（gate_check/saif_*/，VCS -power + $toggle_report，242 万黄金回放 /
100 万 SIMD 密集负载两种 workload）。

| 负载 | 基线 | V2 | V3 |
|------|------|----|----|
| 混合(全部 23 格式)总功耗@1GHz | 8.80 mW | 11.18 mW | 12.24 mW |
| 混合:开关/内部/漏电 | 0.47/5.12/3.21 | 0.52/6.50/4.16 | 0.44/7.53/4.27 (mW) |
| SIMD 密集总功耗@1GHz | — | 11.34 mW | 12.40 mW |
| SIMD 密集:开关 | — | 6.02 µW | **5.11 µW(−15%)** |

注:门级 tb 仿真时钟为 10 MHz(#5000@10ps),SAIF 功耗与频率线性,表中已按
×100 折算到 1GHz;泄漏功耗不随频率变化(基线 32.1 µW 最小,V3 42.7 µW)。

经验记录:本机 pt_shell 不带 PX 时 PWR-001"Power analysis is disabled",需
`set power_enable_analysis true`;PrimePower(pwr_shell)的 read_verilog/
read_ddc 均被禁用(需要 Milkyway 输入),故功耗签核走 pt_shell+PX 路线。

**时钟门控单元调查(回答"库里到底有没有 ICG")**：

- SMIC28 liberty 里**有**专用集成门控单元:`CLKLANAQV2/V4/V6/V8/V12/V16`
  (cell_footprint SCC_CLKLANAQ),属性 `clock_gating_integrated_cell :
  "latch_posedge_postcontrol"`,VCS stdcell 功能模型里也有对应 module;
- 最初 PWR-191 报"无 ICG 单元"是**命令没配对**:DC 默认 control_point=before
  (precontrol),库里只有 postcontrol 型——用
  `set_clock_gating_style -positive_edge_logic {integrated} -control_point after`
  + `compile_ultra -gate_clock` 即可插入(DC 2018 无 set_power_cg_all_registers);
- 插入结果:DC 只给 1 组寄存器(r2a_pp[0][0] + r4_valid,共 25 FF)插了
  CLKLANAQV2;其余 2466 个寄存器自带 stall-enable(EDRNQNV 的 E 端),DC 视为
  已等效门控、不值得再叠 ICG。CG 网表经 VCS 242 万黄金回放 0 mismatch;
- 公平功耗 A/B(同为 1.0ns 重新编译、同负载、PT-PX+SAIF):CG 110.4 µW vs
  无 CG 110.6 µW(仿真时钟 10 MHz)**总功耗 −0.2%**,在编译噪声内——
  enable 门控已覆盖绝大部分收益;ICG 的真正收益在后端**真实时钟树**阶段。

## 5. 复现与产物

| 目录 | 内容 |
|------|------|
| synth/dc/ | 基线综合：makefile、script/dc_sweep.tcl（周期扫描）、inputs/（SDC+filelist+rtl/rtl_v2/rtl_v3 副本）、reports/、outputs/（网表+ddc+sdf） |
| synth/dc_v2/ | S3 切分 6 级变体综合（含 1.0ns 功耗快照） |
| synth/dc_v3/ | **V3 时序+功耗优化 7 级变体综合**（含 SAIF 功耗脚本 script/saif_power.tcl） |
| synth/dc_v3cg/ | V3 + DC 时钟门控实验（CLKLANAQV2 ICG 插入 + PT-PX A/B：−0.2%） |
| synth/dc_retime/ | 寄存器重定时实验（RETIME=1，无收益） |
| v2_check/、v3_check/ | 各变体全量功能验证（242 万黄金 + FPU 交叉 + 穷举 + 随机 + 吞吐，全过） |
| gate_check/ | 门级 VCS 全量回放（iv_tb_full.v）+ SAIF 活动率采集（iv_tb_saif.v、saif_v2/、saif_v3/） |
| parse_reports.py | 报告解析（Fmax 曲线 + 分桶统计） |

结论一句话：**当前 RTL 在 SMIC28/0.8V/25C 的理论上限 ≈1.11 GHz（5 级已平衡）；
S3 切一级（V2/6 级）→ ≈1.31 GHz；S2 流水化 + 移位链重排 + S4/S5 重新分拍 +
功耗门控（V3/7 级）→ ≈1.36 GHz（+23%，每运算能量反而更低）；再往上需 S5 与
S3a 各再切一级（9 级 ≈1.6~1.8 GHz）。**
