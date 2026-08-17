# FPGA项目流程

*导出时间: 2026/8/12 16:52:04*

---

### User

FPGA项目流程

---

### ChatGPT

一个比较完整的 FPGA 项目流程，可以理解成从“需求”一路做到“板上验证”的闭环：


需求分析：先明确输入是什么、输出是什么、时钟频率多少、接口有哪些、吞吐率/延迟要求、资源限制是什么。例如 UART、SPI、ADC、DDR、以太网，或者只是 LED、PWM、数据处理算法。


系统方案设计：把整个功能拆成若干模块，确定模块之间怎么连接，以及哪些功能适合用 FPGA 逻辑实现。典型划分是：接口模块 → 数据缓存 → 数据处理 → 控制模块 → 输出接口。


RTL 编码：使用 Verilog/SystemVerilog/VHDL 编写各个模块。这个阶段重点不是“把代码写出来”，而是想清楚寄存器、组合逻辑、状态机、计数器、FIFO、跨时钟域等硬件结构。


功能仿真：写 Testbench 给模块输入激励，观察输出是否符合预期。一般先做单模块仿真，再做顶层联合仿真。这里主要检查逻辑错误，不考虑真实器件布线延迟。


约束设计：编写 XDC/SDC 等约束文件，包括 FPGA 引脚分配、IO 电平标准、主时钟周期、生成时钟，以及必要的时序约束。


综合 Synthesis：EDA 工具把 RTL 转换成 FPGA 内部的 LUT、触发器、BRAM、DSP 等硬件资源。综合完成后重点看 Warning、资源占用、是否出现锁存器，以及设计结构是否符合预期。


实现 Implementation：包括优化、布局 Place、布线 Route。这个阶段真正决定逻辑放在 FPGA 什么位置，以及内部线路怎么连接。


时序分析：查看 Timing Summary，重点关注 Setup、Hold、WNS、TNS。不是“生成 bit 文件成功”就代表设计正确，通常要求关键时序约束全部满足。


生成配置文件：Xilinx 一般生成 .bit，Intel FPGA 一般生成 .sof 等文件，然后下载到 FPGA。


板级调试：真正上板运行。简单项目可以观察 LED、串口、示波器、逻辑分析仪；复杂项目常使用 Xilinx ILA 或 Intel SignalTap 抓 FPGA 内部信号。


问题定位与迭代：如果板上异常，就按照“输入 → 中间状态 → 输出”的顺序定位，到底是 RTL、时序、引脚、电平、时钟、复位还是外设通信的问题，修改后重新经历综合、实现、下载、验证。


固化与系统联调：功能稳定后烧写 Flash，使 FPGA 上电自动加载，并与 MCU、PS、上位机、ADC、DDR、PL 外设等进行完整系统联调。


所以你可以先记住一条最核心的主线：
需求 → 架构设计 → RTL → 仿真 → 约束 → 综合 → 布局布线 → 时序分析 → 生成 Bitstream → 下载 FPGA → 板级调试 → 迭代完善
如果你现在用的是 Vivado + Xilinx FPGA，实际操作流程通常就是：
Create Project → 添加 Verilog → 添加 XDC → Run Simulation → Run Synthesis → Run Implementation → Generate Bitstream → Hardware Manager → Program Device
而如果是 Zynq/MPSoC 这种带 ARM 的 FPGA，则还会多出来一条软件流程：
Vivado 设计 PL → 导出 XSA/HDF → Vitis/XSDK 建立 PS 软件工程 → PS 配置 PL → PS 与 PL 通信 → 整机联调。
以你后面做实际工程来说，最值得先掌握的不是一次性学完整套 Vivado，而是先做几个递进的小项目：
流水灯 → 按键消抖 → UART → PWM → FIFO → RAM → SPI/I²C → 状态机 → 跨时钟域 → AXI → PS/PL 通信 → 完整项目。
其中真正决定你以后能不能独立做 FPGA 项目的几个核心能力是：时序逻辑、状态机、时钟与复位、Testbench、时序约束、跨时钟域、FIFO、AXI 和板级调试。

