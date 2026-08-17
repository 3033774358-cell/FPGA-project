# SC 译码器存储器面积优化 —— 最终报告（2026-08-17）

> 工程：`F:\ic_FPGA\FPGA\project\tv_verification\sc_fast_ssc_bram`
> （BRAM 版独立存放；原 `sc_fast_ssc_small` 文件夹保持原样）
> 目标器件：威视锐 Y790s / ZU47DR（本机无 ZU47DR license，用 xc7a200t 做
> 相对趋势；baseline 在 xc7a200t 与 ZU47DR 报告几乎逐位一致，见 2026-08-12 阶段报告）
> 工具：Vivado 2024.2（xsim 仿真 + xc7a200t 综合）

## 0. 结论（TL;DR）

把原来"全部存储体退化为寄存器阵列 + 巨型 MUX"的实现，改成
**LLR→BRAM、beta/uhat/节点类型表→分布式 RAM** 的可综合版本：

- 总 LUT：**156,529 → 5,587（-96.4%）**
- FF：29,346 → 1,578（-94.6%）；F7：37,545 → 657（-98.3%）；F8：18,602 → 136（-99.3%）
- BRAM：0 → **10**（2×RAMB36 + 8×RAMB18）；LUTRAM：0 → 480 LUT（120×RAM128X1D）
- 6 个系统级 TB 全部 PASS，译码周期数与 baseline **逐拍一致**（bit-exact）

## 1. 根因（为什么 baseline 是 156K LUT / 0 BRAM）

1. `sc_llr_mem`：写 always 块带异步复位 + 10 个读端口打在同一寄存器数组
   → Vivado `Synth 8-4767` 拒绝 RAM 推断，2047×10bit 退化为 FF + 2047:1 MUX 树；
2. `sc_beta_mem` / `sc_uhat_mem`：整数组复位循环 → BRAM/LUTRAM 均无法推断；
3. `sc_fast_node_rom`：同一异步复位块问题，2047×2bit 退化为 FF。

## 2. 修改方案（端口/时序/算法全部不变）

| 模块 | 修改后结构 |
|---|---|
| `sc_llr_mem` | copyA/copyB 2048×10bit 简单双口 BRAM（1W+1R）+ copyV 8×(256×10bit) BRAM bank（Fast 宽读） |
| `sc_beta_mem` | 2 副本 × 8 bank × 256×1bit 分布式 RAM（宽写按 bank 折叠）；去存储体复位 |
| `sc_uhat_mem` | 2 副本 × 8 bank × 128×1bit 分布式 RAM（copyA 双读口：宽读+串行输出）；去存储体复位 |
| `sc_fast_node_rom` | **2026-08-17 新增**：copyA(1 读口)/copyB(2 读口) × 8 bank × 256×2bit 分布式 RAM；组合读 0 拍不变，控制器零改动 |

关键纪律：
- 存储体去掉异步复位/整块复位，依赖"读前必写"算法保证（Rate-0 跳过时父节点显式写 0，输出级 frozen 掩码兜底）；
- 宽读/宽写按地址低 3 位拆 bank，任何周期不超单 bank 1W+1R（beta/uhat/类型表）或独立端口（BRAM）物理能力；
- 仿真影子数组（`llr_mem`/`beta_mem`/`uhat_mem`/`type_ram`）全部放 `ifndef SYNTHESIS`，综合时排除；
- 越界保护使用与数据同拍的寄存地址（`rd_vec_addr_r`），避免 gap 周期泄漏陈旧 lane 数据。

## 3. 功能验证

### 3.1 RTL 回归（Vivado 2024.2 xsim，6 个 TB 全 PASS）

| Testbench | 结果 | 周期数 |
|---|---|---|
| `tb_llr_vec_bounds` | PASS | — |
| `sc_datapath_tb`（776 checks） | PASS | — |
| `tb_fast_zero_fallback_64` | PASS（Rate-1 零 LLR 回退正确触发） | — |
| `tb_256`（4 case / 9467 checks） | PASS | 3284/case |
| `tb_1024`（4 case / 37659 checks） | PASS | 15606/case |
| `sc_five_n_switch_tb`（5 case / 9883 checks） | PASS | 681/1479/3265/7076/15526 |

