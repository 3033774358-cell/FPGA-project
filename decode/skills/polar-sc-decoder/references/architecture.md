# 架构与接口

## 顶层模块 sc_decoder_core

参数（一经确定保持稳定）：

- `NMAX=1024`、`LLR_W=8`、`INT_W=10`、`MAX_LOG=10`
- `MEM_DEPTH=2*NMAX-1=2047`、`ADDR_W=11`、`INDEX_W=11`、`FAST_P=8`

顶层接口（冻结，优化只动内部）：

| 分组 | 信号 |
|---|---|
| 全局 | `clk`、`rst_n` |
| 配置 | `config_start`、`n_log_cfg[3:0]`、`k_cfg[10:0]`、`config_ready`、`config_busy`、`config_done`、`config_error` |
| 码块 | `block_start`、`block_ready`、`block_busy`、`block_done` |
| LLR 输入 | `llr_in signed[LLR_W-1:0]`、`llr_in_valid`、`llr_in_ready` |
| 译码输出 | `u_valid`、`u_ready`、`u_bit`、`u_index[INDEX_W-1:0]`、`u_last` |

使用顺序：`config_start` 配置 N/K → `config_done` → `block_start` → 串行输入 N 个 LLR → 接收 N 个 `u_hat` → `block_done` → 可复用当前配置或重新配置。

## 模块职责

| 模块 | 职责 |
|---|---|
| `sc_decoder_core` | 顶层封装：配置状态机、ROM 填充、模块实例化 |
| `controller` | SC 深度优先调度、节点类型查询、Rate-0 跳过、Rate-1 快速子状态机、气泡调度 |
| `sc_datapath` | PE 输入选择、f/g 运算、beta 选择（direct/xor/A/B）、叶判定、frozen 掩码、写回控制 |
| `sc_pe` | f/g 计算单元（INT_W=10 饱和运算），与 Python 模型逐位对应 |
| `sc_llr_mem` | 2047×10bit LLR：copyA/copyB 双口 BRAM + copyV 8-bank BRAM 宽读 |
| `sc_beta_mem` | 2047×1bit beta：8 bank 分布式 RAM 两副本、宽写 |
| `sc_uhat_mem` | 1024×1bit uhat：8 bank 分布式 RAM 两副本、宽读 + 串行输出读 |
| `frozen_gen` | 由 Q 序列和 K 生成冻结掩码 |
| `polar_reliability_rom` | 可靠度排序 Q 序列 ROM（与规范一致） |
| `sc_fast_node_rom` | 2047×2bit 节点类型 ROM，配置阶段自底向上填充 |

## 关键约定

- 存储读延迟统一为 1 拍（BRAM/LUTRAM 输出寄存器），控制器与数据通路按此调度。
- 堆索引：`heap_idx(depth, node_idx) = (1<<depth) - 1 + node_idx`。
- 节点类型：R0=1（全冻结）、R1=2（全信息）、其它=普通。
- 运算语义：LLR 映射 `d=0→+A`、`d=1→-A`，无 bit-reversal。
- 输出级按 `frozen_bits` 掩码把冻结位强制为 0，Rate-0 子树无需写 u_hat。
