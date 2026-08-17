# FPGA信道编码流程

*导出时间: 2026/8/12 16:44:39*

---

### User

我现在要用fpga实现这个信道编码的编码和译码，现在已经写完rtl了，现在在进行综合，下一步进行什么

---

### ChatGPT

综合完成后，下一步先检查综合结果，再进入实现（布局布线）。完整流程建议按下面顺序进行：
1. 检查综合报告
不要综合成功后直接生成比特流，先确认：


是否存在 Critical Warning


是否推断出锁存器 Latch


是否有未连接端口或未使用信号


时钟、复位是否识别正确


RAM、ROM、DSP、寄存器的资源占用是否符合预期


编码器和译码器模块有没有被综合工具优化掉


有没有组合逻辑环路


最大组合逻辑层级是否过深


重点查看：


Utilization Report


Schematic


Clock Report


Check Timing


Methodology Report


如果译码器大量使用存储器，例如保存 LLR、部分和、路径度量等，需要确认综合结果确实使用了 BRAM，而不是全部变成 LUT 或寄存器。

2. 补全时序约束和引脚约束
在进入布局布线前，要写好约束文件。
例如 Vivado 的 XDC：
tclcreate_clock -period 10.000 -name sys_clk [get_ports sys_clk]set_property PACKAGE_PIN W5 [get_ports sys_clk]set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]set_property PACKAGE_PIN U18 [get_ports rst_n]set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
如果系统时钟是 100 MHz：
tclcreate_clock -period 10.000 [get_ports sys_clk]
还需要根据设计情况处理：


输入延迟


输出延迟


异步复位


跨时钟域


多周期路径


异步路径


不要为了让时序通过而随意添加假路径。只有真正不需要进行时序分析的路径，才能使用：
tclset_false_path

3. 做综合后功能仿真
虽然 RTL 仿真通过了，但建议再做一次 Post-Synthesis Functional Simulation，确认综合后的网表行为和 RTL 一致。
信道编码设计建议重点验证：


不同码长：


64


128


256


512


1024




不同码率


带 CRC 与不带 CRC


不同码块分段数量


全 0、全 1、交替比特、随机比特


编码后无误码输入译码器，是否能够完全恢复


人为加入单比特、多比特或随机误码，观察译码结果


最好建立一个端到端测试结构：
Plain text原始数据   ↓CRC添加   ↓码块分段   ↓极化编码   ↓误码/噪声注入   ↓极化译码   ↓CRC检查   ↓与原始数据比较
推荐使用 MATLAB、Python 或 C 程序产生标准参考数据，然后和 FPGA 仿真结果逐比特比较。

4. 运行实现：布局布线
综合检查正常后，运行：
Plain textImplementation
Vivado 内部主要包括：
Plain textopt_designplace_designphys_opt_designroute_design
也就是：
Plain text逻辑优化 → 布局 → 物理优化 → 布线

5. 检查实现后的时序
实现完成后重点查看 Timing Summary。
最重要的是：
Plain textWNS ≥ 0TNS = 0WHS ≥ 0THS = 0
其中：


WNS：最差建立时间裕量


TNS：所有建立时间违例总和


WHS：最差保持时间裕量


THS：所有保持时间违例总和


例如：
Plain textWNS = 0.523 nsTNS = 0 ns
说明建立时间满足要求。
如果：
Plain textWNS = -2.1 ns
说明最大时钟频率无法达到当前约束，需要优化。
极化码译码器容易出现时序问题的位置通常包括：


多级 XOR 网络


最小值与符号计算


LLR 的 f、g 运算


路径度量比较


大规模排序网络


冻结位查询


地址生成逻辑


CRC 并行计算


1024 位码块级联逻辑


常见优化方法是：


增加流水线寄存器


将大组合逻辑拆成多拍


使用 BRAM 保存中间结果


分级进行比较和排序


限制单周期循环展开数量


对高扇出控制信号进行寄存器复制


避免在一个周期内完成完整译码迭代



6. 检查资源占用
实现后重新查看：


LUT


FF


BRAM


DSP


BUFG


IO


除了总占用率，还要关注局部拥塞。
例如总 LUT 只用了 50%，但译码器逻辑集中在某个区域，也可能导致布线困难和时序违例。
特别需要记录不同参数下的资源：
参数LUTFFBRAMDSP最大频率N=64N=128N=256N=512N=1024

7. 做布局布线后时序仿真
时序要求较高时，可以运行：
Plain textPost-Implementation Timing Simulation
它会把实际器件延迟考虑进去。
重点检查：


输出数据是否在 valid 有效期间稳定


帧首、帧尾是否对齐


编码长度是否正确


译码输出有没有提前或延迟一拍


连续码块输入时是否丢数据


ready/valid 握手是否存在冲突


复位解除后第一帧是否正常



8. 生成比特流并下载 FPGA
时序和 DRC 都通过后：
Plain textGenerate Bitstream
然后下载到 FPGA 板卡。
板上测试时，建议先使用简单模式：
Plain textFPGA内部产生测试数据        ↓编码器        ↓不加入误码        ↓译码器        ↓比较原始数据
即内部回环测试。
可以设置：
verilogerror_flag <= decoded_data != source_data;
并统计：
verilogtotal_block_counterror_block_countbit_error_count

9. 加入 ILA 在线调试
建议在以下信号处加入 ILA：


编码器输入数据


编码器输入有效信号


编码器输出数据


码块长度


码率


冻结位索引


译码器输入 LLR


译码状态机状态


译码器输出数据


CRC 校验结果


译码成功标志


帧错误标志


当前迭代或节点编号


BRAM 读写地址


不要一次抓取全部 1024 位数据，可以采用：
Plain text数据总线 + 地址 + valid + 状态机
逐周期观察。

10. 最后进行性能测试
功能正确后，需要测试三个核心指标。
吞吐率
假设每个码块包含 $K$ 个信息比特，处理周期数为 $C$，时钟频率为 $f$：
$Throughput=\frac{K\times f}{C}$
延迟
$Latency=\frac{C}{f}$
误码性能
在不同信噪比下统计：


BER：比特误码率


BLER/FER：码块或帧错误率


CRC 通过率


建议测试：
Plain textEb/N0 = 0、0.5、1、1.5、2、2.5、3 dB
并与 MATLAB 或软件参考模型对比。

你现在最直接要做的是：
Plain text检查综合报告→ 完善时钟和IO约束→ 综合后仿真→ Run Implementation→ 检查时序和资源→ Generate Bitstream→ 上板回环测试
其中最关键的门槛是：实现完成后 WNS 必须大于等于 0，并且端到端编码—译码测试结果与软件参考模型一致。

---

### User

我现在使用的工具是vivado
1.我怎么看RAM、ROM、DSP、寄存器的资源占用是否符合预期

编码器和译码器模块有没有被综合工具优化掉
2.Utilization Report

Schematic

Clock Report

Check Timing

Methodology Report这些报告分别是啥
3.如果综合结果没有使用BRAM，怎么调整让他知道要生成BRAM
4.时序约束和引脚约束是用于仿真还是哪些部分
5.关于综合后功能仿真，我怎么建立这个端到端的测试结构，在哪里进行测试，以及怎么用MATLAB产生标准参考数据，FPGA仿真结果的比对用的是哪产生的结果
6.DRC是啥，ILA是啥

---

### ChatGPT

下面按 Vivado 的实际操作路径逐项说明。先记住一个区别：


综合后：主要检查逻辑有没有正确推断、资源是否合理。


实现后：主要检查真实布局布线后的资源、时序、DRC，结果比综合后更可信。


仿真：验证功能，不等于资源检查或时序签核。



1. 怎么查看 RAM、ROM、DSP、寄存器资源，以及模块有没有被优化掉
1.1 打开综合后的设计
综合完成后，在左侧 Flow Navigator 中选择：
Plain textSYNTHESIS└─ Open Synthesized Design
打开后，再选择：
Plain textReports└─ Report Utilization
也可以在 Tcl Console 中运行：
tclreport_utilization
Vivado 的 Utilization Report 可以按资源类别、层次模块、Pblock 等方式显示资源使用情况。AMD 文档+1

1.2 主要看哪些项目
Slice Logic
这里主要看：
项目含义LUT as Logic用于组合逻辑的 LUTLUT as Memory被当作分布式 RAM、ROM 或移位寄存器的 LUTRegisters触发器、寄存器数量F7/F8 Mux较大选择器使用情况
你的极化码编码器主要是异或网络，通常会使用：


LUT


Registers


编码器一般不需要大量 DSP。
译码器如果包含：


LLR 存储


中间节点存储


部分和存储


路径度量存储


冻结位表


则可能使用 BRAM、LUTRAM 和寄存器。

Memory
这里主要看：
项目含义Block RAM TileBRAM 使用量RAMB3636 Kb 级 BRAM 原语RAMB1818 Kb 级 BRAM 原语UltraRAM部分 UltraScale+、Versal 器件上的 URAM
不同 FPGA 型号的报告名称可能稍有区别。
如果看到：
Plain textBlock RAM Tile = 0LUT as Memory = 很多
通常说明存储器被实现成了 LUTRAM，而不是 BRAM。

Arithmetic
这里重点看：
Plain textDSPDSP48E1DSP48E2
不同器件名称不同。
对于极化码：


编码器通常是 XOR 运算，DSP 为 0 很正常。


SC/SCL 译码中的加减、比较、绝对值、最小值通常也可能使用 LUT 和进位链。


只有你写了乘法器、较复杂乘加、特殊度量运算时，才比较可能使用 DSP。


所以不能简单认为“DSP 为 0 就不正常”。

