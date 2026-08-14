# fp32_mult DC 综合（SMIC28, DC 2018）

流程复制自 `~/project/newff` 的 DC 运行方式：

- 库/命令：`/home/public/eda_script/Frontend_makefile/dc_lib.tcl`（SMIC28 SCC28NHKCP RVT,
  tt_v0p8_25c_basic.db），综合命令 `analyze/elaborate/link -> uniquify ->
  compile_ultra -no_autoungroup [-incremental]`，与 newff `backend/syn/dct` 一致。
- 约束：`inputs/fp32_mult.func.sdc` + `inputs/io.sdc`（格式同 newff/backend/sdc/）。
- `script/dc_sweep.tcl`：初次以 1.0ns 时钟综合，随后逐轮收紧周期
  （0.80/0.65/0.55/0.48/0.42/0.38/0.34/0.30/... ns）做 `compile_ultra -incremental`，
  每轮输出 qor/timing/endpoints/area 报告，WNS < -0.5ns 时停止 —— 用于找理论 Fmax。

运行：

    cd fp32_mult/synth/dc
    make dc        # 约 10~20 分钟，日志 dc.log，报告在 reports/，网表在 outputs/

    make clean