---

### User

1.Vivado 设计 PL → 导出 XSA/HDF → Vitis/XSDK 建立 PS 软件工程 → PS 配置 PL → PS 与 PL 通信 → 整机联调。这一条是什么，威视锐 Y790s这是我现在用的板子
2.但是我因为没有这个板子的license，可以通过先用其他类似的型号布局布线，有了之后再加适配器实现吗

---

### ChatGPT

你这里其实是两个问题：第一条是 Zynq/MPSoC 这类“ARM+FPGA”器件的开发链路；第二条是 没有目标器件 license 时，能不能先拿相近型号完成布局布线再迁移。我先把 Y790s 具体用的芯片型号确认一下，再按你的板子说。

已经确认到关键点了：Y790/Y790s 不是普通“纯 FPGA 板”，它的核心属于 Zynq UltraScale+ RFSoC 路线；公开资料显示 Y790 使用的是 ZU47DR，芯片内部同时有 ARM 的 PS、FPGA 的 PL，以及高速 RF-ADC/RF-DAC。也就是说，你前面看到的“Vivado → XSA → Vitis”这条流程，和这类板子确实是对应的。

你这个板子就不能按“普通纯 FPGA”去理解了。公开资料显示，YunSDR Y790 系列采用 Zynq UltraScale+ RFSoC ZU47DR，芯片里同时集成了 ARM 处理器系统（PS）、FPGA 可编程逻辑（PL）以及高速 ADC/DAC。电子趋势FPGA
所以你问的两个问题，答案分别是：
1. Vivado → XSA/HDF → Vitis/XSDK 到底是什么？
它是 Zynq/RFSoC 的“硬件 + 软件联合开发流程”。
你可以把 Y790s 里的 ZU47DR 想象成：
Plain text┌──────────────────────── ZU47DR ────────────────────────┐│                                                        ││    PS（ARM）                    PL（FPGA）              ││                                                        ││  Cortex-A53 / R5         你写的 Verilog / IP / DSP     ││       │                         │                      ││       ├──── AXI ────────────────┤                      ││       │                         │                      ││   DDR / Linux              FIFO / FIR / FFT            ││   C/C++程序               DDC / 算法 / DMA             ││                                 │                      ││                         RF-ADC / RF-DAC                 ││                                                        │└────────────────────────────────────────────────────────┘
Y790 的公开资料明确提到，ZU47DR 内部有 ARM 处理器，同时 PL 侧拥有独立 DDR，并用于高速信号处理。电子趋势FPGA
所以开发工作天然分成两边：
Plain textVivado    ↓设计 FPGA/PL    ↓Verilog / Block Design / AXI / FIFO / DSP    ↓生成 Bitstream    ↓导出 XSA    ↓Vitis    ↓写 ARM/PS 的 C/C++ 程序    ↓ARM 控制 FPGA
AMD 官方现在的流程也是：Vivado 导出 XSA，Vitis 从 XSA 获得处理器、IP、地址映射、时钟、存储器等硬件信息。 AMD 文档+1
所以：


PL = FPGA 部分，你写 Verilog 的地方；


PS = ARM 部分，你写 C/C++、裸机程序或者 Linux 的地方；


AXI = PS 和 PL 之间非常重要的通信通道；


XSA = Vivado 告诉 Vitis“我的 FPGA 硬件到底设计成什么样了”。


你之前看到的 HDF 本质上属于旧版 SDK/XSDK 流程；现在 Vivado + Vitis 主要使用 XSA。

对你的 Y790s，一个实际项目可能长这样
假设你要做：

ADC采集 → FPGA处理 → ARM控制 → 数据输出

那可以设计为：
Plain text       射频输入          ↓      RF ADC          ↓    ┌──────────── PL ────────────┐    │                            │    │ DDC                        │    │ ↓                          │    │ FIR                        │    │ ↓                          │    │ FFT                        │    │ ↓                          │    │ FIFO                       │    │ ↓                          │    │ AXI DMA                    │    └────────────┬───────────────┘                 │                AXI                 │    ┌────────────▼───────────────┐    │            PS              │    │                            │    │ Cortex-A53                 │    │ C/C++ / Linux              │    │ 参数配置                    │    │ 数据处理                    │    │ 网络传输                    │    └────────────────────────────┘
所以你之前说的：

