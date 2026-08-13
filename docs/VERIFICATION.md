# fp32_mult 验证方法学(VERIFICATION)

本文档说明「三个独立 oracle 互证 + 分层激励」的验证体系、覆盖矩阵、复现步骤与审查历史。

## 1. 三套独立参考模型

| oracle | 位置 | 算法 | 独立性 |
|--------|------|------|--------|
| C++ 参考模型 | `tb/fp32_mult_tb.cpp` (ref_ieee) | 位运算式:LZ + 移位归一化 + 对齐 + G/R/S 舍入 | 与 RTL 同构(镜像实现) |
| Python 位运算模型 | `tb/gen_golden.py` | 同上,独立语言实现 | 与 C++ 互为转写检查 |
| **Python Fraction 网格式模型** | `tb/indep_model.py` | **完全不同算法**:精确有理值 -> bit_length 定位指数 -> 整数除法取相邻网格点 -> 比较舍入;无 LZ、无移位归一化、无 k=25-E3 守卫 | **算法级独立** |

另有两个外部独立裁判:
- 宿主 FPU(双精度):FP32 模式与 C++ 参考 100 万 x 4 模式交叉(两个 24 位尾数的乘积在 double 中精确,单次舍入即 IEEE 正确);
- 两位独立审查员各自的 Fraction 模型(63 万 + 830 万条向量复核,见 §5)。

## 2. 验证流程(`make sim` 一次跑完)

```
[0/5] 黄金回放     gen_golden.py 生成时:位运算模型 vs Fraction 模型逐条互裁,
                   不一致立即 abort;随后 DUT 逐条比对,同时 C++ 参考再互证
[1/5] FP32-FPU     C++ 参考 vs 宿主 FPU,100 万 x 4 模式(含 OF/UF/NX 标志)
[2/5] 定向表       63 条手工推导 FP32 向量(干净 + 随机反压各一遍)
[3/5] 窄格式穷举   FP4 16x16x5、E4M3/E5M2 256x256x5、INT4/INT8 全组合
[4/5] 随机混合     200 万条,随机 fmt(0~22)/rm、特殊值注入、气泡、
                   12% 反压、中途复位注入
[5/5] 吞吐         20 万背靠背,严格断言 总拍数 == N + 延迟 + 1
```

黄金向量共 **2,421,115 条**(约 80 MB,不入库,`make sim` 自动生成),覆盖:

| 类别 | 内容 |
|------|------|
| 标量特殊值 | 每格式 22~26 个特殊模式(sNaN/qNaN/Inf/±0/±min_sub/±max_sub/±min_norm/±1/±max...)两两全对 x 5 模式 |
| 标量边界 | 每格式 17 组 tie/上溢/下溢/舍入进正规 + E4M3 exp=1111 有限区(448/256 x {1,1.125,...,1.875} 全模式) |
| 次正规 | E4M3/E5M2/BF16 穷举,FP16/TF32/BF32 25 模式结构化子集 |
| INT | INT4/INT8 穷举,INT16 采样 |
| SIMD | lane-splat 特殊值、单 lane 特殊值两两 x 5、FP4/INT4 单 lane 全穷举、FP8/INT8 单 lane 256x256 穷举(其余 lane 固定 1.0,检验跨 lane 完整性)、每模式 3 万随机全宽 |

## 3. 关键机制

- **双模型互裁**:黄金向量只有两个 Python 模型逐条一致才写盘,任意分歧立即报错退出;
- **驱动协议**:ready/valid 精确建模——输出在周期内稳定、消费者在上升沿**前**取值;反压/气泡/复位均按握手语义记账(dropped 计数 = 复位时刻在途向量数,实测 4~5);
- **吞吐严格断言**:任何延迟漂移(+1 拍)即 FAIL;
- **FPU 探测**:启动时自检宿主 fesetround/fetestexcept 是否生效,失败则明确告警而非静默降级;RNA(ties-away)宿主 FPU 无此模式,改由两个独立 Python 模型 + 穷举覆盖(已在 README 注明)。

## 4. 复现

```sh
# 依赖:Verilator>=5.0 / Python3 / C++17 编译器(macOS 自动加 -frounding-math)
make sim                       # 全套(约 2~4 分钟,含黄金向量生成)
make sim ARGS=--seed 42        # 换种子
make lint                      # 零警告
python3 tb/gen_golden.py       # 单独重生成黄金向量(双模型互裁)
python3 tb/audit_vectors.py    # 审计 FP32 定向向量表
```

`make sim` 输出示例:

```
[0/5] golden replay (independent Python oracle, all formats) ...
      C++ ref vs golden: 2421115 vectors agree
      DUT vs golden: 2421115 vectors passed (2421121 cycles)
      passed (1000000 vectors x 4 modes)        # FP32-FPU
      fmt=7 (16 x 16 x 5) passed ...            # 窄格式穷举
      passed (2000000 vectors, 2223652 cycles, 4 dropped by reset)
      passed: 200000 results in 200006 cycles (latency 5, 1 result/cycle)
ALL PHASES PASSED
```

## 5. 审查历史

设计经两位独立审查员(senior RTL 审查 + 验证方法学审查)复核,各自实现了独立的 Fraction 精确模型:

1. 第一轮发现 **E4M3FN 上溢阈值 off-by-one**(exp=1111 且 mant!=111 的 256~448 有限区被误判为上溢->NaN)——三处模型 + RTL 同步修复,审查员复现向量与独立模型回归确认;
2. 指出两个参考模型算法同构——随后引入第三套 Fraction 网格式模型并接入黄金生成流水线(逐条互裁),补齐 E4M3 exp=1111 全扫、次正规穷举等覆盖;
3. 吞吐断言由宽松上界收紧为严格等式;最终两位审查员均给出 APPROVE。

其余修复历史:FP16 次正规粘滞位必须取自完整乘积(而非截断后尾数)、下溢 tininess 采用舍入前惯例、lane 次正规移位量需 8 位(6 位截断)、INT lane 结果宽度为操作数 2 倍、lane 字段需逐字段重打包进标量容器——均被黄金回放/独立模型捕获。

