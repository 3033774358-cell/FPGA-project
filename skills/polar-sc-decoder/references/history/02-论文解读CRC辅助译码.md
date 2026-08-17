# 论文解读：CRC辅助译码

*导出时间: 2026/8/12 16:42:38*

---

### User

📎 **CRC-Aided_Decoding_of_Polar_Codes.pdf** (PDF)

带着我读这篇论文

---

### ChatGPT

可以。我们不直接硬啃公式，而是按“先看问题—再看算法—最后看结果”的顺序读。这篇论文只有 4 页，但信息密度很高，适合分四轮。
第一轮：先弄清论文到底做了什么
论文题目是 《CRC-Aided Decoding of Polar Codes》，作者 Kai Niu 和 Kai Chen，发表于 2012 年。
它的核心思想可以压缩成一句话：

SCL/SCS 解码器先产生若干个候选码字，再利用 CRC 从这些候选中选出更可能正确的那个。

作者提出了两种算法：


CA-SCL：CRC-Aided Successive Cancellation List decoding
CRC 辅助的串行抵消列表译码


CA-SCS：CRC-Aided Successive Cancellation Stack decoding
CRC 辅助的串行抵消栈译码


论文摘要明确说，它先统一描述 SC、SCL 和 SCS，然后提出 CA-SCL/CA-SCS；在码长 $N=1024$、码率 $R=1/2$、BLER 为 $10^{-4}$ 时，相比文中采用的 3GPP Turbo 码方案有约 $0.5$ dB 增益。CRC-Aided_Decoding_of_Polar_Cod…

一、为什么需要这篇论文
1. Polar 码理论很好，但有限码长下 SC 译码不够好
Polar 码在码长趋于无穷时，可以达到二进制输入离散无记忆信道的对称容量。
但工程上码长不可能无限大。论文指出：

Polar 码虽然在 SC 译码下具有容量可达性，但有限码长性能并不令人满意。CRC-Aided_Decoding_of_Polar_Cod…

问题主要不一定出在 Polar 码本身，而是出在最基本的 SC 译码器。
SC 译码是逐比特判决：
$\hat u_1\rightarrow \hat u_2\rightarrow\cdots\rightarrow \hat u_N$
每判决一个信息比特，就立即确定为 0 或 1，之后不能回头。
因此，假如第 20 位判错了，即使后面收到的信息表明第 20 位可能有问题，SC 也不会修改它。论文直接指出：

一旦某一比特被错误判决，后续译码过程中就没有机会修正。CRC-Aided_Decoding_of_Polar_Cod…

这就是 SC 的主要缺陷：错误传播。

2. SCL 的解决办法：先不要急着只选一条路径
假设译码到某一个信息比特时，0 和 1 都有可能。
SC 的做法是：
$0.51>0.49$
所以立即选 0，并删除 1。
SCL 的做法是：


保留“当前比特为 0”的路径；


也保留“当前比特为 1”的路径；


每条路径继续往后译码；


最多保留 $L$ 条最可靠的路径。


这里的 $L$ 称为列表大小。
例如：
$L=4$
表示在译码过程中最多同时保留 4 条候选路径。
论文将 SCL 描述为：每次信息位扩展时，候选路径数加倍，然后只保留路径度量最大的 $L$ 条。CRC-Aided_Decoding_of_Polar_Cod…

3. SCS 的解决办法：优先搜索最有希望的路径
SCS 不像 SCL 那样让多条等长路径一起向前推进。
它使用一个按路径可靠性排序的栈：


从栈顶取出当前最可靠的路径；


扩展这条路径；


把新路径放回栈中；


重新排序；


始终优先搜索最可靠的路径。


所以：


SCL 更像“多条路径并行前进”；


SCS 更像“最佳优先搜索”。


论文指出，SCL 列表中的路径通常具有相同长度，而 SCS 栈中的路径长度可以不同。CRC-Aided_Decoding_of_Polar_Cod…

二、为什么还需要 CRC
这是理解整篇论文最关键的地方。
即使 SCL 最后留下了 $L$ 个候选码字，仍然存在一个问题：

应该从这 $L$ 个候选中选哪一个？

普通 SCL 的做法是：
$\hat{\mathbf u}
=
\arg\max_{\mathbf u\in\mathcal L}
M(\mathbf u)$
即选择路径度量最大的候选。
但路径度量最大，不一定代表它就是正确码字。尤其在噪声较大时，真正正确的码字可能排在第二、第三，甚至更后面。
于是作者引入 CRC。
发送端先把：
$k\text{ 个信息比特}$
附加：
$m\text{ 个 CRC 比特}$
得到：
$K=k+m$
然后将这 $K$ 个比特作为 Polar 码的信息比特输入编码器。论文中仍将 Polar 码码率定义为：
$R=\frac{K}{N}$
而不是 $k/N$。CRC-Aided_Decoding_of_Polar_Cod…
接收端处理流程是：
$\text{信道输出}
\rightarrow
\text{SCL/SCS}
\rightarrow
\text{多个候选序列}
\rightarrow
\text{CRC 检验}$
论文第 1 页的 Fig. 1 就画出了这个结构。