Vivado 设计 PL → 导出 XSA → Vitis/XSDK 建立 PS 软件工程 → PS 配置 PL → PS 与 PL 通信

放在 Y790s 上是完全合理的开发思路。
只是 Y790s 是比较复杂的 RFSoC 平台，不建议你第一步就自己把整个 PS、RFDC、DDR、100G、时钟全部从零搭起来。Y790 的公开资料显示它还涉及 RFSoC、三组 DDR4、双 100G 等复杂资源。电子趋势FPGA
更好的方式是拿威视锐提供的：
Plain text官方 Vivado 基础工程     +XDC     +Block Design     +RFDC配置     +时钟配置     +DDR配置     +XSA/HDF     +BSP/驱动
然后在这个“底座”上添加你自己的 FPGA 算法。

2. 没有 Y790s 对应的 Vivado license，能不能先用类似型号？
可以开发，但是不能把“类似型号布局布线成功”当成 Y790s 最终布局布线成功。
这一点非常重要。
因为 ZU47DR 属于 Zynq UltraScale+ RFSoC。AMD 的 Vivado 设备支持表里，Standard Edition 对 RFSoC 是：

RFSoC：None

而 Enterprise Edition 才是：

RFSoC：All

也就是说免费/Standard 版本并不包含 RFSoC 的完整器件支持。AMD 文档
所以你现在碰到 license 问题是正常的。

但是可以采用“核心算法 + 适配层”的方法
这其实非常适合你现在的情况。
不要这样做：
Plain text某个其他 FPGA↓完整布局布线↓生成 bit↓以后换 ZU47DR↓希望直接改一下就能用
这个基本行不通。
因为换器件以后：
Plain textLUT数量BRAM位置DSP位置Clock RegionBUFGGTYRFDCDDRIO Bank引脚速度等级封装时钟树布线资源
都可能变化。
所以最终还是必须：
Plain text换成真正 ZU47DR      ↓重新 Synthesis      ↓重新 Implementation      ↓重新 Place      ↓重新 Route      ↓重新 Timing Analysis      ↓Generate Bitstream

但你可以这样设计：
Plain text                    你的算法工程                   ┌────────────┐                   │ Core 核心  │                   │            │                   │ FIR        │                   │ FFT        │                   │ DDC        │                   │ FIFO       │                   │ 算法       │                   └─────┬──────┘                         │                  AXI Stream等                         │              ┌──────────▼──────────┐              │ Adapter / Wrapper   │              │      适配层          │              └──────────┬──────────┘                         │        ┌────────────────┴────────────────┐        │                                 │   临时开发 FPGA                       Y790s   UltraScale+                     ZU47DR RFSoC
这时候所谓的“适配器”不是物理意义上的 FPGA 转换器，而是你代码里的：
Wrapper / Adapter / Interface Layer
比如：
Plain textmy_algorithm_core.v
只写：
Plain textclkrsts_axis_tdatas_axis_tvalids_axis_treadym_axis_tdatam_axis_tvalidm_axis_tready
不要在算法核心里面直接写：
Plain textRFDCDDR pinGTYZU47DR专用Primitive板卡具体Pin特定Clock Wizard

然后外面套：
Plain texty790s_wrapper.v
专门负责：
Plain textY790s RFDC      ↓AXIS适配      ↓my_algorithm_core      ↓AXIS      ↓DMA / DDR / 100G
这样将来换板子，只改 Wrapper，核心算法不用大动。