1.3 怎么判断资源是否“符合预期”
没有一个固定的标准值，需要先根据 RTL 结构做粗略估算。
例如定义：
verilogreg [7:0] llr_mem [0:1023];
理论存储量为：
$1024\times8=8192\text{ bit}$
如果它被推断为 BRAM，理论上只需要一小部分 BRAM 容量，但实际占用还会受到以下因素影响：


深度和位宽组合


单端口还是双端口


是否有多个读端口


是否有输出寄存器


读写冲突模式


器件 BRAM 原语的宽深配置


是否有多个独立数组


所以资源估算只能作为数量级判断。
建议你制作一个表：
存储内容RTL 深度位宽理论位数期望资源冻结位表102411024 bitROM/LUTRAM/BRAMLLR 存储102488192 bitBRAM部分和102411024 bitLUTRAM/BRAM路径度量L×若干8～16视参数而定Register/BRAM
小型冻结位表被放进 LUTROM 并不一定有问题。比较大的 LLR 存储仍全部变成寄存器或 LUT，才需要重点检查。

1.4 怎么看编码器和译码器有没有被优化掉
方法一：看分层资源报告
打开：
Plain textReport Utilization
在报告中切换到：
Plain textHierarchy
或者 Tcl Console 输入：
tclreport_utilization -hierarchical
查看是否存在类似：
Plain textu_encoderu_decoderu_crcu_rate_match
以及这些层次下是否有 LUT、FF、BRAM 等资源。
例如：
InstanceLUTFFBRAMtop/u_encoder12006500top/u_decoder15000900018
说明两个模块都被保留并产生了硬件。

方法二：在 Netlist 中查找实例
打开综合设计后，在左侧或下方找到：
Plain textNetlist
展开层次树，查找：
Plain textu_encoderu_decoder
也可以在 Tcl Console 输入：
tclget_cells -hierarchical -filter {NAME =~ *encoder*}
以及：
tclget_cells -hierarchical -filter {NAME =~ *decoder*}
Netlist 窗口显示的是综合后的逻辑层次，可以查看实例、网络和属性。AMD 文档
需要注意：找不到原来的模块名，不一定表示模块被删除。Vivado 可能进行了层次扁平化、重建或跨层次优化。默认的 rebuilt 策略允许先扁平化优化，再重建一个与 RTL 相似的层次。AMD 文档

方法三：查看 Schematic
在 Netlist 中选中：
Plain textu_encoder
右键：
Plain textSchematic
可以查看该实例实际生成的：


LUT


FF


RAM


DSP


状态机


数据通路


综合后的 Schematic 才是实际综合结果，不是原始 RTL 方框图。

方法四：检查综合日志
打开：
Plain textDesign Runs
右键：
Plain textsynth_1→ Open Run Directory
或者直接看综合后的 Log/Messages。
搜索：
Plain textremovedunusedtrimmedconstantunconnectedoptimized
常见原因包括：


模块输出没有被顶层使用


输出始终是常数


输入固定为常数


模块没有被实例化


实例化端口连接错误


编码器输出没有连接到译码器


译码器最终输出没有连接到顶层端口或其他有效逻辑


状态机永远无法进入工作状态



