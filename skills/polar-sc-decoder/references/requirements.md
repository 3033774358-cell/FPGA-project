# 需求与前置阶段（前半段）

本节提炼自项目前期对话记录（原始记录见 `history/`，索引见 `history-index.md`）。开始写 RTL 前必须先确认这些约定，不要重新向用户追问已确定的信息。

## B / C 分工

项目划分为 B（数据通路）和 C（控制）两部分：

- **B 部分（SC 译码数据通路）**：PE（f/g 运算）、LLR 存储、部分和 beta 存储与数据通路、判决位 u_hat 存储、串行 LLR 装载、译码结果串行输出、面向 C 的微操作接口。
- **C 部分（控制器）**：SC 树深度优先遍历、f/g 运算顺序、LLR 存储读写地址生成、叶节点到达时机、部分和回传与更新时序。
- 早期要求：先写 B 数据通路，另写一个仅用于仿真的简化控制器（test sequencer）完成 B 通路级验证；test sequencer 不是正式 C 交付物。

## 固定配置（第一版）

- `NMAX=1024`，支持 N=64/128/256/512/1024，`n_log=6..10`。
- 串行输入 LLR，顺序为 `d[0], d[1], ..., d[N-1]`；串行输出 `u_hat[0..N-1]`，冻结位输出 0，输出接口 valid/ready。
- `PE_NUM=1`；输入 `LLR_W=8`、内部 `INT_W=10`，必须满足 `INT_W >= LLR_W`（不再支持截断分支）。
- LLR 符号约定：`LLR >= 0` 倾向比特 0，`LLR < 0` 倾向比特 1。
- f 用 min-sum；`g(a,b,beta)=beta ? b-a : b+a`；f/g 均做有符号饱和。
- 第一版 LLR/beta/u_hat 都用寄存器数组，不执行 bit reversal，索引用自然顺序。

## 编码端位序（已确认）

编码器蝶形网络等价于 `d = u · F^(⊕n)`，**没有**显式执行 `B_N` 比特反转。N=4 示例：

```text
d[0] = u0 ^ u1 ^ u2 ^ u3
d[1] = u1 ^ u3
d[2] = u2 ^ u3
d[3] = u3
```

串行输出顺序为 `d[0]..d[N-1]`，SC 根节点 LLR 必须按完全相同顺序存入，不能反序、不能额外做 bit reversal。

## 冻结集约定

- `frozen[i]=1`：u[i] 为冻结位，强制判 0；`frozen[i]=0`：信息位，按叶 LLR 判决。
- 叶判决：`u_hat[phi] <= (frozen[phi]) ? 0 : leaf_llr[INT_W-1]`（内部约定负 LLR 对应比特 1）。
- 冻结可靠度序列生成**不属于 B**；B 只接收 `leaf_frozen` 或在装载阶段缓存外部 frozen。

## 不属于 B 的内容

码块划分、CRC 生成/校验、非冻结信息位抽取、去前缀补零、多码块消息拼接均不属于 B；B 只负责输出完整 `u_hat[0:N-1]`。

## PE 定义与状态

`sc_pe` 接口已固定（`W=10`，a/b/y 有符号，mode_g、beta 输入），已在 Vivado 仿真通过（19 组定向 + 5000 组随机 = 5019 PASS）。不要重新设计；关键边界：不能在 W 位内直接求最小负数的绝对值、`f(-512,-512)` 需饱和到 +511、g 中间结果用 W+1 位、饱和比较两侧明确 signed。

## 模块开发顺序

按顺序一个模块一个模块推进，每个模块给出完整可综合代码、接口说明、关键时序、独立自检 TB：

1. `sc_pe`（已完成）→ 2. `sc_llr_mem` → 3. `sc_beta_mem` → 4. `sc_uhat_mem` → 5. `sc_datapath`（组合上述四者，只执行 C 的微操作，不自行遍历树）→ 6. `sc_test_sequencer` + `sc_b_only_system_tb`（仿真辅助，完成 N=2/4 或小码长无噪声环回）。

`sc_datapath` 微操作接口至少支持：串行装载根 LLR、发起一次 f/g、指定两个 LLR 源地址、指定写回地址、指定 mode_g、指定/读取 beta、发起叶判定、指定叶索引与 frozen、写 u_hat、读写部分和、启动串行输出；用 valid/ready/done 语义避免重复执行。