你现在最适合采用的开发方式
我建议你现在不要追求“用替代器件把最终布局布线都做好”。
而是把工作拆成三层：
Plain text第一层：算法层--------------------------------VerilogFIRFFTCORDICFIFO数据通路状态机DSP算法★ 现在就可以做★ 不依赖 Y790s★ 大量做仿真
然后：
Plain text第二层：接口层--------------------------------AXI4-LiteAXI4-StreamAXI DMA寄存器FIFOCDCPS-PL接口★ 现在也可以做大部分
最后：
Plain text第三层：Y790s硬件层--------------------------------ZU47DRRF ADCRF DACRFDCMTSDDR4GTY100G板级ClockXDC Pin★ 等 license / 厂商工程
于是你的工程结构最好从现在就做成：
Plain textY790s_Project│├── rtl│   ││   ├── core│   │   ├── fir.v│   │   ├── fft_ctrl.v│   │   ├── data_process.v│   │   └── algorithm_top.v│   ││   ├── interface│   │   ├── axis_adapter.v│   │   ├── fifo.v│   │   ├── axi_regs.v│   │   └── cdc.v│   ││   └── board│       └── y790s_wrapper.v│├── sim│   └── tb_algorithm.v│└── xdc    └── y790s.xdc
这样以后真正有 ZU47DR license 时：
Plain text现有算法    ↓基本不动    ↓接 Y790s Wrapper    ↓接威视锐官方底层工程    ↓选择 XCZU47DR    ↓Synthesis    ↓Implementation    ↓Timing    ↓Bitstream
这条路线是可行的。

还有一个对你特别有用的办法
如果你现在虽然没有 Vivado RFSoC license，但是威视锐能给你 Y790s 的 .xsa / .hdf，事情会简单很多。
因为 AMD 的流程允许 Vitis 使用已经导出的硬件平台信息；而且 Vitis 甚至可以使用 pre-synthesis XSA 来做部分软件开发，不是所有 PS 软件开发都必须等你自己重新生成 bitstream。AMD 文档+1
所以可以出现这种开发模式：
Plain text              威视锐        Y790s官方Vivado工程                 ↓            官方 XSA/HDF                 ↓        ┌────────┴────────┐        │                 │       你               厂商       ↓ Vitis/XSDK       ↓ PS裸机 C程序       ↓AXI寄存器 / DDR / DMA
然后等以后有 RFSoC license：
Plain text自己打开完整 Vivado 工程           ↓修改 PL           ↓重新生成 XSA           ↓更新 Vitis Platform

所以我给你一个明确结论
① Y790s 非常适合 PS+PL 的开发模式。
你的学习路线应该是：
Plain textVerilog ↓Vivado PL ↓AXI ↓PS-PL通信 ↓Vitis裸机 ↓DMA ↓DDR ↓RFDC ↓完整Y790s信号链
② 没 license 时，可以用其他 UltraScale/UltraScale+ 器件做 RTL、仿真、接口、资源估算甚至临时布局布线。
但是：

临时器件的布局布线结果不能直接迁移到 ZU47DR。

正确思想是：

迁移 RTL/IP/接口设计，不迁移最终布局布线结果。

等 license 有了以后，再针对 真实 ZU47DR 的封装、速度等级、XDC、RFDC、DDR、GTY、时钟重新做完整 implementation。
③ 你说的“以后再加适配器”这个思路是对的，但适配器应该从现在就设计成“RTL Wrapper / AXI Adapter 层”，而不是等布局布线完之后再转换。
如果你接下来就是准备用 Y790s 做 XSDK/Vitis 裸机 PS→PL→PS 闭环，我可以直接按这块板子给你画一张从 “上位机 → ARM PS → AXI → FPGA PL → DDR/FIFO → AXI → ARM PS → 上位机” 的完整工程结构图，并告诉你第一周具体该建哪些 Vivado 模块、写哪些 Verilog 和 C 文件。

---

### User

但适配器应该从现在就设计成“RTL Wrapper / AXI Adapter 层”，而不是等布局布线完之后再转换。我没理解什么意思

---

### ChatGPT

你可以先把我那句话忘掉，我换一种更直观的方式解释。
你现在的情况是：
最终目标板：Y790s / ZU47DR
但现在 没有这个器件的 Vivado license，所以你想：

能不能先选一个我现在能用的 FPGA 型号，把工程做好，等以后有 ZU47DR license，再“适配”到 Y790s？

