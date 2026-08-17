# Vivado 流程

## 环境

- Vivado 2024.2（本机路径 `E:\verilog\Vivado\2024.2`，bin 与 lib 加入 PATH）。
- 源文件：`sc_opt_work/*.v`（10 个 RTL + 6 个 TB）。

## 行为仿真

```powershell
xvlog --work work controller.v sc_pe.v sc_llr_mem.v sc_beta_mem.v sc_uhat_mem.v sc_datapath.v sc_decoder_core.v frozen_gen.v polar_reliability_rom.v sc_fast_node_rom.v <tb>.v
xelab -L work -s <snap> work.<tb>
xsim <snap> -runall
```

项目里的 `run_sim.ps1` / `sim_run.tcl` 封装了这套命令，按 TB 名输出快照与日志。

## 综合

`synth_run.tcl` 要点：

- `create_project <proj> <dir> -part <part>`，`add_files` 10 个 RTL，`top=sc_decoder_core`；
- strategy `Flow_RuntimeOptimized` + `STEPS.SYNTH_DESIGN.ARGS.NO_CROSS_BOUNDARY_OPT true`（保证 before/after 可比）；
- `launch_runs synth_1 -jobs 8`；`report_utilization -hierarchical`。

**License 问题**：本机无 ZU47DR license，Vivado 报 `A valid license was not found for feature 'Synthesis' and/or device 'xczu47dr'`。应对：

- 用 `xc7a200tfbg676-2`（WebPACK 最大器件）做相对面积趋势参考；实测 baseline 与用户 ZU47DR 报告 LUT/F7/F8 几乎逐位一致（FF 差 0.1%）；
- 绝对面积/时序必须回目标器件 ZU47DR 重综合、布局布线。

## 综合后 / 实现后仿真（目标器件环境）

Vivado GUI：Run Synthesis →（Run Implementation）→ SIMULATION → Launch Simulation 下拉：

- Post-Synthesis Functional / Timing
- Post-Implementation Functional / Timing

Tcl 等价：

```tcl
launch_simulation -mode post-synthesis      -funcsim
launch_simulation -mode post-synthesis      -timing
launch_simulation -mode post-implementation -funcsim
launch_simulation -mode post-implementation -timing
```

注意：网表仿真必须用只驱动顶层端口的 TB（`tb_256` / `tb_1024` / `sc_five_n_switch_tb` 含层次化内部引用，直接跑会失败）。

## 封装 IP 核

- **软核**：Vivado IP Packager 打包 RTL 源码，不需要目标器件 license。
- **固核**：目标器件综合 → 布局布线 → 时序收敛 → 导出网表/DCP → 打包，需要 ZU47DR license。
- 封装前建议：接口标准化为 AXI4-Lite（配置）+ AXI4-Stream（LLR/u_hat），或固化为文档化握手协议；准备约束 XDC、示例工程、接口文档。