CRC 在这里不是主要用来“纠错”
CRC 本身通常用于检错。
这篇论文的创新点是：把 CRC 检验结果用于候选路径选择。
例如 SCL 最终给出 4 条候选路径：
路径路径度量排名CRCA1不通过B2通过C3不通过D4不通过
普通 SCL 会选路径 A。
CA-SCL 会选路径 B。
所以 CRC 实际提供了一种额外约束：
$\text{路径可靠性}
+
\text{码字结构合法性}$
这就是为什么 CA-SCL 往往明显优于普通 SCL。

三、用一个形象比喻理解
把译码想象成走迷宫。
SC
每遇到岔路口，只选看起来最好的一条路：

“左边似乎更可靠，走左边。”

走错后不能回头。
SCL
同时派 $L$ 个人走不同路线：

“先保留几条最可能的路线，最后挑看起来最好的。”

SCS
维护一个“最值得继续探索的路线排行榜”：

“每次都从当前最有希望的路线继续走。”

CA-SCL / CA-SCS
到达出口后，不只是看哪条路线评分最高，还检查它是否持有正确的“CRC 通行证”。
因此：

CRC 不是帮助每一步选择方向，而是在完整候选路径之间进行最终筛选。


四、这篇论文的结构
作者在引言末尾给出的文章组织是：


Section II：基础知识


Polar 编码


APP


SC、SCL、SCS 的统一描述




Section III：CRC 辅助译码


CA-SCL


CA-SCS




Section IV：性能与复杂度


与 SC、SCL、SCS、Turbo 码比较


分析 BLER 和平均计算复杂度




Section V：结论 CRC-Aided_Decoding_of_Polar_Cod…


我们后续阅读时，重点程度可以这样分：
部分重要程度阅读目标Abstract / Introduction高明白为什么用 CRCSection II-A中看懂 APP 和符号Section II-B很高明白三种搜索方式Section III-A很高掌握 CA-SCLSection III-B较高掌握 CA-SCSSection IV很高理解性能与复杂度结论

五、先看懂论文的最终结论
论文在 $N=1024$、$R=1/2$ 的 BI-AWGN 信道中进行了仿真，使用 CRC-24，生成多项式为：
$g(D)=D^{24}+D^{23}+D^6+D^5+D+1$
CRC 的 24 个比特和 $k$ 个原始信息比特一起送入 Polar 编码器。CRC-Aided_Decoding_of_Polar_Cod…
论文报告：


SCL 和 SCS 的性能基本相同；


二者明显优于 SC；


未使用 CRC 辅助时，SCL/SCS 与 Turbo 码在 BLER $10^{-4}$ 附近仍有约 $0.7$ dB 差距；


使用 CRC 后，CA-SCL(32) 和 CA-SCS(32,1000) 反而比文中 Turbo 码基准好约 $0.5$ dB；


仿真到 BLER $10^{-6}$ 时，没有观察到明显错误平台。CRC-Aided_Decoding_of_Polar_Cod…


这里的：
$\text{CA-SCL}(32)$
表示列表大小：
$L=32$
而：
$\text{CA-SCS}(32,1000)$
表示：
$Q=32,\qquad D=1000$
其中：


$Q$：最多尝试的完整候选路径数量；


$D$：栈的最大深度。



六、今天这一轮你需要记住的四句话


SC 每个比特只做一次决定，判错后不能回头。


SCL 保留最多 $L$ 条候选路径，降低正确路径被过早删除的概率。


SCS 使用有序栈，优先扩展当前最可靠的路径。


CRC 不负责产生候选路径，而是帮助从完整候选路径中选出正确码字。


下一步应进入论文第二节，从 Polar 编码结构、信息位集合 $\mathcal A$、冻结位集合 $\mathcal A^c$、码树和路径度量 开始，把公式（1）到公式（6）逐个拆开。

---

### User

按照CA-SCL的逻辑，译码部分应该怎么写verilog代码

---

### ChatGPT

CA-SCL 的 Verilog 实现不要从“CRC 模块”单独入手，而应把它拆成：
$\boxed{\text{SC递归计算}+\text{路径分裂}+\text{路径度量排序剪枝}+\text{逐路径CRC状态}}$
论文规定的 CA-SCL 流程是：初始化一条空路径；逐比特扩展候选路径；候选数超过 $L$ 时只保留度量最优的 $L$ 条；译完 $N$ 位后，按路径度量从优到劣检查 CRC，输出第一条通过 CRC 的路径，否则声明译码失败。CRC-Aided_Decoding_of_Polar_Cod…
下面代码用 SystemVerilog，因为二维数组、参数化路径列表更容易描述。纯 Verilog-2001 需要把数组端口展平。

1. 顶层硬件结构
Plain text                    ┌──────────────────┐channel LLR RAM ───►│ SC LLR计算核心   │                    │ f/g递归运算       │                    └────────┬─────────┘                             │ 每条路径当前bit的LLR                             ▼                    ┌──────────────────┐                    │ 路径扩展          │                    │ L条 → 最多2L条    │                    └────────┬─────────┘                             │ 候选PM、父路径、判决bit                             ▼                    ┌──────────────────┐                    │ 排序与剪枝        │                    │ 2L条 → L条        │                    └────────┬─────────┘                             ▼          ┌────────────────────────────────────┐          │ 路径状态更新                        │          │ partial sum / decoded bits / CRC   │          └─────────────────┬──────────────────┘                            │                       下一bit φ+1                            │                            ▼                    最终CRC选择
其中 CA-SCL 特有的部分主要是：