答案是：可以。
但这里“适配”的对象应该是接口和顶层连接，不是已经布局布线好的结果。
举个最简单的例子。
假设你真正想做的功能只是一个 FPGA 数据处理模块：
Plain text输入数据   ↓┌──────────────┐│ 你的算法模块  ││              ││ FFT/FIR/算法 │└──────────────┘   ↓输出数据
你现在没有 Y790s license，就找另外一块 FPGA 做开发。
问题来了：
假设你直接在算法代码里面写死：
verilogalways @(posedge Y790_ADC_CLK) begin    data <= Y790_RFADC_DATA;end
又直接连接：
Plain textY790 RF-ADCY790 DDRY790 PSY790 专用时钟
那么你的算法和 Y790s 绑死了。
以后换开发板很麻烦。

更好的做法是把它拆开。
你的核心算法只认识一些非常普通的信号：
Plain text              ┌──────────────────────┐data_in ─────→│                      │valid_in ────→│    我的算法 Core     │clk ─────────→│                      │rst ─────────→│                      │              │                      │data_out ←────│                      │valid_out ←───│                      │              └──────────────────────┘
例如：
verilogmodule my_core (    input              clk,    input              rst,    input      [15:0]  data_in,    input              data_valid,    output reg [15:0]  data_out,    output reg         data_out_valid);    // 你的算法endmodule
这里完全没有：
Plain textY790sZU47DRRFADCPSDDR某个具体引脚某个具体 FPGA
所以这个 my_core.v：
Artix-7 能用，Kintex 能用，Zynq 能用，ZU47DR 也能用。
这就是你真正应该提前完成的东西。

然后在 my_core 外面放一层东西。
例如你现在临时拿一个普通 FPGA：
Plain text开发板 AADC A │ ▼┌─────────────────┐│ board_A_wrapper │  ← 适配└───────┬─────────┘        │        ▼┌─────────────────┐│    my_core      │  ← 你的真正算法└───────┬─────────┘        │        ▼    开发板 A 输出
以后换成 Y790s：
Plain textY790sRF-ADC │ ▼┌─────────────────┐│ Y790s_wrapper   │  ← 换掉这一层└───────┬─────────┘        │        ▼┌─────────────────┐│    my_core      │  ← 不改└───────┬─────────┘        │        ▼ AXI / DMA / DDR
这个 wrapper 就是我说的“适配层”。

为什么还会有 AXI Adapter？
因为你以后在 Y790s 上很可能不是这种：
Plain textADC → 你的模块 → DAC
而可能变成：
Plain textPS ARM  │ AXI  │  ▼你的 FPGA 模块
或者：
Plain textRF ADC  ↓AXI Stream  ↓你的模块  ↓AXI Stream  ↓DMA  ↓DDR
假设你的算法核心接口是：
Plain textdata_invalid_indata_outvalid_out
而 Y790s 给你的接口是：
Plain textAXI Streamtdatatvalidtreadytlast
两个接口不完全一样。
那你就在中间写一个“小翻译器”：
Plain textAXI Streamtdatatvalidtready    │    ▼┌──────────────────┐│ AXIS Adapter     ││ 接口转换          │└──────────────────┘    │    ▼data_invalid_in    │    ▼┌──────────────────┐│    my_core       ││    我的算法       │└──────────────────┘
这就是 AXI Adapter。
你甚至可以把它理解成：

转接头。

就像你的显示器只有 HDMI，而电脑只有 DP。
你不是把显示器拆了重做，而是在中间加：
Plain text电脑 DP ↓DP → HDMI 转接器 ↓显示器 HDMI
FPGA 也是一样：
Plain textY790s AXI接口 ↓AXI Adapter ↓你的算法接口

