# SC 译码器插入流水线（Pipeline）改动说明

## 1. 依据的论文

- **High-throughput energy-efficient pipeline architecture for successive cancellation polar decoder**（Hematkhah et al., Microprocessors and Microsystems 92 (2022)）：
  F/G 计算单元（PE）作为独立流水级，每级一拍完成；用寄存器切分长组合路径来提升时钟频率。
- **Hardware architectures for successive cancellation decoding of polar codes**（Leroux et al., ICASSP 2011）：
  line/stream SC 架构；在 stage 之间插入 pipeline register 的思路，以及"流水线延迟带来的调度约束"。

本项目是单 PE 的 line/stream SC 译码器（`sc_datapath` + `sc_controller`），原始关键路径为：

    控制器组合地址 -> LLR/beta 存储器组合读 -> PE(f/g) 组合运算 -> 同步写回

即每个周期下发一条微操作，并在同一周期结束的上升沿写回。组合路径太长会限制 Fmax。

## 2. 改动内容

### 2.1 sc_datapath.v：插入 1 级流水寄存器（写回延迟 1 拍）

在"存储器组合读"与"PE 运算"之间插入一级寄存器（`*_d1`），把关键路径切成两段：

    第 1 段：控制器地址 -> 存储器读 -> *_d1 寄存器（上升沿锁存）
    第 2 段：*_d1 -> PE/beta 选择/叶判决 -> 写回（下一上升沿提交）

每条微操作从"下发"到"写回提交"由 1 拍变为 **2 拍**：

- 周期 T：控制器给读地址、写控制；
- 上升沿 T+1：读数据与控制信号锁存到 `*_d1`；
- 周期 T+1：PE 等组合运算从 `*_d1` 计算；
- 上升沿 T+2：结果写回 `llr_mem` / `beta_mem` / `uhat_mem`。

被延迟的写控制信号（均为 `*_d1` 寄存器）：

- LLR 写：`llr_wr_en_d1`、`llr_wr_addr_d1`，数据 `pe_y`（第 2 段组合结果）；
- beta 写：`beta_wr_en_d1`、`beta_wr_addr_d1`、`beta_wr_mode_d1`、`beta_wr_data_d1`，以及叶节点写（`leaf_decision_en_d1`、`leaf_index_d1`、`leaf_beta_wr_addr_d1`、`leaf_frozen_d1`）；
- PE/叶判决/选择逻辑的输入全部改为 `*_d1`。

接口（端口列表）完全不变，`sc_decoder_core`、`sc_pe`、`sc_llr_mem`、`sc_beta_mem`、`sc_uhat_mem`、`frozen_gen` 均不需要修改。

### 2.2 sc_controller.v：流水线感知调度（插入气泡）

写回延迟 2 拍后，依赖关系要求：**消费者下发周期必须 ≥ 生产者下发周期 + 2**。
SC 深度优先遍历中，需要插入气泡（空拍，不下发任何微操作）的位置：

1. 每个内部节点 PH_F / PH_G 完成、下沉到子节点之后：1 个气泡
   （子节点第一个 f 运算要读父节点最后一次写回的数据）；
2. 每个叶节点判决之后：1 个气泡
   （父节点 g / beta 合并要读该叶节点刚写回的 beta）。

共增加 `3N-2` 个周期（N=64 时 +190，N=1024 时 +3070）。

实现方式：新增 `bubble` 寄存器；

- 组合输出逻辑改为 `(state == ST_DECODE) && !bubble` 才下发微操作；
- 下沉 / 叶判决时置 `bubble=1`，下一个周期只清气泡、不推进任何译码状态。

## 3. 验证

### 3.1 周期精确 Python 模型（sc_model.py）

用 Python 按 RTL 周期语义逐拍复刻了 控制器 + 数据通路 + PE + 三种存储器，分别实现
baseline 与 pipelined 两个版本，并与参考编码器（d = u·F^⊗n，无 bit-reversal，
LLR 映射 d=0→+40 / d=1→-40）比对。