每条路径都维护自己的路径度量；


每条路径都维护自己的 CRC 状态；


剪枝后，新的路径必须继承对应父路径的全部状态；


最后不是直接选最优路径，而是选最优的 CRC 合法路径。



2. 每条路径需要保存的数据
对于列表大小 $L$，建议保存：
systemveriloglogic                  path_active [0:L-1];logic [PM_W-1:0]       path_pm     [0:L-1];logic [CRC_W-1:0]      path_crc    [0:L-1];// 已译码信息位，包含payload和CRClogic [K-1:0]          path_info   [0:L-1];// SC译码需要的部分和logic [N-1:0]          path_uhat   [0:L-1];// 实际工程中还需要每条路径的LLR中间存储或指针logic [PTR_W-1:0]      llr_ptr     [0:L-1];logic [PTR_W-1:0]      ps_ptr      [0:L-1];
直接保存：
systemveriloglogic [N-1:0] path_uhat [0:L-1];
适合先验证算法，但面积较大。
论文提到 SCL 可以通过 memory sharing 和 lazy copy 把空间复杂度降低至 $O(LN)$。CRC-Aided_Decoding_of_Polar_Cod…
因此正式设计更适合：


RAM 存储 LLR 和 partial sum；


路径只保存 RAM 地址指针；


路径分裂时先复制指针；


真正修改数据时再复制对应 RAM bank。



3. 路径度量怎么计算
论文使用的是 log-APP，数值越大表示路径越好。
硬件里通常改成“代价型路径度量”，数值越小越好：
$PM_l^{(i)}
=
PM_l^{(i-1)}
+
\ln\left(1+\exp\left[-(1-2\hat u_i)L_i\right]\right)$
其中 $L_i$ 是当前比特的 LLR。
为了降低硬件复杂度，常使用近似：
$PM_{\text{new}}=
\begin{cases}
PM_{\text{old}},&
\hat u_i=\operatorname{HD}(LLR_i)\\[4pt]
PM_{\text{old}}+|LLR_i|,&
\hat u_i\neq\operatorname{HD}(LLR_i)
\end{cases}$
其中：
Plain textLLR >= 0：硬判决为0LLR <  0：硬判决为1
这意味着：


选择 LLR 支持的比特：不增加惩罚；


选择与 LLR 相反的比特：增加 $|LLR|$。



4. 路径扩展与剪枝模块
下面这个模块完成 CA-SCL 最核心的操作：


输入 $L$ 条路径；


信息位时扩展成最多 $2L$ 条；


冻结位时每条路径只保留比特 0；


根据路径度量选出最好的 $L$ 条；


输出每条新路径的父路径编号和当前判决比特。