那为什么我说“不要等布局布线以后再转换”？
这就是最关键的地方。
因为：
Verilog/RTL 是“设计图”。
而：
布局布线结果是“这个设计图已经在某一块 FPGA 芯片里面具体施工完了”。
比如你在 FPGA A 上布局布线之后：
Plain text这个乘法器↓DSP48 #123这个寄存器↓SLICE_X50Y102这个 RAM↓BRAM_X2Y14这根线↓走 FPGA A 内部某条具体布线资源
已经非常具体了。
换成 ZU47DR 后：
Plain textSLICE位置不同DSP位置不同BRAM位置不同Clock Region不同布线网络不同
所以不能说：
Plain textFPGA A 已布局布线        ↓   加个Adapter        ↓    变成 ZU47DR
不存在这种 adapter。
必须：
Plain text你的 RTL   ↓换成 ZU47DR   ↓重新综合   ↓重新布局   ↓重新布线
但是你的 RTL 本身可以基本不变。

所以对于你现在的情况，最准确的理解是
你现在可以找一个不需要昂贵 license、而且架构比较接近的器件：
Plain text临时 FPGA   │   ├── 编写 Verilog   ├── Testbench 仿真   ├── FSM   ├── FIFO   ├── DSP算法   ├── AXI Stream   ├── AXI Lite   ├── CDC   ├── 综合   └── 临时布局布线
把这些全部学会、跑通。
但是工程最好长这样：
Plain text                   ┌─────────────────┐                   │   my_core.v     │                   │                 │                   │  真正功能代码    │                   │                 │                   │  尽量不依赖板卡  │                   └────────┬────────┘                            │                     通用数据接口                            │             ┌──────────────┴─────────────┐             │                            │             ▼                            ▼┌────────────────────────┐    ┌────────────────────────┐│ 临时开发板 Wrapper      │    │ Y790s Wrapper          ││                        │    │                        ││ 普通ADC                 │    │ RF ADC                 ││ 普通DDR                 │    │ RFDC                   ││ 普通引脚                 │    │ AXI / DMA              ││ 普通时钟                 │    │ PS / PL                 │└────────────────────────┘    └────────────────────────┘          ↑                             ↑       现在用                         以后用
这样你以后得到 Y790s license：
不是重新写整个 FPGA 项目。
而是大致：
Plain text保留：my_core.vFFTFIRFIFO状态机算法大部分 AXI逻辑↓删除/替换：临时开发板 wrapper临时 XDC临时 Clock临时 IO↓加入：Y790s wrapperY790s XDCRFDCPSDDRY790s Clock↓选择 ZU47DR↓重新：SynthesisImplementationBitstream
所以一句话概括：

你现在可以用别的 FPGA 把“发动机”造好，以后换 Y790s 时重新设计“发动机怎么接到这辆车上”；不是先把整辆车按照另一台车造完，再加一个转接头变成 Y790s。

而且如果你现在只是刚开始 FPGA 项目，其实暂时不用刻意自己写复杂的 Wrapper/AXI Adapter。你先把项目分成 “核心算法模块”和“板级顶层 top” 两部分就已经非常好了。
例如：
Plain textproject/│├── my_core.v         ← 尽量通用├── fifo.v            ← 尽量通用├── data_process.v    ← 尽量通用│└── top.v             ← 和当前开发板有关
以后：
Plain texttop.v
换成：
Plain texty790s_top.v
而前三个基本保留。
这就是我上一条说的“从现在就留适配层”的真正意思。

---

### User

我还是没有理解，你换个角度解释吧

---

### ChatGPT

可以。我们这次完全不讲 Wrapper、AXI、RTL 这些词，只讲你现在到底该怎么干。
你现在的想法其实是：

我最终要用 Y790s，但是现在没有 Y790s 的 license。
那我能不能先选一个别的 FPGA 型号，把工程做完，等以后有 license，再把工程“转到”Y790s？

答案是：

能先做，但只能先把“功能”做完，不能把“针对另一颗芯片的布局布线”直接转成 Y790s 的布局布线。

用“装修房子”来理解
假设你最终要装修的是：
房子 B = Y790s / ZU47DR
但是现在你进不了房子 B，因为没有 license。
于是你说：

那我能不能先拿房子 A 做装修？

可以。
你现在可以先决定：


卧室要什么功能


厨房要什么功能


灯怎么控制


空调怎么控制


智能家居逻辑是什么