结果：

- **660 个用例全部通过**：N=2~1024，K∈{1, N/4, N/2, 3N/4, N-1, N}，4 种信息位模式，3 组随机种子；
- baseline 与参考编码逐位一致；
- pipelined 与 baseline 输出**逐位完全相同**；
- 背靠背两个码块 + 输出周期性反压场景也通过。

周期开销（与 baseline 相比，额外周期恰好 = 3N-2）：

| N | baseline | pipelined | 额外周期 | 增加 |
|---|---------:|----------:|---------:|-----:|
| 64   |   963 |  1153 |  190 | +19.7% |
| 128  |  2179 |  2561 |  382 | +17.5% |
| 256  |  4867 |  5633 |  766 | +15.7% |
| 512  | 10755 | 12289 | 1534 | +14.3% |
| 1024 | 23555 | 26625 | 3070 | +13.0% |

（baseline 模型周期数比 RTL 实测多出约 1 个 load 启动周期 + TB 反压停顿，
量级一致，N=1024 实测 baseline 为 22625。）

### 3.2 预期时序收益

流水线把关键路径切成两段：

    原：控制器组合 -> 存储器组合读 -> PE(f/g) -> 写回      （1 段）
    新：控制器组合 -> 存储器组合读 -> *_d1                 （段 1）
        *_d1 -> PE(f/g)/选择/判决 -> 写回                  （段 2）

段 1 与段 2 的延迟大约各为原来的 1/2，理论上 Fmax 可提升约 1.5~2 倍；
而整块延迟只增加约 13%（N=1024）。对"吞吐量 = N / 总周期 × Fmax"而言，
只要 Fmax 提升超过 13% 即为净收益。具体 Fmax 收益需在 Vivado 综合后确认。

## 4. 如何在 Vivado 中验证

用修改后的文件替换 `version` 工程中的同名源文件，然后运行现有系统级 TB：

- `sc_bc_n256_system_tb`（tb_256.v）：N=256、K=128，4 种信息位模式；
- `sc_bc_n1024_system_tb`（tb_1024.v）：N=1024、K=512，4 种信息位模式；
- `sc_five_n_switch_tb`：N=64/128/256/512/1024 五种码长切换。

这三个 TB 只观察 `u_valid/u_bit/u_index/u_last` 输出，不需要修改。

`sc_datapath_tb`（B 数据通路单测）的采样时序已按流水线调整：
组合结果（`pe_result` / `beta_selected_data` / `leaf_decision`）改为下发后第 1 拍检查，
写回改为第 2 拍检查（`execute_*` 任务与 TEST 7/8 内联段均已适配）。

## 5. 文件清单

修改：

- `controller.v`：新增气泡调度（+22/-2）
- `sc_datapath.v`：插入一级流水寄存器，写控制延迟 1 拍（+98/-21）
- `sc_datapath_tb.v`：适配写回/采样时序（+5 处 `@(posedge clk)`）

未修改（直接复用原工程）：

- `sc_pe.v`、`sc_llr_mem.v`、`sc_beta_mem.v`、`sc_uhat_mem.v`
- `sc_decoder_core.v`、`frozen_gen.v`
- `tb_256.v`、`tb_1024.v`、`sc_five_n_switch_tb.v`

## 6. 后续可选优化（论文方向）

- **多码块重叠（vector-overlapping）**：气泡周期可被另一个码块的微操作填充，
  用两份寄存器/存储即可把吞吐量翻倍（Leroux et al. §3.4）；
- **更深流水**：在 PE 内部再切 1 级，代价是气泡数变为 (P-1)(3N-2)，Fmax 可进一步抬高；
- **Fast-SSC 节点合并**：用 Rate-0/Rate-1/REP/SPC 超节点减少树深与气泡数（Hematkhah et al.）。
