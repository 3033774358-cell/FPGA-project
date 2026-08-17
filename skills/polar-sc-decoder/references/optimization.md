# 优化方法

## 流水线化（pipelined SC）

- 在"存储器读 → PE"之间插入 1 级流水寄存器（`*_d1`），写回延迟变为 2 拍。
- 控制器插气泡：每个内部节点下沉后 1 拍、每个叶判定后 1 拍，共增加 `3N-2` 拍。
- 顶层接口不变；实测增加：N=64 +190（+19.7%）、N=1024 +3070（+13.0%）。
- 依据：Hematkhah et al. 2022；Leroux et al. 2011。

## Fast-SSC（Rate-0 / Rate-1）

- **Rate-0**：整棵子树跳过，不计算 alpha、不写 u_hat；父节点把其 beta 当 0（g 退化为加法）。
- **Rate-1**：`DECIDE`（P=8 路硬判 + 宽写 beta/uhat）→ `TRANSFORM`（原位蝶形 `beta = uhat·F^(xor len_log)`），块间 1 空拍。
- **零 LLR fallback**：DECIDE 中发现有效 lane 有精确 0 时取消 Fast 路径、回退普通 SC，保证与 baseline 的 tie-breaking（LLR<0→1，LLR>=0→0）bit-exact。
- 周期收益：N=1024/K=512 naive 掩码 4239（6.3x）；5G 交织掩码 16458（1.62x）。

## 存储器面积优化（BRAM/LUTRAM）

baseline 三个存储器全部落成寄存器 + 巨型 MUX（整核 160301 LUT），根因：

1. always 块带异步复位 → Vivado 拒绝 RAM 推断（`Synth 8-4767`）；
2. 10/17 个读端口打在同一个寄存器数组上 → F7/F8 MUX 树。

改造规则：

- 去掉数组的异步复位/整块复位，依赖"读前必写"的算法保证；Rate-0 跳过时父节点显式写 0，输出级 frozen 掩码兜底。
- 宽读（P=8 lane）按地址低 3 位拆 8 bank，连续 8 地址天然落在不同 bank，一周期并行读。
- 宽写按 bank 折叠；任何读写组合不超过单 bank 1W+1R 物理能力。
- 仿真影子数组放 `ifndef SYNTHESIS`，综合时完全排除。
- 读延迟保持 1 拍，控制器/数据通路流水线零改动。

实测（xc7a200t，Phase1）：`u_sc_llr_mem` 89219→3069 LUT + 10 BRAM（2×RAMB36 + 8×RAMB18）；`sc_decoder_core` 160301→86767 LUT。

## 已知陷阱（务必检查）

- **越界保护用寄存地址**：BRAM 输出是上一拍地址的数据，越界保护必须用与数据同拍的 `rd_vec_addr_r`；用当前组合地址会在 gap 周期泄漏陈旧 lane 数据（真实 bug，曾致 tb_1024 出现 2002 处错误）。
- **去复位后的 X**：读前未写的地址在门级仿真会出 X；必须由调度保证写先于读。
- **统一对比策略**：面积对比必须同一器件、同一 strategy、关闭跨边界优化（`NO_CROSS_BOUNDARY_OPT true`），否则分层统计不可比。
- 带异步复位的 ROM（如 fast_node_rom）同样会被拆成寄存器，后续可低成本改 BRAM。