这些相当于你的：
Verilog 功能、状态机、算法、FIFO、数据处理。
这些东西以后可以搬到房子 B。
但是你不能说：

我已经在房子 A 墙上打好了孔、埋好了水管、电线也走好了。
等我拿到房子 B 的钥匙，把房子 A 的水管位置直接复制过去。

不行。
因为两个房子的：


房间位置不同


墙的位置不同


插座位置不同


水管位置不同


面积不同


这就对应 FPGA 的：


LUT 位置不同


DSP 位置不同


BRAM 不同


时钟资源不同


引脚不同


布线资源不同


所以：
布局布线 = 已经按照“某一颗具体 FPGA”施工。
换 FPGA 以后必须重新施工。

那我之前说的“适配器”到底是什么？
这里最容易误解。
它不是说：

FPGA A 布局布线完成
↓
加一个转换器
↓
变成 Y790s

不是这个意思。
我说的“适配”实际上是：

你的功能代码怎么和不同的板子连接。

还是用家电举例。
你买了一台电视：
电视 = 你的 FPGA 算法
电视本身不关心房子是什么。
它只要求：

给我 220V 电，我就工作。

那么房子 A：
Plain text房子A电路   ↓插座   ↓电视
房子 B：
Plain text房子B电路   ↓插座   ↓电视
电视没有换。
换的是：
电视怎么接到房子的电路上。
这就是我说的“适配层”。

放回你的 FPGA 项目
假设你真正要开发的东西非常简单：

输入 16 位数据 → 算法处理 → 输出 16 位数据。

那么你真正重要的代码就是：
Plain text输入数据   ↓【你的算法】   ↓输出数据
这一部分尽量不要管：


Y790s 是什么板子


ADC 是什么


PS 是什么


引脚是什么


DDR 是什么


它就干一件事情：

给我数据，我算完，把结果给你。

这就是“电视”。

你现在没有 Y790s license。
于是先选 FPGA A：
Plain textFPGA A板子A的数据      ↓【连接部分】      ↓【你的算法】      ↓【连接部分】      ↓板子A输出
你可以：


写代码


仿真


综合


布局布线


上板测试


全部可以做。

以后拿到 Y790s license。
你不是把整个 FPGA A 工程原封不动搬过来。
而是：
Plain text原来：板子A ↓连接A ↓你的算法 ↓连接A
变成：
Plain textY790s ↓连接Y790s ↓你的算法 ↓连接Y790s
中间的：
Plain text【你的算法】
尽量不改。
外面的连接方式改掉。
这就是所谓“适配”。

最重要的是理解“什么东西能搬，什么不能搬”
你现在用其他 FPGA 开发：
你现在做的东西以后能不能带到 Y790sVerilog 算法✅ 能状态机✅ 能FIFO 控制逻辑✅ 能数据处理逻辑✅ 能Testbench✅ 基本能FIR/FFT 算法✅ 基本能一部分 AXI 逻辑✅ 能针对板子A的引脚❌ 不能板子A的 XDC❌ 不能直接用板子A的时钟配置❌ 不一定板子A的 ADC 接口❌ 不一定板子A布局布线结果❌ 不能板子A生成的 bit❌ 不能
所以你要把这件事情理解成：

不是把“FPGA A”变成“Y790s”。
而是把你在 FPGA A 上已经验证好的“功能设计”，重新放进 Y790s。


再给你一个更贴近 Vivado 的例子
假设现在你用一个便宜 Xilinx FPGA。
你写：
Plain textdata_process.v
它完成：
Plain text输入数据 ↓乘2 ↓加100 ↓输出数据
你现在：
Plain textdata_process.v        ↓Vivado        ↓FPGA A        ↓综合        ↓布局布线        ↓bit
完全跑通。
以后拿到 Y790s license：
不是：
Plain textFPGA A 的 bit      ↓转换      ↓Y790s bit
而是重新拿：
Plain textdata_process.v        ↓Y790s 工程        ↓ZU47DR        ↓重新综合        ↓重新布局布线        ↓新的 bit
这里 data_process.v 就是你真正提前完成的成果。

