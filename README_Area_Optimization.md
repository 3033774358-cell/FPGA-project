# sc_fast_ssc_small —— 可综合成 BRAM/LUTRAM 的版本（2026-08-17 定稿）

本文件夹为 `sc_fast_ssc_small` 的**存储器面积优化最终版**，全部存储体
（LLR / beta / uhat / 节点类型表）均已映射到 BRAM / 分布式 RAM，
不再退化为寄存器阵列 + 巨型 MUX。

## 一、与 2026-08-12 重构版相比新增的改动

| 文件 | 改动 | 说明 |
|---|---|---|
| `sc_fast_node_rom.v` | **重写（2026-08-17）** | 2047×2bit 寄存器数组（带异步复位，无法推断 RAM）→ copyA/copyB × 8 bank × 256×2bit 分布式 RAM；组合读延迟保持 0 拍，控制器/数据通路**零改动** |
| `sc_llr_mem.v` | 重写（08-12） | copyA/copyB 2048×10bit 简单双口 BRAM + copyV 8×(256×10bit) BRAM bank |
| `sc_beta_mem.v` | 重写（08-12） | 2 副本 × 8 bank × 256×1bit 分布式 RAM，去存储体复位 |
| `sc_uhat_mem.v` | 重写（08-12） | 2 副本 × 8 bank × 128×1bit 分布式 RAM（copyA 双读口），去存储体复位 |
| `sc_datapath.v` / `controller.v` / `frozen_gen.v` / `polar_reliability_rom.v` | 小改（08-12） | 声明顺序 / timescale，行为不变 |

顶层接口（`sc_decoder_core`）冻结未动；存储读延迟维持 1 拍（LLR/Beta/Uhat）
与 0 拍组合读（节点类型表），**译码周期数与 baseline 逐拍一致**。

## 二、功能验证（Vivado 2024.2 xsim，全部 PASS）

| Testbench | 结果 | 周期数 |
|---|---|---|
| `tb_llr_vec_bounds` | PASS | — |
| `sc_datapath_tb`（776 checks） | PASS | — |
| `tb_fast_zero_fallback_64` | PASS（零 LLR 回退触发） | — |
| `tb_256`（4 case / 9467 checks） | PASS | 3284/case |
| `tb_1024`（4 case / 37659 checks） | PASS | 15606/case |
| `sc_five_n_switch_tb`（5 case / 9883 checks） | PASS | 681/1479/3265/7076/15526 |

Python 逐周期模型回归（768 用例 + 1140 组含 0 随机软 LLR + 240 组零密集
corner + 背靠背/反压 + 5G 掩码基准）全部 bit-exact PASS。

## 三、综合结果（xc7a200tfbg676-2，Vivado 2024.2）

统一策略：`Flow_RuntimeOptimized` + `-flatten_hierarchy none`
（对应技能约定的"关闭跨边界优化"，保证分层统计可比）。

| 模块 | Baseline LUT | 优化后 LUT | Baseline FF | 优化后 FF | RAM 映射 |
|---|---:|---:|---:|---:|---|
| sc_decoder_core（总） | **156529** | **5587** | 29346 | 1578 | 10 BRAM + 480 LUTRAM |
| u_datapath | 146075 | 1474 | 23845 | 172 | — |
| u_sc_llr_mem | 73221 | 272 | 20627 | 35 | 2×RAMB36 + 8×RAMB18 |
| u_sc_beta_mem | 46004 | 287 | 2049 | 2 | 128 LUTRAM |
| u_sc_uhat_mem | 26621 | 687 | 1076 | 45 | 96 LUTRAM |
| u_fast_node_rom | 7042 | 694 | 4115 | 21 | 256 LUTRAM |
| u_controller | 1021 | 1027 | 305 | 304 | 0 |
| u_frozen_gen（含可靠度 ROM） | 2365 | 2365 | 1057 | 1057 | 0 |

关键降幅：**总 LUT -96.4%**，FF -94.6%，F7 37545→657（-98.3%），
F8 18602→136（-99.3%）；BRAM 0→10（2×RAMB36 + 8×RAMB18），
LUTRAM 0→120×RAM128X1D（480 LUT）。

## 四、RAM 映射清单（综合日志 Final Mapping Report）

- Block RAM：`u_ram_a` / `u_ram_b`（2048×10）→ 2×RAMB36；
  `gen_ram_v[0..7]`（256×10）→ 8×RAMB18；
- 分布式 RAM：beta 16 bank、uhat 24 bank（RAM128X1D）、
  节点类型表 16 bank（copyA 1 读口 + copyB 2 读口，RAM128X1D）；
- `polar_reliability_rom`（1024×10 组合读）→ LUT（180 LUT，量级可忽略）。

## 五、使用方法

1. 用本文件夹同名 `.v` 覆盖 Vivado 工程源文件（原文件已备份于
   `orig_backup_20260812\`）；
2. 综合顶层 `sc_decoder_core`；建议使用统一策略
   `Flow_RuntimeOptimized` + `-flatten_hierarchy none`；
3. 本机无 ZU47DR license，绝对数字以 Y790s/ZU47DR 重综合为准
   （趋势已由 xc7a200t 验证：baseline 与 ZU47DR 报告一致）。

## 六、复现脚本（存放在 codex 工作区）

- `sc_fast_ssc_bram_verify/synth_run.tcl`：批量综合（tclargs = 输出目录 源码目录）
- `sc_fast_ssc_bram_verify/run_regression.ps1`：6 个 TB 回归