systemverilogmodule ca_scl_expand_prune #(    parameter int L       = 8,    parameter int LLR_W   = 8,    parameter int PM_W    = 20,    parameter int PATH_W  = (L <= 1) ? 1 : $clog2(L))(    input  logic                         is_frozen_i,    input  logic                         active_i [0:L-1],    input  logic signed [LLR_W-1:0]      llr_i    [0:L-1],    input  logic        [PM_W-1:0]       pm_i     [0:L-1],    output logic                         valid_o  [0:L-1],    output logic        [PATH_W-1:0]     parent_o [0:L-1],    output logic                         bit_o    [0:L-1],    output logic        [PM_W-1:0]       pm_o     [0:L-1]);    localparam int CAND_NUM = 2 * L;    logic                     cand_valid  [0:CAND_NUM-1];    logic [PATH_W-1:0]        cand_parent [0:CAND_NUM-1];    logic                     cand_bit    [0:CAND_NUM-1];    logic [PM_W-1:0]          cand_pm     [0:CAND_NUM-1];    logic                     tmp_valid   [0:CAND_NUM-1];    logic [PATH_W-1:0]        tmp_parent  [0:CAND_NUM-1];    logic                     tmp_bit     [0:CAND_NUM-1];    logic [PM_W-1:0]          tmp_pm      [0:CAND_NUM-1];    integer p;    integer c;    integer k;    integer best_idx;    logic [PM_W-1:0] best_pm;    /*     * LLR符号约定：     * LLR = log(P(u=0)/P(u=1))     * LLR >= 0：硬判决0     * LLR <  0：硬判决1     */    function automatic logic [LLR_W-1:0] abs_llr(        input logic signed [LLR_W-1:0] llr    );        begin            if (llr[LLR_W-1])                abs_llr = (~llr) + 1'b1;            else                abs_llr = llr;        end    endfunction    /*     * 采用近似路径度量：     * 与LLR硬判决一致：不加惩罚     * 与LLR硬判决相反：加|LLR|     */    function automatic logic [PM_W-1:0] update_pm(        input logic [PM_W-1:0]          old_pm,        input logic signed [LLR_W-1:0]  llr,        input logic                     decision    );        logic hard_decision;        logic [LLR_W-1:0] magnitude;        logic [PM_W:0] sum_ext;        begin            hard_decision = llr[LLR_W-1];            magnitude     = abs_llr(llr);            if (decision == hard_decision) begin                update_pm = old_pm;            end            else begin                sum_ext =                    {1'b0, old_pm}                    + {{(PM_W + 1 - LLR_W){1'b0}}, magnitude};                // 饱和处理，防止路径度量溢出                if (sum_ext[PM_W])                    update_pm = {PM_W{1'b1}};                else                    update_pm = sum_ext[PM_W-1:0];            end        end    endfunction    always_comb begin        /*-----------------------------------------         * 1. 生成最多2L条候选路径         *----------------------------------------*/        for (c = 0; c < CAND_NUM; c = c + 1) begin            cand_valid[c]  = 1'b0;            cand_parent[c] = '0;            cand_bit[c]    = 1'b0;            cand_pm[c]     = {PM_W{1'b1}};        end        for (p = 0; p < L; p = p + 1) begin            // bit = 0 分支            cand_valid[2*p]  = active_i[p];            cand_parent[2*p] = p[PATH_W-1:0];            cand_bit[2*p]    = 1'b0;            cand_pm[2*p]     = update_pm(                pm_i[p],                llr_i[p],                1'b0            );            // 信息位产生 bit = 1 分支            if (!is_frozen_i) begin                cand_valid[2*p+1]  = active_i[p];                cand_parent[2*p+1] = p[PATH_W-1:0];                cand_bit[2*p+1]    = 1'b1;                cand_pm[2*p+1]     = update_pm(                    pm_i[p],                    llr_i[p],                    1'b1                );            end        end        /*-----------------------------------------         * 2. 候选复制到临时数组         *----------------------------------------*/        for (c = 0; c < CAND_NUM; c = c + 1) begin            tmp_valid[c]  = cand_valid[c];            tmp_parent[c] = cand_parent[c];            tmp_bit[c]    = cand_bit[c];            tmp_pm[c]     = cand_pm[c];        end        /*-----------------------------------------         * 3. 默认输出         *----------------------------------------*/        for (k = 0; k < L; k = k + 1) begin            valid_o[k]  = 1'b0;            parent_o[k] = '0;            bit_o[k]    = 1'b0;            pm_o[k]     = {PM_W{1'b1}};        end        /*-----------------------------------------         * 4. 每次找最小PM，共选择L次         *         * 这是面积较大的组合选择排序，         * 适合功能验证和较小L。         * L=32时建议换成流水bitonic sorter         * 或多周期比较器。         *----------------------------------------*/        for (k = 0; k < L; k = k + 1) begin            best_idx = -1;            best_pm  = {PM_W{1'b1}};            for (c = 0; c < CAND_NUM; c = c + 1) begin                if (tmp_valid[c]) begin                    if ((best_idx == -1) ||                        (tmp_pm[c] < best_pm)) begin                        best_idx = c;                        best_pm  = tmp_pm[c];                    end                end            end            if (best_idx >= 0) begin                valid_o[k]  = 1'b1;                parent_o[k] = tmp_parent[best_idx];                bit_o[k]    = tmp_bit[best_idx];                pm_o[k]     = tmp_pm[best_idx];                tmp_valid[best_idx] = 1'b0;            end        end    endendmodule
这个模块输出的路径已经按：
$PM_0\le PM_1\le\cdots\le PM_{L-1}$
排列，即第 0 条路径最优。
论文中是 log-APP 越大越好；这里采用负对数代价，因此变成 PM 越小越好，两者逻辑等价。

5. CRC 单比特更新模块
CRC 可以在译码完整个候选以后再统一计算，但硬件更适合每条路径维护一个 CRC 状态。
每译出一个信息位，就执行一次 CRC 更新。
论文仿真使用的是 CRC-24：
$g(D)=D^{24}+D^{23}+D^6+D^5+D+1$
对应不包含最高次 $D^{24}$ 的 24 位多项式可以写为：
Plain text24'h800063
论文只给出了生成多项式，没有明确说明移位方向、初值、反射方式和最终异或方式，因此 RTL 必须与发送端 CRC 实现完全一致。论文中的多项式和 CRC 位拼接方式见这里。CRC-Aided_Decoding_of_Polar_Cod…
下面采用：


MSB first；


CRC 初值全 0；


无输入反射；


无最终异或；


输入完整的 $K=k+m$ 位后，余数为 0 表示通过。