所以你现在其实不需要“做适配器”
我觉得我前面说“从现在开始做 Adapter”反而把你绕晕了。
对你目前这个阶段，先别管这个词。
你只需要记一条：

把“我想实现什么功能”和“这个功能怎么连接某一块具体开发板”分开写。

比如工程里：
Plain text工程│├── data_process.v├── fifo_ctrl.v├── algorithm.v│└── top.v
前三个：
Plain textdata_process.vfifo_ctrl.valgorithm.v
是你的通用功能。
最后：
Plain texttop.v
负责跟当前板子连接。
现在：
Plain texttop.v→ FPGA A
以后：
Plain texttop.v→ 改成 Y790s
而：
Plain textalgorithm.v
最好不用改。
这就已经实现了我之前所谓的“适配层思想”。

最后把你的原问题直接回答成一句话
你问：

我现在没有 Y790s license，能不能先用其他类似型号布局布线，以后有 license 再加适配器？

更准确的答案应该是：

你可以现在用其他型号开发、综合、布局布线，用它验证你的设计；但将来不能在“布局布线结果”后面加适配器变成 Y790s。
将来要把你现在写好的 Verilog/算法拿出来，放进新的 Y790s 工程，然后针对 ZU47DR 再重新综合、重新布局布线。

所以整个过程其实只有：
Plain text现在其他 FPGA   ↓写功能代码   ↓仿真   ↓综合   ↓布局布线   ↓验证“我的设计是对的”以后拿到 Y790s license   ↓把同一套功能代码放进 Y790s   ↓接上 Y790s 的接口   ↓重新综合   ↓重新布局布线   ↓生成 Y790s 的 bit
你现在用其他型号布局布线的意义，是“提前验证设计”，而不是“提前完成 Y790s 的布局布线”。
这两个概念一分开，整个事情就比较清楚了。

---

### User

你的意思就是只能跑功能仿真，但是不能综合和布局布线

---

### ChatGPT

不是。你当然可以在“替代 FPGA 型号”上综合、布局、布线，甚至上板运行。
区别只是：这些结果只对那个替代器件有效，不能直接拿去给 Y790s/ZU47DR 用。
你可以这样理解：
Plain text现在：替代 FPGARTL代码  ↓功能仿真        ✅  ↓综合            ✅  ↓布局            ✅  ↓布线            ✅  ↓时序分析        ✅  ↓生成 bit        ✅  ↓替代板上运行     ✅
等你以后有 Y790s 对应 license：
Plain text原来的 RTL代码      ↓换目标器件为 ZU47DR      ↓重新综合          ← 必须      ↓重新布局          ← 必须      ↓重新布线          ← 必须      ↓重新时序分析      ← 必须      ↓生成 Y790s bit
所以不是“只能跑功能仿真”，而是：

你现在可以把整个 FPGA 开发流程都在替代器件上跑一遍，但你得到的是“替代 FPGA 的最终结果”，不是“提前完成了 Y790s 的最终结果”。

比如你现在拿 FPGA A：
Plain textalgorithm.v    ↓综合    ↓发现占用了：LUT 40%DSP 55%BRAM 30%    ↓布局布线通过    ↓200 MHz 时序通过
这些信息非常有价值，说明你的架构大体可行。
但以后换成 ZU47DR，可能变成：
Plain text同一个 algorithm.v    ↓重新综合    ↓LUT 12%DSP 20%BRAM 8%    ↓重新布局布线    ↓可能 300 MHz 也能过
也可能因为不同的时钟、接口、RFDC、DDR 等因素产生新的时序问题。
所以你现在用类似 FPGA 做综合和布局布线，主要有三个意义：


验证 RTL 能不能综合。


提前发现时序、资源、CDC 等问题。


验证整体架构是否合理。


但最终针对 Y790s 的 资源占用、时序结果、布局布线和 bitstream，都必须等换成 ZU47DR 后重新跑。
一句话：

能综合，也能布局布线；只是以后换 Y790s 要重新综合、重新布局布线，不是只改一个“适配器”就完事。

