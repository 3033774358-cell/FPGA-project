---
name: polar-sc-decoder
description: 编写、修改、验证和优化极化码（Polar code）SC / Fast-SSC 译码器 RTL 的完整流程，覆盖前半段需求确认（B/C 分工、固定配置、编码位序、冻结集、PE 定义、LLR 存储布局、Y790s 板卡选型）与后半段实现（Python 参考模型和逐周期模型、Verilog 模块实现、bit-exact 回归验证、流水线与 Fast-SSC 加速、存储器 BRAM/LUTRAM 面积优化、Vivado 综合与综合后仿真、IP 核封装）。当用户要求实现极化解码器 / SC 译码器 / Fast-SSC 译码器 RTL，或基于 sc_opt_work 工程继续开发、验证、优化、封装 IP 核时使用。
---

# Polar SC 译码器 RTL 开发流程

## 工作流程

按顺序执行，每步完成并验证后再进入下一步：

1. **确认需求与参数**：先读 [需求与前置阶段](references/requirements.md) 的前半段约定（B/C 分工、固定配置、位序、冻结集、PE 定义、LLR 布局、Y790s 选型），再确认码长 N∈{64..1024}（`2^n_log`）、信息位 K、可靠度排序 Q（`polar_reliability_rom`）、冻结位选择、LLR 映射（0→+A，1→-A）、CRC 配置；以 T/XS 10002-2025 附录 H 为基准。历史讨论原始记录在 `references/history/`，先查 [history-index.md](references/history-index.md)。
2. **建立 Python 参考模型**：先写 bit-exact 参考编码/译码模型，与附录 H 示例向量逐比特比对全部一致后才开始 RTL。
3. **建立逐周期模型**：用 Python 逐拍复刻 controller + datapath + 存储器 + PE 的调度，锁定周期数与输出行为；之后每个优化阶段都要与它 bit-exact 对比。
4. **实现 RTL 模块**：按 [架构与接口](references/architecture.md) 划分模块并保持顶层接口冻结。
5. **编写并运行回归**：全部系统级 TB + 专项 TB 必须 PASS，周期数与 baseline 逐拍一致（见 [验证方法](references/verification.md) 的回归矩阵）。
6. **优化**：流水线、Fast-SSC、存储器映射等改动必须保持 bit-exact，周期数变化必须文档化（见 [优化方法](references/optimization.md)）。
7. **综合与面积报告**：统一策略（`Flow_RuntimeOptimized` + 关闭跨边界优化）跑综合，出分层资源报告，确认 BRAM/LUTRAM 映射符合预期。
8. **门级验证与封装**：目标器件环境跑综合后仿真、布局布线及时序收敛，再按 [Vivado 流程](references/vivado-flow.md) 封装 IP 核。

## 核心纪律

- **bit-exact 优先**：任何 RTL 改动后输出必须与参考模型逐比特一致，禁止"近似一致"。
- **周期数可追踪**：每次改动记录周期数变化并与逐周期模型核对；吞吐优化必须有周期数依据。
- **接口冻结**：顶层接口（config / block / LLR 流 / u_hat 流）一经确定不再修改，优化只动内部。
- **仿真与综合分离**：仿真辅助逻辑（shadow 数组、初始化、层次化检查）必须放在 `ifndef SYNTHESIS` 内，综合时排除。
- **统一对比策略**：面积/时序对比必须在同一器件、同一综合策略下进行。

## 参考文件

- [architecture.md](references/architecture.md) — 模块职责、参数、顶层接口、堆索引、节点类型约定
- [requirements.md](references/requirements.md) — 前半段需求：B/C 分工、固定配置、位序、冻结集、PE、模块顺序、LLR 布局、Y790s 选型
- [history-index.md](references/history-index.md) — 29 份前半段历史对话的索引与使用指引
- [verification.md](references/verification.md) — 参考模型、逐周期模型、TB 清单、回归矩阵、门级仿真注意
- [optimization.md](references/optimization.md) — 流水线、Fast-SSC、存储器优化与已知陷阱
- [vivado-flow.md](references/vivado-flow.md) — 仿真命令、综合 Tcl、license 应对、综合后仿真、IP 封装
