# fp32_mult

5 级流水线**多格式 + SIMD 浮点/整数乘法器**:23 种操作模式(14 标量 + 9 打包)、完整 IEEE 754 舍入与异常语义、单一数据通路全复用,含 Verilator 全自动验证与三套独立参考模型互证。

> RTL 风格:纯可综合 Verilog-2001,无 `logic`/`always_ff`/`function`/`task`/`always` 内 procedural `for`;控制 FF 异步低复位、数据 FF 不复位。

## 特性

- **14 种标量格式**:FP32 / FP16 / BF16 / TF32 / BF32 / FP8-E5M2 / FP8-E4M3FN / FP4-E2M1 / INT4·INT8·INT16(有/无符号)
- **9 种 SIMD 打包模式**:FP16x2、BF16x2、FP8-E4M3x4、FP8-E5M2x4、FP4-E2M1x4、INT8U/Sx4、INT4U/Sx4
- **完整 IEEE 754**:5 种舍入模式(RNE/RTZ/RDN/RUP/RNA)、次正规数、NaN/Inf/±0、异常标志 {NV, OF, UF, NX};下溢采用舍入前 tininess(x86/ARM 惯例);E4M3FN 无 Inf(上溢返回其唯一 NaN)
- **固定 5 拍延迟、吞吐 1 组/拍**(SIMD 下 1 组 = K 个结果),ready/valid 反压,可综合
- **最大硬件复用**:全部格式共享同一 24×24 乘法阵列、归一化移位器、舍入单元、次正规对齐路径;SIMD 仅靠阵列子乘器重组 + generate 结构复制,零新增算术模块

## 快速开始

```sh
make sim          # 生成黄金向量(双模型互裁)并跑完整验证
make lint         # Verilator lint(零警告)
make clean
```

依赖:Verilator >= 5.0、Python 3、C++17 编译器(macOS 下需 `-frounding-math`,已内置在 Makefile)。

可选参数:`--seed N`、`--n N`(随机向量数)、`--cross N`(FP32-FPU 交叉验证数)、`--golden FILE`、`--trace`(导出 VCD)。

## 支持格式一览

| fmt | 模式 | 布局(sign/exp/frac 或 N 位) | 备注 |
|-----|------|------------------------------|------|
| 0 | FP32 | 1/8/23 | IEEE binary32 |
| 1 | FP16 | 1/5/10 | IEEE binary16 |
| 2 | BF16 | 1/8/7 | bfloat16 |
| 3 | TF32 | 1/8/10 | 19 位有效 |
| 4 | BF32 | 1/8/15 | 项目自定义(bfloat 家族变体,见 DESIGN.md) |
| 5 | FP8-E5M2 | 1/5/2 | Inf=11111.00,NaN=11111.{01,10,11} |
| 6 | FP8-E4M3FN | 1/4/3 | **无 Inf**;NaN=1111.111;exp=1111 且 mant!=111 为有限值(256~448) |
| 7 | FP4-E2M1 | 1/2/1 | Inf=11.0,NaN=11.1(OCP MX;与 torch e2m1fn 不同,见 DESIGN.md) |
| 8~13 | INT4U/S,INT8U/S,INT16U/S | 4/8/16 | 全精度 2N 位回绕积,不置标志 |
| 14 | **FP16x2** | 2x16b | 每拍 2 结果 |
| 15 | **BF16x2** | 2x16b | 每拍 2 结果 |
| 16 | **FP8-E4M3x4** | 4x8b | 每拍 4 结果 |
| 17 | **FP8-E5M2x4** | 4x8b | 每拍 4 结果 |
| 18 | **FP4-E2M1x4** | 4x4b | 每拍 4 结果 |
| 19/20 | **INT8U/Sx4** | 4x8b | 每拍 4 个 16 位积 |
| 21/22 | **INT4U/Sx4** | 4x4b | 每拍 4 个 8 位积 |

已知限制(见 DESIGN.md 推导):INT16x2 需 32x32 阵列;FP4/INT4 至多 4 路(24x24 阵列只有 4 个可独立配对的子乘器)。

## 文件结构

```
rtl/
  fp32_mult.v        # V1 基线(5 级)——仓库默认 RTL,make sim / lint 使用
  fp32_mult_v2.v     # V2(6 级,S3 切分 S3a/S3b)
  fp32_mult_v3.v     # V3(7 级,时序+功耗优化:S2 流水化+移位链重排+P1/P2 门控)
  fp32_rnd_inc.v     # 舍入增量决策(全格式/SIMD 共用,三个版本共享)
  fp32_defs.vh       # 格式 id 与舍入模式常量(三个版本共享)
tb/
  fp32_mult_tb.cpp   # Verilator 测试平台(通用 C++ 参考模型 + 6 阶段驱动)
  gen_golden.py      # 位运算式 Python 模型,生成黄金向量
  indep_model.py     # 第三 oracle:Fraction 网格就近舍入模型(独立算法)
  golden.txt         # 黄金向量(自动生成,不入库)
  audit_vectors.py   # FP32 定向向量表审计工具
docs/DESIGN.md       # 架构与数学推导
docs/VERIFICATION.md # 验证方法学
docs/SYNTH_DC.md     # DC 综合报告(Fmax 上限、变体对比、门级验证、PT-PX 功耗)
synth/
  dc/                # V1 基线 DC 综合(SMIC28):makefile + 扫描脚本 + SDC + 网表
  dc_v2/             # V2 综合(Fmax +19%)
  dc_v3/             # V3 综合(Fmax +23%)+ PT-PX 功耗脚本
  dc_v3cg/           # V3 + 时钟门控实验(CLKLANAQ ICG 插入)
  dc_retime/         # 寄存器重定时实验(无收益,证明 5 级已平衡)
v2_check/ v3_check/  # V2/V3 全量功能验证(242 万黄金 + 全部 tb 阶段)
gate_check/          # 门级网表 VCS 全量黄金回放 + SAIF 采集(三变体 0 mismatch)
```

