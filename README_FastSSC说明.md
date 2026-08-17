# SC 译码器升级为 Fast-SSC（Rate-0 + Rate-1）

## 1. 依据的论文

- **Fast Successive-Cancellation Decoding of Polar Codes: Identification and Decoding of New Nodes**（Hanif & Ardakani, IEEE Comm. Lett. 2017）：节点类型定义与快速译码思想。
- **High-throughput energy-efficient pipeline architecture for successive cancellation polar decoder**（Hematkhah et al. 2022）：Fast-SSC 流水线实现。
- 经典 SSC 定义（Alamdar-Yazdi & Kschischang）：Rate-0 / Rate-1 节点快速译码。

本次实现 Fast-SSC 核心两层：

| 节点类型 | 定义（节点内信息位集合） | 处理方式 |
|---|---|---|
| **Rate-0** | 空集（全部冻结） | 整棵子树跳过：不计算 alpha、不译码，父节点把其 beta 当 0 |
| **Rate-1** | 全集（全部信息） | P 路向量译码：硬判决 + 部分和变换，一个子树按块一次处理 |
| 其它 | 普通混合节点 | 保持原流水线 SC 的 f/g/合并逐元素处理 |

## 2. 设计概要

在"流水线 SC"基础上新增/修改：

### 2.1 节点类型 ROM（新文件 sc_fast_node_rom.v）

配置阶段（frozen_gen 完成后）自底向上填充 2047×2bit 类型表：

- 叶子：frozen → Rate-0，info → Rate-1；
- 内部：两子均 Rate-0 → Rate-0；两子均 Rate-1 → Rate-1；否则普通。

控制器按堆编号（heap index）组合读查询子节点类型。

### 2.2 Rate-0 跳过（controller）

- **左子树 Rate-0**：跳过 PH_F（不计算左子 alpha），PH_G 的 g 运算用 `beta_force0` 强制 beta=0（g 退化为加法），并跳过 beta_left 复制；
- **右子树 Rate-0**：跳过 PH_G（不计算右子 alpha），PH_C 合并写 `[beta_l, 0]`；
- **根节点 Rate-0**（K=0）：直接输出全零。

### 2.3 Rate-1 向量译码（P=8 路）

快速节点序列（子状态机 fd_state）：

1. **DECIDE**：每周期读 P 个 LLR（sc_llr_mem 新增 8 路宽读），
   按符号位产生 P 个硬判决，宽写 beta_mem（即 β_v，因为 F 自逆，Rate-1 的
   反馈部分和等于原始硬判决）和 uhat_mem（原始值）；
2. **TRANSFORM**：在 uhat_mem 上做 P 路原位蝶形变换 `uhat[k] ^= uhat[k+2^pass]`
   （共 log2(L) 级），得到最终 û 并写回 uhat_mem；
3. 块间插 1 个空拍（流水线 2 拍提交），结束后返回父节点。

u_hat 输出阶段按 `frozen_bits` 把冻结位强制判 0，因此 Rate-0 子树无需写 u_hat。

### 2.4 存储器宽端口

- `sc_llr_mem`：+1 个 P×10bit 组合宽读端口；
- `sc_beta_mem`：+1 个 P bit 宽写端口；
- `sc_uhat_mem`：+2 个 P bit 组合宽读端口 + 1 个 P bit 宽写端口 + frozen 输出掩码。

## 3. Rate-1 零 LLR 回退（bit-exact 保证）

对于有限位宽定点 LLR，Rate-1 节点若检测到输入 alpha 中存在精确 0，
为保持与基准流水 SC 的确定性 tie-breaking（LLR<0 → 1，LLR>=0 → 0）完全一致，
该节点自动 fallback 到普通 SC：

```text
Rate-1 节点
   |
   v
DECIDE 阶段扫描 alpha（P 路宽读，逐 chunk）
   |
   +--- 所有有效 alpha != 0
   |          |
   |          v
   |     正常 Fast Rate-1（DECIDE -> TRANSFORM）
   |
   +--- 任意有效 alpha == 0
              |
              v
         取消 Fast（在 DECIDE->TRANSFORM 之间的 fd_gap 周期判定）
              |
              v
         从当前节点重新走原普通流水 SC DFS
         （current_leaf / cur_depth 不推进，phase[节点]=PH_F 保持不变）
```

实现要点：

- `sc_datapath` 输出 `fast_zero_hit`：只统计有效 lane（`fd_decide_mask_d1` 为 1）
  且完整 LLR 严格等于 0 的 lane；越界补 0 不会触发回退；
- `sc_controller` 用 `fd_zero_seen` 记录整个 DECIDE 过程中是否出现过 0，
  最后一个 DECIDE chunk 的零检测在 fd_gap 周期通过 `fast_zero_hit` 到达；