### 3.2 Python 逐周期模型

`regress_fallback.py` + `sc_fast_model.py` + `check_appendix_h_fast.py`：
768 用例 + 1140 组含 0 随机软 LLR（365 组触发回退）+ 240 组零密集 corner
+ 背靠背/反压 + 5G 掩码基准，Fast-SSC 与流水线 SC **逐位一致** PASS。

## 4. 综合对比（同一器件 xc7a200tfbg676-2、同一策略）

策略：`Flow_RuntimeOptimized` + `-flatten_hierarchy none`
（Vivado 2024.2 中"关闭跨边界优化"的等价写法）。

| 模块 | Baseline LUT | 优化后 LUT | Δ | Baseline FF | 优化后 FF | 优化后 RAM |
|---|---:|---:|---:|---:|---:|---|
| sc_decoder_core（总） | 156529 | **5587** | **-96.4%** | 29346 | 1578 | 10 BRAM + 480 LUTRAM |
| u_datapath | 146075 | 1474 | -99.0% | 23845 | 172 | — |
| u_sc_llr_mem | 73221 | 272 | -99.6% | 20627 | 35 | 2×RAMB36 + 8×RAMB18 |
| u_sc_beta_mem | 46004 | 287 | -99.4% | 2049 | 2 | 128 LUTRAM |
| u_sc_uhat_mem | 26621 | 687 | -97.4% | 1076 | 45 | 96 LUTRAM |
| u_fast_node_rom | 7042 | 694 | -90.1% | 4115 | 21 | 256 LUTRAM |
| u_controller | 1021 | 1027 | +0.6% | 305 | 304 | 0 |
| u_frozen_gen（含可靠度 ROM） | 2365 | 2365 | 0 | 1057 | 1057 | 0 |

顶层汇总：

| 资源 | Baseline | 优化后 | 降幅 |
|---|---:|---:|---:|
| Slice LUTs | 156529 | 5587 | -96.4% |
| Slice Registers | 29346 | 1578 | -94.6% |
| F7 Muxes | 37545 | 657 | -98.3% |
| F8 Muxes | 18602 | 136 | -99.3% |
| Block RAM | 0 | 10（2×RAMB36 + 8×RAMB18） | 0 → 10 |
| LUT as Memory | 0 | 480（120×RAM128X1D） | 0 → 480 |
| DSP | 0 | 0 | — |

## 5. RAM 映射（综合日志 Final Mapping Report）

- Block RAM：`u_ram_a`、`u_ram_b`（2048×10）→ RAMB36E1×2；
  `gen_ram_v[0..7]`（256×10）→ RAMB18E1×8；
- 分布式 RAM：`sc_bit_bank`×16（beta，256×1，RAM128X1D×2/个）、
  `sc_bit_bank_2r`×8 + `sc_bit_bank`×8（uhat，128×1）、
  `sc_type_bank`×8 + `sc_type_bank_2r`×8（节点类型表，256×2）；
- `polar_reliability_rom`（1024×10 组合读，仅 180 LUT）保持 LUT，量级可忽略。

## 6. 剩余事项

1. **Y790s/ZU47DR 绝对数字**：本机无 `xczu47dr` 综合 license，拿到 license 后
   在目标器件上重综合确认绝对利用率与时序收敛；
2. `polar_reliability_rom` 如需 BRAM，需把组合读改同步读并在 `frozen_gen`
   配置 FSM 中吸收 1 拍延迟（配置时延 +N 拍，不影响译码周期），收益仅 ~180 LUT，
   当前优先级低；
3. 后续可做的吞吐优化（与面积无关）：REP/SPC 节点、更深流水、多码块重叠。

## 7. 复现

- 综合：`synth_run.tcl`（vivado -mode batch -source synth_run.tcl -tclargs <out> <rtl>）
- 回归：`run_regression.ps1`（xvlog/xelab/xsim，6 TB）
- 报告输出：`E:\codex\output\sc_fast_ssc_bram_synth\{base,opt,opt2}\`
  - `base`：baseline（orig_backup_20260812）
  - `opt`：08-12 三存储器重构版（未含 fast_node_rom 改动）
  - `opt2`：最终版（含 fast_node_rom LUTRAM 化）
