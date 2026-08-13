# RTL 编码风格指南（可综合 Verilog-2001）

> 本项目所有设计代码（`rtl/*.v`）必须遵守本指南。**核心原则：写硬件，不要写软件。**
> 每一行 RTL 都要能对应到一块组合逻辑或一组触发器；凡是"描述一个计算过程/算法步骤"
> 而非"描述一块电路结构"的写法，一律禁止。验证代码（`testbench/*.sv`）不受此约束。

## 0. 总原则（硬件思维）

- 先想清楚这段代码综合出来是什么电路（多少 FF、多少 mux、多少加法器、关键路径多长），再写。
- 结构优先：用 `generate` 复制结构、用例化搭数据通路；不要用过程式循环"算"出结果。
- 面积可预测：避免让综合器自由展开的写法（动态位宽、隐式大 mux、无边界的归约）。
- 多参考 `ref_project/`（cv32e40p、common_cells、coralnpu、quadrilatero）的真实工业风格。

## 1. 语言子集

**只用 Verilog IEEE 1364-2001 可综合子集，文件后缀 `.v`。**

允许：
- `module`（ANSI 端口风格）、`wire`/`reg`、`assign`、`always`、`generate`/`genvar`、
  `parameter`/`localparam`、`case`/`if`、位拼接 `{}`、部分选择 `[a +: w]`、三目 `?:`。
- 系统函数 `$clog2`（仅用于 localparam 计算位宽，VCS/DC/Spyglass 均支持）。
- 多维存储器：`reg [W-1:0] mem [0:N-1]`。

禁止（SystemVerilog / 不可综合 / 软件化）：
- 类型：`logic`、`typedef`、`enum`、`struct`、`union`、`interface`、`packed` 多维 `[A-1:0][B-1:0]`。
- 过程块：`always_ff`/`always_comb`/`always_latch`（用经典 `always @(...)`）。
- **`function` / `task`**（一律禁止，含自动函数）。
- **`always` 块内的 procedural `for` 循环**（见 §4，用 `generate` 替代）。
- `initial`、`#delay`、`fork`、`wait`、`force`、动态数组、`real`、`string`（综合代码内）。
- DPI、`$display` 等仿真系统任务（综合代码内）。

## 2. 复位策略

- 复位为**异步低有效**：`always @(posedge clk or negedge rst_n)`，复位分支写在最前。
- **控制状态 FF 必须复位**（状态机、计数器、valid/busy/指针、握手寄存器）。
- **数据存储 FF 不接复位**（VRF / MT RF 的数据位元、操作数缓冲等大体量 FF）：
  赛题不要求复位初值，挂复位树是面积/布线纯亏损。数据 always 块写成：
  ```verilog
  always @(posedge clk) begin            // 注意：敏感列表不含 rst_n
      if (we) mem[waddr] <= wdata;
  end
  ```
- 一个 always 块只服务一类（带复位 / 不带复位），不要混。

## 3. 时序 / 组合 always 规则

- 时序块用非阻塞赋值 `<=`；组合块用阻塞赋值 `=`。**不要混用。**
- 组合 `always @(*)`：**必须无意中生成 latch** —— 每条路径都赋值，或在块首给默认值：
  ```verilog
  always @(*) begin
      y = 1'b0;          // 默认值，杜绝 latch
      if (sel) y = a;
  end
  ```
- 优先用连续赋值 `assign` 表达组合逻辑；复杂选择用 `case`（带 `default`）。
- 敏感列表：组合块用 `@(*)`；时序块只列 `clk` 与（异步复位时）`rst_n`。

## 4. 复制与例化（generate —— 替代 for 的唯一手段）

- **结构复制 / 模块例化用 `generate` + `genvar`**（这是允许的"for"）：
  ```verilog
  genvar gi;
  generate
      for (gi = 0; gi < N_LANE; gi = gi + 1) begin : g_lane
          mp_dot_lane u_lane (... gi ...);
      end
  endgenerate
  ```
- 也可用 `generate-for` 复制连续赋值 / 例化字节通道，但**不要**用它替代真正的过程式算法。
- 固定小规模的归约 / mux（如 4 路点积求和），写**显式表达式**或**平衡树**，不要 procedural for：
  ```verilog
  wire signed [33:0] sum = p0 + p1 + p2 + p3;   // 让综合器推平衡加法树
  ```
- 大 mux（如 32:1 选 v 寄存器）用 `case` 或 generate 出的 one-hot & 树，注意关键路径。

## 5. 命名与文件

- 一个文件一个 module，文件名 == module 名（`mp_xxx.v`）。
- 信号命名：低电平有效加 `_n`（`rst_n`）；组合的"下一拍值"用 `_nxt`；握手 `_valid`/`_ready`。
- 模块/信号前缀 `mp_`（matrix processor）。常量统一来自 `rtl/mp_defs.vh`。
- 端口顺序：clk/rst_n → 输入控制 → 输入数据 → 输出。

## 6. 握手与接口

- 统一 valid/ready：`valid` 拉高后数据保持稳定，直到 `ready` 同拍握手；`ready` 可早于 `valid`。
- 握手发生 = `valid & ready` 同拍为真。
- payload 与 valid 分离，便于复用（参考 coralnpu 范式）。
- 跨模块接口一旦定稿即为**稳定契约**，改接口要同步所有使用方并回归。

## 7. 算术与位宽

- 显式管理位宽：所有中间量声明足够宽度，避免隐式截断/扩展告警。
- 有符号运算用 `signed`（`wire signed [...]`），无符号/有符号统一靠显式 1bit 符号扩展进有符号通路。
- 溢出按赛题语义自然回绕（截低位），**不要**加饱和逻辑。
- 用 `*`、`+` 让综合器推断乘法器/加法器是允许的（这是硬件描述，不是软件循环）；
  需要面积可控时再做结构拆分（如 9×9 部分积），以注释说明意图。

## 8. 必须避免的"软件化"反模式

- ❌ `for` 循环遍历做累加/查找/排序（→ 用 generate 结构 或 显式展开）。
- ❌ `function`/`task` 封装"算法"（→ 用连续赋值 / 子模块）。
- ❌ 用变量当下标做动态多级索引（→ 固定结构 + case/mux）。
- ❌ while / repeat / 递归 / 可变循环次数。
- ❌ 在一个 always 里又读又写同一数组多个元素来"模拟"并行（→ 真正并行的多 always / generate）。
- ❌ 把状态机写成"一段顺序执行的过程"（→ 显式 state 寄存器 + 次态组合逻辑）。

## 9. 模块头注释模板

```verilog
// =============================================================================
// mp_xxx : <一句话职责>
// -----------------------------------------------------------------------------
// 接口契约：
//   - <端口组1>：<语义、握手、稳定性约束>
//   - <端口组2>：...
// 实现要点：<级数 / 复位策略 / 关键结构 / 对应 spec 章节>
// 参考：<ref_project 文件:行 或 spec 章节>
// =============================================================================
```

## 10. 提交前自检清单

1. 无 SV 构造、无 `function`/`task`、`always` 内无 procedural `for`。
2. 组合块无 latch（每路径赋值或有默认值）；时序 `<=`、组合 `=`，未混用。
3. 数据大 FF 不接复位；控制 FF 全部复位（异步低有效）。
4. 位宽匹配无隐式截断；有符号路径正确。
5. 端口与 `mp_defs.vh` 常量一致；接口与契约文档一致。
6. 通过 `make compile`（VCS 无 error/严重 warning）与 Spyglass lint。