- 回退发生在 DECIDE 全部 chunk 发完之后（避免与 pipeline 中的 Fast 宽写交叉），
  不做 TRANSFORM，不推进叶子计数，由 normal DFS 从当前节点重新开始；
- DECIDE 期间已写入的 beta/uhat 原始硬判决数据会被普通 SC 重新计算覆盖，
  周期精确 Python 模型已验证不会被提前读取；RTL 功能仿真待完成。

因此当前实现的目标是：**所有量化输入下与 baseline SC bit-exact**，
而不是忽略 tie 情况。

## 4. 验证结果（周期精确模型）

`sc_fast_model.py` 逐拍复刻控制器+数据通路+存储器，与流水线 SC 逐位比对：

- **768 个用例全部通过**：N=2~1024、K∈{0,1,N/4,N/2,3N/4,N-1,N}、4 种模式 ×3 随机种子；
- Fast-SSC 与流水线 SC 输出**逐位相同**；
- **1140 组随机量化软 LLR（-80..+80 且含 0）**：N=4~1024 全部 bit-exact；
- **240 组零密集 corner case**（全 0 / 单 0 / 多 0 / 正负混合）全部 bit-exact；
- 背靠背两个码块 + 输出反压场景通过。

零 LLR 统计：随机软 LLR 套件中 365/1140 组触发了 Rate-1 fallback；
无噪声 +40/-40 码字测试 fallback 次数恒为 0，Fast 路径保持生效
（N=1024/K=512 naive 掩码周期仍为 4239，未退化）。

周期对比（pipelined SC vs Fast-SSC，含装载与输出）：

| 场景 | pipelined SC | Fast-SSC | 提速 |
|---|--:|--:|--:|
| N=256 K=128（naive 掩码） | 5633 | 1158 | 4.9x |
| N=1024 K=512（naive 掩码） | 26625 | 4239 | 6.3x |
| N=1024 K=1024（全 Rate-1） | 26625 | 3469 | 7.7x |
| N=1024 K=0（全 Rate-0） | 26625 | 2223 | 12.0x |
| **N=1024 K=512（5G 38.212 真实掩码）** | 26625 | 16458 | **1.62x** |

> naive 掩码=前 N-K 位冻结（信息位集中在后半段，形成大块 Rate-1 子树），
> 是最好情况；5G 交织掩码信息位分散，大块快速子树少，提速较温和。
> 实际收益以 FPGA 综合后的 Fmax 提升叠加计算。

## 4. 如何在 Vivado 中验证

替换 `version` 工程源文件（`version.srcs\sources_1\new\`）：

- `controller.v`、`sc_datapath.v`、`sc_decoder_core.v`（新）
- `sc_llr_mem.v`、`sc_beta_mem.v`、`sc_uhat_mem.v`（新，来自 sc 工程/rtl 目录）
- `sc_fast_node_rom.v`（新增文件）

系统级 TB：

- `sc_five_n_switch_tb`：走 `sc_decoder_core`，自动包含节点类型 ROM 填充，**无需修改**；
- `tb_256.v` / `tb_1024.v`：已补 ROM 例化与填充等待，可直接用；
- `sc_datapath_tb`：新端口已接 0（保持普通数据通路测试）。

```tcl
open_project E:/internship/FPGA/decode/version/version.xpr
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -mode behavioral -simset sim_1
run all
```

## 5. 文件清单（Fast-SSC 增量）

修改：

- `controller.v`：节点类型查询、Rate-0 跳过、Rate-1 快速子状态机、堆编号跟踪
- `sc_datapath.v`：快速节点单元（DECIDE/TRANSFORM，P 路）、beta_force0、frozen 掩码
- `sc_decoder_core.v`：实例化类型 ROM、配置阶段填充
- `sc_llr_mem.v` / `sc_beta_mem.v` / `sc_uhat_mem.v`：宽读/宽写端口、frozen 输出掩码
- `tb_256.v` / `tb_1024.v` / `sc_datapath_tb.v`：新端口接线

新增：

- `sc_fast_node_rom.v`：节点类型 ROM

## 6. 后续可选优化

- **REP / SPC 快速节点**：REP=求和判决（注意与 SC 的饱和树求和逐位一致），
  SPC=Wagner 译码（奇偶校验+翻转最不可靠位），论文中的标准 Fast-SSC 扩展；
- **新节点类型**（Hanif & Ardakani Type-I..V / 01 / 001 / REP-SPC 等）；
- **加深流水线**（PE 内部再切一级，Fmax 更高）；
- **多码块重叠**（气泡周期处理另一个码块，吞吐翻倍）。