不建议一开始就加 DONT_TOUCH
为了调试层次，可以临时写：
verilog(* keep_hierarchy = "soft" *)polar_encoder u_encoder (    // ...);
KEEP_HIERARCHY="SOFT" 可以较好地保留可见层次，同时允许常量传播；TRUE 会限制更多跨层次优化，可能影响资源和时序。AMD 文档
也可以使用：
verilog(* dont_touch = "yes" *)polar_encoder u_encoder (    // ...);
但 DONT_TOUCH 会一直影响到布局布线，可能阻止正常优化，因此只建议用于定位问题，不要长期大面积使用。AMD 文档

2. 这些报告分别是什么
2.1 Utilization Report
资源利用率报告，用于回答：

这个设计用了多少 FPGA 硬件资源？

主要看：


LUT


FF/Register


LUTRAM


BRAM


URAM


DSP


BUFG


IO


MMCM/PLL


综合后的报告是初步结果，实现后的报告更接近最终结果。
常用命令：
tclreport_utilization
分层查看：
tclreport_utilization -hierarchical

2.2 Schematic
严格来说，Schematic 不是一份文本报告，而是电路原理图查看器。
它有三种常见层次：
RTL Analysis Schematic
综合前的 RTL 结构图，比较接近你写的代码。
Synthesized Schematic
综合后的硬件结构，能够看到：


LUT


FDRE 等寄存器


RAMB18/RAMB36


DSP48


多路选择器


进位链


Implemented Schematic
实现后的实际网表结构。
你现在最需要看的是：
Plain textOpen Synthesized Design→ Schematic
它主要用于确认：


编码器是否还存在


状态机是否正常生成


存储器是 RAMB 还是大量 FF


乘法器是否进入 DSP


信号是否被常量化


模块之间是否真正连接



2.3 Clock Report
“Clock Report”在 Vivado 中可能对应几个不同报告。
Report Clocks
查看设计中定义了哪些时钟，例如：
Plain textsys_clkdecoder_clkclk_100m
主要检查：


时钟名称


周期


波形


是否为主时钟


是否为派生时钟



Report Clock Utilization
查看时钟资源使用情况，例如：


BUFG


BUFH


MMCM


PLL


时钟负载


时钟区域


它主要用于检查时钟结构和时钟资源，而不是检查普通数据路径是否满足时序。AMD 文档说明，该报告可用于分析时钟资源和排查时钟布局问题。AMD 文档
Tcl 命令：
tclreport_clock_utilization

Report Clock Interaction
检查多个时钟域之间的关系：


同步时钟域


异步时钟域


是否有跨时钟域路径


是否存在不合理的时钟约束


如果编码器、译码器全部使用同一个时钟，这部分相对简单。

2.4 Check Timing
Check Timing 不是看 WNS 的主要报告，它重点检查：

你的时序约束是否完整、是否存在结构性问题？

它会检查：


时钟未定义


寄存器没有时钟


输入输出路径未约束


组合逻辑环路


时钟引脚被常量驱动


多个时钟驱动一个寄存器


没有约束的时序端点


不完整的时钟关系


Timing Summary 中的 Check Timing 部分主要报告缺失或不完整的时序约束。AMD 文档
Tcl 命令：
tclcheck_timing
或者生成完整时序报告：
tclreport_timing_summary

2.5 Methodology Report
Methodology Report 是“设计方法检查报告”，用于检查设计是否违反 AMD 推荐的 FPGA 设计方法。
例如检查：


时钟定义是否合理


是否使用普通逻辑生成时钟


时钟是否经过合适的时钟缓冲器


异步复位是否存在风险


时序例外是否可疑


是否存在严重扇出问题


是否存在不合理的约束


CDC 处理是否存在风险


IO 约束是否缺失


命令：
tclreport_methodology
它不是功能正确性证明，而是检查设计写法和约束是否符合推荐方法。AMD 文档

3. 没有使用 BRAM，怎么调整
3.1 最常见原因：异步读取
下面这种写法通常更倾向于 LUTRAM：
verilogreg [7:0] mem [0:1023];assign dout = mem[addr];
因为读取是组合异步读取。
AMD 器件的分布式 RAM 可以异步读，而专用 Block RAM 典型推断模板采用同步读。AMD 文档

3.2 推荐的单端口 BRAM 模板
verilogmodule bram_single_port #(    parameter DATA_WIDTH = 8,    parameter ADDR_WIDTH = 10,    parameter DEPTH      = 1024)(    input  wire                  clk,    input  wire                  en,    input  wire                  we,    input  wire [ADDR_WIDTH-1:0] addr,    input  wire [DATA_WIDTH-1:0] din,    output reg  [DATA_WIDTH-1:0] dout);    (* ram_style = "block" *)    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];    always @(posedge clk) begin        if (en) begin            if (we)                mem[addr] <= din;            dout <= mem[addr];        end    endendmodule
关键点：
verilogdout <= mem[addr];
必须放在：
verilogalways @(posedge clk)
里面，形成同步读取。
RAM_STYLE="block" 明确要求 Vivado 优先推断 Block RAM。AMD 文档+1

3.3 带复位时，只复位输出，不要逐项清空整个存储器
推荐：
verilog(* ram_style = "block" *)reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];always @(posedge clk) begin    if (en) begin        if (we)            mem[addr] <= din;        if (rst)            dout <= {DATA_WIDTH{1'b0}};        else            dout <= mem[addr];    endend
AMD 官方 BRAM 推断模板也是复位 dout，而不是在复位时用循环同时清零整个 RAM。AMD 文档
尽量避免：
veriloginteger i;always @(posedge clk) begin    if (rst) begin        for (i = 0; i < DEPTH; i = i + 1)            mem[i] <= 0;    endend
因为硬件 BRAM 通常不能在一个时钟周期内同时清除全部地址。综合器可能将其拆成大量寄存器或其他逻辑。
需要“逻辑清空”时，常见做法是：


通过地址计数器逐周期写零


保存有效标志


使用帧号/版本号判断数据是否有效


只复位读写地址、计数器和输出寄存器



3.4 简单双端口 BRAM 模板
一个端口写，一个端口读：
verilogmodule bram_simple_dual_port #(    parameter DATA_WIDTH = 8,    parameter ADDR_WIDTH = 10,    parameter DEPTH      = 1024)(    input  wire                  clk,    input  wire                  we,    input  wire [ADDR_WIDTH-1:0] wr_addr,    input  wire [DATA_WIDTH-1:0] wr_data,    input  wire [ADDR_WIDTH-1:0] rd_addr,    output reg  [DATA_WIDTH-1:0] rd_data);    (* ram_style = "block" *)    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];    always @(posedge clk) begin        if (we)            mem[wr_addr] <= wr_data;    end    always @(posedge clk) begin        rd_data <= mem[rd_addr];    endendmodule
这类结构比较适合：


LLR 存储


部分和存储


编码中间数据


译码节点数据



3.5 ROM 推断成 BRAM
例如冻结位表：
verilogmodule frozen_rom #(    parameter ADDR_WIDTH = 10,    parameter DEPTH      = 1024)(    input  wire                  clk,    input  wire [ADDR_WIDTH-1:0] addr,    output reg                   frozen);    (* rom_style = "block" *)    reg rom [0:DEPTH-1];    initial begin        $readmemh("frozen_bits.mem", rom);    end    always @(posedge clk) begin        frozen <= rom[addr];    endendmodule
ROM_STYLE 用于指导 Vivado 将常量数组实现为 Block RAM 或分布式 ROM。AMD 文档
不过 1024×1 只有 1024 bit，Vivado 使用 LUTROM 可能反而更节省整体资源，因此不一定必须强制 BRAM。

3.6 仍然不生成 BRAM时检查什么
依次检查：


是否为同步读取。


是否在复位时循环清空整个数组。


是否同时读取太多地址。


是否在一个周期内写多个不同地址。


是否给数组每个元素都设置了独立控制。


数组是否太小，Vivado认为 LUTRAM 更合适。


数组输出是否最终没有被使用。


是否有 KEEP 阻止寄存器被合并进 RAM；AMD 文档明确指出，不恰当的 KEEP 可能阻碍 BRAM 推断。AMD 文档


是否使用了不受支持的读写冲突行为。


是否多端口数量超出了单个 BRAM 的能力。


修改后重新综合，查看：
Plain textUtilization Report→ Memory
并在 Schematic 中搜索：
Plain textRAMB18RAMB36
仍然无法稳定推断时，可以改用：


XPM Memory


Block Memory Generator IP


这两种方法比自行推断更容易明确控制：


深度


位宽


端口类型


读延迟


写模式


初始化文件



4. 时序约束和引脚约束用于哪里
4.1 时序约束
例如：
tclcreate_clock -period 10.000 -name sys_clk [get_ports sys_clk]
它表示：
Plain textsys_clk 周期为 10 ns，即目标频率为 100 MHz
时序约束主要用于：
Plain text综合→ 实现→ 静态时序分析→ 时序签核
综合和实现都是时序驱动的，约束会影响优化、布局和布线。AMD 也强调，过松、过严或缺失的时序约束都会影响结果。AMD 文档+1
时序约束不会在行为仿真中自动产生时钟
即使 XDC 里写了：
tclcreate_clock -period 10 [get_ports clk]
Testbench 里仍需要写：
veriloginitial begin    clk = 1'b0;    forever #5 clk = ~clk;end
create_clock 是告诉时序分析器“这个时钟有多快”，不是给仿真器产生波形。

4.2 引脚约束
例如：
tclset_property PACKAGE_PIN W5 [get_ports sys_clk]set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]
它告诉 Vivado：


顶层端口连接 FPGA 的哪个物理管脚


使用哪种 IO 电压标准


引脚约束主要用于：
Plain text布局布线→ IO放置→ DRC→ 生成bitstream→ 下载到开发板
物理约束主要由实现阶段的 placer 和 router 使用。AMD 文档
它一般不影响纯 RTL 行为仿真。

4.3 约束作用总结
约束行为仿真综合实现上板create_clock不产生仿真时钟是是间接影响输入输出延迟通常不直接使用是是保证接口时序PACKAGE_PIN否基本不参与逻辑综合是必须IOSTANDARD否基本不参与逻辑综合是必须false_path否时序分析使用是间接影响multicycle_path否时序分析使用是间接影响

5. 怎么建立端到端测试结构
5.1 在哪里建立
在 Vivado 项目中：
Plain textAdd Sources→ Add or Create Simulation Sources→ Create File
创建：
Plain texttb_channel_codec.sv
将它设置为仿真顶层：
Plain textSimulation Sources→ 右键 tb_channel_codec→ Set as Top
然后运行：
Plain textFlow Navigator→ Simulation→ Run Behavioral Simulation
行为仿真通过后，再运行：
Plain textRun Post-Synthesis Functional Simulation
Vivado 支持综合后的功能仿真，用于验证综合网表功能是否仍符合设计要求。AMD 文档+1

5.2 端到端测试结构
你的测试结构建议分为两层。
第一层：分别测试编码器和译码器
Plain textMATLAB原始数据      ↓FPGA编码器RTL      ↓编码结果      ↓与MATLAB编码结果逐比特比较
然后测试译码器：
Plain textMATLAB产生LLR      ↓FPGA译码器RTL      ↓译码结果      ↓与原始信息比特或MATLAB译码结果比较
这一步最容易定位到底是编码器错，还是译码器错。

第二层：FPGA端到端连接
Plain text测试数据   ↓CRC添加   ↓码块分段   ↓极化编码   ↓速率匹配   ↓信道模型或LLR生成   ↓速率恢复   ↓极化译码   ↓CRC检查   ↓与原始数据比较
你的 RTL 如果暂时没有速率匹配、CRC 或信道模块，可以先做最简单回环：
Plain text原始数据→ 编码器→ 生成理想LLR→ 译码器→ 原始数据比较

5.3 编码数据不能直接送进软判决译码器
如果译码器输入是 LLR，那么编码结果不能简单作为 0/1 输入。
可以先使用理想 LLR：
Plain text编码比特0 → 正的较大LLR编码比特1 → 负的较大LLR
例如 8 位有符号 LLR：
verilogllr = coded_bit ? -8'sd64 : 8'sd64;
注意你的 RTL 对 LLR 正负号的定义必须一致。有些实现规定：
Plain text正数更倾向于0负数更倾向于1
也有实现可能相反。

5.4 MATLAB 产生哪些标准参考文件
建议 MATLAB 产生四类文件：
Plain textsource_bits.memencoded_expected.memllr_input.memdecoded_expected.mem
它们分别对应：
文件用途source_bits.mem输入 FPGA 编码器encoded_expected.mem与 FPGA 编码输出比较llr_input.mem输入 FPGA 译码器decoded_expected.mem与 FPGA 译码输出比较

5.5 MATLAB 参考模型框架
下面是假设框架，polar_encode_ref 和 polar_decode_ref 需要替换成与你标准完全一致的参考函数。
MATLABclear;clc;rng(1);K = 512;N = 1024;LLR_WIDTH = 8;% 1. 产生原始信息比特u = randi([0, 1], K, 1);% 2. MATLAB参考编码% 必须与RTL保持相同的冻结位集合、比特顺序、CRC和速率匹配coded_ref = polar_encode_ref(u, K, N);% 3. 产生理想LLRLLR_MAG = 64;llr = zeros(N, 1);for i = 1:N    if coded_ref(i) == 0        llr(i) = LLR_MAG;    else        llr(i) = -LLR_MAG;    endend% 4. 量化、饱和llr_max = 2^(LLR_WIDTH - 1) - 1;llr_min = -2^(LLR_WIDTH - 1);llr_q = round(llr);llr_q(llr_q > llr_max) = llr_max;llr_q(llr_q < llr_min) = llr_min;% 5. MATLAB参考译码decoded_ref = polar_decode_ref(llr_q, K, N);% 6. 保存原始比特fid = fopen('source_bits.mem', 'w');fprintf(fid, '%X\n', u);fclose(fid);% 7. 保存编码参考结果fid = fopen('encoded_expected.mem', 'w');fprintf(fid, '%X\n', coded_ref);fclose(fid);% 8. 保存有符号LLR的补码形式llr_unsigned = mod(int64(llr_q), 2^LLR_WIDTH);fid = fopen('llr_input.mem', 'w');for i = 1:N    fprintf(fid, '%02X\n', llr_unsigned(i));endfclose(fid);% 9. 保存译码参考结果fid = fopen('decoded_expected.mem', 'w');fprintf(fid, '%X\n', decoded_ref);fclose(fid);
这里最关键的是 MATLAB 和 RTL 必须完全一致：


$N$


$K$


冻结位集合


可靠度排序


信息位放置顺序


极化变换方向


比特反转顺序


CRC 多项式


CRC 初始值


CRC 位顺序


码块分段方式


速率匹配方式


LLR 正负定义


LLR 位宽


补码格式


饱和规则


译码算法


SCL 列表大小


路径度量计算方式


否则即使两边各自“看起来正常”，也可能无法逐比特一致。

5.6 Vivado Testbench 读取 MATLAB 文件
下面给出一个简化结构，假设编码器和译码器是串行输入、串行输出。
verilog`timescale 1ns/1psmodule tb_channel_codec;    parameter K = 512;    parameter N = 1024;    parameter LLR_WIDTH = 8;    reg clk;    reg rst_n;    reg src_valid;    reg src_bit;    wire enc_valid;    wire enc_bit;    reg llr_valid;    reg signed [LLR_WIDTH-1:0] llr_in;    wire dec_valid;    wire dec_bit;    reg source_bits       [0:K-1];    reg encoded_expected  [0:N-1];    reg [LLR_WIDTH-1:0] llr_vector [0:N-1];    reg decoded_expected  [0:K-1];    integer i;    integer error_count;    polar_encoder u_encoder (        .clk       (clk),        .rst_n     (rst_n),        .in_valid  (src_valid),        .in_bit    (src_bit),        .out_valid (enc_valid),        .out_bit   (enc_bit)    );    polar_decoder u_decoder (        .clk       (clk),        .rst_n     (rst_n),        .llr_valid (llr_valid),        .llr_in    (llr_in),        .out_valid (dec_valid),        .out_bit   (dec_bit)    );    initial begin        clk = 1'b0;        forever #5 clk = ~clk;    end    initial begin        $readmemh("source_bits.mem",      source_bits);        $readmemh("encoded_expected.mem", encoded_expected);        $readmemh("llr_input.mem",         llr_vector);        $readmemh("decoded_expected.mem",  decoded_expected);    end    initial begin        rst_n       = 1'b0;        src_valid   = 1'b0;        src_bit     = 1'b0;        llr_valid   = 1'b0;        llr_in      = '0;        error_count = 0;        repeat (10) @(posedge clk);        rst_n = 1'b1;        repeat (5) @(posedge clk);        // 输入编码器        for (i = 0; i < K; i = i + 1) begin            @(posedge clk);            src_valid <= 1'b1;            src_bit   <= source_bits[i];        end        @(posedge clk);        src_valid <= 1'b0;        src_bit   <= 1'b0;        // 根据实际编码延迟调整等待时间        repeat (2000) @(posedge clk);        // 输入译码器LLR        for (i = 0; i < N; i = i + 1) begin            @(posedge clk);            llr_valid <= 1'b1;            llr_in    <= $signed(llr_vector[i]);        end        @(posedge clk);        llr_valid <= 1'b0;        llr_in    <= '0;        repeat (10000) @(posedge clk);        if (error_count == 0)            $display("TEST PASS");        else            $display("TEST FAIL, error_count = %0d", error_count);        $finish;    endendmodule
这里只展示了文件输入结构，实际还需要加入输出比较计数器。

5.7 FPGA 仿真结果到底与什么比较
要区分三个结果：
MATLAB 参考结果
由 MATLAB 软件模型产生：
Plain textencoded_expected.memdecoded_expected.mem
这是 Golden Reference，也就是黄金参考结果。
Vivado 仿真结果
由 XSim 对你的：


RTL


综合后网表


实现后网表


进行仿真后得到。
FPGA 上板结果
由真实 FPGA 运行后产生，通常通过：


ILA


UART


AXI


PCIe


Ethernet


读取。
所以当前阶段的标准比对是：
Plain textVivado仿真的编码输出vsMATLAB编码参考结果
以及：
Plain textVivado仿真的译码输出vsMATLAB译码参考结果或原始信息比特
端到端测试时，最直接的判断是：
Plain textFPGA译码输出 == 最初输入的原始信息比特

5.8 推荐的测试顺序
不要直接一上来加高斯噪声。按以下顺序：
Plain text1. 编码器固定短向量测试2. 编码器随机向量测试3. 译码器理想LLR测试4. 编码器→理想LLR→译码器5. 单点翻转或固定错误模式6. 固定随机种子的噪声测试7. 大批量BER/BLER统计8. 综合后功能仿真9. 实现后时序仿真10. FPGA上板测试
Vivado 官方建议 Testbench 在仿真开始时初始化全部输入，并明确设置 timescale；综合后和实现后仿真还需考虑器件全局复位过程。AMD 文档

6. DRC 和 ILA 是什么
6.1 DRC
DRC 是：
Plain textDesign Rule Check设计规则检查
它检查你的设计是否违反 FPGA 器件或 Vivado 流程的基本规则。
常见问题包括：


顶层 IO 未指定引脚


IO 未指定电压标准


多个逻辑驱动同一个信号


时钟资源使用不合理


BRAM/DSP 原语连接错误


MMCM/PLL 参数非法


布局位置冲突


IO Bank 电压冲突


调试时钟未连接


某些必需端口悬空


物理资源无法放置


bitstream 生成条件不满足


运行方式：
Plain textOpen Synthesized Design→ Reports→ Report DRC
或者：
tclreport_drc
DRC 会在实现过程中反复运行；布局布线后检查更全面。一些综合阶段的 Critical Warning 到生成 bitstream 时会升级为 Error 并阻止比特流生成。AMD 文档+1
所以不要看到：
Plain textSynthesis completed successfully
就认为设计一定可以生成 bitstream。

6.2 ILA
ILA 是：
Plain textIntegrated Logic Analyzer片上集成逻辑分析仪
它相当于放在 FPGA 内部的“虚拟示波器”。
普通示波器只能观察 FPGA 引脚，而 ILA 可以观察内部信号，例如：
Plain textencoder_stateencoder_validencoded_bitdecoder_statellr_datallr_addrpath_metricfrozen_bitdecoded_validdecoded_bitcrc_okerror_flag
ILA 在真实 FPGA 上运行，通过 JTAG 将采集到的数据传给 Vivado Hardware Manager。它不是仿真器，而是硬件在线调试工具。ILA 可以在 RTL 中实例化，也可以在综合后插入。AMD 文档+1

6.3 ILA 的典型使用流程
方法一：Mark Debug
在 RTL 中标记：
verilog(* mark_debug = "true" *) wire dec_valid;(* mark_debug = "true" *) wire dec_bit;(* mark_debug = "true" *) wire [7:0] llr_data;(* mark_debug = "true" *) wire [9:0] llr_addr;
MARK_DEBUG 可以帮助保留被探测网络及其名称，避免这些网络被复制、重定时或删除。AMD 文档
综合完成后：
Plain textOpen Synthesized Design→ Tools→ Set Up Debug
选择探测信号，设置采样深度，例如：
Plain text1024204840968192
然后：
Plain textRun Implementation→ Generate Bitstream→ Open Hardware Manager→ Program Device
进入 ILA 后设置触发条件，例如：
Plain textstart == 1
或者：
Plain textdec_valid == 1
然后点击触发采样。

方法二：直接实例化 ILA IP
在：
Plain textIP Catalog→ ILA
创建 ILA，配置：


Probe 数量


每个 Probe 位宽


Capture Depth


Trigger 设置


然后在 RTL 中实例化：
verilogila_0 u_ila (    .clk    (clk),    .probe0 (encoder_state),    .probe1 (encoded_bit),    .probe2 (llr_data),    .probe3 (decoder_state),    .probe4 (decoded_bit),    .probe5 (crc_ok));

6.4 ILA 会消耗资源
ILA 会额外消耗：


BRAM：保存采样数据


LUT：触发逻辑


FF：采样和控制


时钟资源


JTAG 调试资源


因此不要直接抓：
Plain text1024位数据总线 × 16384深度
建议抓：
Plain text数据地址valid状态机计数器帧起始帧结束
通过地址和周期逐步还原数据。

你现在在 Vivado 中的实际操作顺序
Plain text1. Open Synthesized Design2. Report Utilization3. 查看 Hierarchy 中 encoder、decoder4. 在 Netlist 中搜索 encoder、decoder5. 打开 Schematic6. 检查 BRAM 是否为 RAMB18/RAMB367. 运行 Check Timing8. 运行 Report Methodology9. 运行 Report DRC10. 建立 Simulation Sources 和端到端 Testbench11. MATLAB产生输入及参考结果12. Run Behavioral Simulation13. Run Post-Synthesis Functional Simulation14. 添加XDC时钟及引脚约束15. Run Implementation16. 检查最终 Timing Summary、Utilization、DRC17. 添加ILA并上板测试
把你的编码器顶层端口、译码器顶层端口，以及目前用于存储 LLR/部分和的 RTL 数组代码贴出来，下一步可以直接按你的实际接口整理成可运行的 Vivado Testbench 和 BRAM 模板。

---

### User

综合后仿真要干什么

---

### ChatGPT

综合后仿真的核心目的是检查：

RTL经过 Vivado 综合、优化并转换成 FPGA 原语后，功能是否仍与综合前一致。

综合前仿真运行的是你写的 Verilog/SystemVerilog RTL；综合后功能仿真运行的是 Vivado 生成的综合网表，其中逻辑已经变成 LUT、触发器、BRAM、DSP 等器件原语。AMD 官方也将其目的定义为确认综合优化没有改变设计功能。AMD 文档
你具体要做什么
不需要重新写一套完整测试平台，通常直接使用行为仿真时的 Testbench 和 MATLAB 参考数据。
测试关系是：
Plain text同一套输入激励       │       ├── RTL行为仿真       │       └── 综合后网表仿真                │                ↓       与MATLAB参考结果比较
对于你的信道编码系统，综合后仿真重点完成以下验证。
1. 验证编码器输出
MATLAB先生成：
Plain text原始信息比特CRC结果码块分段结果极化编码结果
然后将同一组原始信息比特输入综合网表中的编码器，逐比特比较：
Plain textVivado综合网表编码结果             =MATLAB标准编码结果
重点检查：


输出总长度是否正确；


信息位和冻结位位置是否正确；


比特顺序是否一致；


编码输出有没有提前或延迟；


第一位和最后一位有没有丢失；


valid 与数据是否对齐；


连续两个码块之间有没有混叠。


例如 Testbench 中可以写：
systemveriloginteger enc_index;integer enc_error_count;always @(posedge clk) begin    if (enc_out_valid) begin        if (enc_out_bit !== encoded_expected[enc_index]) begin            $display(                "ENC ERROR: index=%0d, FPGA=%b, MATLAB=%b",                enc_index,                enc_out_bit,                encoded_expected[enc_index]            );            enc_error_count <= enc_error_count + 1;        end        enc_index <= enc_index + 1;    endend

2. 验证译码器输出
MATLAB产生：
Plain text编码比特→ 调制→ 信道噪声或理想信道→ 量化LLR
将 MATLAB 生成的 LLR 输入综合后的译码器，再比较：
Plain textVivado译码输出       =原始信息比特
也可以与 MATLAB 译码器输出比较：
Plain textVivado译码输出       =MATLAB译码输出
建议先使用理想 LLR：
Plain text编码比特0 → +64编码比特1 → -64
假设你的译码器定义为：
Plain text正LLR倾向于0负LLR倾向于1
先不加噪声。理想输入都不能正确恢复时，说明编码、冻结位、数据顺序、控制逻辑或译码算法本身存在问题。

3. 做端到端回环验证
完整结构为：
Plain text原始数据   ↓CRC添加   ↓码块分段   ↓极化编码   ↓理想LLR或噪声信道   ↓极化译码   ↓CRC检查   ↓恢复的信息数据   ↓与原始数据比较
推荐分三步测试，不要直接全部连起来调试：
Plain text第一步：单独验证编码器第二步：单独验证译码器第三步：编码器和译码器端到端连接
否则端到端出错时，很难判断问题在编码器、译码器还是接口时序。

综合后仿真重点发现哪些问题
综合优化导致的功能变化
例如：


某个模块输出没有真正使用，被优化掉；


某个寄存器被判定为常数；


状态机状态被重新编码；


有符号与无符号运算结果不一致；


位宽截断；


组合逻辑中的不完整赋值；


case 语句写法导致综合与仿真解释不一致；


未初始化信号在行为仿真和综合网表仿真中表现不同。



RAM和ROM推断问题
例如你原来写的是：
verilogreg [7:0] llr_mem [0:1023];
综合后可能变成：


BRAM；


LUTRAM；


大量触发器；


ROM；


逻辑常量。


综合后仿真需要检查：


BRAM同步读取增加的一拍延迟是否正确处理；


读地址与输出数据是否对齐；


写后读行为是否符合预期；


初始化文件有没有正确加载；


双端口同时读写时有没有冲突。


BRAM是同步读取时，常见错误是 RTL 控制逻辑仍按“地址给出后立即有数据”设计，导致数据和地址错一拍。

DSP和算术推断问题
对于译码器中的：


LLR加减；


绝对值；


最小值；


路径度量；


饱和处理；


需要检查：


正负号；


补码；


位宽扩展；


溢出；


截断；


饱和；


舍入方式。


例如：
verilogreg signed [7:0] a;reg signed [7:0] b;
如果结果仍然只有 8 位：
verilogsum = a + b;
就可能产生溢出。综合后仿真应使用边界数据测试：
Plain text127 + 1-128 - 1127 + 127-128 + -128abs(-128)

复位与启动问题
综合后网表里的寄存器通常不会像某些 RTL 仿真写法那样“天然为零”。
重点检查：


复位是否覆盖所有必要状态；


复位保持周期是否足够；


复位解除后是否等待了必要周期；


第一帧输入是否被正确接受；


BRAM内容是否真的被初始化；


计数器、状态机、地址是否从正确位置开始。


Testbench 中建议：
systemveriloginitial begin    rst_n = 1'b0;    repeat (20)        @(posedge clk);    rst_n = 1'b1;    repeat (10)        @(posedge clk);    // 再开始输入第一帧end

在Vivado哪里运行
综合成功后：
Plain textFlow Navigator→ Simulation→ Run Simulation→ Run Post-Synthesis Functional Simulation
Vivado会生成综合网表，并使用器件仿真库运行综合后功能仿真。AMD 文档
仿真顶层仍然选择你的 Testbench，例如：
Plain texttb_channel_codec
而不是把编码器或译码器本身直接设置为仿真顶层。

综合后功能仿真检查不检查延迟
要区分两种模式。
Post-Synthesis Functional Simulation
主要检查功能：
Plain text不重点考虑真实布线延迟
它回答的是：

综合后的逻辑功能对不对？

你现在应该优先运行这一项。
Post-Synthesis Timing Simulation
加入综合网表的估计延迟，但此时还没有布局布线，因此延迟并不完整，尤其不包含最终真实互连布线结果。AMD 文档+1
Post-Implementation Timing Simulation
布局布线完成后进行，使用实现后的实际延迟信息，比综合后时序仿真更接近 FPGA 真正运行情况。AMD 文档+1
三者区别可以概括为：
仿真类型仿真对象主要用途Behavioral SimulationRTL代码验证算法和控制功能Post-Synthesis Functional综合网表检查综合优化后功能Post-Implementation Timing布局布线网表检查真实延迟下的行为

波形具体看什么
建议至少加入这些信号：
Plain textclkrst_nencoder_startencoder_in_validencoder_in_readyencoder_in_dataencoder_out_validencoder_out_readyencoder_out_dataencoder_donedecoder_startllr_validllr_readyllr_datadecoder_out_validdecoder_out_datadecoder_donecrc_ok
另外加入内部调试信号：
Plain text编码器状态机译码器状态机输入计数器输出计数器BRAM读地址BRAM写地址冻结位索引当前译码位索引错误计数器
重点不是看波形“像不像”，而是自动检查：
Plain text输入数量是否等于K编码输出数量是否等于NLLR输入数量是否等于N译码输出数量是否等于K每一位是否与MATLAB结果一致done是否只出现一次valid是否与数据严格对齐

仿真通过的判据
编码器测试结束时：
Plain text编码输出数量 = N编码错误数量 = 0
译码器测试结束时：
Plain text译码输出数量 = K译码错误数量 = 0CRC结果正确
端到端测试结束时输出：
Plain text================================POST-SYNTHESIS TEST PASSEncoder errors : 0Decoder errors : 0Decoded bits   : K================================
例如：
systemverilogif ((enc_error_count == 0) &&    (dec_error_count == 0) &&    (enc_index == N) &&    (dec_index == K)) begin    $display("POST-SYNTHESIS TEST PASS");end else begin    $display("POST-SYNTHESIS TEST FAIL");    $display("Encoder error count = %0d", enc_error_count);    $display("Decoder error count = %0d", dec_error_count);end
所以你现在做综合后仿真，不是单纯打开波形看一遍，而是用同一套 Testbench、MATLAB输入和黄金参考结果，对综合后的编码器和译码器进行逐比特自动比对。通过后再进行 Implementation、时序分析和上板验证。

---

### User

这个是不是就是形式验证

---

### ChatGPT

不是。综合后仿真不等于形式验证。
综合后仿真属于动态仿真、网表仿真：你给综合后的网表输入一组组测试数据，再观察输出是否正确。Vivado 官方对它的定位是验证综合后的设计是否仍满足功能要求，以及综合优化有没有改变设计行为。AMD 文档+1
两者的核心区别
对比项综合后功能仿真形式验证验证对象综合后的网表RTL、网表或两者验证方式用 Testbench 输入测试向量数学推导、状态空间搜索是否需要测试数据需要通常不依赖传统测试向量检查范围只检查实际跑过的情况尝试覆盖所有满足约束的输入和状态结果某些测试通过或失败属性被证明、找到反例，或无法完成证明能否证明设计完全正确不能在假设和证明范围内可以典型用途功能回归、观察波形、调试接口属性检查、等价性检查、死锁检查
形式验证的目标是对所有满足约束的可能输入或状态进行证明，而不是只检查有限几组测试数据。Cadence Community+1

用你的编码器举例
假设你使用 MATLAB 生成了 1000 组输入数据，然后进行综合后仿真：
Plain textMATLAB输入数据      ↓综合后的编码器网表      ↓编码结果      ↓与MATLAB参考结果比较
1000 组全部正确，只能说明：

这1000组数据下，综合网表输出正确。

不能说明其他所有输入一定正确。
即使输入长度只有 $K=512$，理论输入组合数也是：
$2^{512}$
不可能通过普通仿真穷举全部输入。

什么才是与你当前需求最接近的形式验证
你现在想确认的是：

综合前RTL和综合后网表的功能是否完全一致。

对应的形式验证叫：


逻辑等价性检查 LEC


形式等价性检查


如果包含跨周期、流水线变化，可能需要 顺序等价性检查 SEC/SLEC


它比较：
Plain textRTL设计   ↕综合后网表
工具会尝试证明两者在所有合法输入条件下功能等价，而不是只跑几个测试向量。形式等价检查正是使用形式、静态方法判断两个设计表示是否功能等价。Synopsys+2Siemens Blog Network+2

两种方法的结构区别
综合后仿真
Plain text测试向量1 ─┐测试向量2 ─┼→ 综合后网表 → 输出比较测试向量3 ─┘
例如：
systemverilogfor (int i = 0; i < TEST_NUM; i++) begin    send_data(test_data[i]);    if (fpga_result !== matlab_result[i])        $error("Mismatch at case %0d", i);end
它只检查 TEST_NUM 组数据。
形式等价检查
Plain text               ┌→ RTL输出所有合法输入 ──┤               └→ 网表输出证明：RTL输出 == 网表输出
它检查的逻辑目标可以表示为：
$\forall input,\quad
Output_{\mathrm{RTL}}=Output_{\mathrm{Netlist}}$

综合后仿真还有没有必要
有必要。
即使以后进行了形式等价检查，综合后仿真仍然适合检查：


BRAM改为同步读取后是否错了一拍；


初始化文件是否正确加载；


复位后的第一帧是否正确；


valid、ready、done 是否与数据对齐；


输出位数是否为 $N$；


编码位序是否与MATLAB一致；


LLR正负方向是否正确；


CRC、码块分段和编码器之间的接口是否正确；


Testbench及系统级数据流是否正确。


形式验证更擅长证明逻辑属性，而仿真更方便观察完整数据流和波形。因此工程中通常两者是互补关系，不是互相替代。

你当前应该怎么做
对于现在这个极化码编码和译码项目，建议先不急着专门搭形式验证环境，先完成：
Plain textRTL行为仿真→ MATLAB逐比特参考比对→ 综合→ 综合后功能仿真→ Implementation→ 时序分析→ 上板ILA测试
综合后仿真通过，只能得到：

在当前测试数据下，综合后的网表功能与预期一致。

不能表述为：

已经通过形式验证，证明所有情况下完全正确。

你当前做的是基于测试向量的综合后网表验证，而不是形式验证。

---

### User

1.那我后面还需要做形式验证吗
2.我需要给你提供哪些代码，你能帮我构建MATLAB的模型

---

### ChatGPT

1. 后面是否必须做形式验证
通常不是必须项。
对于你目前的 FPGA 信道编码/译码项目，更实际的验证主线是：
Plain textMATLAB算法参考模型→ RTL行为仿真→ 综合→ 综合后功能仿真→ Implementation→ 静态时序分析→ 上板ILA验证→ BER/BLER性能测试
只要下面几项都完成，通常已经能够支撑课程设计、毕业设计、论文原型或一般工程开发：


编码输出与 MATLAB 参考结果逐比特一致；


理想 LLR 下译码结果与原始数据完全一致；


加噪声后 BER/BLER 与 MATLAB 趋势一致；


综合后仿真通过；


实现后无时序违例；


上板运行结果正确。


哪些情况下建议增加形式验证
下面这些情况才更值得做：


航空航天、汽车、医疗、安全控制等高可靠场景；


项目明确要求形式验证或逻辑等价检查；


控制状态机复杂，容易死锁；


多个时钟域和复杂握手；


译码器资源共享调度复杂；


BRAM 读写地址控制复杂；


需要证明“所有合法输入条件下都不会出现某种错误”。


但不建议一开始就对完整极化码译码算法做全面形式证明。译码器状态空间很大，包含大量存储器、循环和数据运算，证明成本很高。
更适合做的是对控制逻辑进行局部形式验证，例如证明：
Plain text接收到start后，有限周期内一定产生done输入未准备好时不会错误采样输出valid有效时数据保持稳定写地址永远不会超过存储深度输入一个码块后输出数量严格等于K编码输出数量严格等于N不会同时出现两个冲突的BRAM写操作状态机不会进入非法状态复位后一定回到IDLE
因此你的项目推荐这样安排：
验证内容推荐程度MATLAB黄金模型比对必须RTL行为仿真必须综合后功能仿真推荐静态时序分析必须ILA上板测试必须BER/BLER仿真推荐局部形式验证可选加分完整算法形式证明一般不需要RTL与综合网表等价检查有工具或项目要求时进行

2. 构建 MATLAB 模型需要提供哪些代码
可以帮你构建与 RTL 对应的 MATLAB 编码器、译码器和自动对比程序。最方便的方式是把相关 RTL 文件打成一个 ZIP。
不一定需要整个 Vivado 工程，至少需要以下内容。
第一类：顶层接口，必须提供
编码器顶层模块
例如：
Plain textpolar_encoder_top.v
需要看到：


输入数据接口；


输出数据接口；


start、valid、ready、done；


码长、码率、信息长度参数；


数据是串行还是并行；


一个时钟输入多少位；


输出顺序。


例如：
verilogmodule polar_encoder_top #(    parameter N = 1024,    parameter K = 512)(    input  wire clk,    input  wire rst_n,    input  wire start,    input  wire in_valid,    input  wire in_bit,    output wire in_ready,    output wire out_valid,    output wire out_bit,    output wire done);
译码器顶层模块
例如：
Plain textpolar_decoder_top.v
需要确认：


输入是硬判决比特还是 LLR；


LLR 位宽；


LLR 是有符号补码还是其他格式；


正 LLR 表示 0 还是表示 1；


输出是全部 $N$ 位还是只输出 $K$ 个信息位；


译码算法是 SC、SCL、SSC 还是其他算法；


SCL 的列表大小；


CRC 是否参与路径选择。



第二类：编码核心代码，必须提供
建议提供所有与编码数据流有关的模块，例如：
Plain textpolar_encoder.vpolar_transform.vfrozen_insert.vreliability_rom.vbit_reverse.vcrc_append.vblock_segmentation.vrate_matching.vencoder_controller.v
重点需要确认：
信息位放置规则
例如 RTL 是按可靠度序列选择信息位：
verilogif (info_bit_flag[index])    u[index] <= input_bit;else    u[index] <= 1'b0;
MATLAB 必须使用完全相同的位置。
极化变换方向
常见极化编码可表示为：
$x=uG_N$
但是不同实现可能存在：


是否包含比特反转；


XOR 蝶形从前向后还是从后向前；


输入索引从 0 还是从 1；


最终输出是否重新排列；


位流是高位先出还是低位先出。


所以不能只根据“极化码”三个字写一个通用模型，必须按照你的 RTL 位序复现。

第三类：译码核心代码，必须提供
例如：
Plain textpolar_decoder.vsc_decoder.vscl_decoder.vf_node.vg_node.vpartial_sum.vpath_metric.vpath_sort.vllr_memory.vpartial_sum_memory.vdecoder_controller.vcrc_check.v
特别要提供以下运算模块。
F节点
例如：
verilogassign f_out =    sign_a ^ sign_b        ? -min_abs        :  min_abs;
需要知道是否使用：


精确函数；


min-sum 近似；


offset min-sum；


饱和处理。


G节点
例如：
verilogg_out = b + ((u == 0) ? a : -a);
需要确认：


位宽有没有扩展；


是否饱和；


是否直接截断；


负数的处理；


中间结果位宽。


路径度量
若使用 SCL，需要提供路径度量更新公式，例如：
verilogif (hard_bit == candidate_bit)    pm_new = pm_old;else    pm_new = pm_old + abs_llr;
MATLAB必须复现 RTL 使用的定点近似，不能只使用浮点理论公式，否则路径选择可能不同。

第四类：参数表和初始化文件，必须提供
包括：
Plain text*.mem*.coe*.hex*.dat*.txt
尤其是：


可靠度排序表；


冻结位表；


CRC 多项式表；


码块分段表；


码率匹配表；


交织表；


地址映射表；


ROM 初始化文件。


你发的标准图片中包含 $N=64、128、256、512、1024$ 的母可靠度序列选择，但最终 MATLAB 仍应以 RTL 实际使用的 ROM 数据为准。

第五类：CRC代码和参数，必须提供
根据你上传的标准，可能涉及：


CRC12；


CRC24A；


CRC24B；


CRC32。


需要明确：
Plain textCRC多项式CRC初始值输入位顺序高位优先还是低位优先是否反射是否异或输出CRC附加顺序
即使多项式相同，位序不同也会得到完全不同的 CRC 结果。
最好提供：
Plain textcrc12.vcrc24a.vcrc24b.vcrc32.v
以及你 RTL 中调用 CRC 的位置。

第六类：码块分段和级联代码，必须提供
你发的标准中涉及：


是否添加 24 位 CRC；


码块数量 $C$；


不同码长的块数；


最后一个码块处理；


CBG 分组；


码块级联。


因此需要提供：
Plain textblock_segment.vblock_concat.vcbg_controller.v
或者相应顶层控制代码。
MATLAB模型需要复现：
Plain text输入B位→ 判断是否分段→ 每块添加CRC→ 确定每块Kr→ 填充→ 选择N→ 极化编码→ 码块级联

第七类：码率匹配代码，存在就提供
例如：
Plain textrate_match.vpuncture.vshorten.vrepeat.vinterleaver.v
需要确认 RTL 使用的是：


截短；


打孔；


重复；


子块交织；


循环缓冲；


输出 $E$ 位的具体顺序。


如果第一阶段只验证母码编码和译码，码率匹配可以暂时不加入。

第八类：现有 Testbench，强烈建议提供
例如：
Plain texttb_encoder.svtb_decoder.svtb_top.sv
Testbench 能帮助确认：


输入发送协议；


时钟周期；


复位方式；


start 保持几个周期；


valid 是否允许间断；


每帧之间间隔；


输出采样条件；


目前已经测试过哪些数据。


即使 Testbench 不完整，也应一起发过来。

第九类：Vivado配置或参数说明
还需要文字说明以下参数：
Plain textFPGA型号：时钟频率：支持的N：支持的K：支持的码率：编码器并行度：译码器算法：列表大小L：LLR位宽：路径度量位宽：接口每拍位数：是否包含CRC：是否包含码块分段：是否包含码率匹配：
例如：
Plain text器件：xc7a100tfgg484-2时钟：100 MHzN：64/128/256/512/1024K：动态配置译码：SCLLR：8位有符号补码LLR规则：正数表示更倾向于0输入：每拍1个LLR输出：每拍1个信息比特

最小提交内容
为了先开始做一个基础模型，最少提供：
Plain text1. encoder_top.v2. decoder_top.v3. 所有被顶层实例化的子模块4. 所有.mem/.coe/.hex文件5. 当前Testbench6. N、K、LLR位宽、译码算法说明
最好直接把：
Plain textVivado工程中的srcs目录
打包上传，不需要上传这些大目录：
Plain text.runs.cache.gen.sim.ip_user_files
一个推荐的压缩包结构是：
Plain textpolar_fpga/├─ rtl/│  ├─ encoder_top.v│  ├─ decoder_top.v│  ├─ crc/│  ├─ encoder/│  ├─ decoder/│  └─ memory/├─ sim/│  ├─ tb_encoder.sv│  ├─ tb_decoder.sv│  └─ tb_top.sv├─ data/│  ├─ reliability.mem│  ├─ frozen_bits.mem│  └─ other_tables.mem└─ README.txt
README 里只需要写清楚：
Plain text顶层模块：N和K：编码输入顺序：编码输出顺序：译码算法：LLR格式：当前已知问题：

MATLAB模型可以分成哪些文件
根据你的 RTL，可以构建成下面的结构：
Plain textmatlab_model/├─ main_generate_vector.m├─ main_encoder_verify.m├─ main_decoder_verify.m├─ main_end_to_end.m│├─ polar_encode_rtl_ref.m├─ polar_decode_rtl_ref.m├─ polar_transform.m├─ build_frozen_set.m│├─ crc12_calc.m├─ crc24a_calc.m├─ crc24b_calc.m├─ crc32_calc.m│├─ block_segmentation.m├─ rate_matching.m├─ rate_recovery.m│├─ quantize_llr.m├─ f_node_fixed.m├─ g_node_fixed.m│├─ write_mem_file.m├─ read_fpga_output.m└─ compare_result.m
最终可以产生：
Plain textencoder_input.memencoder_expected.memdecoder_llr_input.memdecoder_expected.mem
并自动读取 Vivado 输出：
Plain textencoder_actual.txtdecoder_actual.txt
生成类似结果：
Plain textEncoder comparison:Expected bits = 1024Actual bits   = 1024Error bits    = 0Result        = PASSDecoder comparison:Expected bits = 512Actual bits   = 512Error bits    = 0Result        = PASS
当前阶段建议优先完成 MATLAB黄金模型 + RTL逐比特比对，形式验证放在功能和时序全部正常之后，只针对状态机、地址边界和握手协议做局部属性验证。

---

### User

你这个说的和A模块是一个东西吗

---

### ChatGPT

是，基本上就是同一个东西。
但准确说，图里的 A 模块是我前面所说 MATLAB 黄金模型工作的核心部分；我前面描述的 MATLAB 模型范围稍大，还可以继续覆盖 CRC、码块分段和端到端链路。
图中 A 与我前面说法的对应关系
图中 A 的内容对应的具体工作浮点 SC 参考模型建立理论正确的 SC 译码器，作为算法基准定点位宽扫描模拟 FPGA 中有限位宽、补码、截断、饱和，寻找合适的 LLR 和中间数据位宽生成对拍向量生成 Vivado Testbench 使用的 .mem/.txt 输入和期望输出测试框架自动读取 RTL 仿真结果，与 MATLAB 结果逐比特比较并输出 PASS/FAIL黄金模型作为 RTL 编码器、译码器的标准参考结果
也就是：
Plain textMATLAB浮点SC模型        ↓验证算法本身是否正确        ↓转换为与RTL一致的定点SC模型        ↓生成输入向量和期望输出        ↓Vivado运行RTL/综合后仿真        ↓MATLAB或Testbench自动对拍
A 模块不包含什么
图中的 A 主要是软件参考模型与测试工具，不包含：


B：FPGA 中真正的 SC 译码数据通路；


C：控制 f/g 计算顺序的 FSM；


D：硬件中的 CRC24B、码块分段、解级联；


E：顶层连接、XDC、综合和时序收敛。


因此，A 不会被综合到 FPGA 中，它是用来验证 B、C、D 是否正确的。
我前面说的 MATLAB 模型比 A 多出的部分
我前面提出的是一个可扩展的完整模型，除了 A，还可以加入 D 的软件参考：
Plain text输入信息→ CRC添加→ 码块分段→ frozen mask生成→ 极化编码→ BPSK/AWGN或理想LLR→ SC译码→ CRC检查→ 解分段→ 原始数据比较
所以两者关系可以理解为：
Plain text图中的A=MATLAB黄金模型的第一阶段和核心部分我前面说的完整MATLAB模型=A + 部分D的软件参考模型 + 自动对拍工具
建议你现在先做的 A 模块
第一阶段先实现以下文件：
Plain textmatlab/├─ polar_encode_ref.m          % 编码黄金模型├─ sc_decode_float.m           % 浮点SC译码├─ sc_decode_fixed.m           % 定点SC译码├─ f_float.m├─ g_float.m├─ f_fixed.m├─ g_fixed.m├─ build_frozen_mask.m├─ quantize_llr.m├─ generate_test_vectors.m├─ compare_rtl_result.m└─ run_regression.m
产生：
Plain textencoder_input.memencoder_expected.memdecoder_llr_input.memdecoder_expected.mem
然后 Vivado Testbench 读取这些文件，将 RTL 输出写成：
Plain textencoder_actual.txtdecoder_actual.txt
最后 MATLAB 比较：
Plain textencoder_expected.mem  vs encoder_actual.txtdecoder_expected.mem  vs decoder_actual.txt
为了构建 A，需要你提供什么
即使 A 在计划中写着“无依赖”，要做到与现有 RTL 逐比特完全一致，仍需要确认：


支持的 $N$、$K$ 或码率；


可靠度序列或 frozen mask 文件；


编码器的输入、输出比特顺序；


SC 译码器的 LLR 定义；


LLR 输入位宽；


f、g 节点 RTL；


中间 LLR 位宽；


加减法是截断、回绕还是饱和；


abs(-2^{W-1}) 的处理；


判决规则是 LLR >= 0 判 0，还是其他规则；


信息位输出顺序；


当前 Testbench。


其中 FSM 调度、BRAM 地址和硬件流水线不属于 MATLAB 算法本身，但后续需要结合 B、C 的 RTL 来检查时序对齐。
所以，你图里的 A 模块正是现在优先应该建立的 MATLAB 黄金模型、定点模型和对拍环境。完成 A 后，再用它逐层验证 B、C、D。

---

### User

那这些我的组员在做，你直接开始教我布局布线部分的内容

---

### ChatGPT

好，我们从 **Vivado 的布局布线（Implementation）**开始。现阶段先不要手工摆放逻辑，也不要急着画 Pblock；第一轮应让 Vivado 自动完成实现，先获得时序、资源和拥塞基线。AMD 也建议在没有明确物理问题时，优先尝试无 Pblock 或最少物理约束的实现。AMD 文档
一、布局布线到底在做什么
综合只是把 RTL 转换成逻辑资源，例如：
Plain textVerilog  ↓LUT、触发器、BRAM、DSP、MUX、Carry Chain
实现阶段则要把这些逻辑映射到 FPGA 芯片内部的实际位置，并用实际布线资源连接：
Plain textopt_design    ↓place_design    ↓phys_opt_design    ↓route_design
其中：


opt_design：实现前逻辑优化；


place_design：决定 LUT、寄存器、BRAM、DSP 放在哪个物理位置；


phys_opt_design：根据物理位置进一步优化关键路径、扇出和复制等；


route_design：选择实际布线资源连接逻辑。


phys_opt_design 既可以在布局后运行，也可以在布线后再次运行。AMD 文档+2AMD 文档+2
在 Vivado 的 Project Mode 中，点击一次 Run Implementation，工具通常会自动完成上述流程。

二、布局布线之前必须准备什么
1. 确认综合顶层
在 Sources 窗口确认真正用于上板的顶层模块带有顶层标志，例如：
Plain textchannel_codec_top
而不是：
Plain textpolar_encoderpolar_decodertb_channel_codec
Testbench 不能作为综合和实现顶层。
右键顶层模块：
Plain textSet as Top

2. 确认 FPGA 器件型号
进入：
Plain textProject Manager→ Settings→ General→ Project Device
确认 FPGA 型号和开发板实际器件一致。
例如不能只看“Artix-7”，还要确认完整型号，包括：
Plain text器件系列容量封装速度等级
型号选择错误会直接导致：


可用资源不同；


引脚不同；


时序模型不同；


bitstream 无法用于目标板卡。



3. 建立 XDC 约束文件
进入：
Plain textAdd Sources→ Add or Create Constraints→ Create File
创建：
Plain textchannel_codec.xdc
布局布线至少需要正确的时钟约束。引脚约束则用于确定顶层端口对应的物理管脚和 IO 电压标准。

三、先写最基本的时钟约束
假设顶层时钟端口叫：
veriloginput wire sys_clk;
开发板输入时钟为 100 MHz，那么周期为 10 ns：
tclcreate_clock -name sys_clk \             -period 10.000 \             -waveform {0.000 5.000} \             [get_ports sys_clk]
含义是：
Plain text时钟频率：100 MHz周期：10 ns上升沿：0 ns下降沿：5 ns
如果是 50 MHz：
tclcreate_clock -name sys_clk \             -period 20.000 \             [get_ports sys_clk]
如果是 200 MHz：
tclcreate_clock -name sys_clk \             -period 5.000 \             [get_ports sys_clk]
时序约束会驱动综合、布局、布线和静态时序分析。没有正确时钟约束，即使 Vivado 显示 Implementation 完成，也不能证明电路能以目标频率工作。Timing Summary 是 Vivado 用于最终时序签核的主要报告。AMD 文档+1

四、添加引脚和 IO 电平约束
例如：
tclset_property PACKAGE_PIN <时钟管脚> [get_ports sys_clk]set_property IOSTANDARD LVCMOS33 [get_ports sys_clk]set_property PACKAGE_PIN <复位管脚> [get_ports rst_n]set_property IOSTANDARD LVCMOS33 [get_ports rst_n]
这里的 <时钟管脚>、<复位管脚> 不能照抄其他开发板，必须从以下资料获取：


你的开发板原理图；


开发板 Master XDC；


FPGA 管脚分配表；


开发板厂家示例工程。


例如某块板使用 W5，不代表你的板也是 W5。
如果编码器、译码器当前只准备通过 ILA 做内部回环测试，第一阶段通常只需要：


时钟；


复位；


必要的 LED/UART 等上板接口。


如果数据通过外部 ADC、SPI、并行总线或其他芯片进入 FPGA，还必须根据外部器件时序添加 set_input_delay 和 set_output_delay。因为 Vivado 本身只知道 FPGA 内部延迟，板级和外部芯片延迟需要通过 XDC 告诉它。AMD 文档+2AMD 文档+2

五、布局布线前先检查约束
综合完成后点击：
Plain textOpen Synthesized Design
然后在 Tcl Console 运行：
tclcheck_timing
再运行：
tclreport_methodology
以及：
tclreport_timing_summary
重点检查是否出现：
Plain textNo clockUnconstrained internal endpointsMultiple clockConstant clockCombinational loop
如果 Vivado 根本没有识别出时钟，不能直接继续看 WNS。
还可以输入：
tclget_clocks
正常情况下应该返回类似：
Plain textsys_clk
再输入：
tclreport_clocks
确认周期是你设定的数值。

六、运行第一次布局布线
在左侧 Flow Navigator 中点击：
Plain textIMPLEMENTATION→ Run Implementation
首次运行选择默认策略即可：
Plain textStrategy:Vivado Implementation Defaults
默认策略在运行时间和时序收敛能力之间进行平衡，适合做第一轮基线实现。AMD 文档
运行时 Vivado 会依次执行：
Plain textDesign Initialization        ↓Opt Design        ↓Power Opt Design（视设置而定）        ↓Place Design        ↓Post-Place Phys Opt Design        ↓Route Design        ↓Post-Route Phys Opt Design（视策略而定）
运行完成后选择：
Plain textOpen Implemented Design
先不要马上生成 bitstream。

七、实现完成后首先检查什么
打开 Implemented Design 后，建议按下面顺序检查。
第一步：检查是否全部布通
Tcl Console 输入：
tclreport_route_status
重点看是否存在：
Plain textUnrouted NetsRouting ErrorsNets with Routing Conflicts
理想结果应为：
Plain text所有需要布线的网络已经完成Unrouted Nets = 0
report_route_status 就是用来定位未布线或存在布线错误网络的。AMD 文档

第二步：检查 DRC
运行：
tclreport_drc
或者：
Plain textReports→ Report DRC
关注级别：
Plain textErrorCritical WarningWarningAdvisory
当前阶段至少应达到：
Plain textDRC Error = 0
常见错误包括：


顶层引脚没有指定；


IOSTANDARD 没有指定；


时钟资源放置不合法；


IO Bank 电压冲突；


多重驱动；


BRAM 或时钟原语连接不合法；


无法完成物理布局。



第三步：检查时序
运行：
tclreport_timing_summary
或者：
Plain textReports→ Timing→ Report Timing Summary
重点看：
Plain textSetupWNSTNSHoldWHSTHS
通过标准为：
Plain textWNS ≥ 0 nsTNS = 0 nsWHS ≥ 0 nsTHS = 0 ns
AMD 的时序签核指标要求建立/恢复裕量为正、TNS 为 0，保持/移除裕量为正、THS 为 0。AMD 文档+1
例如：
Plain textWNS = 1.247 nsTNS = 0.000 nsWHS = 0.083 nsTHS = 0.000 ns
表示时序通过。
如果显示：
Plain textWNS = -2.315 nsTNS = -187.426 ns
说明存在建立时间违例，当前设计不能稳定达到 XDC 指定的目标频率。

第四步：检查是否存在未约束路径
Timing Summary 中展开：
Plain textCheck Timing
以及：
Plain textUnconstrained Paths
一个常见误区是：
Plain textWNS为正
但实际上许多路径根本没有被约束。
例如外部输入、输出路径如果没有 set_input_delay 或 set_output_delay，Vivado默认不会完整分析这些路径。AMD 文档
因此真正的通过条件不是只有 WNS 为正，而是：
Plain text时钟约束正确关键输入输出路径已约束没有重要的未约束路径WNS/TNS通过WHS/THS通过

第五步：检查最终资源
运行：
tclreport_utilization
分层查看：
tclreport_utilization -hierarchical
重点确认：


编码器和译码器资源仍然存在；


BRAM 数量是否合理；


LUT、FF 是否过高；


DSP 使用是否符合设计；


ILA 加入后资源是否明显增加。


Utilization Report 可以在不同实现阶段生成，并支持按层次、Pblock 和物理区域分析资源。AMD 文档

第六步：检查时钟结构
运行：
tclreport_clock_utilization
主要检查：


BUFG 使用；


MMCM/PLL；


时钟负载；


时钟区域；


时钟是否错误地走普通布线。


Clock Utilization Report 用于分析时钟原语和时钟布线资源，也可辅助定位时钟放置问题。AMD 文档

八、如何看最差时序路径
在 Timing Summary 中展开：
Plain textIntra-Clock Paths→ sys_clk→ Setup
双击最差路径。
一条时序路径一般显示：
Plain text起点寄存器    ↓组合逻辑    ↓布线    ↓终点寄存器
重点看：
Plain textLogic DelayRoute DelayLogic LevelsRequirementData Path DelaySlack
例如：
Plain textRequirement       10.000 nsData Path Delay   11.750 nsSlack             -1.950 ns
说明数据需要约 11.75 ns 才能到达，但只允许约 10 ns，加上时钟不确定度后违例约 1.95 ns。

九、SC译码器出现时序违例时怎么判断
你的 SC 译码器比较容易出现下面几类关键路径。
1. f/g 运算链太长
例如一个周期中连续完成：
Plain text绝对值→ 比较→ 最小值→ 符号异或→ 加减→ 多级MUX→ 写回
如果 Logic Delay 占大多数，说明组合逻辑过深。
解决方向：
Plain text增加流水线寄存器拆分f/g运算限制单周期并行层数减少长MUX链增加中间结果寄存
AMD建议优先分析综合后或 opt_design 后最长逻辑路径，因为降低逻辑深度通常比反复尝试布局布线更有效。AMD 文档

2. FSM控制信号扇出过大
例如下面的信号同时控制大量 PE、BRAM 和寄存器：
Plain textstatestagenode_typewrite_enablefrozen_flagclear
如果路径报告显示：
Plain textRoute Delay 很高Fanout 很大
说明问题可能不是运算本身，而是控制网络跨越芯片范围太大。
解决方向：


对控制信号增加一级寄存器；


分区域生成局部使能；


让综合器复制高扇出寄存器；


不要让一个组合译码信号直接控制几千个寄存器；


避免巨大的一层 case 产生超大选择器。



3. BRAM与PE距离太远
如果 LLR RAM、部分和 RAM 与 f/g PE 之间路由时间很长，可能出现：
Plain textBRAM输出→ 大MUX→ PE→ 大MUX→ BRAM输入
一个周期内同时读、计算、选择并写回，路径可能过长。
解决方向：
Plain text第1拍：BRAM读取第2拍：f/g计算第3拍：结果写回
而不是全部压在一个周期完成。

4. 地址计算链太长
例如单周期内计算：
Plain text层级→ 节点编号→ 偏移地址→ RAM bank选择→ 实际读地址
如果使用多级乘法、除法、取模和大型 MUX，可能成为关键路径。
对极化码固定的 $N=64/128/256/512/1024$，很多地址关系都可以改成：


位移；


拼接；


查表；


预计算；


分拍计算。



十、如果 WNS 为负，先不要马上画 Pblock
建议按以下顺序处理：
Plain text1. 确认时钟周期是否写对2. 确认生成时钟和跨时钟约束是否正确3. 查看最差路径属于哪个模块4. 判断是Logic Delay还是Route Delay5. 修正RTL结构和流水线6. 再尝试实现策略7. 最后才考虑Pblock和手工布局
AMD建议先检查约束完整性和方法学问题，再分析时序违例的根因，而不是直接加入物理约束。AMD 文档+1

十一、什么时候更换 Implementation Strategy
如果默认策略已经接近通过，例如：
Plain textWNS = -0.1 nsWNS = -0.3 ns
可以尝试：
Plain textPerformance_Explore
在 Vivado 中进入：
Plain textDesign Runs→ 选中 impl_1→ Change Run Settings
或者：
Plain textProject Settings→ Implementation→ Strategy
选择：
Plain textPerformance_Explore
AMD将 Performance_Explore 推荐为默认策略无法满足目标、且可以接受更长运行时间时的优先尝试策略。AMD 文档
但是，如果出现：
Plain textWNS = -5 ns
而时钟周期只有 10 ns，通常不是换策略能够根治的，应优先修改 RTL 流水线和组合逻辑深度。

十二、什么时候检查拥塞
如果遇到：


place_design 很慢；


route_design 无法完成；


大量路径 Route Delay 很高；


LUT资源没有满，但局部区域非常密集；


编码器、译码器和 ILA 挤在某一区域；


运行：
tclreport_design_analysis
查看 Congestion 部分。
Vivado 的 Congestion Report 会标记拥塞区域，并指出这些区域中包含哪些设计层次；拥塞会减少可用布局和布线选择，并增加时序收敛难度。AMD 文档+1
此时再考虑：


降低并行度；


使用更多 BRAM、减少分布式寄存器；


拆分大模块；


减少超宽总线；


增加流水线；


最后使用 Pblock 约束相关模块。



十三、第一轮实现的合格标准
你的第一次布局布线应达到下面这些结果：
项目合格条件Route Status所有网络完成布线DRC无 Error时钟被正确识别SetupWNS ≥ 0，TNS = 0HoldWHS ≥ 0，THS = 0未约束路径无重要未约束路径BRAM与设计预期基本一致资源占用没有超器件容量Methodology无必须处理的 Critical Warning编码器/译码器在综合网表和分层资源中存在
达到这些条件后，再进入：
Plain textGenerate Bitstream→ Hardware Manager→ 下载FPGA→ ILA在线测试

十四、你现在直接执行的步骤
先按下面操作，不要更换策略，也不要画 Pblock：
Plain text1. 确认FPGA型号和顶层模块2. 创建XDC3. 添加真实时钟周期4. 添加时钟、复位等必要引脚5. Open Synthesized Design6. 运行 check_timing7. 运行 report_methodology8. Run Implementation9. Open Implemented Design10. 运行 report_route_status11. 运行 report_drc12. 运行 report_timing_summary13. 运行 report_utilization -hierarchical
第一轮重点保存以下结果：
Plain textFPGA完整型号目标时钟频率WNS、TNS、WHS、THSLUT、FF、BRAM、DSP占用最差Setup路径DRC Error/Critical WarningRoute Status
这些结果决定下一步是修改 XDC、修改 RTL 流水线、调整 BRAM，还是只需要更换实现策略。