systemverilogmodule crc_serial_msb #(    parameter int CRC_W = 24,    parameter logic [CRC_W-1:0] CRC_POLY = 24'h800063)(    input  logic [CRC_W-1:0] crc_i,    input  logic             data_bit_i,    output logic [CRC_W-1:0] crc_o);    logic feedback;    logic [CRC_W-1:0] shifted;    always_comb begin        feedback = crc_i[CRC_W-1] ^ data_bit_i;        shifted  = {crc_i[CRC_W-2:0], 1'b0};        if (feedback)            crc_o = shifted ^ CRC_POLY;        else            crc_o = shifted;    endendmodule
也可以把它写成顶层内部函数：
systemverilogfunction automatic logic [CRC_W-1:0] crc_next(    input logic [CRC_W-1:0] state,    input logic             data_bit);    logic feedback;    logic [CRC_W-1:0] shifted;    begin        feedback = state[CRC_W-1] ^ data_bit;        shifted  = {state[CRC_W-2:0], 1'b0};        if (feedback)            crc_next = shifted ^ CRC_POLY;        else            crc_next = shifted;    endendfunction

6. 剪枝后怎样继承父路径状态
这是 CA-SCL RTL 中最容易写错的部分。
假设剪枝模块输出：
Plain text新路径0来自旧路径3，当前判决bit=1新路径1来自旧路径0，当前判决bit=0新路径2来自旧路径3，当前判决bit=0
那么旧路径 3 被复制成了两条新路径。
因此不能直接在原数组上边读边覆盖，应该使用：


current bank；


next bank。


例如：
systemveriloginteger j;integer parent;always_comb begin    for (j = 0; j < L; j = j + 1) begin        next_active[j] = winner_valid[j];        next_pm[j]     = winner_pm[j];        next_crc[j]    = '0;        next_info[j]   = '0;        next_uhat[j]   = '0;        if (winner_valid[j]) begin            parent = winner_parent[j];            // 完整继承父路径            next_crc[j]  = curr_crc[parent];            next_info[j] = curr_info[parent];            next_uhat[j] = curr_uhat[parent];            // 保存当前译码比特            next_uhat[j][bit_index] = winner_bit[j];            // 只有信息位进入CRC和信息序列            if (!is_frozen) begin                next_info[j][info_index] = winner_bit[j];                next_crc[j] =                    crc_next(                        curr_crc[parent],                        winner_bit[j]                    );            end        end    endend
然后在时钟沿统一提交：
systemverilogalways_ff @(posedge clk or negedge rst_n) begin    if (!rst_n) begin        // 清零    end    else if (commit_en) begin        for (int j = 0; j < L; j++) begin            curr_active[j] <= next_active[j];            curr_pm[j]     <= next_pm[j];            curr_crc[j]    <= next_crc[j];            curr_info[j]   <= next_info[j];            curr_uhat[j]   <= next_uhat[j];        end    endend
实际设计中还要更新 SC 的部分和树：
systemverilognext_partial_sum[j]    = partial_sum_update(        curr_partial_sum[parent],        bit_index,        winner_bit[j]      );
partial_sum_update() 的具体写法取决于你采用：


全并行 SC；


半并行 SC；


line architecture；


tree architecture。



7. SC 的 LLR 递归模块
CA-SCL 并没有改变 Polar 码本身的 LLR 递推。
硬件中通常使用 min-sum 近似：
$f(a,b)
=
\operatorname{sign}(a)
\operatorname{sign}(b)
\min(|a|,|b|)$
$g(a,b,\hat u)
=
b+(1-2\hat u)a$
对应代码：
systemverilogmodule polar_f_node #(    parameter int W = 8)(    input  logic signed [W-1:0] a_i,    input  logic signed [W-1:0] b_i,    output logic signed [W-1:0] f_o);    logic sign_o;    logic [W-1:0] abs_a;    logic [W-1:0] abs_b;    logic [W-1:0] min_abs;    always_comb begin        abs_a = a_i[W-1] ? ((~a_i) + 1'b1) : a_i;        abs_b = b_i[W-1] ? ((~b_i) + 1'b1) : b_i;        sign_o = a_i[W-1] ^ b_i[W-1];        min_abs = (abs_a < abs_b) ? abs_a : abs_b;        if (sign_o)            f_o = -$signed(min_abs);        else            f_o = $signed(min_abs);    endendmodule
systemverilogmodule polar_g_node #(    parameter int W = 8)(    input  logic signed [W-1:0] a_i,    input  logic signed [W-1:0] b_i,    input  logic                partial_sum_i,    output logic signed [W:0]   g_o);    always_comb begin        if (partial_sum_i == 1'b0)            g_o = $signed(b_i) + $signed(a_i);        else            g_o = $signed(b_i) - $signed(a_i);    endendmodule
要注意 g 运算可能增加 1 位，后续需要：


饱和截断；


舍入；


或保留更宽的内部 LLR。



8. 顶层状态机
一个比较清晰的状态机可以写成：
systemverilogtypedef enum logic [3:0] {    S_IDLE,    S_INIT,    S_LLR_START,    S_LLR_WAIT,    S_EXPAND,    S_PRUNE,    S_COMMIT,    S_NEXT_BIT,    S_CRC_SELECT,    S_OUTPUT} state_t;
状态流程：
Plain textS_IDLE  │ start  ▼S_INIT  │ 初始化path 0  ▼S_LLR_START  │ 启动当前bit的SC LLR计算  ▼S_LLR_WAIT  │ llr_valid  ▼S_EXPAND  │ 生成最多2L候选  ▼S_PRUNE  │ 保留最佳L条  ▼S_COMMIT  │ 复制父路径、更新PM/CRC/partial sum  ▼S_NEXT_BIT  ├─ bit_index < N-1 ──► S_LLR_START  └─ bit_index = N-1 ──► S_CRC_SELECT                              │                              ▼                           S_OUTPUT
控制框架：
systemverilogalways_ff @(posedge clk or negedge rst_n) begin    if (!rst_n) begin        state      <= S_IDLE;        bit_index  <= '0;        info_index <= '0;        done_o     <= 1'b0;        fail_o     <= 1'b0;    end    else begin        done_o <= 1'b0;        case (state)            S_IDLE: begin                if (start_i)                    state <= S_INIT;            end            S_INIT: begin                bit_index  <= 0;                info_index <= 0;                state      <= S_LLR_START;            end            S_LLR_START: begin                // 启动所有活动路径当前bit的LLR计算                state <= S_LLR_WAIT;            end            S_LLR_WAIT: begin                if (all_path_llr_valid)                    state <= S_EXPAND;            end            S_EXPAND: begin                // expand/prune模块是组合逻辑时                state <= S_PRUNE;            end            S_PRUNE: begin                state <= S_COMMIT;            end            S_COMMIT: begin                // 提交next path bank                state <= S_NEXT_BIT;            end            S_NEXT_BIT: begin                if (!is_frozen)                    info_index <= info_index + 1'b1;                if (bit_index == N-1) begin                    state <= S_CRC_SELECT;                end                else begin                    bit_index <= bit_index + 1'b1;                    state     <= S_LLR_START;                end            end            S_CRC_SELECT: begin                state <= S_OUTPUT;            end            S_OUTPUT: begin                done_o <= 1'b1;                state  <= S_IDLE;            end            default: state <= S_IDLE;        endcase    endend

9. 最终 CRC 路径选择
论文要求按路径度量从优到劣检查，输出第一条通过 CRC 的路径；如果所有候选都不通过，则译码失败。CRC-Aided_Decoding_of_Polar_Cod…
由于前面的剪枝结果已经按 PM 从小到大排列，可以直接从路径 0 开始找：
systemveriloginteger s;integer selected_path;always_comb begin    selected_path = -1;    for (s = 0; s < L; s = s + 1) begin        if ((selected_path == -1) &&            curr_active[s] &&            (curr_crc[s] == {CRC_W{1'b0}})) begin            selected_path = s;        end    endend
输出 payload，不输出 CRC 位：
systemverilogalways_ff @(posedge clk or negedge rst_n) begin    if (!rst_n) begin        data_o <= '0;        fail_o <= 1'b0;    end    else if (state == S_CRC_SELECT) begin        if (selected_path >= 0) begin            data_o <= curr_info[selected_path][0:DATA_K-1];            fail_o <= 1'b0;        end        else begin            data_o <= '0;            fail_o <= 1'b1;        end    endend
这里假定：
systemveriloglocalparam int DATA_K = K - CRC_W;
而且信息序列排列方式为：
Plain textpayload bits + CRC bits
若编码端采用其他比特排列，需要相应调整。

10. 顶层核心伪代码
把整个 CA-SCL 压缩成 RTL 逻辑，就是：
systemverilog// 初始化active[0] = 1;pm[0]     = 0;crc[0]    = 0;for (phi = 0; phi < N; phi++) begin    // 1. 对每条活动路径计算当前bit的LLR    for (l = 0; l < L; l++)        llr[l] = sc_llr_calculate(l, phi);    // 2. 冻结位只扩展0，信息位扩展0和1    candidates = expand_paths(        active,        pm,        llr,        frozen_mask[phi]    );    // 3. 从最多2L条中保留最佳L条    winners = prune_best_L(candidates);    // 4. 根据parent index继承路径状态    for (l = 0; l < L; l++) begin        new_path[l] = old_path[winners[l].parent];        new_path[l].bit[phi] = winners[l].bit;        new_path[l].pm       = winners[l].pm;        // 信息位才更新CRC        if (!frozen_mask[phi])            new_path[l].crc =                crc_next(                    old_path[winners[l].parent].crc,                    winners[l].bit                );    endend// 最终从PM最小到最大寻找CRC通过路径for (l = 0; l < L; l++) begin    if (crc[l] == 0) begin        output_path = l;        break;    endend

11. 真正做 FPGA 时的几个关键点
排序器
当 $L=32$ 时，每个信息位最多有 64 条候选路径。
前面代码使用组合选择排序，面积和时序压力都很大。工程上更常用：


bitonic sorting network；


radix-$2L$ partial sorter；


双调流水排序；


多周期最小值查找；


threshold-based pruning。


如果追求吞吐率，使用流水 bitonic sorter；如果追求面积，使用多周期比较器。
路径复制
不能每次路径分裂都复制整块 LLR RAM。
正式版本使用：
Plain textpath pointerreference countlazy copyfree bank list
新路径首先只复制父路径指针，当某一路径需要修改共享存储时再分配新 bank。
CRC 更新时间
CRC 只对信息集合 $\mathcal A$ 中的比特更新：
systemverilogif (!is_frozen)    crc_next(...);
冻结位不能送入 CRC。
路径度量归一化
长码译码时 PM 会不断增大。每完成一个信息位，可以执行：
$PM_l\leftarrow PM_l-\min_j PM_j$
这样最优路径重新变为 0，避免定点溢出，而且不会改变路径排序。
同一路径产生两个子路径
当两个获胜路径来自同一个父路径时，必须让它们分别继承父路径原始状态，不能让第二条子路径继承第一条子路径已经修改后的状态。因此需要双缓冲或 lazy copy。

12. 推荐的工程文件划分
Plain textca_scl_decoder_top.sv├── polar_sc_controller.sv├── polar_llr_memory.sv├── polar_partial_sum_memory.sv├── polar_f_node.sv├── polar_g_node.sv├── path_metric_unit.sv├── path_expand_unit.sv├── path_pruner.sv├── path_memory_manager.sv├── crc_serial_msb.sv├── frozen_bit_rom.sv└── output_selector.sv
其中 CA-SCL 相比普通 SCL 新增或修改的重点是：
Plain textpath_crc[L]crc_next()CRC合法路径选择
而不是重新设计一套 SC 的 $f/g$ 递归运算。
要把代码进一步整理成可以仿真的完整工程，还需要固定这几个参数：码长 $N$、信息长度 $K$、列表大小 $L$、LLR 位宽、路径度量位宽、CRC 位序，以及你打算采用全并行还是半并行 SC 架构。

---

### User

那你总结下论文内容吧

---

### ChatGPT

这篇论文的核心可以概括为：

在 Polar 码的 SCL/SCS 译码器后加入 CRC 校验，用 CRC 从多个候选路径中选出正确码字，从而显著改善有限码长下的译码性能。

1. 研究背景
Polar 码在理论上能够达到二进制输入离散无记忆信道的对称容量，但在有限码长条件下，传统串行抵消译码（SC）的性能并不理想。主要原因是 SC 逐比特进行贪心判决，一旦某个比特判错，后续无法回退修正，容易产生错误传播。CRC-Aided_Decoding_of_Polar_Cod…
为了改善 SC，已有研究提出了：


SCL：串行抵消列表译码


SCS：串行抵消栈译码


它们通过保留多条候选路径，降低正确路径被过早删除的概率。

2. 论文的主要贡献
论文提出两种 CRC 辅助译码算法：
$\text{CA-SCL}$
即 CRC-Aided Successive Cancellation List Decoding；
以及：
$\text{CA-SCS}$
即 CRC-Aided Successive Cancellation Stack Decoding。
其基本思路是：


发送端将 $m$ 位 CRC 附加到 $k$ 位原始信息后；


得到总长度为


$K=k+m$
的信息序列；


将这 $K$ 位一起送入 Polar 编码器；


接收端的 SCL 或 SCS 译码器产生多个完整候选序列；


利用 CRC 检查结果选择最终输出码字。CRC-Aided_Decoding_of_Polar_Cod…


因此，CRC 在本文中不仅用于传统的错误检测或重传判断，而是直接参与候选码字选择。

3. SC、SCL 和 SCS 的统一解释
论文使用一棵深度为 $N$ 的码树描述译码过程。
每一层对应一个待译码比特，每一条从根节点到叶节点的路径对应一个长度为 $N$ 的候选序列。
论文利用后验概率 APP 及其对数形式作为路径度量，用于评价不同候选路径的可靠性。CRC-Aided_Decoding_of_Polar_Cod…
SC 译码
SC 每一层只保留一条路径，相当于在码树中进行贪心搜索。


冻结位直接判为固定值，通常是 0；


信息位选择当前后验概率较大的分支。


其复杂度较低，为：
$O(N\log N)$
但一旦早期判错，之后没有修正机会。CRC-Aided_Decoding_of_Polar_Cod…
SCL 译码
SCL 在每个信息位处，将当前每条候选路径分别扩展为 0、1 两个分支。
若扩展后路径数超过列表大小 $L$，就只保留路径度量最优的 $L$ 条。
通过 lazy copy 和存储共享技术，SCL 的时间和空间复杂度可以分别降低为：
$O(LN\log N)$
和
$O(LN)$
CRC-Aided_Decoding_of_Polar_Cod…
SCS 译码
SCS 使用按路径度量排序的栈保存候选路径。
每次从栈顶取出当前最可靠的路径继续扩展。当一条路径到达长度 $N$ 时，普通 SCS 就输出该路径。
与 SCL 不同：


SCL 中候选路径通常长度相同；


SCS 栈中的路径长度可以不同；


SCS 属于串行的最佳优先搜索。CRC-Aided_Decoding_of_Polar_Cod…



4. CA-SCL 算法
CA-SCL 的流程包括四个步骤。
初始化
列表中只有一条空路径，其路径度量设为 0：
$\mathcal L^{(0)}=\{\varnothing\}$
路径扩展
译码到第 $i$ 位时，每条候选路径分别连接比特 0 和 1，形成新的候选路径。
实际执行时：


冻结位只允许固定分支；


信息位才扩展为两个分支。


竞争与剪枝
若候选路径数超过列表大小 $L$，仅保留路径度量最优的 $L$ 条。
CRC 辅助选择
当所有路径都扩展到长度 $N$ 后，按照路径度量从优到劣依次进行 CRC 检查：


输出第一条通过 CRC 的路径；


如果 $L$ 条路径都未通过 CRC，则宣布译码失败。CRC-Aided_Decoding_of_Polar_Cod…


普通 SCL 最终直接选择路径度量最优的路径，而 CA-SCL 选择的是：
$\text{路径度量较优且 CRC 合法的路径}$
因此，即使正确码字不是列表中的第一名，只要仍然保留在列表中，就可能被 CRC 找出来。

5. CA-SCS 算法
CA-SCS 在普通 SCS 基础上加入 CRC 检查，并引入两个主要参数：
$Q$
和
$D$
其中：


$D$：栈的最大深度；


$Q$：对特定路径长度允许弹出的最大路径数量，也限制最多尝试的完整候选路径数。


CA-SCS 的基本过程是：


将空路径压入栈；


弹出当前路径度量最大的路径；


根据冻结位或信息位进行路径扩展；


对栈中路径重新排序；


当栈顶路径达到长度 $N$ 时，对其进行 CRC 检查；


若通过 CRC，立即输出；


若不通过，则继续搜索下一条完整路径；


当已检查 $Q$ 条完整路径或栈为空时，宣布失败。CRC-Aided_Decoding_of_Polar_Cod…


普通 SCS 找到第一条完整路径就停止，而 CA-SCS 在第一条完整路径 CRC 不通过时，还会继续搜索。

6. CA-SCL 与 CA-SCS 的区别
论文将两者的主要区别总结为：
对比项CA-SCLCA-SCS路径扩展多条路径并行扩展按栈顶路径串行扩展候选状态候选路径长度相同候选路径长度可能不同时间复杂度固定随信道条件变化空间复杂度$O(LN)$$O(DN)$高信噪比特点仍执行完整列表译码可较快找到正确路径
当：
$Q=L$
时，CA-SCL 和 CA-SCS 的译码性能基本相同，但 CA-SCS 的时间复杂度具有可变性，高信噪比下通常更低。CRC-Aided_Decoding_of_Polar_Cod…

7. 仿真设置
论文在二进制输入加性白高斯噪声信道 BI-AWGNC 上进行了仿真。
主要参数为：
$N=1024$
$R=\frac{1}{2}$
对比对象包括：


SC；


SCL；


SCS；


CA-SCL；


CA-SCS；


3GPP 标准中的 8 状态 Turbo 码。


所有方案均采用 CRC-24，其生成多项式为：
$g(D)=D^{24}+D^{23}+D^6+D^5+D+1$
原始信息位和 CRC 位均作为纠错编码器的输入，论文将码率统一定义为：
$R=\frac{K}{N}$
CRC-Aided_Decoding_of_Polar_Cod…

8. 性能结果
论文图 3 比较了各种方案的 BLER 性能。
主要结论如下。
SCL 和 SCS 明显优于 SC
SCL 和 SCS 的性能基本相同，并且都远好于传统 SC。
但是，在不使用 CRC 辅助选择时，SCL/SCS 在：
$\mathrm{BLER}=10^{-4}$
处仍比论文中的 Turbo 码基准差约：
$0.7\ \mathrm{dB}$
CA-SCL 和 CA-SCS 显著提升性能
当列表大小或路径搜索数量足够大时，CA-SCL/SCS 可以超过 Turbo 码。
例如：
$\text{CA-SCL}(32)$
和：
$\text{CA-SCS}(32,1000)$
在：
$\mathrm{BLER}=10^{-4}$
处相对于 Turbo 码获得约：
$0.5\ \mathrm{dB}$
的增益。
仿真至：
$\mathrm{BLER}=10^{-6}$
时，论文没有观察到明显的错误平台。CRC-Aided_Decoding_of_Polar_Cod…
这里：


CA-SCL(32) 表示 $L=32$；


CA-SCS(32,1000) 表示 $Q=32,\ D=1000$。



9. 复杂度结果
论文以路径度量递归运算次数衡量平均计算复杂度。
SC 译码器的复杂度约为：
$N\log_2N
=
1024\times10
\approx10^4$
Turbo 码每次 Log-MAP 迭代约需：
$2\times(8\times4)\times\frac{N}{2}
\approx3\times10^4$
次度量操作。CRC-Aided_Decoding_of_Polar_Cod…
复杂度对比表明：


SC 复杂度最低，但误码性能最差；


CA-SCL 的复杂度基本固定；


CA-SCS 的复杂度随信噪比变化；


高信噪比时，CA-SCS 可以快速找到通过 CRC 的路径，因此平均复杂度明显下降；


CA-SCS 的复杂度甚至可以接近 SC，并低于 Turbo 译码器。


论文给出的结果是：


CA-SCS，$Q=16$ 时，复杂度低于 Turbo 译码，性能增益约 0.4 dB；


CA-SCS，$Q=32$ 时，复杂度与 Turbo 译码接近，性能增益约 0.5 dB。CRC-Aided_Decoding_of_Polar_Cod…



10. 论文最终结论
论文证明了 CRC 不仅可以用于检错，也可以作为列表或栈译码中的候选路径筛选工具。
CA-SCL 和 CA-SCS 的优势是：


提升 Polar 码有限码长下的译码性能；


当列表或搜索规模足够大时，可以超过文中采用的 Turbo 码基准；


CA-SCS 具有可变复杂度；


高信噪比下，CA-SCS 的平均复杂度可以显著降低；


CRC 辅助路径选择使 Polar 码成为实际通信系统中更有竞争力的方案。CRC-Aided_Decoding_of_Polar_Cod…


一句话评价
这篇论文最重要的价值不是发明了 SCL，而是明确提出并验证了：
$\boxed{\text{Polar码}+\text{列表/栈搜索}+\text{CRC候选筛选}}$
这一组合。
后来的 Polar 码工程应用中，尤其是列表译码方案，基本都沿用了这种思想。