## 代码风格要求

- Verilog-2001，兼容 Icarus Verilog 与 Vivado；testbench 除外不得用不可综合结构。
- 时序 always 用非阻塞赋值；组合逻辑避免锁存；有符号比较/扩展/切片显式处理。
- 参数与地址位宽合法，N=64~1024 不允许计数器截断；必须解释存储地址布局。
- 不给伪代码、不省略模块、不一次性丢出所有模块。
- 注意 Verilog-2001 中 `$display` 不能用相邻字符串拼接；长 TB 用 Run All，不要只跑默认 1000ns。

## 无噪声环回

第一阶段的逻辑验证链路：消息 → Polar 编码 → 码字比特 → 理想 LLR → SC 译码。理想 LLR 示例：`llr = encoded_bit ? -8'sd32 : 8'sd32`。用于检查位序、frozen 对应、f/g 顺序、部分和与 u_hat 索引。正式性能仿真用 BPSK+AWGN：`LLR = 2y/σ²`，但不属于纯 B RTL 主要交付。

## LLR 存储布局演进

- 旧方案 `MEM_DEPTH=(MAX_LOG+1)*NMAX=11264`（每深度固定预留 1024）被否决：空间过大、综合压力大、双组合读形成大选择器、对 PE_NUM=1 深度优先没有必要。
- 新方案按"当前深度工作区"分配：`MEM_DEPTH=2*NMAX-1=2047`，`ADDR_W=11`。depth d 的 base：`base(0)=0`，`base(d+1)=base(d)+(NMAX>>d)`；depth d 占用 `NMAX>>d` 个位置，小 N 只用每层前 `N>>d` 个位置；同深度切换节点可覆盖。
- 地址由 C 按深度优先遍历顺序生成，B 只提供物理地址读写。

## sc_llr_mem 接口与 TB 覆盖要点

接口：clk/rst_n；装载：`load_start/n_log/llr_in/llr_in_valid/llr_in_ready/load_busy/load_done`；普通同步写：`wr_en/wr_addr/wr_data`；两个组合读：`rd_addr_a/rd_data_a`、`rd_addr_b/rd_data_b`。

规则：`load_start` 空闲时拉高一拍启动装载并锁存 N；`load_busy=1` 时 `llr_in_ready=1`，仅 `valid&&ready` 才收数；收满 N 个后 `load_busy` 拉低、`load_done` 拉高一拍；装载优先，装载期间普通 `wr_en` 与再次 `load_start` 被忽略；复位只清控制状态，不清存储单元；`llr_in` 从 LLR_W 显式符号扩展到 INT_W。

TB 至少覆盖：复位状态、普通同步写、双组合读、N=64 连续装载、符号扩展（-128/-1/0/127）、valid 暂停（空拍不计数不错位）、装载期间 wr_en 忽略、装载期间 load_start 忽略、load_done 单拍、N=1024 满装载不截断、中间层工作区写读、装载不破坏中间层地址。

## 目标板卡（Y790s）

- 威视锐 YunSDR Y790s 是 SDR 整机平台，不是 FPGA 型号；核心芯片是 AMD/Xilinx **Zynq UltraScale+ RFSoC ZU47DR**（部分配置 ZU48DR）。
- Vivado 选型：Create Project → Default Part → Family: Zynq UltraScale+ RFSoC → Device: xczu47dr，再按板卡实际封装/速度等级选完整料号（如 `xczu47dr-2-ffve1156-i`）。确定方法：打开厂家原始 .xpr，Tcl 执行 `get_property PART [current_project]`。
- 配套 FX200 PCIe 前传加速卡内还有 Kintex UltraScale+ KU15P（FX800 为 Virtex UltraScale+ VU13P）。
- 本机无 ZU47DR license 时，用 `xc7a200tfbg676-2` 做相对面积趋势参考（详见 `vivado-flow.md`）。

## 附录 H 与早期验证约定

- 附录 H 数据按 LSB 优先打印（`LSB ---> ... ---> MSB`），首比特为 bit0。
- 帧类型 2 末块 K=剩余比特（不补零）；R=1（MCS 8/12）直通不做极化扩展；帧级 CRC 与块级 CRC 不同（详见 `verification.md`）。
- 全部约定细节以 `verification.md` 和 `verify/` 工程为准，此处只记录历史结论。