三个版本的模块名都是 `fp32_mult`、接口与语义完全一致(功能等价,验证覆盖相同),
差异只在流水级数与内部结构:

| 版本 | 文件 | 级数 | Fmax(SMIC28/0.8V/25°C) | 面积@1GHz | 选型建议 |
|------|------|------|-------------------------|-----------|----------|
| V1 | `rtl/fp32_mult.v` | 5 | ≈1.11 GHz | 10,078 µm² | 默认:低延迟、最省电(7.96 pJ/运算) |
| V2 | `rtl/fp32_mult_v2.v` | 6 | ≈1.31 GHz(+19%) | 11,116 µm² | 中间档 |
| V3 | `rtl/fp32_mult_v3.v` | 7 | ≈1.36 GHz(+23%) | 12,377 µm² | 频率优先(8.99 pJ/运算) |

换版本:把对应文件拷为 `rtl/fp32_mult.v` 即可(make sim 验证;V2/V3 需把 tb 里
`LATENCY` 常量改为 6/7,v2_check/v3_check 内已配好)。

## 接口

| 信号 | 方向 | 说明 |
|------|------|------|
| `clk`, `rst_n` | in | 时钟 / 异步低复位 |
| `in_valid`/`in_ready` | in/out | 输入握手;反压时全流水线冻结 |
| `a[31:0]`, `b[31:0]` | in | 操作数容器(SIMD 模式为 lane 打包) |
| `fmt[4:0]` | in | 操作模式 id(上表) |
| `rm[2:0]` | in | 舍入模式(RISC-V 编码;INT 忽略) |
| `out_valid`/`out_ready` | out/in | 输出握手 |
| `result[63:0]` | out | 标量在 [31:0];INT8x4 为 4x16 位;其余 SIMD 按 lane 密排 |
| `fflags[15:0]` | out | 4 lane x 4 位 {NV,OF,UF,NX};标量在 [3:0] |

## 验证(全自动,一次跑完)

- **黄金回放 242 万条**:两个独立 Python 模型(位运算式 + Fraction 网格式)逐条互裁、一致才落盘,随后 DUT 逐条比对;覆盖每格式全特殊值交互、上溢/下溢/tie 边界、E4M3 exp=1111 有限区、次正规穷举(BF16/E4M3/E5M2)、SIMD 单 lane 穷举与跨 lane 完整性;
- **FP32 vs 宿主 FPU**:100 万 x 4 模式;
- **窄格式穷举**:FP4/FP8/INT4/INT8 全组合;
- **随机混合格式** 200 万(气泡/反压/中途复位);
- **吞吐严格断言**:总拍数 == N + 延迟 + 1。

> 历史:设计经两位独立审查员复核(各自 Fraction 精确模型 63 万 + 830 万条向量),曾发现并修复 E4M3 上溢阈值缺陷,详见 docs/VERIFICATION.md。

## 性能(yosys / nextpnr / icetime 实测,iCE40 HX8K 映射)

| | 标量 | +SIMD |
|---|---|---|
| 面积 | 3,708 LUT4 / ~50K 晶体管 | 8,383 LUT4 / ~108K 晶体管(+126%) |
| 关键路径 | S4 ≈ 57 级 | S4 ≈ 58 级(**不变**) |
| 延迟 / 吞吐 | 5 拍 / 1 结果 | 5 拍 / **1 组(最多 4 结果)** |

SIMD lane 通路未恶化关键路径:用 2.26x 面积换最多 4x 吞吐,频率基本无损。

## ASIC 综合（Design Compiler / SMIC28）

DC O-2018.06 + SMIC28 SCC28NHKCP RVT（tt/0.8V/25°C）实测：

| | 5 级(原版) | 6 级(S3 切分, rtl_v2) | **7 级(时序+功耗优化, rtl_v3)** |
|---|---|---|---|
| Fmax | ≈1.11 GHz | ≈1.31 GHz(+19%) | **≈1.36 GHz(+23%)** |
| 面积@1.0ns | 10,078 µm² / 14,756 单元 | 11,116 µm² | 12,377 µm² / 15,530 单元 |
| 延迟 | 5 拍 | 6 拍 | 7 拍 |
| 关键级 | S3 ≈0.90ns | S2/S3a/S5 ≈0.76ns | S5 打包/S3a/Lane-S4a ≈0.73ns |
| 功耗@1GHz(PT-PX+SAIF 实测) | **8.80 mW** | 11.18 mW | 12.24 mW(P1/P2 门控使开关功耗 −15%,深流水线内部功耗更高) |

- 三个变体均经 **VCS 门级全量 2,421,115 条黄金向量回放,0 mismatch**(gate_check/)。
- 完整报告、Fmax 扫描曲线、SAIF 功耗分析与下一步路线见 [docs/SYNTH_DC.md](docs/SYNTH_DC.md)；
  复现:`cd synth/dc_v3 && make dc`(命令流参照 ~/project/newff 的 DC 流程)。

## 文档

- [docs/DESIGN.md](docs/DESIGN.md) — 流水线架构、容器约定、全部数学推导、格式特殊值、SIMD 子乘器原理
- [docs/VERIFICATION.md](docs/VERIFICATION.md) — 三 oracle 方法学、覆盖矩阵、复现步骤、审查历史
- [docs/SYNTH_DC.md](docs/SYNTH_DC.md) — DC 综合报告:Fmax 上限、关键路径分桶、S3 切分实验、优化建议、门级验证

