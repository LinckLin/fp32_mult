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
（`set_optimize_registers true`，dc_v3），Fmax 1.096 GHz（vs 1.106），
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

## 3. 还有哪些优化空间（按性价比排序）

1. **流水化 12×12 乘法器（S2 再切）**。当前乘法器 0.76~0.90 ns 是硬墙。
   经典 FPU 做法是把阵列乘法拆成 2 级（部分积 + 压缩树分两拍）。
   预期：S2 降到 ~0.45ns 后，Fmax 被 S3a/S5 的 0.76ns 继续限制，需配套
   第 2、3 条。
2. **S3a 继续切 / 代数化简**。S3 的 `p<<lz>>(23-F)` 与 S4 的 `>>k` 是
   **两级串行桶形移位**，而 k=25−E3、E3=E+1−lz，代入可得 S4 移位量
   `47−E−F`、guard/round/sticky 位在乘积域的位置 `46−E−F / 45−E−F`——
   **与 lz 无关**。即 S3 的移位结果只被 m 切片使用，S4 完全可以
   **直接由 48 位乘积 p 并行提取**（g/r/s、sg/sr/ss、fpre 全部是 p 的
   纯位提取，移位量只依赖 E、F），省掉一整级串行移位延迟。这是
   DESIGN.md 公式的未挖掘推论，值得重写 S3/S4 接口。
3. **S5 打包级拆分/化简**。S5 锥 = 增量加法器 + NaN/Inf/max 模式 mux +
   64 位结果拼装，0.76~0.90ns。可把增量加法放进 S4 级（普通路径的
   mr=m+inc 与次正规的 fsub 提前一周期算好）、S5 只留纯 mux。
4. **格式参数化**。当前 fmt 是运行时可编程参数，所有移位都是全可变
   barrel。若按格式例化固定参数实例（per-format 特化），移位变成静态
   布线，S1/S3 延迟大幅下降——代价是失去"单数据通路全复用"的面积优势。
5. **int 路径旁路**。INT 乘法不需要 LZ/归一化/舍入，却与 FP 共用
   S3/S4 深通路（mux 后的 psh 直通）。把 INT 结果在 S2 后直接打包、
   S3/S4 只服务 FP，可缩短 INT 延迟但会加宽 mux。
6. **综合前端兼容性（与本次 DC 流程相关的工程问题）**：
   - RTL 大量使用 Verilog-2001 尺寸转换 `8'(...)` 等，DC PRESTO 的
     verilog 模式不支持（VER-720），需按 **sverilog** 分析；
   - 流水寄存器声明放在模块末尾、前文先使用，PRESTO 不解析前向引用
     （VER-956），需把声明块前移（synth/dc/inputs/rtl/ 内为语义等价的
     副本，建议上游直接调整）；
   - tb 的 `fpu_rounding_probe()` 在 GCC 下被常量折叠
     （`(float)0x1.000001p0` 编译期算完），Linux/GCC 上 `make sim`
     会误报 FATAL——源头改成 volatile double 即可（v2_check 已修）。

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

## 5. 复现与产物

| 目录 | 内容 |
|------|------|
| synth/dc/ | 基线综合：makefile、script/dc_sweep.tcl（周期扫描）、inputs/（SDC+filelist+声明前移副本）、reports/（qor/timing/endpoints/area/power）、outputs/（网表+ddc+sdf） |
| synth/dc_v2/ | S3 切分 6 级变体综合（同上结构） |
| synth/dc_v3/ | 寄存器重定时实验（RETIME=1） |
| synth/dc/inputs/rtl_v2/ | V2 RTL（6 级） |
| v2_check/ | V2 全量功能验证（242 万黄金 + FPU 交叉 + 穷举 + 随机 + 吞吐，全过） |
| gate_check/ | 门级 iverilog 黄金回放 + 失败调试记录 |
| parse_reports.py | 报告解析（Fmax 曲线 + 分桶统计） |

结论一句话：**当前 RTL 在 SMIC28/0.8V/25C 的理论上限 ≈ 1.11 GHz，5 级已
平衡；S3 切一级（6 级）实测提升到 ≈1.31 GHz（+19%，面积 +21%），再往上
需要流水化乘法器 + S3/S4 移位代数合并 + 打包级拆分。**
