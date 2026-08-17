# 前半段历史对话索引

原始 ChatGPT 对话导出存放在 `history/`（29 份）。以下按主题列出，需要深挖某段历史时先查本表再打开对应文件。文件均为 UTF-8，用支持 UTF-8 的查看器打开。

| 文件 | 原始导出名 | 主题 | 何时查看 |
|---|---|---|---|
| [01-FPGA编码译码介绍](history/01-FPGA编码译码介绍.md) | saas-nexus-1786524144132 | FPGA 编码/译码入门 | 需要项目背景叙述时 |
| [02-论文解读CRC辅助译码](history/02-论文解读CRC辅助译码.md) | saas-nexus-1786524158682 | CRC 辅助译码论文解读 | 需要 CRC/CA-SCL 原理时 |
| [03-Polar编码蝶形结构](history/03-Polar编码蝶形结构.md) | saas-nexus-1786524164847 | 编码蝶形/位序 | 确认编码器结构时 |
| [04-B仿真简化控制器代码](history/04-B仿真简化控制器代码.md) | saas-nexus-1786524178276 | B 通路简化控制器/test sequencer | 早期 datapath 级验证时 |
| [05-SC译码逻辑解析](history/05-SC译码逻辑解析.md) | saas-nexus-1786524185756 | SC 算法、左右子树、信道 LLR | 复习 SC 原理时 |
| [06-Vivado仿真启动问题与需求](history/06-Vivado仿真启动问题与需求.md) | saas-nexus-1786524203557 | 任务范围/固定配置/位序/冻结/PE/模块顺序/代码风格 | **需求主线，最常查** |
| [07-Polar译码N设置](history/07-Polar译码N设置.md) | saas-nexus-1786524208676 | N 值选择讨论 | 码长配置疑问时 |
| [08-Polar译码中的N值选择](history/08-Polar译码中的N值选择.md) | saas-nexus-1786524215359 | N 值选择讨论（续） | 同上 |
| [09-报错原因分析-LLR存储布局](history/09-报错原因分析-LLR存储布局.md) | saas-nexus-1786524230167 | 综合/仿真报错、LLR 布局 11264→2047、sc_llr_mem 接口与 TB | 存储器设计细节时 |
| [10-SC控制器设计解析](history/10-SC控制器设计解析.md) | saas-nexus-1786524241438 | 控制器状态机/调度 | 控制器设计讨论时 |
| [11-SC译码器控制器代码](history/11-SC译码器控制器代码.md) | saas-nexus-1786524256423 | 控制器代码实现过程 | 控制器实现细节时 |
| [12-FPGA信道编码流程](history/12-FPGA信道编码流程.md) | saas-nexus-1786524279596 | 信道编码总体流程 | 编码链路总体时 |
| [13-Verilog-SC译码器需求](history/13-Verilog-SC译码器需求.md) | saas-nexus-1786524291015 | SC 译码器需求细化 | 需求分歧时 |
| [14-Vivado编译问题分析](history/14-Vivado编译问题分析.md) | saas-nexus-1786524299725 | 编译报错排查 | Vivado 编译报错时 |
| [15-Vivado编译卡住解决](history/15-Vivado编译卡住解决.md) | saas-nexus-1786524306159 | 编译卡住排查 | Vivado 卡死/超时时 |
| [16-SC-LLR-Mem设计](history/16-SC-LLR-Mem设计.md) | saas-nexus-1786524315392 | LLR 存储器设计定稿 | 存储器读写语义时 |
| [17-时序优化与信道编码](history/17-时序优化与信道编码.md) | saas-nexus-1786524321520 | 时序/信道编码杂项 | 时序讨论时 |
| [18-编码译码示例数据解析](history/18-编码译码示例数据解析.md) | saas-nexus-1786524361134 | 附录 H 示例数据识别（LSB 优先等） | 理解 TV 向量时 |
| [19-极化码编码修改建议-附录H](history/19-极化码编码修改建议-附录H.md) | saas-nexus-1786524368851 | 附录 H 交叉验证发现（末块 K、R=1 直通等） | 编码/译码兼容差异时 |
| [20-完整SC解码结构图](history/20-完整SC解码结构图.md) | saas-nexus-1786524635898 | 完整结构图讨论 | 总体架构梳理时 |
| [21-Y790s型号解析](history/21-Y790s型号解析.md) | saas-nexus-1786524645512 | Y790s=ZU47DR RFSoC、Vivado 选型 | Vivado 选器件时 |
| [22-Codex与ChatGPT整合问题](history/22-Codex与ChatGPT整合问题.md) | saas-nexus-1786524650394 | 工具链协作问题 | 与本技能无关，一般不用 |
| [23-检查SC译码架构](history/23-检查SC译码架构.md) | saas-nexus-1786524670407 | 架构检查/仿真运行 | 架构评审时 |
| [24-压缩包文件识别](history/24-压缩包文件识别.md) | saas-nexus-1786524680355 | 工程文件/压缩包识别 | 工程目录混乱时 |
| [25-威视锐Y790s板卡对应](history/25-威视锐Y790s板卡对应.md) | saas-nexus-1786524714802 | 板卡器件对应关系 | 板级资源确认时 |
| [26-FPGA项目流程](history/26-FPGA项目流程.md) | saas-nexus-1786524724542 | 项目整体流程总结 | 流程梳理时 |
| [27-5G极化信道编码译码A](history/27-5G极化信道编码译码A.md) | saas-nexus-1786524730468 | 5G 极化编码译码背景 | 5G/协议背景时 |
| [28-5G极化信道编码译码B](history/28-5G极化信道编码译码B.md) | saas-nexus-1786524759779 | 5G 极化编码译码背景（续） | 同上 |
| [29-5G极化信道编码译码C](history/29-5G极化信道编码译码C.md) | saas-nexus-1786524759799 | 5G 极化编码译码背景（续） | 同上 |

使用建议：默认只读 `requirements.md`；涉及具体设计细节或历史结论争议时，按本表定位到对应 history 文件再读。
