# Verilog SC 译码器需求

*导出时间: 2026/8/12 16:44:51*

---

### User

我现在要把我的SC译码升级成SCL译码，你先简要阐述这俩的差异，然后需要我提供哪些代码，你可以帮我升级

---

### ChatGPT

SC 和 SCL 都常用于 Polar 码译码，核心区别如下。
SC 与 SCL 的差异
SC（Successive Cancellation，串行抵消译码）


从第 1 个比特开始依次判决；


每个信息位只保留一个判决结果；


前面一旦判错，错误可能向后传播；


复杂度和存储开销较低，约为
$O(N\log N)$


中短码长下性能通常不够理想。


SCL（Successive Cancellation List，串行抵消列表译码）


冻结位仍然固定判为 0；


遇到信息位时，同时保留“判 0”和“判 1”两种可能；


候选路径数量超过列表大小 $L$ 后，根据路径度量值 Path Metric，只保留最优的 $L$ 条路径；


最后从候选路径中选择度量最优的结果；


如果结合 CRC，即 CA-SCL，可以优先选择通过 CRC 校验的路径，性能会明显优于普通 SC；


复杂度约为
$O(LN\log N)$
存储量也大约增加到 SC 的 $L$ 倍。


例如列表大小 $L=8$，译码过程中最多同时维护 8 条候选路径。

为了帮你从 SC 升级到 SCL，需要提供的代码
最重要的是下面几部分。
1. SC 译码主函数
例如：
MATLABu_hat = SC_decoder(llr, frozen_bits, N)
或者 C/C++ 中类似：
C++vector<int> sc_decode(    const vector<double>& llr,    const vector<int>& frozen_set);
需要看到：


比特是如何逐个判决的；


冻结位是如何识别的；


最终是输出 u_hat，还是已经完成了重编码或信息位提取。


2. LLR 递归更新函数
通常包括 $f$ 和 $g$ 函数：
$f(a,b)=2\tanh^{-1}\left(\tanh(a/2)\tanh(b/2)\right)$
常用近似形式：
$f(a,b)\approx \operatorname{sign}(a)\operatorname{sign}(b)
\min(|a|,|b|)$
以及：
$g(a,b,\hat{u})=b+(1-2\hat{u})a$
请提供代码中对应的函数，例如：
MATLABfunction y = f_func(a, b)function y = g_func(a, b, u)
3. 部分和更新代码
也就是已经译出的比特如何向上回传，例如：
MATLABbeta_leftbeta_rightpartial_sum
SCL 中每条路径都需要有自己独立的部分和，因此这一部分是升级时的重点。
4. Polar 码参数和冻结位定义
需要提供：


码长 $N$；


信息位数 $K$；


码率；


冻结位集合或可靠性序列；


是否使用 CRC；


CRC 长度和生成多项式；


输入 LLR 的正负定义。


尤其需要确认你代码中的 LLR 约定是：
$LLR=\ln\frac{P(y|x=0)}{P(y|x=1)}$
此时通常：
MATLABLLR >= 0  判为0LLR < 0   判为1
有些代码正好相反，必须根据原代码确定。
5. 编码端代码
至少提供：


信息位放置方式；


CRC 是否在 Polar 编码前添加；


Polar 编码函数；


是否存在比特反转、交织、速率匹配、打孔或缩短。


SCL 输出的是完整的 $\hat{u}$，最终信息位提取顺序必须和编码端一致。
6. 仿真或调用代码
包括：


调制方式，如 BPSK；


噪声添加；


接收端 LLR 计算；


SC 译码函数的调用位置；


BER、BLER 统计方法。


这样升级后可以直接比较：
Plain textSCSCL-L2SCL-L4SCL-L8CA-SCL-L8

最小需要发送的代码
代码较多时，至少先发下面四部分：
Plain text1. SC译码主函数2. f函数和g函数3. 部分和更新函数4. SC译码的调用代码及N、K、冻结位定义
同时说明：
Plain text编程语言：MATLAB / C / C++ / Python列表大小：例如 L=4、8或16是否使用CRC：是 / 否目标：普通SCL还是CRC辅助CA-SCLLLR输入格式：浮点LLR还是硬判决数据
升级后的核心结构大致会变成：
Plain text初始化一条空路径        ↓依次译码第 i 位        ↓冻结位：所有路径都扩展为 ui=0信息位：每条路径分别扩展为 ui=0 和 ui=1        ↓更新每条路径的 Path Metric        ↓候选超过 L 条时，只保留最优 L 条        ↓更新每条路径的部分和与后续 LLR        ↓译完全部比特        ↓普通SCL：选择 Path Metric 最优路径CA-SCL：优先选择通过 CRC 的最优路径
你可以直接把当前的 SC 译码函数和调用部分完整贴出来。我会尽量保留你的原有变量、接口和仿真框架，在此基础上改成可配置列表大小 $L$ 的 SCL，并标明新增或修改的位置。

---

### User

要哪些，编程语言verilog

---

### ChatGPT

从你这套 Verilog SC 译码器结构看，建议先把这 8 个文件都提供，因为升级到 SCL 不只是改判决逻辑，还涉及 LLR、部分和、路径存储和控制状态机的整体复制与调度。
优先级如下：
第一批：必须提供


sc_decoder_core.v
顶层核心，先看模块连接、输入输出、译码启动与完成接口。


controller.v
SCL 的路径扩展、排序剪枝、路径复制都会进入控制状态机，这是改动最大的模块之一。


sc_datapath.v
用于判断当前 SC 数据通路如何组织，哪些资源能复用，哪些需要扩展为多路径。


sc_pe.v
查看 $f$、$g$ 运算、叶节点硬判决以及数据位宽。PE 本身通常可以复用，但要确认接口和时序。


sc_llr_mem.v
SCL 中每条路径都需要独立的 LLR 状态，或者采用共享内存加路径映射，因此必须分析该模块。


sc_beta_mem.v
Beta/partial sum 必须按路径保存，是 SCL 升级的核心模块。


sc_uhat_mem.v
每条候选路径需要保存各自的 $\hat u$，最后从最优路径输出。


第二批：用于验证


sc_test_sequencer.v
需要确认它是真正的 testbench、测试控制模块，还是片上测试序列发生器。升级后要据此验证 SCL 结果。



最好再一起提供的内容
除了这 8 个 .v 文件，还需要：


所有 include 的 .vh 文件；


参数定义文件；


顶层 testbench；


仿真输入数据文件，如 .mem、.txt、.hex；


冻结位表或可靠性序列；


当前 SC 的仿真波形或正确输出样例；


综合工具和目标器件，例如 Vivado、Quartus；


码参数，例如：
Plain textN = ?K = ?LLR 位宽 = ?列表大小 L = 2/4/8/16？是否加入 CRC？是否要求全流水、半并行或优先节省资源？


上传顺序建议
可以先上传这四个：
Plain textsc_decoder_core.vcontroller.vsc_datapath.vsc_pe.v
我先还原当前 SC 的架构、译码流程和时序。
然后再上传：
Plain textsc_llr_mem.vsc_beta_mem.vsc_uhat_mem.vsc_test_sequencer.v
这样可以继续设计 SCL 的：


路径管理单元；


Path Metric 更新单元；


$2L \rightarrow L$ 排序剪枝单元；


LLR/部分和/译码比特的多路径存储；


路径复制和懒复制机制；


最优路径输出；


可选 CRC 辅助选择。


建议第一版先实现 普通 SCL，列表大小 $L=4$，保持现有 PE 计算结构，采用时分复用，先保证功能正确。直接把上述 8 个 Verilog 文件全部上传最稳妥。

---

### User

module sc_controller #(
    parameter integer NMAX      = 1024,
    parameter integer MAX_LOG   = 10,
    parameter integer ADDR_W    = 11,
    parameter integer INDEX_W   = 11
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // =========================================================================
    // 译码任务控制
    // =========================================================================

    // 空闲时拉高一个周期，启动SC树译码。
    //
    // 推荐直接连接sc_datapath的load_done。
    input  wire                         decode_start,

    // 当前码长log2。
    //
    // 正式支持：
    //   6、7、8、9、10
    //
    // 同时允许1～5用于小规模回归测试。
    input  wire [3:0]                   n_log,

    // 冻结位掩码。
    //
    // frozen_bits[i] = 1：u[i]为冻结位，判决固定为0
    // frozen_bits[i] = 0：u[i]为信息位，根据LLR符号判决
    input  wire [NMAX-1:0]              frozen_bits,

    // 控制器正在执行译码或等待u_hat输出
    output reg                          decode_busy,

    // 完整u_hat输出结束后的单周期脉冲
    output reg                          decode_done,

    // =========================================================================
    // sc_datapath：LLR读取与PE控制
    // =========================================================================

    output reg  [ADDR_W-1:0]            llr_rd_addr_a,
    output reg  [ADDR_W-1:0]            llr_rd_addr_b,

    // 0：f运算
    // 1：g运算
    output reg                          pe_mode_g,

    output reg                          llr_wr_en,
    output reg  [ADDR_W-1:0]            llr_wr_addr,

    // =========================================================================
    // sc_datapath：beta读取与写回控制
    // =========================================================================

    output reg  [ADDR_W-1:0]            beta_rd_addr_a,
    output reg  [ADDR_W-1:0]            beta_rd_addr_b,

    output reg                          beta_wr_en,
    output reg  [ADDR_W-1:0]            beta_wr_addr,

    // beta_wr_mode=00时使用。
    // 本控制器当前不需要直接写常量beta，保持为0。
    output reg                          beta_wr_data,

    // 00：beta_wr_data
    // 01：beta_rd_data_a XOR beta_rd_data_b
    // 10：beta_rd_data_a
    // 11：beta_rd_data_b
    output reg  [1:0]                   beta_wr_mode,

    // =========================================================================
    // sc_datapath：叶节点判决控制
    // =========================================================================

    output reg                          leaf_decision_en,
    output reg                          leaf_frozen,
    output reg  [INDEX_W-1:0]           leaf_index,
    output reg  [ADDR_W-1:0]            leaf_beta_wr_addr,

    // =========================================================================
    // sc_uhat_mem输出控制
    // =========================================================================

    // 根beta合并完成后拉高一个周期
    output reg                          output_start,

    // 来自sc_datapath/sc_uhat_mem。
    // 最后一个u_hat完成valid/ready握手后拉高一个周期。
    input  wire                         output_done
);

    // =========================================================================
    // 每层递归阶段
    // =========================================================================

    localparam [1:0] PH_F = 2'b00;
    localparam [1:0] PH_G = 2'b01;
    localparam [1:0] PH_C = 2'b10;

    // =========================================================================
    // 顶层控制状态
    // =========================================================================

    localparam [1:0] ST_IDLE         = 2'b00;
    localparam [1:0] ST_DECODE       = 2'b01;
    localparam [1:0] ST_OUTPUT_START = 2'b10;
    localparam [1:0] ST_OUTPUT_WAIT  = 2'b11;

    reg [1:0] state;

    // =========================================================================
    // DFS控制寄存器
    // =========================================================================

    // 当前深度：
    //
    //   0       = 根节点
    //   n_log   = 叶节点
    reg [3:0] cur_depth;

    // 当前f/g/beta合并的元素序号。
    //
    // 最大根节点half=512，因此INDEX_W=11足够。
    reg [INDEX_W-1:0] element_index;

    // 当前即将判决的自然叶节点索引phi。
    reg [INDEX_W-1:0] current_leaf;

    // 每一深度当前递归阶段。
    //
    // phase[0]       对应根节点
    // phase[n_log-1] 对应长度2的内部节点
    // phase[n_log]   实际为叶节点，不使用phase值
    reg [1:0] phase [0:MAX_LOG];

    // beta合并子阶段：
    //
    // 0：写 parent[k]      = left XOR right
    // 1：写 parent[k+half] = right
    reg merge_second_write;

    integer reset_i;

    // =========================================================================
    // 组合几何量
    // =========================================================================

    integer current_node_len;
    integer current_half;

    integer parent_base_int;
    integer child_base_int;
    integer leaf_base_int;

    integer parent_addr_a_int;
    integer parent_addr_b_int;
    integer child_addr_int;

    integer beta_parent_low_int;
    integer beta_parent_high_int;
    integer beta_child_int;

    // =========================================================================
    // 深度工作区基地址函数
    // =========================================================================
    //
    // depth=0：
    //      base=0
    //
    // depth>=1：
    //      base=2*NMAX-(NMAX>>(depth-1))
    //
    // NMAX=1024时：
    //      0,1024,1536,1792,...,2046
    // =========================================================================

    function [ADDR_W-1:0] depth_base;
        input integer depth_value;
        integer base_value;
        begin
            if (depth_value <= 0) begin
                base_value = 0;
            end else begin
                base_value =
                    (2 * NMAX) -
                    (NMAX >> (depth_value - 1));
            end

            depth_base = base_value[ADDR_W-1:0];
        end
    endfunction

    // =========================================================================
    // 当前节点几何关系
    // =========================================================================
    //
    // 当前深度cur_depth对应的实际节点长度：
    //
    //      current_node_len = 2^(n_log-cur_depth)
    //
    // 内部节点：
    //
    //      current_half = current_node_len/2
    //
    // 例如N=64：
    //
    //      depth0：len=64，half=32
    //      depth1：len=32，half=16
    //      ...
    //      depth5：len=2，half=1
    //      depth6：len=1，叶节点
    // =========================================================================

    always @* begin
        current_node_len = 1;
        current_half     = 0;

        if (cur_depth <= n_log) begin
            current_node_len = 1 << (n_log - cur_depth);

            if (cur_depth < n_log) begin
                current_half = 1 << (n_log - cur_depth - 1);
            end
        end

        parent_base_int = depth_base(cur_depth);

        if (cur_depth < MAX_LOG) begin
            child_base_int = depth_base(cur_depth + 1);
        end else begin
            child_base_int = depth_base(MAX_LOG);
        end

        leaf_base_int = depth_base(n_log);

        parent_addr_a_int =
            parent_base_int + element_index;

        parent_addr_b_int =
            parent_base_int +
            current_half +
            element_index;

        child_addr_int =
            child_base_int +
            element_index;

        beta_parent_low_int =
            parent_base_int +
            element_index;

        beta_parent_high_int =
            parent_base_int +
            current_half +
            element_index;

        beta_child_int =
            child_base_int +
            element_index;
    end

    // =========================================================================
    // sc_datapath控制信号组合逻辑
    // =========================================================================

    always @* begin
        // ---------------------------------------------------------------------
        // 默认值
        // ---------------------------------------------------------------------

        llr_rd_addr_a      = {ADDR_W{1'b0}};
        llr_rd_addr_b      = {ADDR_W{1'b0}};

        pe_mode_g          = 1'b0;

        llr_wr_en          = 1'b0;
        llr_wr_addr        = {ADDR_W{1'b0}};

        beta_rd_addr_a     = {ADDR_W{1'b0}};
        beta_rd_addr_b     = {ADDR_W{1'b0}};

        beta_wr_en         = 1'b0;
        beta_wr_addr       = {ADDR_W{1'b0}};
        beta_wr_data       = 1'b0;
        beta_wr_mode       = 2'b00;

        leaf_decision_en   = 1'b0;
        leaf_frozen        = 1'b0;
        leaf_index         = current_leaf;
        leaf_beta_wr_addr  = leaf_base_int[ADDR_W-1:0];

        output_start       = 1'b0;

        // ---------------------------------------------------------------------
        // SC译码运行
        // ---------------------------------------------------------------------

        if (state == ST_DECODE) begin

            // ================================================================
            // 叶节点
            // ================================================================
            //
            // 叶节点LLR始终位于当前深度工作区的第0个位置。
            //
            // sc_datapath根据：
            //
            //      leaf_frozen
            //      llr_rd_data_a符号位
            //
            // 产生判决，并同时写入：
            //
            //      beta_mem[leaf_beta_wr_addr]
            //      uhat_mem[current_leaf]
            // ================================================================

            if (cur_depth == n_log) begin
                llr_rd_addr_a =
                    leaf_base_int[ADDR_W-1:0];

                llr_rd_addr_b =
                    leaf_base_int[ADDR_W-1:0];

                leaf_decision_en =
                    1'b1;

                leaf_index =
                    current_leaf;

                leaf_beta_wr_addr =
                    leaf_base_int[ADDR_W-1:0];

                if (current_leaf < NMAX) begin
                    leaf_frozen =
                        frozen_bits[current_leaf];
                end else begin
                    leaf_frozen =
                        1'b1;
                end
            end else begin

                // ============================================================
                // 内部节点PH_F：生成左子节点LLR
                // ============================================================
                //
                // child[k] =
                //     f(parent[k], parent[k+half])
                // ============================================================

                if (phase[cur_depth] == PH_F) begin
                    llr_rd_addr_a =
                        parent_addr_a_int[ADDR_W-1:0];

                    llr_rd_addr_b =
                        parent_addr_b_int[ADDR_W-1:0];

                    pe_mode_g =
                        1'b0;

                    llr_wr_en =
                        1'b1;

                    llr_wr_addr =
                        child_addr_int[ADDR_W-1:0];
                end

                // ============================================================
                // 内部节点PH_G：生成右子节点LLR
                // ============================================================
                //
                // child[k] =
                //     g(parent[k],
                //       parent[k+half],
                //       beta_left[k])
                //
                // 同周期还要把beta_left[k]复制到父节点低半区：
                //
                //     parent_beta[k] = beta_left[k]
                //
                // 这一步用于保存左子树beta，因为child工作区即将被右子树覆盖。
                // ============================================================

                else if (phase[cur_depth] == PH_G) begin
                    llr_rd_addr_a =
                        parent_addr_a_int[ADDR_W-1:0];

                    llr_rd_addr_b =
                        parent_addr_b_int[ADDR_W-1:0];

                    pe_mode_g =
                        1'b1;

                    llr_wr_en =
                        1'b1;

                    llr_wr_addr =
                        child_addr_int[ADDR_W-1:0];

                    // beta_rd_data_a同时作为：
                    //
                    // 1. sc_pe执行g运算的beta输入；
                    // 2. 保存到父节点低半区的beta_left。
                    beta_rd_addr_a =
                        beta_child_int[ADDR_W-1:0];

                    beta_rd_addr_b =
                        beta_child_int[ADDR_W-1:0];

                    beta_wr_en =
                        1'b1;

                    beta_wr_addr =
                        beta_parent_low_int[ADDR_W-1:0];

                    // 直接写beta_rd_data_a
                    beta_wr_mode =
                        2'b10;
                end

                // ============================================================
                // 内部节点PH_C：beta合并
                // ============================================================
                //
                // child工作区当前保存beta_right。
                //
                // 父节点低半区当前保存beta_left。
                //
                // 第一个周期：
                //
                //     parent[k] =
                //         beta_left[k] XOR beta_right[k]
                //
                // 第二个周期：
                //
                //     parent[k+half] =
                //         beta_right[k]
                // ============================================================

                else begin
                    if (!merge_second_write) begin
                        // -----------------------------------------------------
                        // 第1周期：parent低半 = left XOR right
                        // -----------------------------------------------------

                        beta_rd_addr_a =
                            beta_parent_low_int[ADDR_W-1:0];

                        beta_rd_addr_b =
                            beta_child_int[ADDR_W-1:0];

                        beta_wr_en =
                            1'b1;

                        beta_wr_addr =
                            beta_parent_low_int[ADDR_W-1:0];

                        beta_wr_mode =
                            2'b01;
                    end else begin
                        // -----------------------------------------------------
                        // 第2周期：parent高半 = right
                        // -----------------------------------------------------

                        beta_rd_addr_a =
                            beta_child_int[ADDR_W-1:0];

                        beta_rd_addr_b =
                            beta_child_int[ADDR_W-1:0];

                        beta_wr_en =
                            1'b1;

                        beta_wr_addr =
                            beta_parent_high_int[ADDR_W-1:0];

                        beta_wr_mode =
                            2'b10;
                    end
                end
            end
        end

        // ---------------------------------------------------------------------
        // 启动sc_uhat_mem输出
        // ---------------------------------------------------------------------

        if (state == ST_OUTPUT_START) begin
            output_start = 1'b1;
        end
    end

    // =========================================================================
    // 主时序控制
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            decode_busy        <= 1'b0;
            decode_done        <= 1'b0;

            cur_depth          <= 4'd0;
            element_index      <= {INDEX_W{1'b0}};
            current_leaf       <= {INDEX_W{1'b0}};
            merge_second_write <= 1'b0;

            for (reset_i = 0;
                 reset_i <= MAX_LOG;
                 reset_i = reset_i + 1) begin
                phase[reset_i] <= PH_F;
            end
        end else begin
            // decode_done默认只保持一个周期
            decode_done <= 1'b0;

            case (state)

                // =============================================================
                // 空闲
                // =============================================================

                ST_IDLE: begin
                    decode_busy        <= 1'b0;
                    cur_depth          <= 4'd0;
                    element_index      <= {INDEX_W{1'b0}};
                    current_leaf       <= {INDEX_W{1'b0}};
                    merge_second_write <= 1'b0;

                    if (decode_start &&
                        (n_log >= 1) &&
                        (n_log <= MAX_LOG)) begin

                        decode_busy        <= 1'b1;
                        cur_depth          <= 4'd0;
                        element_index      <= {INDEX_W{1'b0}};
                        current_leaf       <= {INDEX_W{1'b0}};
                        merge_second_write <= 1'b0;

                        for (reset_i = 0;
                             reset_i <= MAX_LOG;
                             reset_i = reset_i + 1) begin
                            phase[reset_i] <= PH_F;
                        end

                        state <= ST_DECODE;
                    end
                end

                // =============================================================
                // SC树译码
                // =============================================================

                ST_DECODE: begin
                    decode_busy <= 1'b1;

                    // ---------------------------------------------------------
                    // 叶节点判决
                    // ---------------------------------------------------------
                    //
                    // 本周期组合逻辑已经拉高leaf_decision_en。
                    // 在当前上升沿：
                    //
                    //   1. sc_datapath写入叶beta；
                    //   2. sc_uhat_mem写入u_hat[current_leaf]；
                    //   3. 控制器返回叶节点父层。
                    // ---------------------------------------------------------

                    if (cur_depth == n_log) begin
                        current_leaf       <= current_leaf + 1'b1;
                        element_index      <= {INDEX_W{1'b0}};
                        merge_second_write <= 1'b0;

                        if (cur_depth != 0) begin
                            cur_depth <= cur_depth - 1'b1;
                        end
                    end else begin

                        // -----------------------------------------------------
                        // PH_F：左子节点LLR生成
                        // -----------------------------------------------------

                        if (phase[cur_depth] == PH_F) begin
                            if (element_index ==
                                (current_half - 1)) begin

                                // 当前节点左alpha全部生成完毕。
                                //
                                // 父层下一阶段设为PH_G。
                                // 子层从PH_F开始。
                                phase[cur_depth] <= PH_G;

                                if (cur_depth < MAX_LOG) begin
                                    phase[cur_depth + 1'b1] <= PH_F;
                                end

                                element_index      <= {INDEX_W{1'b0}};
                                merge_second_write <= 1'b0;
                                cur_depth          <= cur_depth + 1'b1;
                            end else begin
                                element_index <= element_index + 1'b1;
                            end
                        end

                        // -----------------------------------------------------
                        // PH_G：右子节点LLR生成
                        // -----------------------------------------------------

                        else if (phase[cur_depth] == PH_G) begin
                            if (element_index ==
                                (current_half - 1)) begin

                                // 当前节点右alpha全部生成完毕。
                                //
                                // 父层下一阶段设为PH_C。
                                // 子层重新从PH_F开始。
                                phase[cur_depth] <= PH_C;

                                if (cur_depth < MAX_LOG) begin
                                    phase[cur_depth + 1'b1] <= PH_F;
                                end

                                element_index      <= {INDEX_W{1'b0}};
                                merge_second_write <= 1'b0;
                                cur_depth          <= cur_depth + 1'b1;
                            end else begin
                                element_index <= element_index + 1'b1;
                            end
                        end

                        // -----------------------------------------------------
                        // PH_C：beta合并
                        // -----------------------------------------------------

                        else begin
                            if (!merge_second_write) begin
                                // 当前周期已经写入：
                                //
                                // parent[k] = left XOR right
                                //
                                // 下一周期写入：
                                //
                                // parent[k+half] = right
                                merge_second_write <= 1'b1;
                            end else begin
                                // 当前周期已经写入：
                                //
                                // parent[k+half] = right

                                merge_second_write <= 1'b0;

                                if (element_index ==
                                    (current_half - 1)) begin

                                    element_index <= {INDEX_W{1'b0}};

                                    // 根节点beta合并完成。
                                    //
                                    // 此时beta_mem[0:N-1]应与编码码字d一致。
                                    if (cur_depth == 0) begin
                                        state <= ST_OUTPUT_START;
                                    end else begin
                                        // 返回当前节点父层。
                                        //
                                        // 父层phase已经在下降当前子树之前设置：
                                        //
                                        //   左子树完成后为PH_G
                                        //   右子树完成后为PH_C
                                        cur_depth <= cur_depth - 1'b1;
                                    end
                                end else begin
                                    element_index <= element_index + 1'b1;
                                end
                            end
                        end
                    end
                end

                // =============================================================
                // 启动u_hat串行输出
                // =============================================================
                //
                // output_start由组合逻辑在该状态拉高一个完整周期。
                // =============================================================

                ST_OUTPUT_START: begin
                    decode_busy <= 1'b1;
                    state       <= ST_OUTPUT_WAIT;
                end

                // =============================================================
                // 等待完整u_hat输出结束
                // =============================================================

                ST_OUTPUT_WAIT: begin
                    decode_busy <= 1'b1;

                    if (output_done) begin
                        decode_busy <= 1'b0;
                        decode_done <= 1'b1;
                        state       <= ST_IDLE;
                    end
                end

                default: begin
                    state       <= ST_IDLE;
                    decode_busy <= 1'b0;
                    decode_done <= 1'b0;
                end

            endcase
        end
    end

endmodule
module sc_decoder_core #(
    parameter integer NMAX      = 1024,
    parameter integer LLR_W     = 8,
    parameter integer INT_W     = 10,
    parameter integer MAX_LOG   = 10,
    parameter integer MEM_DEPTH = 2 * NMAX - 1,
    parameter integer ADDR_W    = 11,
    parameter integer INDEX_W   = 11
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // -------------------------------------------------------------------------
    // 码块配置接口
    // -------------------------------------------------------------------------
    input  wire                         config_start,
    input  wire [3:0]                   n_log_cfg,
    input  wire [10:0]                  k_cfg,
    output wire                         config_ready,
    output reg                          config_busy,
    output reg                          config_done,
    output reg                          config_error,

    // -------------------------------------------------------------------------
    // 当前配置下的码块启动接口
    // -------------------------------------------------------------------------
    input  wire                         block_start,
    output wire                         block_ready,
    output wire                         block_busy,
    output wire                         block_done,

    // -------------------------------------------------------------------------
    // 信道LLR串行输入
    // -------------------------------------------------------------------------
    input  wire signed [LLR_W-1:0]      llr_in,
    input  wire                         llr_in_valid,
    output wire                         llr_in_ready,

    // -------------------------------------------------------------------------
    // 译码结果串行输出
    // -------------------------------------------------------------------------
    output wire                         u_valid,
    input  wire                         u_ready,
    output wire                         u_bit,
    output wire [INDEX_W-1:0]           u_index,
    output wire                         u_last
);

    // =========================================================================
    // 配置控制状态机
    // =========================================================================

    localparam [2:0] ST_NO_CONFIG = 3'd0;
    localparam [2:0] ST_CFG_START = 3'd1;
    localparam [2:0] ST_CFG_WAIT  = 3'd2;
    localparam [2:0] ST_READY     = 3'd3;
    localparam [2:0] ST_ACTIVE    = 3'd4;

    localparam [3:0] MAX_LOG_CODE = MAX_LOG;

    reg [2:0] state;

    reg [3:0]  n_log_active;
    reg [10:0] k_active;

    reg  frozen_start;
    wire frozen_busy;
    wire frozen_done;

    // 明确保留该名称，便于testbench层次化检查。
    wire [NMAX-1:0] frozen_mask;

    reg datapath_load_start;

    wire [11:0] cfg_n_value;
    wire        cfg_n_valid;
    wire        cfg_k_valid;
    wire        cfg_valid;

    assign cfg_n_value = (12'd1 << n_log_cfg);

    assign cfg_n_valid =
        (n_log_cfg >= 4'd6) &&
        (n_log_cfg <= MAX_LOG_CODE);

    assign cfg_k_valid =
        ({1'b0, k_cfg} <= cfg_n_value);

    assign cfg_valid =
        cfg_n_valid && cfg_k_valid;

    assign config_ready =
        ((state == ST_NO_CONFIG) ||
         (state == ST_READY)) &&
        !config_busy;

    assign block_ready =
        (state == ST_READY);

    // =========================================================================
    // frozen_gen
    // =========================================================================

    frozen_gen #(
        .NMAX(NMAX)
    )
    u_frozen_gen (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (frozen_start),
        .n_log   (n_log_active),
        .K       (k_active),
        .busy    (frozen_busy),
        .done    (frozen_done),
        .frozen  (frozen_mask)
    );

    // =========================================================================
    // controller与datapath内部连线
    // =========================================================================

    wire load_busy;
    wire load_done;

    wire decode_busy;
    wire decode_done;

    wire output_busy;
    wire output_done;

    wire [ADDR_W-1:0] llr_rd_addr_a;
    wire [ADDR_W-1:0] llr_rd_addr_b;

    wire signed [INT_W-1:0] llr_rd_data_a;
    wire signed [INT_W-1:0] llr_rd_data_b;

    wire pe_mode_g;
    wire llr_wr_en;
    wire [ADDR_W-1:0] llr_wr_addr;
    wire signed [INT_W-1:0] pe_result;

    wire [ADDR_W-1:0] beta_rd_addr_a;
    wire [ADDR_W-1:0] beta_rd_addr_b;
    wire beta_rd_data_a;
    wire beta_rd_data_b;

    wire beta_wr_en;
    wire [ADDR_W-1:0] beta_wr_addr;
    wire beta_wr_data;
    wire [1:0] beta_wr_mode;
    wire beta_selected_data;

    wire leaf_decision_en;
    wire leaf_frozen;
    wire [INDEX_W-1:0] leaf_index;
    wire [ADDR_W-1:0] leaf_beta_wr_addr;
    wire leaf_decision;

    wire output_start;

    assign block_done = decode_done;

    assign block_busy =
        config_busy ||
        (state == ST_ACTIVE) ||
        load_busy ||
        decode_busy ||
        output_busy;

    // =========================================================================
    // sc_datapath
    // =========================================================================

    sc_datapath #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (MAX_LOG),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    )
    u_datapath (
        .clk                 (clk),
        .rst_n               (rst_n),

        .load_start          (datapath_load_start),
        .n_log               (n_log_active),
        .llr_in              (llr_in),
        .llr_in_valid        (llr_in_valid),
        .llr_in_ready        (llr_in_ready),
        .load_busy           (load_busy),
        .load_done           (load_done),

        .llr_rd_addr_a       (llr_rd_addr_a),
        .llr_rd_addr_b       (llr_rd_addr_b),
        .llr_rd_data_a       (llr_rd_data_a),
        .llr_rd_data_b       (llr_rd_data_b),

        .pe_mode_g           (pe_mode_g),
        .llr_wr_en           (llr_wr_en),
        .llr_wr_addr         (llr_wr_addr),
        .pe_result           (pe_result),

        .beta_rd_addr_a      (beta_rd_addr_a),
        .beta_rd_data_a      (beta_rd_data_a),

        .beta_rd_addr_b      (beta_rd_addr_b),
        .beta_rd_data_b      (beta_rd_data_b),

        .beta_wr_en          (beta_wr_en),
        .beta_wr_addr        (beta_wr_addr),
        .beta_wr_data        (beta_wr_data),
        .beta_wr_mode        (beta_wr_mode),
        .beta_selected_data  (beta_selected_data),

        .leaf_decision_en    (leaf_decision_en),
        .leaf_frozen         (leaf_frozen),
        .leaf_index          (leaf_index),
        .leaf_beta_wr_addr   (leaf_beta_wr_addr),
        .leaf_decision       (leaf_decision),

        .output_start        (output_start),
        .output_busy         (output_busy),
        .output_done         (output_done),

        .u_valid             (u_valid),
        .u_ready             (u_ready),
        .u_bit               (u_bit),
        .u_index             (u_index),
        .u_last              (u_last)
    );

    // =========================================================================
    // sc_controller
    // =========================================================================

    sc_controller #(
        .NMAX      (NMAX),
        .MAX_LOG   (MAX_LOG),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    )
    u_controller (
        .clk                  (clk),
        .rst_n                (rst_n),

        .decode_start         (load_done),
        .n_log                (n_log_active),
        .frozen_bits          (frozen_mask),

        .decode_busy          (decode_busy),
        .decode_done          (decode_done),

        .llr_rd_addr_a        (llr_rd_addr_a),
        .llr_rd_addr_b        (llr_rd_addr_b),
        .pe_mode_g            (pe_mode_g),
        .llr_wr_en            (llr_wr_en),
        .llr_wr_addr          (llr_wr_addr),

        .beta_rd_addr_a       (beta_rd_addr_a),
        .beta_rd_addr_b       (beta_rd_addr_b),
        .beta_wr_en           (beta_wr_en),
        .beta_wr_addr         (beta_wr_addr),
        .beta_wr_data         (beta_wr_data),
        .beta_wr_mode         (beta_wr_mode),

        .leaf_decision_en     (leaf_decision_en),
        .leaf_frozen          (leaf_frozen),
        .leaf_index           (leaf_index),
        .leaf_beta_wr_addr    (leaf_beta_wr_addr),

        .output_start         (output_start),
        .output_done          (output_done)
    );

    // =========================================================================
    // 配置/码块状态控制
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_NO_CONFIG;
            n_log_active        <= 4'd6;
            k_active            <= 11'd0;

            frozen_start        <= 1'b0;
            datapath_load_start <= 1'b0;

            config_busy         <= 1'b0;
            config_done         <= 1'b0;
            config_error        <= 1'b0;
        end
        else begin
            // 默认脉冲信号拉低
            frozen_start        <= 1'b0;
            datapath_load_start <= 1'b0;
            config_done         <= 1'b0;
            config_error        <= 1'b0;

            case (state)

                // -------------------------------------------------------------
                // 尚无有效配置
                // -------------------------------------------------------------
                ST_NO_CONFIG: begin
                    config_busy <= 1'b0;

                    if (config_start) begin
                        if (cfg_valid) begin
                            n_log_active <= n_log_cfg;
                            k_active     <= k_cfg;

                            config_busy  <= 1'b1;
                            state        <= ST_CFG_START;
                        end
                        else begin
                            config_error <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 在锁存配置后的下一拍启动frozen_gen
                // -------------------------------------------------------------
                ST_CFG_START: begin
                    config_busy  <= 1'b1;
                    frozen_start <= 1'b1;
                    state        <= ST_CFG_WAIT;
                end

                // -------------------------------------------------------------
                // 等待冻结掩码完成
                // -------------------------------------------------------------
                ST_CFG_WAIT: begin
                    config_busy <= 1'b1;

                    if (frozen_done) begin
                        config_busy <= 1'b0;
                        config_done <= 1'b1;
                        state       <= ST_READY;
                    end
                end

                // -------------------------------------------------------------
                // 已有配置，可以启动码块或重新配置
                // -------------------------------------------------------------
                ST_READY: begin
                    config_busy <= 1'b0;

                    if (config_start) begin
                        if (cfg_valid) begin
                            n_log_active <= n_log_cfg;
                            k_active     <= k_cfg;

                            config_busy  <= 1'b1;
                            state        <= ST_CFG_START;
                        end
                        else begin
                            config_error <= 1'b1;
                        end
                    end
                    else if (block_start) begin
                        datapath_load_start <= 1'b1;
                        state               <= ST_ACTIVE;
                    end
                end

                // -------------------------------------------------------------
                // 当前码块正在装载、译码或输出
                // -------------------------------------------------------------
                ST_ACTIVE: begin
                    config_busy <= 1'b0;

                    if (decode_done) begin
                        state <= ST_READY;
                    end
                end

                default: begin
                    state        <= ST_NO_CONFIG;
                    config_busy  <= 1'b0;
                    config_error <= 1'b1;
                end

            endcase
        end
    end

endmodule
module sc_datapath #(
    parameter integer NMAX      = 1024,
    parameter integer LLR_W     = 8,
    parameter integer INT_W     = 10,
    parameter integer MAX_LOG   = 10,

    // NMAX=1024 时：
    // MEM_DEPTH=2047
    // ADDR_W=11
    parameter integer MEM_DEPTH = 2 * NMAX - 1,
    parameter integer ADDR_W    = 11,

    // 能够表示自然索引0～1023以及码长1024
    parameter integer INDEX_W   = 11
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // =========================================================================
    // 根节点串行 LLR 装载接口
    // =========================================================================

    // 空闲状态下拉高一个周期，启动一次根节点LLR装载
    input  wire                         load_start,

    // 当前码长log2：
    // 6、7、8、9、10分别对应64、128、256、512、1024
    input  wire [3:0]                   n_log,

    // 串行输入信道LLR
    input  wire signed [LLR_W-1:0]      llr_in,

    // 当前llr_in有效
    input  wire                         llr_in_valid,

    // LLR存储模块能够接收输入
    output wire                         llr_in_ready,

    // 正在装载根节点LLR
    output wire                         load_busy,

    // 最后一个根节点LLR接收完成脉冲
    output wire                         load_done,

    // =========================================================================
    // LLR 存储器读取接口
    // =========================================================================

    // PE操作数a的地址
    // 叶节点判决时，该地址也作为叶节点LLR地址
    input  wire [ADDR_W-1:0]            llr_rd_addr_a,

    // PE操作数b的地址
    input  wire [ADDR_W-1:0]            llr_rd_addr_b,

    // 两个组合读出的LLR
    output wire signed [INT_W-1:0]      llr_rd_data_a,
    output wire signed [INT_W-1:0]      llr_rd_data_b,

    // =========================================================================
    // PE 微操作接口
    // =========================================================================

    // 0：执行f运算
    // 1：执行g运算
    input  wire                         pe_mode_g,

    // 将PE结果写回LLR存储器
    input  wire                         llr_wr_en,

    // PE结果写回地址
    input  wire [ADDR_W-1:0]            llr_wr_addr,

    // 当前PE组合计算结果
    output wire signed [INT_W-1:0]      pe_result,

    // =========================================================================
    // beta 存储器读取接口
    // =========================================================================

    // beta读端口A
    //
    // 执行g运算时，beta_rd_data_a作为sc_pe的beta输入。
    input  wire [ADDR_W-1:0]            beta_rd_addr_a,
    output wire                         beta_rd_data_a,

    // beta读端口B
    input  wire [ADDR_W-1:0]            beta_rd_addr_b,
    output wire                         beta_rd_data_b,

    // =========================================================================
    // 内部节点 beta 写回接口
    // =========================================================================

    // 普通beta写使能
    input  wire                         beta_wr_en,

    // beta写回地址
    input  wire [ADDR_W-1:0]            beta_wr_addr,

    // 直接写入数据
    // 仅在beta_wr_mode=2'b00时使用
    input  wire                         beta_wr_data,

    // beta写数据来源选择
    //
    // 00：beta_wr_data
    // 01：beta_rd_data_a XOR beta_rd_data_b
    // 10：beta_rd_data_a
    // 11：beta_rd_data_b
    input  wire [1:0]                   beta_wr_mode,

    // 经过选择后的beta写入数据
    // 主要用于仿真观察和调试
    output wire                         beta_selected_data,

    // =========================================================================
    // 叶节点判决接口
    // =========================================================================

    // 拉高一个周期，执行一次叶节点判决
    input  wire                         leaf_decision_en,

    // 当前叶节点是否为冻结位
    input  wire                         leaf_frozen,

    // 当前叶节点自然索引phi
    input  wire [INDEX_W-1:0]           leaf_index,

    // 当前叶节点判决写入beta_mem的物理地址
    input  wire [ADDR_W-1:0]            leaf_beta_wr_addr,

    // 当前组合产生的叶节点最终判决
    output wire                         leaf_decision,

    // =========================================================================
    // u_hat 串行输出接口
    // =========================================================================

    // 所有叶节点译码完成后拉高一个周期，启动完整u_hat输出
    input  wire                         output_start,

    // 当前正在输出u_hat
    output wire                         output_busy,

    // 最后一个u_hat完成握手后拉高一个周期
    output wire                         output_done,

    // 当前输出有效
    output wire                         u_valid,

    // 下游准备接收当前输出
    input  wire                         u_ready,

    // 当前输出判决位
    output wire                         u_bit,

    // 当前输出自然索引
    output wire [10:0]                  u_index,

    // 当前输出是u_hat[N-1]
    output wire                         u_last
);

    // =========================================================================
    // 内部信号：PE
    // =========================================================================

    wire signed [INT_W-1:0] pe_y;
    wire                    pe_beta;

    // g运算使用beta读端口A
    assign pe_beta = beta_rd_data_a;

    // 将PE输出连接到顶层调试端口
    assign pe_result = pe_y;

    // =========================================================================
    // 叶节点判决组合逻辑
    // =========================================================================
    //
    // 冻结位强制判决0。
    //
    // 非冻结位：
    //制判决0。
    //
    // 非冻结位：
    //
    //     LLR符号位为0 → 判决0
    //     LLR符号位为1 → 判决1
    // =========================================================================

    assign leaf_decision =
        leaf_frozen
        ? 1'b0
        : llr_rd_data_a[INT_W-1];

    // =========================================================================
    // beta 写入数据选择
    // =========================================================================

    localparam [1:0] BETA_SRC_DIRECT = 2'b00;
    localparam [1:0] BETA_SRC_XOR    = 2'b01;
    localparam [1:0] BETA_SRC_A      = 2'b10;
    localparam [1:0] BETA_SRC_B      = 2'b11;

    reg beta_selected_data_reg;

    always @(*) begin
        case (beta_wr_mode)

            BETA_SRC_DIRECT: begin
                beta_selected_data_reg = beta_wr_data;
            end

            BETA_SRC_XOR: begin
                beta_selected_data_reg =
                    beta_rd_data_a ^ beta_rd_data_b;
            end

            BETA_SRC_A: begin
                beta_selected_data_reg = beta_rd_data_a;
            end

            BETA_SRC_B: begin
                beta_selected_data_reg = beta_rd_data_b;
            end

            default: begin
                beta_selected_data_reg = 1'b0;
            end

        endcase
    end

    assign beta_selected_data = beta_selected_data_reg;

    // =========================================================================
    // beta 存储器实际写端口
    // =========================================================================
    //
    // 优先级：
    //
    //     leaf_decision_en > beta_wr_en
    // =========================================================================

    wire                    beta_mem_wr_en;
    wire [ADDR_W-1:0]       beta_mem_wr_addr;
    wire                    beta_mem_wr_data;

    assign beta_mem_wr_en =
        leaf_decision_en | beta_wr_en;

    assign beta_mem_wr_addr =
        leaf_decision_en
        ? leaf_beta_wr_addr
        : beta_wr_addr;

    assign beta_mem_wr_data =
        leaf_decision_en
        ? leaf_decision
        : beta_selected_data_reg;

    // =========================================================================
    // Processing Element
    // =========================================================================

    sc_pe #(
        .W(INT_W)
    )
    u_sc_pe (
        .a      (llr_rd_data_a),
        .b      (llr_rd_data_b),
        .mode_g (pe_mode_g),
        .beta   (pe_beta),
        .y      (pe_y)
    );

    // =========================================================================
    // LLR 存储器
    // =========================================================================
    //
    // 普通写端口的数据固定来自PE结果pe_y。
    //
    // 当根节点正在串行装载时，sc_llr_mem内部会忽略llr_wr_en。
    // =========================================================================

    sc_llr_mem #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (MAX_LOG),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .N_W       (INDEX_W)
    )
    u_sc_llr_mem (
        .clk          (clk),
        .rst_n        (rst_n),

        .load_start   (load_start),
        .n_log        (n_log),
        .llr_in       (llr_in),
        .llr_in_valid (llr_in_valid),
        .llr_in_ready (llr_in_ready),
        .load_busy    (load_busy),
        .load_done    (load_done),

        .wr_en        (llr_wr_en),
        .wr_addr      (llr_wr_addr),
        .wr_data      (pe_y),

        .rd_addr_a    (llr_rd_addr_a),
        .rd_data_a    (llr_rd_data_a),

        .rd_addr_b    (llr_rd_addr_b),
        .rd_data_b    (llr_rd_data_b)
    );

    // =========================================================================
    // beta 存储器
    // =========================================================================

    sc_beta_mem #(
        .NMAX      (NMAX),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W)
    )
    u_sc_beta_mem (
        .clk       (clk),
        .rst_n     (rst_n),

        .wr_en     (beta_mem_wr_en),
        .wr_addr   (beta_mem_wr_addr),
        .wr_data   (beta_mem_wr_data),

        .rd_addr_a (beta_rd_addr_a),
        .rd_data_a (beta_rd_data_a),

        .rd_addr_b (beta_rd_addr_b),
        .rd_data_b (beta_rd_data_b)
    );

    // =========================================================================
    // u_hat 存储与串行输出模块
    // =========================================================================
    //
    // leaf_decision_en有效时，将leaf_decision写入：
    //
    //     uhat_mem[leaf_index]
    //
    // 同一个时钟沿，leaf_decision也会通过beta存储器写端口写入对应地址。
    // =========================================================================

    sc_uhat_mem #(
        .NMAX    (NMAX),
        .INDEX_W (INDEX_W)
    )
    u_sc_uhat_mem (
        .clk          (clk),
        .rst_n        (rst_n),

        .wr_en        (leaf_decision_en),
        .wr_index     (leaf_index),
        .wr_bit       (leaf_decision),

        .output_start (output_start),
        .n_log        (n_log),

        .output_busy  (output_busy),
        .output_done  (output_done),

        .u_valid      (u_valid),
        .u_ready      (u_ready),
        .u_bit        (u_bit),
        .u_index      (u_index),
        .u_last       (u_last)
    );

endmodule
module sc_pe #(
    parameter integer W = 10
)(
    input  wire signed [W-1:0] a,
    input  wire signed [W-1:0] b,
    input  wire                mode_g,
    input  wire                beta,
    output reg  signed [W-1:0] y
);

    // -------------------------------------------------------------------------
    // W+1 位有符号饱和边界
    //
    // 以 W=10 为例：
    // MAX_EXT = +511
    // MIN_EXT = -512
    // -------------------------------------------------------------------------
    localparam signed [W:0] MAX_EXT =
        {2'b00, {(W-1){1'b1}}};

    localparam signed [W:0] MIN_EXT =
        {2'b11, {(W-1){1'b0}}};

    // -------------------------------------------------------------------------
    // 绝对值的无符号边界
    //
    // MAX_MAG = 2^(W-1)-1
    // MIN_MAG = 2^(W-1)
    //
    // MIN_MAG 对应最小负数的绝对值。
    // 例如 W=10 时，|-512|=512。
    // -------------------------------------------------------------------------
    localparam [W:0] MAX_MAG =
        {2'b00, {(W-1){1'b1}}};

    localparam [W:0] MIN_MAG =
        {2'b01, {(W-1){1'b0}}};

    // W 位输出边界
    localparam signed [W-1:0] MAX_OUT =
        {1'b0, {(W-1){1'b1}}};

    localparam signed [W-1:0] MIN_OUT =
        {1'b1, {(W-1){1'b0}}};

    // f 运算中使用 W+1 位无符号绝对值
    reg [W:0] abs_a;
    reg [W:0] abs_b;
    reg [W:0] min_abs;

    reg f_negative;

    // g 运算中使用 W+1 位有符号数
    reg signed [W:0] a_ext;
    reg signed [W:0] b_ext;
    reg signed [W:0] g_ext;

    always @* begin
        // 默认赋值，避免组合锁存
        y          = {W{1'b0}};

        abs_a      = {(W+1){1'b0}};
        abs_b      = {(W+1){1'b0}};
        min_abs    = {(W+1){1'b0}};
        f_negative = 1'b0;

        // 明确进行符号扩展
        a_ext      = {a[W-1], a};
        b_ext      = {b[W-1], b};
        g_ext      = {(W+1){1'b0}};

        // =====================================================================
        // f 运算
        // =====================================================================
        if (!mode_g) begin

            // -----------------------------------------------------------------
            // 求 |a|
            //
            // 必须先扩展为 W+1 位，再执行二进制补码取负。
            // 这样才能正确处理最小负数。
            // -----------------------------------------------------------------
            if (a[W-1]) begin
                abs_a =
                    (~{a[W-1], a})
                    + {{W{1'b0}}, 1'b1};
            end
            else begin
                abs_a = {1'b0, a};
            end

            // 求 |b|
            if (b[W-1]) begin
                abs_b =
                    (~{b[W-1], b})
                    + {{W{1'b0}}, 1'b1};
            end
            else begin
                abs_b = {1'b0, b};
            end

            // 取较小绝对值
            if (abs_a < abs_b)
                min_abs = abs_a;
            else
                min_abs = abs_b;

            // 两输入异号时，f 结果为负
            f_negative = a[W-1] ^ b[W-1];

            if (f_negative) begin
                // -------------------------------------------------------------
                // 负结果
                //
                // -2^(W-1) 可以由 W 位表示。
                // 若绝对值达到或超过 MIN_MAG，则饱和到 MIN_OUT。
                // -------------------------------------------------------------
                if (min_abs >= MIN_MAG) begin
                    y = MIN_OUT;
                end
                else begin
                    // 对 min_abs 的低 W 位执行二进制补码取负
                    y =
                        (~min_abs[W-1:0])
                        + {{(W-1){1'b0}}, 1'b1};
                end
            end
            else begin
                // -------------------------------------------------------------
                // 正结果
                //
                // +2^(W-1) 无法由 W 位有符号数表示。
                // 例如 f(-512,-512)=+512，需要饱和到 +511。
                // -------------------------------------------------------------
                if (min_abs > MAX_MAG)
                    y = MAX_OUT;
                else
                    y = $signed(min_abs[W-1:0]);
            end
        end

        // =====================================================================
        // g 运算
        // =====================================================================
        else begin
            if (beta)
                g_ext = b_ext - a_ext;
            else
                g_ext = b_ext + a_ext;

            // 明确执行有符号饱和比较
            if (g_ext > MAX_EXT)
                y = MAX_OUT;
            else if (g_ext < MIN_EXT)
                y = MIN_OUT;
            else
                y = g_ext[W-1:0];
        end
    end

endmodule

---

### ChatGPT

从这四个模块看，你当前的 SC 译码器是典型的 单路径、深度优先 DFS、单 PE 时分复用结构。升级到 SCL 可以继续沿用现有树遍历框架，但不能只修改叶节点判决，需要同步改造路径状态、存储器和控制状态机。
一、当前模块的改造程度
模块改造程度说明sc_pe.v很小现有 $f/g$ 运算可以直接复用sc_controller.v很大增加路径遍历、分裂、路径度量、剪枝和复制状态sc_datapath.v很大所有存储访问必须增加 path_id，加入 PM 计算和路径管理sc_decoder_core.v中等增加列表参数、路径选择和可选 CRC 接口sc_llr_mem.v很大从单路径 LLR 存储改为多路径存储sc_beta_mem.v很大每条路径必须保存独立部分和sc_uhat_mem.v很大保存 $L$ 条候选译码序列，最后输出最优路径frozen_gen.v通常不改冻结位集合对所有路径相同
你目前的 sc_pe 已经实现了饱和 Min-Sum 运算，适合继续用于 SCL。

二、当前 SC 结构为什么不能直接变成 SCL
现在每个叶节点只有一次判决：
verilogassign leaf_decision =    leaf_frozen    ? 1'b0    : llr_rd_data_a[INT_W-1];
也就是信息位只保留 LLR 硬判决结果。
SCL 在信息位必须将每条现有路径扩展为两个候选：
Plain text原路径 p├── 候选 u=0└── 候选 u=1
例如 $L=4$，原来有 4 条路径，信息位处会临时形成 8 条候选，然后按照路径度量保留最优 4 条。
硬件友好的路径度量可以使用：
$PM_{\mathrm{new}}=
\begin{cases}
PM_{\mathrm{old}}, & u=\mathrm{HD}(LLR)\\
PM_{\mathrm{old}}+|LLR|, & u\neq\mathrm{HD}(LLR)
\end{cases}$
其中：
veriloghard_bit = llr[INT_W-1];
你的 LLR 符号定义与这个公式一致。

三、推荐基于现有代码采用的第一版架构
建议第一版采用：
Plain textSCL列表大小：L = 4译码类型：普通SCLPE数量：1个，继续时分复用路径度量：|LLR|近似度量路径存储：4个独立存储Bank路径剪枝：顺序比较或小型排序网络CRC：第一版暂不加入
这样改动虽然仍然较大，但可以最大限度保留你现在的 DFS 控制器。
核心思路
当前这些状态仍可以由所有路径共享：
verilogcur_depthelement_indexcurrent_leafphase[]merge_second_write
新增一个路径循环计数器：
verilogreg [PATH_W-1:0] current_path;reg [PATH_W:0]   active_path_count;
每个树节点微操作从：
Plain text处理一个 element
改为：
Plain text对当前 element 的所有有效路径依次处理处理完全部路径后，再进入下一个 element
例如原来的 PH_F：
Plain textelement 0element 1element 2...
改成：
Plain textelement 0, path 0element 0, path 1element 0, path 2element 0, path 3element 1, path 0element 1, path 1...
这样仍然只需要一个 sc_pe。

四、存储器建议
第一版可以采用直接多 Bank 结构，物理地址表示为：
$\text{physical address}
=
\text{path\_id}\times MEM\_DEPTH+\text{local address}$
例如：
veriloglocalparam integer PATH_NUM = 4;localparam integer TOTAL_DEPTH = PATH_NUM * MEM_DEPTH;
逻辑上：
verilogllr_mem [0:PATH_NUM-1][0:MEM_DEPTH-1];beta_mem[0:PATH_NUM-1][0:MEM_DEPTH-1];uhat_mem[0:PATH_NUM-1][0:NMAX-1];
综合兼容性更好的写法一般是压平：
verilogreg signed [INT_W-1:0] llr_mem [0:PATH_NUM*MEM_DEPTH-1];wire [TOTAL_ADDR_W-1:0] physical_addr =    path_id * MEM_DEPTH + local_addr;
需要看你现有三个存储模块的具体实现后，才能决定是直接二维 Bank，还是压平地址。

五、下一步请继续提供这些文件
必须提供
Plain textsc_llr_mem.vsc_beta_mem.vsc_uhat_mem.vfrozen_gen.v
其中前三个决定路径状态如何复制和保存，是下一步最关键的代码。
用于验证
Plain textsc_test_sequencer.v完整 testbench仿真使用的 .mem、.hex 或 .txt 文件当前 SC 的正确仿真结果
如果截图中的 controller.v 不是刚才这个 sc_controller，也需要一起提供。

六、还需要明确的参数
请在上传代码时附上：
Plain text目标列表大小：L=2、4还是8普通SCL还是CA-SCL使用Vivado还是Quartus目标FPGA型号是否优先考虑低资源还是高速度当前SC的时钟频率要求
没有特殊要求时，我建议按以下默认方案升级：
Plain textL = 4普通SCL单PE时分复用PM_W = 24全路径独立Bank先保证仿真正确，再做懒复制优化
另外，你的 sc_datapath 中这一处建议顺便参数化：
verilogoutput wire [10:0] u_index
改成：
verilogoutput wire [INDEX_W-1:0] u_index
下一批直接上传三个存储模块和 frozen_gen.v，就可以开始设计具体的 scl_llr_mem、scl_beta_mem、scl_uhat_mem 以及路径管理状态机。

---

### User

1.为什么第一版不加入CRC，为什么一定要保留DFS控制器
2.L=4，但是最好设置成参数，方便我更改，使用vivado，目前还不知道FPGA型号，优先考虑高速度
3.// =============================================================================
// frozen_gen.v  --  由 (N, K) 生成极化码冻结掩码 (依据 spec 附录C 可靠度序列)
// -----------------------------------------------------------------------------
// spec 6.9.1.4: 码长 N、信息位数 K 时, 在可靠度排序序列 Q_0^{N-1} 中取"后 K 个"
// (可靠性最高) 索引作为非冻结(信息)集, 前 N-K 个作为冻结集. 且长为 N 的序列是
// 全序列 Q_0^{Nmax-1} 中"比特索引 < N"的子序列 (嵌套性).
//
// 实现: 从最高可靠度秩 (rank=NMAX-1) 向下扫描可靠度 ROM, 对每个 rank 取比特索引
// q=ROM[rank]; 若 q<N 且信息配额未满, 则将 q 标为信息位 (frozen[q]=0), 直到标满 K 个.
//   —— 自顶向下天然给出"可靠性最高的 K 个 (且索引<N) 位置", 即非冻结集.
// 位 >= N 的 frozen 恒为 1 (置0), 便于后续 u 装配对任意 N 统一处理.
//
// 时延: 可变, 最多 ~NMAX 拍 (一次配置). 混合码长流中同一 (N,K) 只需配置一次,
//       顶层可缓存复用 (见 polar_encode_top).
//
// 端口: start 在 busy=0 时被接受; done 为单拍脉冲, 与 frozen 有效同拍.
// =============================================================================
module frozen_gen #(
    parameter integer NMAX = 1024
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire [3:0]       n_log,     // log2(N); spec 取 6..10, 也支持更小便于测试
    input  wire [10:0]      K,         // 信息位数 (0..N)
    output reg              busy,
    output reg              done,
    output reg [NMAX-1:0]   frozen     // 1=冻结(u=0), 0=信息位; 位>=N 恒为1
);
    localparam integer RW = $clog2(NMAX);   // 秩位宽 (=10)
    localparam [RW-1:0] RANK_MAX = {RW{1'b1}};   // = NMAX-1 (NMAX 为 2 的幂)

    reg  [RW-1:0] rank;
    wire [9:0]    q;                        // 当前秩对应的比特索引
    reg  [11:0]   need;                     // 尚需标记的信息位数
    wire [11:0]   N = (12'd1 << n_log);     // 码长 N

    polar_reliability_rom u_rom (.rank(rank), .q(q));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            done   <= 1'b0;
            frozen <= {NMAX{1'b1}};
            rank   <= {RW{1'b0}};
            need   <= 12'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                frozen <= {NMAX{1'b1}};      // 全部先置冻结
                need   <= {1'b0, K};
                rank   <= RANK_MAX;          // 从最高可靠度秩开始
                busy   <= (K != 0);          // K=0 则无需处理
                done   <= (K == 0);          // K=0 立即完成 (全冻结)
            end else if (busy) begin
                if (({2'b00, q} < N) && (need != 0)) begin
                    frozen[q] <= 1'b0;        // 标为信息位
                    if (need == 12'd1) begin  // 刚标满 K 个 -> 完成
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        need <= need - 1'b1;
                        rank <= rank - 1'b1;
                    end
                end else begin
                    if (rank == 0) begin      // 扫到底 (K>N 的异常保护) -> 结束
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        rank <= rank - 1'b1;
                    end
                end
            end
        end
    end
endmodule
module sc_llr_mem #(
    parameter integer NMAX = 1024,
    parameter integer LLR_W = 8,
    parameter integer INT_W = 10,

    // NMAX=1024 时 MAX_LOG=10
    parameter integer MAX_LOG = $clog2(NMAX),

    // 每层预留 NMAX 个位置，共 MAX_LOG+1 层
    // NMAX=1024 时 MEM_DEPTH=11*1024=11264
    parameter integer MEM_DEPTH = 2 * NMAX - 1,

    // NMAX=1024
    // MEM_DEPTH=2047
    // ADDR_W=11
    parameter integer ADDR_W = $clog2(MEM_DEPTH),

    // 需要能够表示 NMAX 本身：
    // NMAX=1024 时 N_W=11
    parameter integer N_W =  $clog2(NMAX)+1
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // =========================================================================
    // 根节点串行装载接口
    // =========================================================================

    // 空闲状态下拉高一个周期，启动根节点 LLR 装载
    input  wire                     load_start,

    // 当前码长的 log2：
    // 6、7、8、9、10 分别对应 64～1024
    input  wire [3:0]               n_log,

    // 串行输入 LLR
    input  wire signed [LLR_W-1:0]  llr_in,

    // llr_in 当前周期有效
    input  wire                     llr_in_valid,

    // 模块能够接收 llr_in
    output wire                     llr_in_ready,

    // 正在装载根节点 LLR
    output reg                      load_busy,

    // 最后一个根节点 LLR 接收完成后，拉高一个周期
    output reg                      load_done,

    // =========================================================================
    // 普通同步写端口
    // =========================================================================

    // 普通写使能
    // 仅在 load_busy=0 时有效
    input  wire                     wr_en,

    // 写入物理地址
    input  wire [ADDR_W-1:0]        wr_addr,

    // 写入内部 LLR
    input  wire signed [INT_W-1:0]  wr_data,

    // =========================================================================
    // 双组合读端口
    // =========================================================================

    input  wire [ADDR_W-1:0]        rd_addr_a,
    output wire signed [INT_W-1:0]  rd_data_a,

    input  wire [ADDR_W-1:0]        rd_addr_b,
    output wire signed [INT_W-1:0]  rd_data_b
);

    // =========================================================================
    // LLR 存储数组
    // =========================================================================

    reg signed [INT_W-1:0] llr_mem [0:MEM_DEPTH-1];

    // =========================================================================
    // 根节点装载状态
    // =========================================================================

    // 当前需要装载的 LLR 总数 N
    // NMAX=1024，因此必须使用11位表示1024
    reg [N_W-1:0] active_n;

    // 当前即将写入的根节点索引
    // 范围为 0～N-1
    reg [N_W-1:0] load_count;

    // =========================================================================
    // 输入 LLR 位宽转换
    // =========================================================================
    //
    // 默认：
    //
    //     LLR_W = 8
    //     INT_W = 10
    //
    // 例如：
    //
    //     8'b1110_0000 = -32
    //
    // 符号扩展后：
    //
    //     10'b11_1110_0000 = -32
    //
    // 不改变数值。
    // =========================================================================

    wire signed [INT_W-1:0] llr_in_ext;

    generate
    if(INT_W > LLR_W)
    begin

    assign llr_in_ext =
    {
     {(INT_W-LLR_W){llr_in[LLR_W-1]}},
     llr_in
    };
    end
    else
    begin
    assign llr_in_ext = llr_in;
    end
    endgenerate

    // =========================================================================
    // valid/ready 握手
    // =========================================================================

    assign llr_in_ready = load_busy;

    wire llr_in_fire;

    assign llr_in_fire = llr_in_valid && llr_in_ready;

    // =========================================================================
    // 双端口组合读取
    // =========================================================================
    //
    // PE_NUM=1，但一次 f/g 需要两个操作数，所以提供两个组合读地址。
    //
    // 地址变化后，rd_data_a 和 rd_data_b 组合更新。
    // =========================================================================

    assign rd_data_a = llr_mem[rd_addr_a];
    assign rd_data_b = llr_mem[rd_addr_b];

    // =========================================================================
    // 时序控制及写入
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_busy  <= 1'b0;
            load_done  <= 1'b0;
            active_n   <= {N_W{1'b0}};
            load_count <= {N_W{1'b0}};
        end
        else begin
            // load_done 默认只保持一个周期
            load_done <= 1'b0;

            // =================================================================
            // 启动一次新的根节点装载
            // =================================================================
            //
            // 仅在当前空闲时接受 load_start。
            //
            // load_start 所在周期只启动装载，不接收第一个 LLR。
            // 下一个周期 llr_in_ready 才会变为1。
            // =================================================================

            if (load_start && !load_busy) begin
                active_n   <= (1 << n_log);
                load_count <= {N_W{1'b0}};
                load_busy  <= 1'b1;
            end

            // =================================================================
            // 根节点串行装载
            // =================================================================

            else if (load_busy) begin
                if (llr_in_fire) begin

                    // 根节点基地址固定为0
                    //
                    // load_count=0 → d[0]
                    // load_count=1 → d[1]
                    // ...
                    llr_mem[load_count] <= llr_in_ext;

                    // 当前是否为最后一个 LLR
                    if (load_count == (active_n - 1'b1)) begin
                        load_count <= {N_W{1'b0}};
                        load_busy  <= 1'b0;
                        load_done  <= 1'b1;
                    end
                    else begin
                        load_count <= load_count + 1'b1;
                    end
                end
            end

            // =================================================================
            // 普通写端口
            // =================================================================
            //
            // 只有不处于根节点装载状态时，wr_en 才有效。
            // =================================================================

            else if (wr_en) begin
                llr_mem[wr_addr] <= wr_data;
            end
        end
    end

endmodule 
module sc_beta_mem #(

    parameter integer NMAX = 1024,

    parameter integer MEM_DEPTH = 2*NMAX-1,

    parameter integer ADDR_W = $clog2(MEM_DEPTH)

)(

    input  wire                 clk,

    input  wire                 rst_n,


    // =========================================================================
    // 同步写接口
    // =========================================================================

    input  wire                 wr_en,

    input  wire [ADDR_W-1:0]    wr_addr,

    input  wire                 wr_data,


    // =========================================================================
    // 双组合读接口
    // =========================================================================

    input  wire [ADDR_W-1:0]    rd_addr_a,

    output wire                 rd_data_a,


    input  wire [ADDR_W-1:0]    rd_addr_b,

    output wire                 rd_data_b


);



////////////////////////////////////////////////////////////
// beta存储阵列
////////////////////////////////////////////////////////////


reg beta_mem [0:MEM_DEPTH-1];



////////////////////////////////////////////////////////////
// 组合读
////////////////////////////////////////////////////////////


assign rd_data_a = beta_mem[rd_addr_a];


assign rd_data_b = beta_mem[rd_addr_b];



////////////////////////////////////////////////////////////
// 同步写
////////////////////////////////////////////////////////////
//
// 复位不清空beta_mem
//
// 因为:
// 1. 未写入地址不会被使用
// 2. 避免大量寄存器复位资源
//
////////////////////////////////////////////////////////////


always @(posedge clk or negedge rst_n)
begin

    if(!rst_n)
    begin

        // 不清空存储

    end

    else
    begin

        if(wr_en)
        begin

            beta_mem[wr_addr] <= wr_data;

        end

    end

end



endmodule
module sc_uhat_mem #(
    parameter integer NMAX = 1024,

    // 固定配置 NMAX=1024 时，需要 11 位表示：
    // 0～1023 的索引以及 active_n=1024
    parameter integer INDEX_W = 11
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // =========================================================================
    // u_hat 同步写接口
    // =========================================================================

    // 写使能
    input  wire                     wr_en,

    // 写入的自然索引 phi
    input  wire [INDEX_W-1:0]       wr_index,

    // 已完成冻结位处理和 LLR 符号判决的最终判决位
    input  wire                     wr_bit,

    // =========================================================================
    // 串行输出启动接口
    // =========================================================================

    // 空闲时拉高一个周期，启动 u_hat 串行输出
    input  wire                     output_start,

    // 当前码长的 log2
    // 合法取值为 6～10
    input  wire [3:0]               n_log,

    // 当前正在输出
    output reg                      output_busy,

    // 最后一个 u_hat 完成握手后拉高一个周期
    output reg                      output_done,

    // =========================================================================
    // valid/ready 串行输出接口
    // =========================================================================

    // 当前输出有效
    output wire                     u_valid,

    // 下游准备接收当前输出
    input  wire                     u_ready,

    // 当前输出判决位
    output wire                     u_bit,

    // 当前输出自然索引
    output wire [10:0]              u_index,

    // 当前输出是否为 u_hat[N-1]
    output wire                     u_last
);

    // =========================================================================
    // u_hat 存储数组
    // =========================================================================
    //
    // 自然顺序存储：
    //
    //     uhat_mem[0]     = u_hat[0]
    //     uhat_mem[1]     = u_hat[1]
    //     ...
    //     uhat_mem[N-1]   = u_hat[N-1]
    //
    // 第一版使用寄存器数组。
    // =========================================================================

    reg uhat_mem [0:NMAX-1];

    // =========================================================================
    // 输出控制寄存器
    // =========================================================================

    // 当前码长 N
    //
    // 需要表示 NMAX=1024，因此使用 11 位。
    reg [INDEX_W-1:0] active_n;

    // 当前正在输出的 u_hat 索引
    reg [INDEX_W-1:0] output_index;

    // =========================================================================
    // valid/ready 握手
    // =========================================================================

    wire u_fire;

    assign u_valid = output_busy;

    assign u_fire = u_valid && u_ready;

    // =========================================================================
    // 输出数据
    // =========================================================================
    //
    // output_index 在反压期间保持不变，并且 output_busy 期间禁止写存储器，
    // 因此 u_bit、u_index 和 u_last 均能够保持稳定。
    // =========================================================================

    assign u_bit = uhat_mem[output_index];

    // 固定输出接口要求 u_index 为 11 位。
    assign u_index = output_index[10:0];

    assign u_last =
        output_busy &&
        (output_index == (active_n - 1'b1));

    // =========================================================================
    // 写入及串行输出控制
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            output_busy  <= 1'b0;
            output_done  <= 1'b0;
            active_n     <= {INDEX_W{1'b0}};
            output_index <= {INDEX_W{1'b0}};
        end
        else begin

            // output_done 默认只维持一个时钟周期
            output_done <= 1'b0;

            // =================================================================
            // 空闲状态
            // =================================================================

            if (!output_busy) begin

                // -------------------------------------------------------------
                // u_hat 写入
                // -------------------------------------------------------------
                //
                // 只在输出空闲时允许写入。
                //
                // output_start 与 wr_en 同周期出现时，两项操作均会执行。
                // -------------------------------------------------------------

                if (wr_en) begin
                    uhat_mem[wr_index] <= wr_bit;
                end

                // -------------------------------------------------------------
                // 启动串行输出
                // -------------------------------------------------------------

                if (output_start) begin
                    active_n     <= (11'd1 << n_log);
                    output_index <= {INDEX_W{1'b0}};
                    output_busy  <= 1'b1;
                end
            end

            // =================================================================
            // 串行输出状态
            // =================================================================

            else begin

                // 只有 valid 和 ready 同时有效时才推进输出索引
                if (u_fire) begin

                    // 当前是最后一个输出
                    if (output_index == (active_n - 1'b1)) begin
                        output_busy  <= 1'b0;
                        output_done  <= 1'b1;
                        output_index <= {INDEX_W{1'b0}};
                    end
                    else begin
                        output_index <= output_index + 1'b1;
                    end
                end
            end
        end
    end

endmodule

---

### ChatGPT

你这个目标已经明确：Vivado、列表大小默认 $L=4$ 且参数化、优先速度。基于这个目标，我需要修正前面的建议：CRC并非不能第一版加入，现有 DFS 控制器也不是必须原样保留。
1. 为什么之前建议第一版不加入 CRC
不是因为 CRC 不重要，而是因为 CRC 和 SCL 树译码属于两个相对独立的问题。
普通 SCL 最后直接选择路径度量最小的路径：
$\hat l=\arg\min_l PM_l$
CA-SCL 则先检查每条幸存路径的 CRC：


有路径通过 CRC：从通过 CRC 的路径中选择 PM 最小者；


没有路径通过 CRC：退化为选择全局 PM 最小者。


CRC 主要影响的是最终路径选择，不改变前面的 $f/g$ 运算、路径分裂和 $2L\rightarrow L$ 剪枝过程。
此前建议暂不加入，主要有两个工程原因：


先验证 SCL 路径分裂、PM 更新、路径复制和剪枝是否正确，便于定位错误；


你暂时没有提供 CRC 的长度、多项式、初始值、输入位序及编码端处理方式。


但你的目标是完整升级，因此现在更合理的方案是：从一开始就预留可参数化 CRC，使用参数决定普通 SCL 或 CA-SCL。
例如：
verilogparameter integer LIST_SIZE = 4;parameter integer CRC_EN    = 0;parameter integer CRC_W     = 24;parameter [31:0]  CRC_POLY  = 32'h01864CFB;parameter [31:0]  CRC_INIT  = 32'h00000000;
其中：
Plain textCRC_EN = 0：普通SCLCRC_EN = 1：CA-SCL
不过 CRC 多项式不能直接替你决定，需要与编码端完全一致。
还要注意你当前的：
veriloginput wire [10:0] k_cfg;
表示的是非冻结位总数。加入 CRC 后通常应满足：
$K_{\mathrm{cfg}}=K_{\mathrm{payload}}+K_{\mathrm{CRC}}$
例如有效数据 128 bit、CRC 16 bit，那么：
Plain textk_cfg = 144
frozen_gen 应按照 144 个非冻结位生成冻结集合。

2. 为什么不一定要保留 DFS 控制器
确实不一定。
SC 的比特判决存在严格的数据依赖，因此从算法意义上，仍然需要按照“先左子树、后右子树”的顺序处理。但这不等于必须保留你现在这个单路径、单 PE、逐元素 DFS 控制器。
当前控制器的执行方式大致是：
Plain text节点PH_F逐元素计算→ 下降左子树→ 叶节点判决→ 返回→ 节点PH_G逐元素计算→ 下降右子树→ beta合并
这个结构适合低资源 SC，但直接扩展为：
Plain textelement 0 path 0element 0 path 1element 0 path 2element 0 path 3element 1 path 0...
虽然最容易实现，但周期数基本会增加到原来的 $L$ 倍，不符合你“优先高速度”的要求。
更适合你的结构
建议保留的只是树遍历顺序和 phase 调度思想，不是原控制器本身。新的控制器应改成：
Plain text共享树调度器       │       ├── path 0 PE + 存储Bank       ├── path 1 PE + 存储Bank       ├── path 2 PE + 存储Bank       └── path 3 PE + 存储Bank
即所有有效路径并行执行同一个节点操作。
原来的：
verilogcur_depthelement_indexphase[]merge_second_write
仍然可以作为共享调度状态，但要增加：
verilogactive_path_maskpath_metric[]path_bank_map[]candidate_parent[]candidate_bit[]
因此更准确地说：

不保留当前 sc_controller 原样，只复用其中正确的树地址计算和 PH_F/PH_G/PH_C 调度逻辑，重新设计成 SCL 共享树调度器。


3. 根据“高速度优先”确定的总体架构
建议默认参数为：
verilogparameter integer LIST_SIZE   = 4;parameter integer PE_PER_PATH = 1;parameter integer PM_W        = INT_W + MAX_LOG + 2;parameter integer CRC_EN      = 0;
其中总 PE 数量为：
$PE_{\mathrm{TOTAL}}=LIST\_SIZE\times PE\_PER\_PATH$
默认：
Plain textLIST_SIZE   = 4PE_PER_PATH = 1总PE数量    = 4
即 4 条路径并行，而不是一个 PE 在 4 条路径之间轮询。
这样做有几个优势：


SCL 周期数不会简单增加到 SC 的 4 倍；


每条路径只需要一组双读端口；


便于 Vivado 使用独立 BRAM Bank；


将来可以把 LIST_SIZE 改为 2 或 8；


后续还可以加入 Fast-SSCL 节点加速。


建议第一阶段支持：
Plain textLIST_SIZE = 1、2、4、8
最好限制为 2 的整数次幂，方便使用 Bitonic 排序网络。

4. LIST_SIZE 参数和运行时配置的区别
你说“设置成参数方便修改”，可以采用综合参数：
verilogparameter integer LIST_SIZE = 4;
修改后重新综合：
verilog.LIST_SIZE(8)
需要注意：Verilog 参数是综合期配置，FPGA 下载比特流后不能动态改成其他列表大小。
如果以后还希望运行时在 $L=2/4/8$ 之间切换，可以采用：
verilogparameter integer LIST_MAX = 8;input wire [3:0] list_size_cfg;
硬件按照 LIST_MAX=8 综合，运行时只启用其中一部分路径。但资源消耗仍然按照 8 条路径计算。
现阶段建议使用综合参数：
verilogparameter integer LIST_SIZE = 4;
结构更清楚，时序也更容易优化。

5. 路径度量更新
你当前 LLR 定义是：
verilogllr >= 0  → 硬判决0llr < 0   → 硬判决1
可以采用硬件友好的近似路径度量：
$PM'=
\begin{cases}
PM, & u=\operatorname{HD}(LLR)\\
PM+|LLR|, & u\neq\operatorname{HD}(LLR)
\end{cases}$
对于每条路径，在信息位产生两个候选：
$PM_0=PM+
\begin{cases}
|LLR|,&LLR<0\\
0,&LLR\ge0
\end{cases}$
$PM_1=PM+
\begin{cases}
0,&LLR<0\\
|LLR|,&LLR\ge0
\end{cases}$
冻结位不分裂，但也必须更新 PM：
$PM_{\mathrm{frozen}}=PM_0$
也就是说，当冻结位被强制判为 0，但当前 LLR 强烈倾向于 1 时，该路径应该受到惩罚。
建议 PM 位宽：
verilogparameter integer PM_W = INT_W + MAX_LOG + 2;
在当前参数下：
Plain textINT_W   = 10MAX_LOG = 10PM_W    = 22
足够覆盖最多 1024 次度量累加，并留出裕量。

6. 高速剪枝结构
当 $L=4$ 时，每个信息位产生 8 个候选：
Plain textpath0-u0  path0-u1path1-u0  path1-u1path2-u0  path2-u1path3-u0  path3-u1
需要从 8 个 PM 中选最小的 4 个。
速度优先时不建议使用逐项循环排序，而应使用：
Plain text参数化 Bitonic sorting network
对 $L=4$：
Plain text8输入 → 流水比较交换网络 → 4个最优候选
排序项需要同时携带：
verilogcandidate_pmcandidate_parent_pathcandidate_bitcandidate_valid
为了提高 Vivado 的最高频率，可以在比较网络中插入流水寄存器。这样信息位处理会有固定的几拍排序延迟，但时钟频率明显更容易提高。

7. 不能在路径分裂时复制整个存储器
你目前的三个存储器都是单路径存储：
verilogllr_mem  [0:2046]beta_mem [0:2046]uhat_mem [0:1023]
直接改成：
verilogllr_mem[path][addr]beta_mem[path][addr]uhat_mem[path][index]
逻辑上是正确的，但如果在路径分裂时完整复制父路径，会产生严重问题。
每次复制一条路径需要搬运：
Plain textLLR：2047 × 10 bitbeta：2047 bitu_hat：1024 bit
如果串行复制，速度会非常慢；如果单周期并行复制，则会形成巨大的多路选择和扇出。
因此建议采用：
写时复制 Copy-on-Write
路径分裂时只复制路径的元数据：
verilogpath_metricCRC状态各层存储Bank映射父路径编号
而不是复制整个 LLR/beta 存储器。
只有当新路径即将写入一个与其他路径共享的 Bank 时，才分配一个新 Bank，并复制对应层的数据。
具体可以维护：
verilogalpha_bank_map[path][stage]beta_bank_map [path][stage]bank_ref_count[stage][bank]
路径分裂时：
Plain text子路径继承父路径的Bank编号引用计数加1
后续写操作发生时：
Plain text引用计数=1：直接写引用计数>1：分配新Bank，复制该层，再写入
这是高速 SCL 中非常关键的设计，否则路径复制会成为最大瓶颈。

8. 当前存储模块需要怎样修改
sc_llr_mem
当前使用组合读取：
verilogassign rd_data_a = llr_mem[rd_addr_a];assign rd_data_b = llr_mem[rd_addr_b];
这种写法在 Vivado 中很可能被实现为：


LUTRAM；


大量寄存器和多路选择器；


不利于较大规模、高频率设计。
速度优先且考虑后续 FPGA 适配，建议改为：
Plain text同步双端口读取每条并行路径一个LLR Bank读延迟1拍控制器增加READ和WRITE流水状态
例如：
verilogalways @(posedge clk) begin    rd_data_a <= llr_mem[rd_addr_a];    rd_data_b <= llr_mem[rd_addr_b];    if (wr_en)        llr_mem[wr_addr] <= wr_data;end
这样更容易推断 Block RAM。
需要增加类似属性：
verilog(* ram_style = "block" *)reg signed [INT_W-1:0] llr_mem [0:MEM_DEPTH-1];
但是否最终使用 BRAM、LUTRAM 或 UltraRAM，需要拿到具体 FPGA 型号后再决定。
sc_beta_mem
beta 每条路径只有 2047 bit，$L=4$ 时总计约 8 kbit。可以先采用：


分路径 Bank；


分布式 RAM 或寄存器；


后续再视时序决定是否加入写时复制。


sc_uhat_mem
$L=4,N=1024$ 时总共只有：
$4\times1024=4096\text{ bit}$
可以先保存为多路径阵列：
verilogreg uhat_mem [0:LIST_SIZE-1][0:NMAX-1];
最后根据 best_path 输出：
verilogassign u_bit = uhat_mem[best_path][output_index];
后续若 $L=8/16$，再考虑使用路径历史 RAM 或指针回溯结构。

9. CRC 最适合的高速实现方法
为了避免译码结束后再逐条扫描全部信息位，建议为每条路径维护一个 CRC 状态：
verilogreg [CRC_W-1:0] crc_state [0:LIST_SIZE-1];
每遇到一个非冻结位：
Plain text候选u=0：由父路径CRC状态更新0候选u=1：由父路径CRC状态更新1
候选剪枝以后，CRC 状态随幸存路径一起提交。
译码结束时：
Plain textcrc_state[path]满足校验条件 → crc_pass[path]=1
这样最终路径选择只需要比较：
Plain textCRC通过标志路径度量
不需要再额外消耗 $L\times K$ 拍做 CRC 扫描。
不过这要求你提供：
Plain textCRC宽度CRC多项式初始值最终异或值是否反射输入是否反射输出数据位输入顺序CRC位在消息中的排列顺序
还需要编码端代码，才能保证译码端 CRC 与编码端完全一致。

10. 你提供的现有代码中需要顺便修正的地方
u_index 不应写死为 11 位
sc_datapath 和 sc_uhat_mem 中目前为：
verilogoutput wire [10:0] u_index
应改成：
verilogoutput wire [INDEX_W-1:0] u_index
sc_llr_mem 注释与实际结构不一致
注释写的是：
Plain text每层预留 NMAX 个位置，共 MAX_LOG+1 层
但实际使用的是：
verilogMEM_DEPTH = 2 * NMAX - 1;
配合 depth_base() 使用的是压缩树工作区，而不是每层 NMAX 个位置。应修改注释，避免后续 SCL 存储改造时产生误解。
小码长测试配置不一致
frozen_gen 注释说支持更小码长测试，但 sc_decoder_core 中：
verilogassign cfg_n_valid =    (n_log_cfg >= 4'd6) &&    (n_log_cfg <= MAX_LOG_CODE);
实际上禁止了 $N<64$。如果需要用 $N=8/16/32$ 做 SCL 回归测试，建议改为：
verilogassign cfg_n_valid =    (n_log_cfg >= 4'd1) &&    (n_log_cfg <= MAX_LOG_CODE);
综合正式版本时再根据要求限制为 6～10。
frozen_gen 目前实际上只适配 NMAX=1024
verilogwire [9:0] q;
把可靠度索引固定为 10 位，因此 NMAX 参数并非完全通用。当前固定 NMAX=1024 没有问题，但后续最好改成：
verilogwire [RW-1:0] q;
前提是可靠度 ROM 接口同步参数化。

11. 我建议最终采用的版本
基于你当前要求，建议目标设计确定为：
Plain text默认列表大小：L=4L设置方式：综合参数LIST_SIZE工具：Vivado路径执行：L条路径并行每路径PE：默认1个总PE：默认4个路径度量：Min-Sum近似PM剪枝：流水Bitonic排序网络LLR存储：同步双端口、分Bank、写时复制beta存储：分路径/分层Banku_hat存储：L×N多路径存储CRC：参数化可选，接口从第一版预留控制器：重构为共享SCL树调度器后续高速优化：Fast-SSCL节点识别
目前核心代码已经基本齐全。为了开始生成完整可仿真的 SCL 工程，还需要：
Plain text1. polar_reliability_rom.v2. 当前完整testbench或sc_test_sequencer.v3. 编码器代码4. 一组已知正确的LLR输入和SC输出5. CRC编码代码或CRC具体参数
没有 CRC 参数时，可以先把 CRC_EN=0 完成普通 SCL，但 CRC 接口和路径 CRC 状态会在架构中预留，后续不需要推翻主体结构。

---

### User

1.你要哪几个的代码
2.完整tb太长了，你需要tb干什么，你应该自己能根据代码补全tb吧
3.我怎么获取一组已知的正确的LLR和SC输出，直接计算吗
4.CRC24B

---

### ChatGPT

1. 现在需要哪些代码
frozen_gen.v 已经提供，不需要再发。截图中其余 7 个文件建议全部上传：
Plain textcrc_gen.vcode_block_concat.vpolar_encoder.vpolar_butterfly.vpolar_encode_stream.vpolar_encode_chain_top.vpolar_reliability_rom.v
其中优先级如下：


必须看：crc_gen.v、code_block_concat.v
确认 CRC24B 的位移方向、CRC 比特顺序，以及 K 到底表示“有效数据长度”还是“有效数据+24位CRC”。


必须看：polar_encoder.v、polar_reliability_rom.v
确认信息位装配顺序、Polar 变换方向和可靠度序列是否与译码器完全一致。


建议一起看：polar_encode_chain_top.v、polar_encode_stream.v、polar_butterfly.v
用于确认串行握手、码字输出顺序以及模块之间是否存在比特反转、缓存或流水延迟。


最省事的方式就是：把截图中除 frozen_gen.v 外的其余文件全部上传。

2. 完整 TB 不需要提供
你说得对，我可以根据编码器和译码器接口重新写一套完整自检 TB，不需要你把原 TB 全部发过来。
原 TB 的价值主要是确认一些代码外部约定，例如：


复位保持多少拍；


config_start、block_start 的启动顺序；


LLR 是按 d[0] → d[N-1] 还是反序输入；


编码器码字输出是否经过比特反转；


u_bit 输出的是完整 $u$、信息位，还是有效载荷。


这些大部分都可以从编码器代码中确认。因此我会重新建立：
Plain texttb_crc24btb_polar_encodertb_sc_decodertb_scl_decodertb_ca_scl_chain
并让 TB 自动完成：
Plain text生成数据→ 添加CRC24B→ Polar编码→ 生成LLR→ SC/SCL译码→ CRC校验→ 自动比较结果

3. 如何获得一组已知正确的 LLR 和 SC 输出
不建议人工计算 $N=64$、$N=1024$ 的完整数据。最可靠的方法是建立一个独立的软件参考模型，自动生成测试向量。
第一阶段：无噪声确定性测试
先选一组载荷，例如：
Plain textN = 64有效载荷 A = 16 bitCRC = 24 bitK = A + 24 = 40 bitL = 4
处理流程为：
$\text{payload}
\rightarrow \text{CRC24B}
\rightarrow \text{信息位序列}
\rightarrow \text{Polar编码}
\rightarrow d[0:N-1]$
然后将码字映射为强可靠度 LLR。
你的译码器约定为：
Plain text正LLR → 比特0负LLR → 比特1
因此可以直接生成：
verilogllr[i] = codeword[i] ? -8'sd64 : 8'sd64;
即：
$LLR_i=
\begin{cases}
+64,&d_i=0\\
-64,&d_i=1
\end{cases}$
LLR_W=8 时，±64 在安全范围内。
无噪声条件下，期望结果非常明确：
Plain textSC输出的完整u_hat = 编码前装配的u信息位提取结果    = payload + CRC24BCRC校验           = 通过重新编码u_hat     = 原码字d
这组数据最适合先验证：


冻结位位置；


编码与译码比特顺序；


$f/g$ 运算；


beta 合并；


u_hat 自然索引；


CRC 拼接顺序。


不要只测全零数据，因为全零数据无法有效暴露位序和 XOR 路径错误。建议至少测试：
Plain text全零数据全一数据010101...交替数据固定随机数据
第二阶段：带噪声的软件黄金向量
BPSK 映射可设为：
$s_i=
\begin{cases}
+1,&d_i=0\\
-1,&d_i=1
\end{cases}$
加入高斯噪声：
$y_i=s_i+n_i$
浮点 LLR 为：
$LLR_i=\frac{2y_i}{\sigma^2}$
之后缩放、四舍五入并截断到 8 位：
Plain textllr_q = round(llr_float × scale)llr_q限制在[-128,127]
软件参考 SC 和 CA-SCL 会输出：
Plain textllr_input.memexpected_u.memexpected_info.memexpected_payload.memexpected_path_metric.memexpected_crc_pass.mem
TB 用 $readmemh 或 $readmemb 读取这些文件进行自动比较。
这比直接拿当前 SC RTL 的结果作为标准更可靠，因为软件模型和 RTL 是两套独立实现，不容易出现“同一种错误互相验证”的情况。

4. CRC24B 已明确，但仍要看 crc_gen.v
3GPP CRC24B 的生成多项式是：
$g_{\mathrm{CRC24B}}(D)
=
D^{24}+D^{23}+D^6+D^5+D+1$
采用省略最高次项的常见表示时，对应低 24 位掩码通常写作：
verilog24'h800063
3GPP TS 38.212 规定 CRC24B 长度为 24，并采用系统形式附加 CRC 比特。ETSI
但是仅知道“CRC24B”仍不足以直接连接 CA-SCL，因为必须与现有 crc_gen.v 确认：
Plain text输入是MSB-first还是LSB-first移位寄存器向左还是向右CRC比特按什么顺序输出初始值是多少是否有最终异或payload与CRC如何拼接K是否包含24位CRC
对于你目前的编码链，大概率应当是：
$K=A+24$
其中：


$A$：原始有效载荷长度；


24：CRC24B；


$K$：放入 Polar 非冻结位置的总比特数。


但在看到 code_block_concat.v 和 crc_gen.v 前，不应直接写死。
下一步
直接上传截图中除 frozen_gen.v 外的 7 个 Verilog 文件。拿到后可以先完整还原编码链的位序和 CRC24B 规则，再确定 CA-SCL 的路径 CRC 更新方式、接口和自检测试向量格式。

---

### User

// =============================================================================
// code_block_concat.v -- 码块级联 (T/XS 10002-2025  6.9.1.5)
// -----------------------------------------------------------------------------
// 将各码块编码后的比特序列 f_r(0..E_r-1) 按码块顺序串行拼接为输出 g_k:
//   k=0; for r=0..C-1 { for j=0..E_r-1 { g[k]=f_r(j); k++; } }
// 逐块装入(s_load, 并行码块 s_blk, 有效长 s_elen), 串行输出拼接流(m_valid/m_bit),
// k_count 给出输出比特序号 k. s_ready=1 时可装入下一块; done 在最后一块输出完脉冲.
// =============================================================================
module code_block_concat #(
    parameter integer NMAX = 1024
)(
    input  wire             clk,
    input  wire             rst_n,
    // 装入一个码块
    input  wire             s_load,       // s_ready=1 时的装入脉冲
    input  wire [NMAX-1:0]  s_blk,        // 码块比特 f_r, bit j = f_r(j)
    input  wire [10:0]      s_elen,       // 该块有效比特数 E_r
    input  wire             s_last,       // 是否最后一块
    output reg              s_ready,       // 可接收下一块
    // 串行拼接输出
    output reg              m_valid,
    output reg              m_bit,
    output reg [31:0]       k_count,
    output reg              done          // 最后一块输出完毕 (单拍)
);
    reg [NMAX-1:0] blk;
    reg [10:0]     elen, j;
    reg            last_r;
    localparam IDLE=1'b0, EMIT=1'b1;
    reg st;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_ready<=1'b1; m_valid<=1'b0; m_bit<=1'b0; k_count<=32'd0;
            done<=1'b0; j<=11'd0; st<=IDLE;
        end else begin
            done<=1'b0; m_valid<=1'b0;
            case (st)
                IDLE: begin
                    s_ready <= 1'b1;
                    if (s_load) begin
                        blk<=s_blk; elen<=s_elen; last_r<=s_last;
                        j<=11'd0; s_ready<=1'b0; st<=EMIT;
                    end
                end
                EMIT: begin
                    m_valid <= 1'b1;
                    m_bit   <= blk[j[9:0]];        // g[k] = f_r(j)  (j<=1023, 取低10位索引)
                    k_count <= k_count + 1'b1;
                    if (j == elen-1) begin
                        if (last_r) done <= 1'b1;
                        st <= IDLE;                // 本块输出完, 回 IDLE 等下一块
                    end else begin
                        j <= j + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
// =============================================================================
// crc_gen.v  --  串行 LFSR 循环冗余校验 (T/XS 10002-2025  6.9.1.1 / 6.10.1)
// -----------------------------------------------------------------------------
// 6.9.1.3 带CRC的码块分段: 每个码块用生成多项式 g_CRC24B(D) 计算 24 比特 CRC.
// 采用系统码: 多项式 a0*D^(A+L-1)+...+a_{A-1}*D^L + p0*D^(L-1)+...+p_{L-1} 可被 g(D) 整除.
// 输入比特按 MSB(a0) 优先逐比特送入; 送完 A 个消息比特后 crc 即为 L 位校验.
//
// 生成多项式 (摘自 spec 6.10.1, 仅取低 L 位, 隐含最高次 D^L):
//   g_CRC24B(D)=D24+D23+D21+D20+D17+D15+D13+D12+D8+D4+D2+D+1  -> POLY=24'hB2B117
//   (亦支持 CRC24A=24'h00065B / CRC12=12'h80F / CRC32=32'h04C11DB7, 改参数即可)
// 生成种子 seed: 寄存器初值. 码块 CRC24B 的种子为 0x555555 (spec 6.10.1).
// =============================================================================
module crc_gen #(
    parameter integer WIDTH = 24,
    parameter [WIDTH-1:0] POLY = 24'hB2B117      // 默认 CRC24B
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             load,       // 置1: 用 seed 装载寄存器 (每块开始前)
    input  wire [WIDTH-1:0] seed,       // 生成种子 (CRC24B 码块: 0x555555)
    input  wire             en,         // 置1: 送入一个消息比特 din
    input  wire             din,        // 消息比特, MSB(a0) 优先
    output wire [WIDTH-1:0] crc         // 当前 CRC 余数
);
    reg  [WIDTH-1:0] r;
    wire fb = r[WIDTH-1] ^ din;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      r <= {WIDTH{1'b0}};
        else if (load)   r <= seed;
        else if (en)     r <= {r[WIDTH-2:0], 1'b0} ^ (fb ? POLY : {WIDTH{1'b0}});
    end

    assign crc = r;
endmodule
// =============================================================================
// polar_butterfly.v -- 纯蝶形编码 (档案 3.4 polar_encode_simple, 可综合)
// -----------------------------------------------------------------------------
// 只做 d = u * G_N (GF(2)) 的迭代蝶形, 不含 build_u_vector 的信息位散布网络
// (散布在顶层 polar_encode_full 里以移位寄存器串行完成 —— 正是档案把
//  build_u_vector 与 polar_encode_simple 分成两个函数的原因)。
//
// ★ 为什么单独抽出来: 导师确认版 polar_encoder.v 把"散布 + 蝶形"合在一个模块,
//   当 N=1024 时其内部散布网络在 Vivado 分层综合下无法塌缩, 占 ~175k LUT。
//   蝶形本身只是 XOR, 便宜; 把散布拿到外面串行做, 编码器就只剩蝶形 (~数千 LUT)。
//   本模块蝶形逻辑与确认版逐字相同, 仅去掉 u_packed 那段; 确认版原封不动保留。
//
// 运行时可变 N: 固定 log2(NMAX) 级蝶形网络, 编码 N=2^n_log 的码块时只施加前
//   n_log 级 (stage 0..n_log-1); u 的有效块须"低位对齐"在 u[0..N-1], 高位为 0,
//   则前 n_log 级不会把高位混入低 N 位, 低 N 位即为码字 (与 polar_encoder_nvar
//   验证过的可变 N 蝶形同理)。
//
// 时延 = n_log + 1 拍; 握手: start 在 busy=0 被接受; done 单拍脉冲。
// =============================================================================
module polar_butterfly #(
    parameter integer NMAX = 1024
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire [3:0]       n_log,      // log2(N)
    input  wire [NMAX-1:0]  u,          // 预装配 u (低 N 位有效, u[k]=第 k 个输入, 高位0)
    output reg              busy,
    output reg              done,
    output reg [NMAX-1:0]   d           // 码字 (低 N 位有效)
);
    localparam integer SMAX = $clog2(NMAX);
    localparam integer CW   = (SMAX <= 1) ? 1 : $clog2(SMAX+1);

    reg  [NMAX-1:0] x;
    reg  [CW-1:0]   stage;
    wire [NMAX-1:0] stage_net [0:SMAX-1];

    genvar gs, gi, gj;
    generate
        for (gs = 0; gs < SMAX; gs = gs + 1) begin : g_stage
            localparam integer M = (1 << gs);
            for (gi = 0; gi < NMAX; gi = gi + 2*M) begin : g_grp
                for (gj = 0; gj < M; gj = gj + 1) begin : g_pair
                    assign stage_net[gs][gi+gj]   = x[gi+gj] ^ x[gi+gj+M];
                    assign stage_net[gs][gi+gj+M] = x[gi+gj+M];
                end
            end
        end
    endgenerate

    wire [NMAX-1:0] x_next  = stage_net[stage];
    wire [CW-1:0]   last_st = n_log - 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            done  <= 1'b0;
            stage <= {CW{1'b0}};
            x     <= {NMAX{1'b0}};
            d     <= {NMAX{1'b0}};
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                x     <= u;
                stage <= {CW{1'b0}};
                busy  <= 1'b1;
            end else if (busy) begin
                x <= x_next;
                if (stage == last_st) begin
                    d    <= x_next;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    stage <= stage + 1'b1;
                end
            end
        end
    end
endmodule
// =============================================================================
// polar_encode_chain.v -- 完整信道编码链 (T/XS 10002-2025  6.9, 查表全规则)
//                          串行瘦身版 (v2, 综合顶层)
// -----------------------------------------------------------------------------
// ★ 综合顶层 (Vivado top). 完整实现 spec 6.9 两条路径, 协议表格全部内置:
//
// [无线帧类型3/4] 6.9.1.3 带CRC的码块分段 + 6.9.1.1 码块CRC24B:
//   - B <= Kcb: 单块, 无码块CRC (L=0);  Kcb = 1024R (速率适配表 1024 列)
//   - B >  Kcb: C=⌈B/(Kcb-24)⌉ 块, 每块加CRC24B; 满块 K=Kcb 编 N=1024 码率R
//   - 末块 (r=C-1) 进一步细分 (R≠1), U=64(R-1/16):
//       Kr > 16U: 前补0至 1024R, 编 N=1024 码率R
//       否则 q=⌈Kr/U⌉, 前补0至 qU:
//         q=16: 编 N=1024, K=16U (码率 R-1/16)
//         q≤15: q 的二进制 b3..b0 对应是否用 512/256/128/64 码长,
//               各块 K=N(R-1/16) (即表23 对应列), 按 512→64 顺序切分
//     (以上规则已逐行对照 spec 附录A 表A.1: 分块组合与 Padding 完全一致)
//
// [无线帧类型2] 6.9.1.2 不带CRC的码块分段 (查表):
//   - B > 1920R: N1024=⌊(B-904R)/1024R⌋, Km=B-N1024·1024R; 否则 N1024=0, Km=B
//   - index=⌊(Km-1)/128R⌋ 查【表20】得 N512/N256/N128 (index>14 按14, 见假设③)
//   - N64=⌈(Km-ΣN·K_N)/K64⌉, K 值查【表24】; 块序 1024→512→256→128→64
//
// 内置协议表 (均为显式查表, 与协议逐格对照):
//   表22 (MCS→编码速率R), 表20 (类型2 分段表格),
//   表23 (类型3/4 末块细分 512/256/128/64 的 K 值, 码率R-1/16),
//   表24 (类型2 512/256/128/64 的 K 值)。 码长1024 的 K = 1024R 由 K1024 给出。
// 分段后: 6.9.1.4 极化编码 (附录C可靠度序列) → 6.9.1.5 码块级联 串行输出.
//
// ★ v2 瘦身 (与老师确认代码融合, 修 Vivado F7 Mux 爆炸):
//   旧版(存档 legacy_xingshan/)为全并行: msg_l[mp] 2048:1 变址读、info_reg[i] 变址写、
//   编码器内部信息位散布网络 —— 在 Vivado 实现阶段 F7 Mux 需 87339 > 器件 50700。
//   本版全串行数据通路, 上述三处全部消除:
//   - 消息读取: msg_sh 移位寄存器, 每拍只看 msg_sh[0] (零变址 mux);
//   - u 装配 (信息位散布): u_sh 移位寄存器逐位串行装配, 冻结位置0/信息位取流
//     (fz_sh 冻结掩码同拍同步移位), 零组合散布网络;
//   - 蝶形: 单个 polar_butterfly —— 蝶形逻辑与**老师已确认的 polar_encoder.v 逐字
//     相同**, 仅不含其内部散布网络 (该网络 N=1024 时在 Vivado 分层综合下爆 ~175k
//     LUT, 已实测); 确认版原封不动保留在库中单独测试, 不进综合数据通路;
//   - 末块 CRC 不再预扫描: V 序列按序消费, 消息位随取随喂 CRC, 到 CRC 区时值已就绪;
//   - 全链变址 mux 仅剩: u_bottom 对齐 (5选1) + 级联块内读 (单个 N:1) 两处。
//   分段/查表状态机与旧版逐字一致 (协议语义零改动), 由整链 TB 黄金模型交叉验证。
//
// 文档化假设: ①末块多码长按 512→256→128→64 顺序顺次取比特;
//   ②类型2 末尾不足位在末块块首补0; ③表20 index>14 钳位为14
// 补0均为"前补": 序列 = 0^pad ‖ 消息 ‖ CRC;  msg[0]=第一比特
// 全部除法/取整以迭代减法实现 (无变量除法, Vivado 综合友好)
// =============================================================================
module polar_encode_chain #(
    parameter integer NMAX    = 1024,
    parameter integer MSG_MAX = 2048       // 支持的最大输入信息比特数
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [MSG_MAX-1:0]   msg,       // 输入信息比特, msg[0]=首比特
    input  wire [15:0]          B,         // 信息比特总长
    input  wire [3:0]           mcs,       // 表22 调制编码方式索引 0..12
    input  wire                 ftype2,    // 1=无线帧类型2(6.9.1.2); 0=类型3/4(6.9.1.3)
    input  wire [23:0]          crc_seed,  // 码块CRC24B生成种子 (广播类: 0x555555)
    output reg                  busy,
    output reg                  done,      // 整链输出完毕 (单拍)
    output wire                 m_valid,   // 级联后串行输出
    output wire                 m_bit,
    output wire [31:0]          k_count,
    output reg  [7:0]           cb_count   // 本次产生的码块总数 (观测/校验)
);
    // ---------------- 协议表格 ----------------
    // 表22: MCS -> r16 (= 编码速率R × 16; 调制方式与信道编码无关)
    function [4:0] tab22_r16;
        input [3:0] m;
        case (m)
            4'd0, 4'd2:  tab22_r16 = 5'd4;    // R=1/4  (BPSK/QPSK)
            4'd1, 4'd3:  tab22_r16 = 5'd6;    // R=3/8
            4'd4:        tab22_r16 = 5'd8;    // R=1/2
            4'd5, 4'd9:  tab22_r16 = 5'd10;   // R=5/8
            4'd6, 4'd10: tab22_r16 = 5'd12;   // R=3/4
            4'd7, 4'd11: tab22_r16 = 5'd14;   // R=7/8
            4'd8, 4'd12: tab22_r16 = 5'd16;   // R=1
            default:     tab22_r16 = 5'd8;    // 非法MCS按1/2 (spec 仅 0..12)
        endcase
    endfunction

    // 表20: index(0..14) -> {N512[1:0], N256[1:0], N128[1:0]}
    function [5:0] tab20;
        input [3:0] idx;
        case (idx)
            4'd0:  tab20 = {2'd0,2'd0,2'd0};   4'd1:  tab20 = {2'd0,2'd0,2'd1};
            4'd2:  tab20 = {2'd0,2'd0,2'd2};   4'd3:  tab20 = {2'd0,2'd1,2'd1};
            4'd4:  tab20 = {2'd0,2'd1,2'd2};   4'd5:  tab20 = {2'd0,2'd2,2'd1};
            4'd6:  tab20 = {2'd0,2'd2,2'd2};   4'd7:  tab20 = {2'd1,2'd1,2'd1};
            4'd8:  tab20 = {2'd1,2'd1,2'd2};   4'd9:  tab20 = {2'd1,2'd2,2'd1};
            4'd10: tab20 = {2'd1,2'd2,2'd2};   4'd11: tab20 = {2'd2,2'd1,2'd1};
            4'd12: tab20 = {2'd2,2'd1,2'd2};   4'd13: tab20 = {2'd2,2'd2,2'd1};
            default: tab20 = {2'd2,2'd2,2'd2}; // idx=14 (及钳位)
        endcase
    endfunction

    // 表23: 类型3/4 末块细分 速率适配 K 值 (码率 R-1/16); nsel: 0=码长512, 1=256, 2=128, 3=64
    //   数值直接照抄 spec 表23 (第一表格) 原格, 便于逐格对照; 等价于 N×(R-1/16)。
    //   (码长1024 列 = 1024R, 与满块相同, 由 K1024 给出, 不在本函数内。)
    function [9:0] tab23;
        input [4:0] r16v;
        input [1:0] nsel;
        case ({r16v, nsel})
            {5'd4, 2'd0}: tab23 = 10'd96;   {5'd4, 2'd1}: tab23 = 10'd48;   // R=1/4
            {5'd4, 2'd2}: tab23 = 10'd24;   {5'd4, 2'd3}: tab23 = 10'd12;
            {5'd6, 2'd0}: tab23 = 10'd160;  {5'd6, 2'd1}: tab23 = 10'd80;   // R=3/8
            {5'd6, 2'd2}: tab23 = 10'd40;   {5'd6, 2'd3}: tab23 = 10'd20;
            {5'd8, 2'd0}: tab23 = 10'd224;  {5'd8, 2'd1}: tab23 = 10'd112;  // R=1/2
            {5'd8, 2'd2}: tab23 = 10'd56;   {5'd8, 2'd3}: tab23 = 10'd28;
            {5'd10,2'd0}: tab23 = 10'd288;  {5'd10,2'd1}: tab23 = 10'd144;  // R=5/8
            {5'd10,2'd2}: tab23 = 10'd72;   {5'd10,2'd3}: tab23 = 10'd36;
            {5'd12,2'd0}: tab23 = 10'd352;  {5'd12,2'd1}: tab23 = 10'd176;  // R=3/4
            {5'd12,2'd2}: tab23 = 10'd88;   {5'd12,2'd3}: tab23 = 10'd44;
            {5'd14,2'd0}: tab23 = 10'd416;  {5'd14,2'd1}: tab23 = 10'd208;  // R=7/8
            {5'd14,2'd2}: tab23 = 10'd104;  {5'd14,2'd3}: tab23 = 10'd52;
            default:      tab23 = 10'd0;    // R=1 不细分, 不会取用
        endcase
    endfunction

    // 表24: 类型2 速率适配 K 值; nsel: 0=码长512, 1=256, 2=128, 3=64
    function [9:0] tab24;
        input [4:0] r16v;
        input [1:0] nsel;
        case ({r16v, nsel})
            {5'd10,2'd0}: tab24 = 10'd316;  {5'd10,2'd1}: tab24 = 10'd156;
            {5'd10,2'd2}: tab24 = 10'd74;   {5'd10,2'd3}: tab24 = 10'd36;
            {5'd12,2'd0}: tab24 = 10'd382;  {5'd12,2'd1}: tab24 = 10'd189;
            {5'd12,2'd2}: tab24 = 10'd90;   {5'd12,2'd3}: tab24 = 10'd45;
            {5'd14,2'd0}: tab24 = 10'd446;  {5'd14,2'd1}: tab24 = 10'd221;
            {5'd14,2'd2}: tab24 = 10'd106;  {5'd14,2'd3}: tab24 = 10'd53;
            default:      tab24 = 10'd0;    // 类型2 仅支持表24所列速率
        endcase
    endfunction

    // n∈{0,1,2} 与 K 的乘积 (类型2 rem 计算用)
    function [10:0] mul012;
        input [1:0] c;
        input [9:0] K;
        case (c)
            2'd0:    mul012 = 11'd0;
            2'd1:    mul012 = {1'b0, K};
            default: mul012 = {K, 1'b0};
        endcase
    endfunction

    // ---------------- 状态机 ----------------
    localparam [4:0]
        S_IDLE      = 5'd0,
        SB_FULL_INIT= 5'd1,  SB_LAST_INIT= 5'd2,  SB_QINIT    = 5'd3,
        SB_QLOOP    = 5'd4,  SB_SUBNEXT  = 5'd5,
        SA_INIT     = 5'd6,  SA_N1024    = 5'd7,  SA_IDX      = 5'd8,
        SA_REM      = 5'd9,  SA_N64      = 5'd10, SA_BLKNEXT  = 5'd11,
        SA_PAD      = 5'd12,
        S_FZ        = 5'd13, S_ASM       = 5'd14, S_ENC       = 5'd15,
        S_CATW      = 5'd16, S_ROUTE     = 5'd17, S_DONE      = 5'd18;
    reg [4:0] state;
    localparam [1:0] PH_BFULL=2'd0, PH_BSUB=2'd1, PH_A=2'd2;
    reg [1:0] phase;

    // ---------------- 锁存与派生量 ----------------
    reg  [MSG_MAX-1:0] msg_sh;             // 消息移位寄存器 (消费一位移一位, 零变址 mux)
    reg  [15:0] B_l;
    reg  [15:0] mp;                        // 已消费消息位数 (仅计数, 供类型2 avail)
    reg  [4:0]  r16;
    reg         use_crc;

    wire [10:0] K1024 = {r16, 6'b0};                 // 1024R = 64·r16
    wire [10:0] KmL   = K1024 - 11'd24;              // 满块消息容量 Kcb-24
    wire [6:0]  Uu    = {(r16-5'd1), 2'b0};          // U = 64(R-1/16) = 4(r16-1)
    wire [10:0] U16   = {(r16-5'd1), 6'b0};          // 16U = 64(r16-1)
    // 类型2 门限/常量 (r16 为偶数, 904R=56.5·r16 为整数)
    wire [15:0] r16w    = {11'b0, r16};
    wire [15:0] thr1920 = (r16w << 7) - (r16w << 3);                       // 1920R=120·r16
    wire [15:0] r904    = (r16w << 5) + (r16w << 4) + (r16w << 3) + (r16w >> 1); // 904R
    wire [15:0] r128w   = (r16w << 3);                                     // 128R=8·r16

    // 分段迭代
    reg  [15:0] remaining, tmpx;
    reg  [10:0] Kr;
    reg  [4:0]  qv;
    reg  [3:0]  subsel;                              // {512,256,128,64}
    // 类型2 计数
    reg  [3:0]  c1024;
    reg  [1:0]  c512, c256, c128;
    reg  [5:0]  c64;
    reg  [15:0] km;
    reg  [3:0]  idxA;
    reg  signed [15:0] remA;
    // 当前块
    reg  [10:0] Kblk;
    reg  [3:0]  nlog_blk;
    reg         blk_is_last;

    wire [15:0] avail = B_l - mp;                    // 类型2: 剩余可取消息位

    // ---------------- CRC24B (6.9.1.1 / 6.10.1) ----------------
    // 块虚拟序列 V = 0^padv ‖ 消息(Kmsg_cur位) ‖ CRC24(crc_on 时); 按 vpos 顺序消费。
    // 消息位随消费同步喂入 CRC (crc_en), 消费到 CRC 区时余数已就绪 —— 无需旧版的
    // 末块预扫描 (类型3/4 末块细分跨多个子块时 vpos/CRC 跨子块连续, 语义不变)。
    reg  [10:0] padv;                                // V 前补0 位数
    reg  [10:0] Kmsg_cur;                            // V 中消息位数
    reg         crc_on;                              // V 尾部是否有 24 位块 CRC
    reg  [10:0] vpos;                                // V 消费位置

    wire        crc_load = (state == SB_FULL_INIT) || (state == SB_LAST_INIT);
    wire        crc_en, crc_din;
    wire [23:0] crc_val;
    crc_gen #(.WIDTH(24), .POLY(24'hB2B117)) u_crc (
        .clk(clk), .rst_n(rst_n), .load(crc_load), .seed(crc_seed),
        .en(crc_en), .din(crc_din), .crc(crc_val));
    wire [23:0] crc_rev;                             // p_i = crc[23-i] (高位先)
    genvar gc;
    generate for (gc=0; gc<24; gc=gc+1) begin: g_rev
        assign crc_rev[gc] = crc_val[23-gc];
    end endgenerate

    wire [11:0] vend   = {1'b0, padv} + {1'b0, Kmsg_cur};   // 消息区末界 (V 坐标)
    wire        in_pad = (vpos <  padv);
    wire        in_msg = (vpos >= padv) && ({1'b0, vpos} < vend);
    /* verilator lint_off UNUSEDSIGNAL */            // vgap 仅用 [4:0] (CRC 偏移 0..23), 高位不参与
    wire [10:0] vgap   = vpos - vend[10:0];          // CRC 区内: 0..23
    /* verilator lint_on UNUSEDSIGNAL */
    wire        vbit   = in_pad ? 1'b0 : (in_msg ? msg_sh[0] : crc_rev[vgap[4:0]]);

    // ---------------- 冻结集 (6.9.1.4, 附录C 可靠度序列) ----------------
    reg         fg_start;
    /* verilator lint_off UNUSEDSIGNAL */            // fg_busy 观测用, FSM 以 done 驱动
    wire        fg_busy, fg_done;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [NMAX-1:0] fg_frozen;
    frozen_gen #(.NMAX(NMAX)) u_fg (
        .clk(clk), .rst_n(rst_n), .start(fg_start),
        .n_log(nlog_blk), .K(Kblk), .busy(fg_busy), .done(fg_done), .frozen(fg_frozen));

    // ---------------- u 串行装配 (信息位散布, 零组合散布网络) ----------------
    reg [NMAX-1:0] fz_sh;                  // 冻结掩码移位寄存器 (每拍看 [0])
    reg [NMAX-1:0] u_sh;                   // u 移位装配: N 拍后块占据高 N 位
    reg [10:0]     acnt;
    wire [10:0] Nv_blk = 11'd1 << nlog_blk;

    wire        cur_fz = fz_sh[0];
    wire        ubit   = cur_fz ? 1'b0 : vbit;

    assign crc_en  = (state == S_ASM) && !cur_fz && in_msg && crc_on;
    assign crc_din = msg_sh[0];

    // ---------------- 极化编码 (6.9.1.4): 单个纯蝶形 ----------------
    // u_sh 装配后块占据"高 N 位" (u[0] 位于 1024-N); 蝶形要求"低位对齐",
    //   故用 5:1 mux 把高 N 位窗口搬到低 N 位 (nlog_blk 仅 5 种取值, 廉价 5 选 1)。
    wire [NMAX-1:0] u_bottom = (nlog_blk == 4'd9) ? {512'h0, u_sh[1023:512]} :
                               (nlog_blk == 4'd8) ? {768'h0, u_sh[1023:768]} :
                               (nlog_blk == 4'd7) ? {896'h0, u_sh[1023:896]} :
                               (nlog_blk == 4'd6) ? {960'h0, u_sh[1023:960]} :
                                                    u_sh;                   // N=1024
    reg             bf_start;
    wire            bf_done;
    wire [NMAX-1:0] bf_d;
    /* verilator lint_off PINCONNECTEMPTY */          // busy 观测口, FSM 以 done 驱动
    polar_butterfly #(.NMAX(NMAX)) u_bf (
        .clk(clk), .rst_n(rst_n), .start(bf_start),
        .n_log(nlog_blk), .u(u_bottom), .busy(), .done(bf_done), .d(bf_d));
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------- 码块级联 (6.9.1.5) ----------------
    reg             cat_load, cat_last;
    wire            cat_ready, cat_done;
    wire [10:0]     elen = (11'd1 << nlog_blk);      // E_r = N
    code_block_concat #(.NMAX(NMAX)) u_cat (
        .clk(clk), .rst_n(rst_n),
        .s_load(cat_load), .s_blk(bf_d), .s_elen(elen), .s_last(cat_last),
        .s_ready(cat_ready), .m_valid(m_valid), .m_bit(m_bit),
        .k_count(k_count), .done(cat_done));

    // ---------------- 主 FSM ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; phase<=PH_BFULL; busy<=0; done<=0; cb_count<=0;
            msg_sh<=0; B_l<=0; mp<=0; r16<=5'd8; use_crc<=0;
            remaining<=0; tmpx<=0; Kr<=0; qv<=0; subsel<=0;
            c1024<=0; c512<=0; c256<=0; c128<=0; c64<=0;
            km<=0; idxA<=0; remA<=0;
            Kblk<=0; nlog_blk<=4'd6; blk_is_last<=0;
            padv<=0; Kmsg_cur<=0; crc_on<=0; vpos<=0;
            fz_sh<=0; u_sh<=0; acnt<=0;
            fg_start<=0; bf_start<=0; cat_load<=0; cat_last<=0;
        end else begin
            done<=0; fg_start<=0; bf_start<=0; cat_load<=0;
            case (state)
                // ================= 入口 =================
                S_IDLE: begin
                    busy<=0;
                    if (start && !busy) begin
                        msg_sh<=msg; B_l<=B; mp<=0; cb_count<=0; busy<=1;
                        use_crc<=0;
                        r16<=tab22_r16(mcs);
                        if (ftype2) begin
                            phase<=PH_A;
                            state<=SA_INIT;
                        end else begin
                            remaining<=B;
                            state<=SB_FULL_INIT;
                        end
                    end
                end

                // ============ 类型3/4: 满块循环 (6.9.1.3) ============
                // 首次判据 B>Kcb (=K1024); 之后判据 remaining>Kcb-24 (满块循环)
                SB_FULL_INIT: begin                  // 本拍同时装载 CRC 种子
                    if (( use_crc && (remaining > {5'b0, KmL}))  ||
                        (!use_crc && (remaining > {5'b0, K1024}))) begin
                        use_crc<=1;
                        Kblk<=K1024; nlog_blk<=4'd10; blk_is_last<=0;
                        padv<=0; Kmsg_cur<=KmL; crc_on<=1; vpos<=0;
                        phase<=PH_BFULL;
                        fg_start<=1; state<=S_FZ;
                    end else begin
                        state<=SB_LAST_INIT;
                    end
                end

                // ============ 类型3/4: 末块 + 细分 ============
                SB_LAST_INIT: begin                  // 本拍装载 CRC 种子 (随消费喂入, 无预扫)
                    Kmsg_cur<=remaining[10:0];
                    Kr<=remaining[10:0] + (use_crc ? 11'd24 : 11'd0);
                    crc_on<=use_crc; vpos<=0;
                    state<=SB_QINIT;
                end
                SB_QINIT: begin                      // 细分决策 (spec 6.9.1.3)
                    phase<=PH_BSUB; subsel<=0;
                    if (r16 == 5'd16) begin          // R=1: 不细分
                        padv<=0; Kblk<=Kr; nlog_blk<=4'd10; blk_is_last<=1;
                        fg_start<=1; state<=S_FZ;
                    end else if (Kr > U16) begin     // Kr>16U: 补0至1024R, 码长1024 @ 码率R
                        //   K = K1024 = 1024R = 表23 "码长1024" 列 (与满块同值)
                        padv<=K1024-Kr; Kblk<=K1024; nlog_blk<=4'd10; blk_is_last<=1;
                        fg_start<=1; state<=S_FZ;
                    end else begin                   // 迭代求 q=⌈Kr/U⌉
                        tmpx<={5'b0,Kr}; qv<=5'd1;
                        state<=SB_QLOOP;
                    end
                end
                SB_QLOOP: begin
                    if (tmpx > {9'b0,Uu}) begin
                        tmpx<=tmpx-{9'b0,Uu}; qv<=qv+1'b1;
                    end else begin                   // 终止: 余量∈(0,U], pad=U-余量
                        padv<={4'b0,Uu}-tmpx[10:0];
                        if (qv == 5'd16) begin       // q=16: 码长1024 @ 码率R-1/16
                            //   K = 1024(R-1/16) = 16U (按码率定义, 非表23格值)
                            Kblk<=U16; nlog_blk<=4'd10; blk_is_last<=1;
                            fg_start<=1; state<=S_FZ;
                        end else begin               // q≤15: 二进制选码长
                            subsel<=qv[3:0];
                            state<=SB_SUBNEXT;
                        end
                    end
                end
                SB_SUBNEXT: begin                    // 512→256→128→64 顺序; K 值查【表23】(码率R-1/16)
                    if (subsel[3]) begin             // 码长512: K = tab23[R,512]
                        nlog_blk<=4'd9; Kblk<={1'b0,tab23(r16,2'd0)};
                        subsel[3]<=0; blk_is_last<=(subsel[2:0]==3'b0);
                    end else if (subsel[2]) begin    // 码长256: K = tab23[R,256]
                        nlog_blk<=4'd8; Kblk<={1'b0,tab23(r16,2'd1)};
                        subsel[2]<=0; blk_is_last<=(subsel[1:0]==2'b0);
                    end else if (subsel[1]) begin    // 码长128: K = tab23[R,128]
                        nlog_blk<=4'd7; Kblk<={1'b0,tab23(r16,2'd2)};
                        subsel[1]<=0; blk_is_last<=(subsel[0]==1'b0);
                    end else begin                   // 码长64:  K = tab23[R,64]
                        nlog_blk<=4'd6; Kblk<={1'b0,tab23(r16,2'd3)};
                        subsel[0]<=0; blk_is_last<=1;
                    end
                    fg_start<=1; state<=S_FZ;
                end

                // ============ 类型2: 计数 (6.9.1.2 查表) ============
                SA_INIT: begin
                    c1024<=0; km<=B_l;
                    if (B_l > thr1920) begin         // N1024 = ⌊(B-904R)/1024R⌋
                        tmpx<=B_l - r904;
                        state<=SA_N1024;
                    end else begin
                        tmpx<=B_l - 16'd1;           // (Km-1)
                        idxA<=0;
                        state<=SA_IDX;
                    end
                end
                SA_N1024: begin
                    // 循环: tmpx=(B-904R)-n·1024R 与 km=B-n·1024R 同步递减;
                    // 终止时 n=⌊(B-904R)/1024R⌋=N1024, km 即剩余待编码比特 Km
                    if (tmpx >= {5'b0,K1024}) begin
                        tmpx<=tmpx-{5'b0,K1024};
                        km<=km-{5'b0,K1024};
                        c1024<=c1024+1'b1;
                    end else begin
                        tmpx<=km-16'd1;              // 转 (Km-1) 供 index 迭代
                        idxA<=0;
                        state<=SA_IDX;
                    end
                end
                SA_IDX: begin                        // index=⌊(Km-1)/128R⌋, 钳位14
                    if ((tmpx >= r128w) && (idxA < 4'd14)) begin
                        tmpx<=tmpx-r128w; idxA<=idxA+1'b1;
                    end else begin
                        {c512,c256,c128}<=tab20(idxA);
                        state<=SA_REM;
                    end
                end
                SA_REM: begin                        // rem = Km - Σ N·K_N (表24)
                    remA <= $signed({1'b0,km[14:0]})
                          - $signed({5'b0,mul012(c512,tab24(r16,2'd0))})
                          - $signed({5'b0,mul012(c256,tab24(r16,2'd1))})
                          - $signed({5'b0,mul012(c128,tab24(r16,2'd2))});
                    c64<=0;
                    state<=SA_N64;
                end
                SA_N64: begin                        // N64=⌈rem/K64⌉ (迭代)
                    if ((remA > 0) && (tab24(r16,2'd3) != 10'd0)) begin
                        remA<=remA - $signed({5'b0,{1'b0,tab24(r16,2'd3)}});
                        c64<=c64+1'b1;
                    end else
                        state<=SA_BLKNEXT;
                end
                SA_BLKNEXT: begin                    // 块序 1024→512→256→128→64
                    if (c1024 != 0) begin
                        nlog_blk<=4'd10; Kblk<=K1024; c1024<=c1024-1'b1;
                        blk_is_last<=((c1024==4'd1)&&(c512==0)&&(c256==0)&&(c128==0)&&(c64==0));
                    end else if (c512 != 0) begin
                        nlog_blk<=4'd9; Kblk<={1'b0,tab24(r16,2'd0)}; c512<=c512-1'b1;
                        blk_is_last<=((c512==2'd1)&&(c256==0)&&(c128==0)&&(c64==0));
                    end else if (c256 != 0) begin
                        nlog_blk<=4'd8; Kblk<={1'b0,tab24(r16,2'd1)}; c256<=c256-1'b1;
                        blk_is_last<=((c256==2'd1)&&(c128==0)&&(c64==0));
                    end else if (c128 != 0) begin
                        nlog_blk<=4'd7; Kblk<={1'b0,tab24(r16,2'd2)}; c128<=c128-1'b1;
                        blk_is_last<=((c128==2'd1)&&(c64==0));
                    end else begin
                        nlog_blk<=4'd6; Kblk<={1'b0,tab24(r16,2'd3)}; c64<=c64-1'b1;
                        blk_is_last<=(c64==6'd1);
                    end
                    state<=SA_PAD;
                end
                SA_PAD: begin                        // 末块不足位: 块首补0
                    padv     <= (avail < {5'b0,Kblk}) ? (Kblk - avail[10:0]) : 11'd0;
                    Kmsg_cur <= (avail < {5'b0,Kblk}) ? avail[10:0] : Kblk;
                    crc_on<=0; vpos<=0;
                    fg_start<=1; state<=S_FZ;
                end

                // ============ 公共: 冻结集 → 装配 → 编码 → 级联 → 调度 ============
                S_FZ: begin                          // 冻结集生成 → 装入移位寄存器
                    if (fg_done) begin
                        fz_sh<=fg_frozen; acnt<=0;
                        state<=S_ASM;
                    end
                end
                S_ASM: begin                         // u 串行装配 (N 拍); 消息位同步喂 CRC
                    u_sh<={ubit, u_sh[NMAX-1:1]};
                    fz_sh<={1'b0, fz_sh[NMAX-1:1]};
                    if (!cur_fz) begin
                        vpos<=vpos+11'd1;
                        if (in_msg) begin
                            msg_sh<={1'b0, msg_sh[MSG_MAX-1:1]};
                            mp<=mp+16'd1;
                        end
                    end
                    if (acnt == Nv_blk - 11'd1) begin
                        bf_start<=1;                 // 启动蝶形 (u_bottom 已就绪)
                        state<=S_ENC;
                    end else
                        acnt<=acnt+11'd1;
                end
                S_ENC: begin                         // 蝶形编码 (log2(N)+1 拍)
                    if (bf_done)
                        state<=S_CATW;
                end
                S_CATW: begin
                    if (cat_ready) begin
                        cat_load<=1; cat_last<=blk_is_last;
                        cb_count<=cb_count+1'b1;
                        state<=S_ROUTE;
                    end
                end
                S_ROUTE: begin
                    case (phase)
                        PH_BFULL: begin
                            remaining<=remaining-{5'b0,KmL};
                            state<=SB_FULL_INIT;
                        end
                        PH_BSUB:  state<=(subsel!=4'b0) ? SB_SUBNEXT : S_DONE;
                        default:  state<=({c1024,c512,c256,c128,c64}!=0)
                                          ? SA_BLKNEXT : S_DONE;
                    endcase
                end
                S_DONE: begin
                    if (cat_done) begin
                        done<=1; busy<=0; state<=S_IDLE;
                    end
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
先给你一部分，太多了，剩下的在下个指令给你

---

### ChatGPT

收到，这一批已经能确定不少关键规则。先不急着改代码，等剩余模块补齐后统一设计，避免接口反复推翻。
已经确认的编码约定
1. CRC24B 的实现方式已经明确
你的 CRC 不是通用默认模板，而是严格按照当前协议代码实现：
verilogPOLY = 24'hB2B117seed = crc_seed
CRC 更新方式为：
verilogfb = r[23] ^ din;r_next = {r[22:0], 1'b0} ^ (fb ? 24'hB2B117 : 24'd0);
因此是：


消息比特按 a0 开始依次输入；


MSB-first；


CRC 寄存器左移；


初始值由外部 crc_seed 提供；


当前默认使用 24'h555555；


CRC 输出也按高位优先追加。


编码链中：
verilogcrc_rev[0] = crc_val[23];crc_rev[1] = crc_val[22];...crc_rev[23] = crc_val[0];
所以 CA-SCL 的 CRC 路径状态更新必须完全复制这一逻辑，不能直接套其他 CRC24B 模块。

2. Kblk 的真实含义已经明确
你的编码器中：
$K_{\mathrm{blk}}
=
K_{\mathrm{padding}}
+
K_{\mathrm{message}}
+
K_{\mathrm{CRC}}$
也就是说，传给：
verilogfrozen_gen.K
的是 Polar 码中全部非冻结位数量，不仅是原始消息长度。
例如：
Plain text前补零：8 bit消息：200 bitCRC：24 bitKblk：232 bit
这些前补零虽然数值固定为 0，但在当前实现里占据的是非冻结位置，而不是 Polar 冻结位。

3. 编码与译码索引顺序基本确定
编码装配时按冻结掩码自然顺序处理：
verilogcur_fz = fz_sh[0];
即依次处理：
Plain textu[0], u[1], ..., u[N-1]
polar_butterfly 直接对低 $N$ 位执行：
Plain textstage 0stage 1...stage n_log-1
目前没有看到额外的比特反转操作。
编码结果也是：
verilogm_bit = blk[j];
即码字按：
Plain textd[0], d[1], ..., d[N-1]
顺序输出。这与当前 SC 译码器根 LLR 从地址 0 开始装载的顺序能够对应。

一个必须提前处理的关键问题
你的 CRC24B 不一定对应一个独立 Polar 码块。
在类型 3/4 的末块处理中，一个带 CRC 的逻辑码块可能进一步拆成：
Plain textN=512 的Polar块N=256 的Polar块N=128 的Polar块N=64 的Polar块
但它们共同消费同一个：
Plain textV = 前补零 || 消息 || CRC24B
从代码中可以看到，多个子块之间：
verilogvposcrc_valmsg_sh
都是连续推进的，CRC 并没有为每个 Polar 子块重新开始。
因此不能简单地在每个 scl_decoder_core 译码完成后，独立检查一次 CRC24B。这样只适用于“一个逻辑 CRC 码块正好对应一个 Polar 码块”的情况。
完整架构更可能需要分为两层：
Plain textscl_decoder_core负责单个Polar块的L条候选路径          ↓ca_scl_chain_controller负责多个Polar子块之间的候选组合、CRC状态延续和最终选择
否则若每个子块只提前选择一条最优路径，前一个子块中 PM 略差但最终能够通过 CRC 的路径会被过早删除。
这会是后续设计中最重要的架构问题之一。

下一批需要的代码
请继续提供：
Plain textpolar_reliability_rom.vpolar_encoder.vpolar_encode_stream.v
如果截图中的：
Plain textpolar_encode_chain_top.v
和本次发来的 polar_encode_chain 不是同一个模块，也需要提供它。
其中：


polar_reliability_rom.v：确认可靠度序列和索引方向；


polar_encoder.v：作为并行确认版，交叉验证当前蝶形和信息位散布；


polar_encode_stream.v：确认单块编码接口、输入输出顺序和握手；


polar_encode_chain_top.v：确认外层如何向各码块传递 N、K、CRC、padding 等信息。


完整 TB 仍然不用发，我会根据最终接口重新写自检 TB。

---

### User

// =============================================================================
// polar_encode_stream.v -- 流式输入封装顶层 (推荐 Vivado 综合顶层, 无需 OOC)
// -----------------------------------------------------------------------------
// 动机: 链核 polar_encode_chain 的 msg 是 2048 位并行输入 (≈2100 引脚), 任何芯片
//   都装不下物理引脚, 直接综合必须设 Out-of-Context。本封装把消息改为**逐位串行
//   装载** (s_valid/s_bit), 顶层引脚降到几十个 —— 普通流程即可综合, 也可上板。
//
// 装载机制 (零变址网络, 与链核同一面积原则):
//   - buf_sh 移位寄存器: 每 s_valid 拍从高位插入一位 (a0 先送);
//   - 送满 B 位后进入对齐段: 继续补零移位至总移位数 = MSG_MAX,
//     此时 a0 恰好落在 bit0 (链核要求 msg[0]=首比特), 无需桶形移位器;
//   - 对齐最多 MSG_MAX 拍, 相对编码时延可忽略。
//
// 时序: cfg_start(采样 B/mcs/ftype2/crc_seed) → s_ready=1 期间送 B 位
//   (可有气泡, s_valid 置位才计数) → 自动启动链核 → m_valid/m_bit 串行输出
//   → done 单拍 = 整帧完毕, 回到空闲可配置下一帧。
//
// 链核 polar_encode_chain 原封不动实例化 (已由整链 TB 黄金模型验证);
// 本封装另有 tb_polar_encode_stream 与链核并行输入版逐位等价性比对。
// =============================================================================
module polar_encode_stream #(
    parameter integer NMAX    = 1024,
    parameter integer MSG_MAX = 2048
)(
    input  wire        clk,
    input  wire        rst_n,
    // 帧配置 (cfg_start 拍采样; 仅空闲时接受)
    input  wire        cfg_start,
    input  wire [15:0] B,         // 信息比特总长
    input  wire [3:0]  mcs,       // 表22 调制编码方式索引 0..12
    input  wire        ftype2,    // 1=无线帧类型2; 0=类型3/4
    input  wire [23:0] crc_seed,  // 码块CRC24B种子 (广播类: 0x555555)
    // 消息串行装载 (s_ready=1 期间有效, a0 先送)
    input  wire        s_valid,
    input  wire        s_bit,
    output wire        s_ready,
    // 状态与编码输出 (m_* 直通链核)
    output wire        busy,      // 整帧处理中 (含装载/对齐)
    output wire        done,      // 整帧输出完毕 (单拍)
    output wire        m_valid,
    output wire        m_bit,
    output wire [31:0] k_count,
    output wire [7:0]  cb_count
);
    localparam integer CW = $clog2(MSG_MAX) + 1;      // 计数到 MSG_MAX (含) 的位宽
    localparam [CW-1:0] SHMAX = MSG_MAX[CW-1:0];

    localparam [1:0] W_IDLE=2'd0, W_LOAD=2'd1, W_ALIGN=2'd2, W_RUN=2'd3;
    reg [1:0]         wst;
    reg [MSG_MAX-1:0] buf_sh;
    reg [CW-1:0]      shcnt;      // 已移位次数 (装载+对齐)
    reg [15:0]        bitcnt;     // 已装载消息位数
    reg [15:0]        B_l;
    reg [3:0]         mcs_l;
    reg               ft2_l;
    reg [23:0]        seed_l;
    reg               core_start;

    assign s_ready = (wst == W_LOAD);
    assign busy    = (wst != W_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst<=W_IDLE; buf_sh<=0; shcnt<=0; bitcnt<=0;
            B_l<=0; mcs_l<=0; ft2_l<=0; seed_l<=0; core_start<=0;
        end else begin
            core_start<=0;
            case (wst)
                W_IDLE: if (cfg_start) begin
                    B_l<=B; mcs_l<=mcs; ft2_l<=ftype2; seed_l<=crc_seed;
                    shcnt<={CW{1'b0}}; bitcnt<=16'd0;
                    wst<=W_LOAD;
                end
                W_LOAD: begin
                    if (B_l == 16'd0)                 // 异常保护: 空帧直接对齐
                        wst<=W_ALIGN;
                    else if (s_valid) begin
                        buf_sh<={s_bit, buf_sh[MSG_MAX-1:1]};
                        shcnt<=shcnt+1'b1;
                        bitcnt<=bitcnt+1'b1;
                        if (bitcnt+16'd1 == B_l) wst<=W_ALIGN;
                    end
                end
                W_ALIGN: begin                        // 补零至 a0 落到 bit0
                    if (shcnt == SHMAX) begin
                        core_start<=1;
                        wst<=W_RUN;
                    end else begin
                        buf_sh<={1'b0, buf_sh[MSG_MAX-1:1]};
                        shcnt<=shcnt+1'b1;
                    end
                end
                W_RUN: if (done) wst<=W_IDLE;
                default: wst<=W_IDLE;
            endcase
        end
    end

    /* verilator lint_off PINCONNECTEMPTY */          // 链核 busy 由本封装 busy 覆盖
    polar_encode_chain #(.NMAX(NMAX), .MSG_MAX(MSG_MAX)) u_core (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .msg(buf_sh), .B(B_l), .mcs(mcs_l), .ftype2(ft2_l), .crc_seed(seed_l),
        .busy(), .done(done), .m_valid(m_valid), .m_bit(m_bit),
        .k_count(k_count), .cb_count(cb_count));
    /* verilator lint_on PINCONNECTEMPTY */
endmodule
// =============================================================================
// polar_encoder.v  --  Polar 码编码器 (FPGA 时序实现, 可综合, Vivado/Icarus 通用)
// -----------------------------------------------------------------------------
// 算法依据: T/XS 10002-2025 (星闪 SLE) 6.9.1.4 极化编码
//   编码输出  d = u * G_N (GF(2)),  G_N = (G_2)^{⊗n},  G_2 = [1 0; 1 1],  N = 2^n
//   输入序列 u 的构造 (spec 伪代码):
//       k = 0;
//       for (n = 0; n < N; n++)
//           if (n ∈ 非冻结集)  u[n] = c[k++];   // 信息比特
//           else               u[n] = 0;         // 冻结比特置 0
//   冻结集由可靠度排序序列 (spec 附录C) 确定. 本模块以 frozen 掩码为输入
//   (frozen[n]=1 表示位置 n 冻结), 掩码由上层查表/ROM 提供, 编码器与其来源解耦.
//
// 实现方式: 迭代蝶形 —— 一个 N 位状态寄存器 x, 每个时钟应用一级蝶形变换:
//       第 s 级 (跨距 M = 2^s):
//         for (i = 0; i < N; i += 2M)
//           for (j = 0; j < M; j++)  x[i+j] ^= x[i+j+M];   // 顶半异或, 底半直传
//   共 log2(N) 级, 每级一拍. 相比把 10 级 XOR 全摊成组合逻辑, 每拍关键路径
//   只有 1 级 XOR + 级选择 mux, FPGA 时序好收敛; 面积为 log2(N) 套单级网络.
//
// 握手时序:
//   start 在 busy=0 时被接受 (frozen/info 在该拍被采样, 之后可变);
//   busy 保持 log2(N) 拍; done 为单拍脉冲, 与 d 更新同拍;
//   总时延 = log2(N)+1 拍 (1 拍装载 + log2(N) 拍变换); d 保持到下一次编码完成.
//
// 参数: N 必须为 2 的幂 (spec 取值 {64,128,256,512,1024}).
//   信息比特数 K = frozen 中 0 的个数; info 低 K 位有效, info[0] 为第一个信息比特 c0.
// =============================================================================
module polar_encoder #(
    parameter integer N = 64
)(
    input  wire         clk,
    input  wire         rst_n,      // 异步低有效复位
    // 控制握手
    input  wire         start,      // busy=0 时的 start 被接受
    output reg          busy,
    output reg          done,       // 单拍脉冲, 表示 d 已更新为本次码字
    // 数据
    input  wire [N-1:0] frozen,     // 冻结掩码: 1=冻结位(u=0), 0=信息位
    input  wire [N-1:0] info,       // 信息比特, 右对齐: info[0]=c0 ... 共 K 个有效
    output reg  [N-1:0] d           // 码字 d = u * G_N
);
    localparam integer STAGES = $clog2(N);
    localparam integer SW     = (STAGES <= 1) ? 1 : $clog2(STAGES);

    // ---- u 的装配 (spec 伪代码): 冻结位置 0, 信息位顺序填入 info ----
    // 注: 对大 N 这是一个较大的组合散布网络, 仅在装载拍使用;
    //     若综合后时序紧张, 可将其拆为独立流水级.
    reg [N-1:0] u_packed;
    integer n, k;
    always @* begin
        k = 0;
        u_packed = {N{1'b0}};
        for (n = 0; n < N; n = n + 1) begin
            if (!frozen[n]) begin
                u_packed[n] = info[k];
                k = k + 1;
            end
        end
    end

    // ---- log2(N) 套单级蝶形网络, 由 stage 计数器选择当前应用哪一级 ----
    reg  [N-1:0]  x;                        // 状态寄存器 (原位变换)
    reg  [SW-1:0] stage;
    wire [N-1:0]  stage_net [0:STAGES-1];   // 第 s 级网络作用于当前 x 的结果

    genvar gs, gi, gj;
    generate
        for (gs = 0; gs < STAGES; gs = gs + 1) begin : g_stage
            localparam integer M = (1 << gs);
            for (gi = 0; gi < N; gi = gi + 2*M) begin : g_grp
                for (gj = 0; gj < M; gj = gj + 1) begin : g_pair
                    assign stage_net[gs][gi+gj]   = x[gi+gj] ^ x[gi+gj+M]; // 顶半异或
                    assign stage_net[gs][gi+gj+M] = x[gi+gj+M];            // 底半直传
                end
            end
        end
    endgenerate

    wire [N-1:0] x_next = stage_net[stage];

    // ---- 控制 FSM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            done  <= 1'b0;
            stage <= {SW{1'b0}};
            x     <= {N{1'b0}};
            d     <= {N{1'b0}};
        end else begin
            done <= 1'b0;
            if (start && !busy) begin              // 接受任务: 装载 u
                x     <= u_packed;
                stage <= {SW{1'b0}};
                busy  <= 1'b1;
            end else if (busy) begin
                x <= x_next;                       // 应用第 stage 级蝶形
                if (stage == STAGES-1) begin       // 最后一级: 输出码字
                    d    <= x_next;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    stage <= stage + 1'b1;
                end
            end
        end
    end

    // 仿真时的参数检查 (综合器忽略 initial 块)
    initial begin
        if ((N & (N-1)) != 0 || N < 2) begin
            $display("polar_encoder: 参数 N=%0d 非法, 必须为 2 的幂", N);
            $finish;
        end
    end
endmodule
// =============================================================================
// polar_reliability_rom.v  --  极化码可靠度序列 ROM (组合读)
// -----------------------------------------------------------------------------
// 数据来源: T/XS 10002-2025 附录C 表C.1 (规范性) 极化码可靠度序列.
//   mem[rank] = Q_rank = 比特索引;  rank 0 = 最不可靠 .. 1023 = 最可靠.
//   (由 PDF 按几何坐标提取, 已校验为 0..1023 的排列; Q[0]=0, Q[1023]=1023.)
// 长为 N(=2^n) 的子序列 = 本表中比特索引 < N 的项, 保持秩序 (spec 6.9.1.4 嵌套性).
// 数据内联, 无需外部 .mem 文件, Vivado / Icarus 通用.
// =============================================================================
module polar_reliability_rom (
    input  wire [9:0] rank,   // 可靠度秩 0..1023
    output wire [9:0] q       // Q_rank: 该秩对应的比特索引
);
    reg [9:0] mem [0:1023];
    initial begin
        mem[0]=10'd0; mem[1]=10'd1; mem[2]=10'd2; mem[3]=10'd4; mem[4]=10'd8; mem[5]=10'd16; mem[6]=10'd32; mem[7]=10'd3;
        mem[8]=10'd5; mem[9]=10'd64; mem[10]=10'd9; mem[11]=10'd6; mem[12]=10'd17; mem[13]=10'd10; mem[14]=10'd18; mem[15]=10'd128;
        mem[16]=10'd12; mem[17]=10'd33; mem[18]=10'd65; mem[19]=10'd20; mem[20]=10'd256; mem[21]=10'd34; mem[22]=10'd24; mem[23]=10'd36;
        mem[24]=10'd7; mem[25]=10'd129; mem[26]=10'd66; mem[27]=10'd512; mem[28]=10'd11; mem[29]=10'd40; mem[30]=10'd68; mem[31]=10'd130;
        mem[32]=10'd19; mem[33]=10'd13; mem[34]=10'd48; mem[35]=10'd14; mem[36]=10'd72; mem[37]=10'd257; mem[38]=10'd21; mem[39]=10'd132;
        mem[40]=10'd35; mem[41]=10'd258; mem[42]=10'd26; mem[43]=10'd513; mem[44]=10'd80; mem[45]=10'd37; mem[46]=10'd25; mem[47]=10'd22;
        mem[48]=10'd136; mem[49]=10'd260; mem[50]=10'd264; mem[51]=10'd38; mem[52]=10'd514; mem[53]=10'd96; mem[54]=10'd67; mem[55]=10'd41;
        mem[56]=10'd144; mem[57]=10'd28; mem[58]=10'd69; mem[59]=10'd42; mem[60]=10'd516; mem[61]=10'd49; mem[62]=10'd74; mem[63]=10'd272;
        mem[64]=10'd160; mem[65]=10'd520; mem[66]=10'd288; mem[67]=10'd528; mem[68]=10'd192; mem[69]=10'd544; mem[70]=10'd70; mem[71]=10'd44;
        mem[72]=10'd131; mem[73]=10'd81; mem[74]=10'd50; mem[75]=10'd73; mem[76]=10'd15; mem[77]=10'd320; mem[78]=10'd133; mem[79]=10'd52;
        mem[80]=10'd23; mem[81]=10'd134; mem[82]=10'd384; mem[83]=10'd76; mem[84]=10'd137; mem[85]=10'd82; mem[86]=10'd56; mem[87]=10'd27;
        mem[88]=10'd97; mem[89]=10'd39; mem[90]=10'd259; mem[91]=10'd84; mem[92]=10'd138; mem[93]=10'd145; mem[94]=10'd261; mem[95]=10'd29;
        mem[96]=10'd43; mem[97]=10'd98; mem[98]=10'd515; mem[99]=10'd88; mem[100]=10'd140; mem[101]=10'd30; mem[102]=10'd146; mem[103]=10'd71;
        mem[104]=10'd262; mem[105]=10'd265; mem[106]=10'd161; mem[107]=10'd576; mem[108]=10'd45; mem[109]=10'd100; mem[110]=10'd640; mem[111]=10'd51;
        mem[112]=10'd148; mem[113]=10'd46; mem[114]=10'd75; mem[115]=10'd266; mem[116]=10'd273; mem[117]=10'd517; mem[118]=10'd104; mem[119]=10'd162;
        mem[120]=10'd53; mem[121]=10'd193; mem[122]=10'd152; mem[123]=10'd77; mem[124]=10'd164; mem[125]=10'd768; mem[126]=10'd268; mem[127]=10'd274;
        mem[128]=10'd518; mem[129]=10'd54; mem[130]=10'd83; mem[131]=10'd57; mem[132]=10'd521; mem[133]=10'd112; mem[134]=10'd135; mem[135]=10'd78;
        mem[136]=10'd289; mem[137]=10'd194; mem[138]=10'd85; mem[139]=10'd276; mem[140]=10'd522; mem[141]=10'd58; mem[142]=10'd168; mem[143]=10'd139;
        mem[144]=10'd99; mem[145]=10'd86; mem[146]=10'd60; mem[147]=10'd280; mem[148]=10'd89; mem[149]=10'd290; mem[150]=10'd529; mem[151]=10'd524;
        mem[152]=10'd196; mem[153]=10'd141; mem[154]=10'd101; mem[155]=10'd147; mem[156]=10'd176; mem[157]=10'd142; mem[158]=10'd530; mem[159]=10'd321;
        mem[160]=10'd31; mem[161]=10'd200; mem[162]=10'd90; mem[163]=10'd545; mem[164]=10'd292; mem[165]=10'd322; mem[166]=10'd532; mem[167]=10'd263;
        mem[168]=10'd149; mem[169]=10'd102; mem[170]=10'd105; mem[171]=10'd304; mem[172]=10'd296; mem[173]=10'd163; mem[174]=10'd92; mem[175]=10'd47;
        mem[176]=10'd267; mem[177]=10'd385; mem[178]=10'd546; mem[179]=10'd324; mem[180]=10'd208; mem[181]=10'd386; mem[182]=10'd150; mem[183]=10'd153;
        mem[184]=10'd165; mem[185]=10'd106; mem[186]=10'd55; mem[187]=10'd328; mem[188]=10'd536; mem[189]=10'd577; mem[190]=10'd548; mem[191]=10'd113;
        mem[192]=10'd154; mem[193]=10'd79; mem[194]=10'd269; mem[195]=10'd108; mem[196]=10'd578; mem[197]=10'd224; mem[198]=10'd166; mem[199]=10'd519;
        mem[200]=10'd552; mem[201]=10'd195; mem[202]=10'd270; mem[203]=10'd641; mem[204]=10'd523; mem[205]=10'd275; mem[206]=10'd580; mem[207]=10'd291;
        mem[208]=10'd59; mem[209]=10'd169; mem[210]=10'd560; mem[211]=10'd114; mem[212]=10'd277; mem[213]=10'd156; mem[214]=10'd87; mem[215]=10'd197;
        mem[216]=10'd116; mem[217]=10'd170; mem[218]=10'd61; mem[219]=10'd531; mem[220]=10'd525; mem[221]=10'd642; mem[222]=10'd281; mem[223]=10'd278;
        mem[224]=10'd526; mem[225]=10'd177; mem[226]=10'd293; mem[227]=10'd388; mem[228]=10'd91; mem[229]=10'd584; mem[230]=10'd769; mem[231]=10'd198;
        mem[232]=10'd172; mem[233]=10'd120; mem[234]=10'd201; mem[235]=10'd336; mem[236]=10'd62; mem[237]=10'd282; mem[238]=10'd143; mem[239]=10'd103;
        mem[240]=10'd178; mem[241]=10'd294; mem[242]=10'd93; mem[243]=10'd644; mem[244]=10'd202; mem[245]=10'd592; mem[246]=10'd323; mem[247]=10'd392;
        mem[248]=10'd297; mem[249]=10'd770; mem[250]=10'd107; mem[251]=10'd180; mem[252]=10'd151; mem[253]=10'd209; mem[254]=10'd284; mem[255]=10'd648;
        mem[256]=10'd94; mem[257]=10'd204; mem[258]=10'd298; mem[259]=10'd400; mem[260]=10'd608; mem[261]=10'd352; mem[262]=10'd325; mem[263]=10'd533;
        mem[264]=10'd155; mem[265]=10'd210; mem[266]=10'd305; mem[267]=10'd547; mem[268]=10'd300; mem[269]=10'd109; mem[270]=10'd184; mem[271]=10'd534;
        mem[272]=10'd537; mem[273]=10'd115; mem[274]=10'd167; mem[275]=10'd225; mem[276]=10'd326; mem[277]=10'd306; mem[278]=10'd772; mem[279]=10'd157;
        mem[280]=10'd656; mem[281]=10'd329; mem[282]=10'd110; mem[283]=10'd117; mem[284]=10'd212; mem[285]=10'd171; mem[286]=10'd776; mem[287]=10'd330;
        mem[288]=10'd226; mem[289]=10'd549; mem[290]=10'd538; mem[291]=10'd387; mem[292]=10'd308; mem[293]=10'd216; mem[294]=10'd416; mem[295]=10'd271;
        mem[296]=10'd279; mem[297]=10'd158; mem[298]=10'd337; mem[299]=10'd550; mem[300]=10'd672; mem[301]=10'd118; mem[302]=10'd332; mem[303]=10'd579;
        mem[304]=10'd540; mem[305]=10'd389; mem[306]=10'd173; mem[307]=10'd121; mem[308]=10'd553; mem[309]=10'd199; mem[310]=10'd784; mem[311]=10'd179;
        mem[312]=10'd228; mem[313]=10'd338; mem[314]=10'd312; mem[315]=10'd704; mem[316]=10'd390; mem[317]=10'd174; mem[318]=10'd554; mem[319]=10'd581;
        mem[320]=10'd393; mem[321]=10'd283; mem[322]=10'd122; mem[323]=10'd448; mem[324]=10'd353; mem[325]=10'd561; mem[326]=10'd203; mem[327]=10'd63;
        mem[328]=10'd340; mem[329]=10'd394; mem[330]=10'd527; mem[331]=10'd582; mem[332]=10'd556; mem[333]=10'd181; mem[334]=10'd295; mem[335]=10'd285;
        mem[336]=10'd232; mem[337]=10'd124; mem[338]=10'd205; mem[339]=10'd182; mem[340]=10'd643; mem[341]=10'd562; mem[342]=10'd286; mem[343]=10'd585;
        mem[344]=10'd299; mem[345]=10'd354; mem[346]=10'd211; mem[347]=10'd401; mem[348]=10'd185; mem[349]=10'd396; mem[350]=10'd344; mem[351]=10'd586;
        mem[352]=10'd645; mem[353]=10'd593; mem[354]=10'd535; mem[355]=10'd240; mem[356]=10'd206; mem[357]=10'd95; mem[358]=10'd327; mem[359]=10'd564;
        mem[360]=10'd800; mem[361]=10'd402; mem[362]=10'd356; mem[363]=10'd307; mem[364]=10'd301; mem[365]=10'd417; mem[366]=10'd213; mem[367]=10'd568;
        mem[368]=10'd832; mem[369]=10'd588; mem[370]=10'd186; mem[371]=10'd646; mem[372]=10'd404; mem[373]=10'd227; mem[374]=10'd896; mem[375]=10'd594;
        mem[376]=10'd418; mem[377]=10'd302; mem[378]=10'd649; mem[379]=10'd771; mem[380]=10'd360; mem[381]=10'd539; mem[382]=10'd111; mem[383]=10'd331;
        mem[384]=10'd214; mem[385]=10'd309; mem[386]=10'd188; mem[387]=10'd449; mem[388]=10'd217; mem[389]=10'd408; mem[390]=10'd609; mem[391]=10'd596;
        mem[392]=10'd551; mem[393]=10'd650; mem[394]=10'd229; mem[395]=10'd159; mem[396]=10'd420; mem[397]=10'd310; mem[398]=10'd541; mem[399]=10'd773;
        mem[400]=10'd610; mem[401]=10'd657; mem[402]=10'd333; mem[403]=10'd119; mem[404]=10'd600; mem[405]=10'd339; mem[406]=10'd218; mem[407]=10'd368;
        mem[408]=10'd652; mem[409]=10'd230; mem[410]=10'd391; mem[411]=10'd313; mem[412]=10'd450; mem[413]=10'd542; mem[414]=10'd334; mem[415]=10'd233;
        mem[416]=10'd555; mem[417]=10'd774; mem[418]=10'd175; mem[419]=10'd123; mem[420]=10'd658; mem[421]=10'd612; mem[422]=10'd341; mem[423]=10'd777;
        mem[424]=10'd220; mem[425]=10'd314; mem[426]=10'd424; mem[427]=10'd395; mem[428]=10'd673; mem[429]=10'd583; mem[430]=10'd355; mem[431]=10'd287;
        mem[432]=10'd183; mem[433]=10'd234; mem[434]=10'd125; mem[435]=10'd557; mem[436]=10'd660; mem[437]=10'd616; mem[438]=10'd342; mem[439]=10'd316;
        mem[440]=10'd241; mem[441]=10'd778; mem[442]=10'd563; mem[443]=10'd345; mem[444]=10'd452; mem[445]=10'd397; mem[446]=10'd403; mem[447]=10'd207;
        mem[448]=10'd674; mem[449]=10'd558; mem[450]=10'd785; mem[451]=10'd432; mem[452]=10'd357; mem[453]=10'd187; mem[454]=10'd236; mem[455]=10'd664;
        mem[456]=10'd624; mem[457]=10'd587; mem[458]=10'd780; mem[459]=10'd705; mem[460]=10'd126; mem[461]=10'd242; mem[462]=10'd565; mem[463]=10'd398;
        mem[464]=10'd346; mem[465]=10'd456; mem[466]=10'd358; mem[467]=10'd405; mem[468]=10'd303; mem[469]=10'd569; mem[470]=10'd244; mem[471]=10'd595;
        mem[472]=10'd189; mem[473]=10'd566; mem[474]=10'd676; mem[475]=10'd361; mem[476]=10'd706; mem[477]=10'd589; mem[478]=10'd215; mem[479]=10'd786;
        mem[480]=10'd647; mem[481]=10'd348; mem[482]=10'd419; mem[483]=10'd406; mem[484]=10'd464; mem[485]=10'd680; mem[486]=10'd801; mem[487]=10'd362;
        mem[488]=10'd590; mem[489]=10'd409; mem[490]=10'd570; mem[491]=10'd788; mem[492]=10'd597; mem[493]=10'd572; mem[494]=10'd219; mem[495]=10'd311;
        mem[496]=10'd708; mem[497]=10'd598; mem[498]=10'd601; mem[499]=10'd651; mem[500]=10'd421; mem[501]=10'd792; mem[502]=10'd802; mem[503]=10'd611;
        mem[504]=10'd602; mem[505]=10'd410; mem[506]=10'd231; mem[507]=10'd688; mem[508]=10'd653; mem[509]=10'd248; mem[510]=10'd369; mem[511]=10'd190;
        mem[512]=10'd364; mem[513]=10'd654; mem[514]=10'd659; mem[515]=10'd335; mem[516]=10'd480; mem[517]=10'd315; mem[518]=10'd221; mem[519]=10'd370;
        mem[520]=10'd613; mem[521]=10'd422; mem[522]=10'd425; mem[523]=10'd451; mem[524]=10'd614; mem[525]=10'd543; mem[526]=10'd235; mem[527]=10'd412;
        mem[528]=10'd343; mem[529]=10'd372; mem[530]=10'd775; mem[531]=10'd317; mem[532]=10'd222; mem[533]=10'd426; mem[534]=10'd453; mem[535]=10'd237;
        mem[536]=10'd559; mem[537]=10'd833; mem[538]=10'd804; mem[539]=10'd712; mem[540]=10'd834; mem[541]=10'd661; mem[542]=10'd808; mem[543]=10'd779;
        mem[544]=10'd617; mem[545]=10'd604; mem[546]=10'd433; mem[547]=10'd720; mem[548]=10'd816; mem[549]=10'd836; mem[550]=10'd347; mem[551]=10'd897;
        mem[552]=10'd243; mem[553]=10'd662; mem[554]=10'd454; mem[555]=10'd318; mem[556]=10'd675; mem[557]=10'd618; mem[558]=10'd898; mem[559]=10'd781;
        mem[560]=10'd376; mem[561]=10'd428; mem[562]=10'd665; mem[563]=10'd736; mem[564]=10'd567; mem[565]=10'd840; mem[566]=10'd625; mem[567]=10'd238;
        mem[568]=10'd359; mem[569]=10'd457; mem[570]=10'd399; mem[571]=10'd787; mem[572]=10'd591; mem[573]=10'd678; mem[574]=10'd434; mem[575]=10'd677;
        mem[576]=10'd349; mem[577]=10'd245; mem[578]=10'd458; mem[579]=10'd666; mem[580]=10'd620; mem[581]=10'd363; mem[582]=10'd127; mem[583]=10'd191;
        mem[584]=10'd782; mem[585]=10'd407; mem[586]=10'd436; mem[587]=10'd626; mem[588]=10'd571; mem[589]=10'd465; mem[590]=10'd681; mem[591]=10'd246;
        mem[592]=10'd707; mem[593]=10'd350; mem[594]=10'd599; mem[595]=10'd668; mem[596]=10'd790; mem[597]=10'd460; mem[598]=10'd249; mem[599]=10'd682;
        mem[600]=10'd573; mem[601]=10'd411; mem[602]=10'd803; mem[603]=10'd789; mem[604]=10'd709; mem[605]=10'd365; mem[606]=10'd440; mem[607]=10'd628;
        mem[608]=10'd689; mem[609]=10'd374; mem[610]=10'd423; mem[611]=10'd466; mem[612]=10'd793; mem[613]=10'd250; mem[614]=10'd371; mem[615]=10'd481;
        mem[616]=10'd574; mem[617]=10'd413; mem[618]=10'd603; mem[619]=10'd366; mem[620]=10'd468; mem[621]=10'd655; mem[622]=10'd900; mem[623]=10'd805;
        mem[624]=10'd615; mem[625]=10'd684; mem[626]=10'd710; mem[627]=10'd429; mem[628]=10'd794; mem[629]=10'd252; mem[630]=10'd373; mem[631]=10'd605;
        mem[632]=10'd848; mem[633]=10'd690; mem[634]=10'd713; mem[635]=10'd632; mem[636]=10'd482; mem[637]=10'd806; mem[638]=10'd427; mem[639]=10'd904;
        mem[640]=10'd414; mem[641]=10'd223; mem[642]=10'd663; mem[643]=10'd692; mem[644]=10'd835; mem[645]=10'd619; mem[646]=10'd472; mem[647]=10'd455;
        mem[648]=10'd796; mem[649]=10'd809; mem[650]=10'd714; mem[651]=10'd721; mem[652]=10'd837; mem[653]=10'd716; mem[654]=10'd864; mem[655]=10'd810;
        mem[656]=10'd606; mem[657]=10'd912; mem[658]=10'd722; mem[659]=10'd696; mem[660]=10'd377; mem[661]=10'd435; mem[662]=10'd817; mem[663]=10'd319;
        mem[664]=10'd621; mem[665]=10'd812; mem[666]=10'd484; mem[667]=10'd430; mem[668]=10'd838; mem[669]=10'd667; mem[670]=10'd488; mem[671]=10'd239;
        mem[672]=10'd378; mem[673]=10'd459; mem[674]=10'd622; mem[675]=10'd627; mem[676]=10'd437; mem[677]=10'd380; mem[678]=10'd818; mem[679]=10'd461;
        mem[680]=10'd496; mem[681]=10'd669; mem[682]=10'd679; mem[683]=10'd724; mem[684]=10'd841; mem[685]=10'd629; mem[686]=10'd351; mem[687]=10'd467;
        mem[688]=10'd438; mem[689]=10'd737; mem[690]=10'd251; mem[691]=10'd462; mem[692]=10'd442; mem[693]=10'd441; mem[694]=10'd469; mem[695]=10'd247;
        mem[696]=10'd683; mem[697]=10'd842; mem[698]=10'd738; mem[699]=10'd899; mem[700]=10'd670; mem[701]=10'd783; mem[702]=10'd849; mem[703]=10'd820;
        mem[704]=10'd728; mem[705]=10'd928; mem[706]=10'd791; mem[707]=10'd367; mem[708]=10'd901; mem[709]=10'd630; mem[710]=10'd685; mem[711]=10'd844;
        mem[712]=10'd633; mem[713]=10'd711; mem[714]=10'd253; mem[715]=10'd691; mem[716]=10'd824; mem[717]=10'd902; mem[718]=10'd686; mem[719]=10'd740;
        mem[720]=10'd850; mem[721]=10'd375; mem[722]=10'd444; mem[723]=10'd470; mem[724]=10'd483; mem[725]=10'd415; mem[726]=10'd485; mem[727]=10'd905;
        mem[728]=10'd795; mem[729]=10'd473; mem[730]=10'd634; mem[731]=10'd744; mem[732]=10'd852; mem[733]=10'd960; mem[734]=10'd865; mem[735]=10'd693;
        mem[736]=10'd797; mem[737]=10'd906; mem[738]=10'd715; mem[739]=10'd807; mem[740]=10'd474; mem[741]=10'd636; mem[742]=10'd694; mem[743]=10'd254;
        mem[744]=10'd717; mem[745]=10'd575; mem[746]=10'd913; mem[747]=10'd798; mem[748]=10'd811; mem[749]=10'd379; mem[750]=10'd697; mem[751]=10'd431;
        mem[752]=10'd607; mem[753]=10'd489; mem[754]=10'd866; mem[755]=10'd723; mem[756]=10'd486; mem[757]=10'd908; mem[758]=10'd718; mem[759]=10'd813;
        mem[760]=10'd476; mem[761]=10'd856; mem[762]=10'd839; mem[763]=10'd725; mem[764]=10'd698; mem[765]=10'd914; mem[766]=10'd752; mem[767]=10'd868;
        mem[768]=10'd819; mem[769]=10'd814; mem[770]=10'd439; mem[771]=10'd929; mem[772]=10'd490; mem[773]=10'd623; mem[774]=10'd671; mem[775]=10'd739;
        mem[776]=10'd916; mem[777]=10'd463; mem[778]=10'd843; mem[779]=10'd381; mem[780]=10'd497; mem[781]=10'd930; mem[782]=10'd821; mem[783]=10'd726;
        mem[784]=10'd961; mem[785]=10'd872; mem[786]=10'd492; mem[787]=10'd631; mem[788]=10'd729; mem[789]=10'd700; mem[790]=10'd443; mem[791]=10'd741;
        mem[792]=10'd845; mem[793]=10'd920; mem[794]=10'd382; mem[795]=10'd822; mem[796]=10'd851; mem[797]=10'd730; mem[798]=10'd498; mem[799]=10'd880;
        mem[800]=10'd742; mem[801]=10'd445; mem[802]=10'd471; mem[803]=10'd635; mem[804]=10'd932; mem[805]=10'd687; mem[806]=10'd903; mem[807]=10'd825;
        mem[808]=10'd500; mem[809]=10'd846; mem[810]=10'd745; mem[811]=10'd826; mem[812]=10'd732; mem[813]=10'd446; mem[814]=10'd962; mem[815]=10'd936;
        mem[816]=10'd475; mem[817]=10'd853; mem[818]=10'd867; mem[819]=10'd637; mem[820]=10'd907; mem[821]=10'd487; mem[822]=10'd695; mem[823]=10'd746;
        mem[824]=10'd828; mem[825]=10'd753; mem[826]=10'd854; mem[827]=10'd857; mem[828]=10'd504; mem[829]=10'd799; mem[830]=10'd255; mem[831]=10'd964;
        mem[832]=10'd909; mem[833]=10'd719; mem[834]=10'd477; mem[835]=10'd915; mem[836]=10'd638; mem[837]=10'd748; mem[838]=10'd944; mem[839]=10'd869;
        mem[840]=10'd491; mem[841]=10'd699; mem[842]=10'd754; mem[843]=10'd858; mem[844]=10'd478; mem[845]=10'd968; mem[846]=10'd383; mem[847]=10'd910;
        mem[848]=10'd815; mem[849]=10'd976; mem[850]=10'd870; mem[851]=10'd917; mem[852]=10'd727; mem[853]=10'd493; mem[854]=10'd873; mem[855]=10'd701;
        mem[856]=10'd931; mem[857]=10'd756; mem[858]=10'd860; mem[859]=10'd499; mem[860]=10'd731; mem[861]=10'd823; mem[862]=10'd922; mem[863]=10'd874;
        mem[864]=10'd918; mem[865]=10'd502; mem[866]=10'd933; mem[867]=10'd743; mem[868]=10'd760; mem[869]=10'd881; mem[870]=10'd494; mem[871]=10'd702;
        mem[872]=10'd921; mem[873]=10'd501; mem[874]=10'd876; mem[875]=10'd847; mem[876]=10'd992; mem[877]=10'd447; mem[878]=10'd733; mem[879]=10'd827;
        mem[880]=10'd934; mem[881]=10'd882; mem[882]=10'd937; mem[883]=10'd963; mem[884]=10'd747; mem[885]=10'd505; mem[886]=10'd855; mem[887]=10'd924;
        mem[888]=10'd734; mem[889]=10'd829; mem[890]=10'd965; mem[891]=10'd938; mem[892]=10'd884; mem[893]=10'd506; mem[894]=10'd749; mem[895]=10'd945;
        mem[896]=10'd966; mem[897]=10'd755; mem[898]=10'd859; mem[899]=10'd940; mem[900]=10'd830; mem[901]=10'd911; mem[902]=10'd871; mem[903]=10'd639;
        mem[904]=10'd888; mem[905]=10'd479; mem[906]=10'd946; mem[907]=10'd750; mem[908]=10'd969; mem[909]=10'd508; mem[910]=10'd861; mem[911]=10'd757;
        mem[912]=10'd970; mem[913]=10'd919; mem[914]=10'd875; mem[915]=10'd862; mem[916]=10'd758; mem[917]=10'd948; mem[918]=10'd977; mem[919]=10'd923;
        mem[920]=10'd972; mem[921]=10'd761; mem[922]=10'd877; mem[923]=10'd952; mem[924]=10'd495; mem[925]=10'd703; mem[926]=10'd935; mem[927]=10'd978;
        mem[928]=10'd883; mem[929]=10'd762; mem[930]=10'd503; mem[931]=10'd925; mem[932]=10'd878; mem[933]=10'd735; mem[934]=10'd993; mem[935]=10'd885;
        mem[936]=10'd939; mem[937]=10'd994; mem[938]=10'd980; mem[939]=10'd926; mem[940]=10'd764; mem[941]=10'd941; mem[942]=10'd967; mem[943]=10'd886;
        mem[944]=10'd831; mem[945]=10'd947; mem[946]=10'd507; mem[947]=10'd889; mem[948]=10'd984; mem[949]=10'd751; mem[950]=10'd942; mem[951]=10'd996;
        mem[952]=10'd971; mem[953]=10'd890; mem[954]=10'd509; mem[955]=10'd949; mem[956]=10'd973; mem[957]=10'd1000; mem[958]=10'd892; mem[959]=10'd950;
        mem[960]=10'd863; mem[961]=10'd759; mem[962]=10'd1008; mem[963]=10'd510; mem[964]=10'd979; mem[965]=10'd953; mem[966]=10'd763; mem[967]=10'd974;
        mem[968]=10'd954; mem[969]=10'd879; mem[970]=10'd981; mem[971]=10'd982; mem[972]=10'd927; mem[973]=10'd995; mem[974]=10'd765; mem[975]=10'd956;
        mem[976]=10'd887; mem[977]=10'd985; mem[978]=10'd997; mem[979]=10'd986; mem[980]=10'd943; mem[981]=10'd891; mem[982]=10'd998; mem[983]=10'd766;
        mem[984]=10'd511; mem[985]=10'd988; mem[986]=10'd1001; mem[987]=10'd951; mem[988]=10'd1002; mem[989]=10'd893; mem[990]=10'd975; mem[991]=10'd894;
        mem[992]=10'd1009; mem[993]=10'd955; mem[994]=10'd1004; mem[995]=10'd1010; mem[996]=10'd957; mem[997]=10'd983; mem[998]=10'd958; mem[999]=10'd987;
        mem[1000]=10'd1012; mem[1001]=10'd999; mem[1002]=10'd1016; mem[1003]=10'd767; mem[1004]=10'd989; mem[1005]=10'd1003; mem[1006]=10'd990; mem[1007]=10'd1005;
        mem[1008]=10'd959; mem[1009]=10'd1011; mem[1010]=10'd1013; mem[1011]=10'd895; mem[1012]=10'd1006; mem[1013]=10'd1014; mem[1014]=10'd1017; mem[1015]=10'd1018;
        mem[1016]=10'd991; mem[1017]=10'd1020; mem[1018]=10'd1007; mem[1019]=10'd1015; mem[1020]=10'd1019; mem[1021]=10'd1021; mem[1022]=10'd1022; mem[1023]=10'd1023;
    end
    assign q = mem[rank];
endmodule

---

### ChatGPT

这批代码已经足够，编码端的位序、冻结集、Polar 变换和 CRC24B 规则都已闭合。暂时不需要再提供其他编码器代码，也不需要原来的完整 TB。
先修正一点：我前面提到过通用 CRC24B 多项式 24'h800063，不适用于你这套协议实现。你的工程必须以现有代码为准：
verilogCRC_POLY = 24'hB2B117;CRC_SEED = 24'h555555;   // 实际由 crc_seed 输入
一、现在已经确定的编码与译码约定
1. 完整比特顺序
编码侧顺序为：
Plain text消息：a0、a1、...，a0先输入CRC：crc[23]、crc[22]、...、crc[0]信息散布：从u[0]开始，按非冻结位置自然顺序填入Polar输出：d[0]、d[1]、...、d[N-1]LLR输入：llr_mem[0]对应d[0]
因此目前没有额外的 bit-reversal，SC/SCL 译码器的自然索引方向是正确的。
2. LLR正负定义
仍然是：
Plain textLLR >= 0：倾向比特0LLR <  0：倾向比特1
无噪声测试可直接使用：
verilogllr = code_bit ? -8'sd64 : 8'sd64;
3. Kblk 的含义
你的 frozen_gen.K 不是单纯的消息长度，而是：
$K_{\mathrm{blk}}
=
K_{\mathrm{pad}}
+
K_{\mathrm{message}}
+
K_{\mathrm{CRC}}$
其中 CRC 开启时：
$K_{\mathrm{CRC}}=24$
这意味着前补零占据的是非冻结位置，并不是 Polar 冻结位。

二、发现了一个当前 SC 译码器中需要修正的问题
编码器会生成：
Plain textV = 前补0 || 消息 || CRC
但当前 SC 译码器只知道：
verilogfrozen_bits[i]
因此它会把前补零对应的非冻结位当成普通信息位，并根据 LLR 符号进行判决：
verilogleaf_decision = llr_sign;
这不够准确。前补零是接收端已知的固定 0，SCL 中也不应该对它进行路径分裂。
升级后叶节点应区分三类：
叶节点类型处理方式Polar冻结位强制判0，不分裂前补零位置强制判0，不分裂消息或CRC位置产生0/1两条候选
冻结位和前补零位都要按强制判 0 更新路径度量：
$PM'=PM+
\begin{cases}
0,&LLR\ge0\\
|LLR|,&LLR<0
\end{cases}$
所以 SCL 配置接口除了 N、K，还需要增加类似：
veriloginput wire [10:0] pad_count;
或者由上层直接生成一个：
veriloginput wire [NMAX-1:0] known_zero_mask;
对于当前编码链，使用 pad_count 更节省资源。

三、CRC24B应当怎样检查
你的 CRC 生成递推为：
verilogfb = crc_state[23] ^ din;crc_next =    {crc_state[22:0], 1'b0} ^    (fb ? 24'hB2B117 : 24'd0);
检查时应：


CRC 状态加载 crc_seed；


跳过前补零；


依次输入译码出的消息位；


再输入译码出的24位 CRC；


最终余数为 0，则 CRC 通过。


即：
verilogcrc_pass = (crc_state_after_last_crc == 24'd0);
这里特别要注意：前补零不参与 CRC 运算。从你的编码代码可以看到：
verilogassign crc_en =    (state == S_ASM) &&    !cur_fz &&    in_msg &&    crc_on;
只有消息区被送入 CRC 生成器。

四、CRC不能简单放进每个Polar子块内部
这是当前架构最关键的问题。
在类型3/4的末尾，一个逻辑 CRC 码块可能被拆成多个 Polar 子块，例如：
Plain text逻辑码块V├── N=512子块├── N=256子块├── N=128子块└── N=64子块
这些子块共享同一个：
Plain text前补零 || 消息 || CRC24B
CRC状态和 vpos 跨子块连续，不会在每个 Polar 子块开始时重新加载种子。
因此错误的做法是：
Plain text每个Polar子块单独做一次CRC24B校验
正确结构应分成两层。
单Polar块SCL核心
Plain textscl_decoder_core
负责：


输入一个 (N,K) Polar 子块；


输出最多 $L$ 条候选；


每条候选带有：


信息序列；


Path Metric；


候选有效标志。




逻辑码块CA-SCL管理层
Plain textca_scl_group
负责：


接收同一个逻辑 CRC 码块内的一个或多个 Polar 子块；


跨子块延续消息位置和 CRC 状态；


合并各子块候选；


在逻辑码块结束时执行 CRC24B 选择。


若前一阶段有 $L$ 条组合路径，当前子块也有 $L$ 条候选，就形成：
$L\times L$
个组合。默认 $L=4$ 时是 16 个组合，再剪枝回 4 条。
因此，第一版可以包含 CRC，但 CRC应当作为 scl_decoder_core 上方的独立模块，而不是硬塞进单子块核心里。

五、最终建议的模块结构
Plain textscl_decoder_top.v│├── scl_decoder_core.v│   ├── scl_controller.v│   ├── scl_datapath.v│   ├── sc_pe.v × LIST_SIZE × PE_PER_PATH│   ├── scl_llr_mem.v│   ├── scl_beta_mem.v│   ├── scl_uhat_mem.v│   ├── scl_pm_update.v│   └── scl_pruner.v│├── ca_scl_group.v│   ├── crc24b_path_update.v│   ├── group_candidate_merge.v│   └── final_path_selector.v│└── frozen_gen.v    └── polar_reliability_rom.v
核心参数建议为：
verilogparameter integer LIST_SIZE   = 4;parameter integer PE_PER_PATH = 1;parameter integer PM_W        = 24;parameter integer CRC_W       = 24;parameter [23:0] CRC_POLY     = 24'hB2B117;
同时加入参数检查：
veriloginitial begin    if ((LIST_SIZE & (LIST_SIZE-1)) != 0)        $error("LIST_SIZE必须为2的整数次幂");end
为了兼容普通 .v 文件和 Vivado，模块之间的多路径数据建议使用压平总线，而不是 SystemVerilog 数组端口，例如：
verilogwire [LIST_SIZE*PM_W-1:0] path_metric_bus;

六、DFS控制器如何处理
现在可以给出更准确的结论：
不保留现有 sc_controller 原代码，但保留其深度优先树调度和地址复用方式。
原因不是 SCL 必须使用 DFS，而是你现在的：
verilogMEM_DEPTH = 2*NMAX-1
以及：
verilogdepth_base()
依赖深度优先遍历重复使用各深度工作区。直接改成广度优先会使存储结构、地址生成和部分和管理全部重做。
新的高速结构是：
Plain text共享一套DFS树调度        ↓L条路径并行计算相同节点
默认 $L=4$ 时，至少使用4个 sc_pe，而不是一个 PE 轮流处理4条路径。因此保留 DFS 不等于保留低速单路径执行。
后续还可以参数化：
verilogPE_PER_PATH = 1、2、4、8
以增加节点内部并行度。具体 FPGA 型号确定后，再选 BRAM Bank 数量和最佳 PE 数量。

七、TB和已知正确结果不需要人工计算
已知正确的译码结果就是编码前构造的 u_ref。
自检 TB 可以完成：
Plain text固定消息→ 按当前crc_gen生成CRC24B→ 构造pad || message || CRC→ 根据frozen_mask构造u_ref→ Polar编码得到d→ d映射成量化LLR→ 送入SC/SCL→ 将译码u_hat与u_ref比较
第一组无噪声：
verilogllr[i] = d[i] ? -8'sd64 : 8'sd64;
然后增加确定性错误测试，例如将部分 LLR 改为：
Plain text正确但较弱：±2符号翻转：∓3其他位置：±64
这样可以构造出：
Plain textSC失败SCL-L4成功CA-SCL-L4通过CRC并选出正确路径
不需要你手工计算任何一组 64 位或 1024 位 SC 输出。
当前结论
目前不再需要其他代码。升级时会按以下顺序实施：


参数化 $L=4$ 的单 Polar 块 SCL 核；


加入前补零强制判决；


加入 $2L\rightarrow L$ 路径度量剪枝；


输出前 $L$ 条候选；


加入 CRC24B 逻辑码块管理层；


建立无噪声、弱错误和 CA-SCL 恢复三类自检 TB。

---

### User

你再看一遍CRC添加的编码逻辑，确认没有理解错的话，我们开始写scl了

---

### ChatGPT

我重新逐拍检查了 CRC 添加逻辑，现在理解是确定的。之前关于“逻辑 CRC 码块可能拆成多个 Polar 子块”的判断也正确，但需要把几个边界锁死。
CRC24B 的准确编码逻辑
1. 并非所有码块都添加 CRC
你的编码链中：


帧类型 2：不加 CRC；


帧类型 3/4，且 $B\le K_{1024}$：单块，不加 CRC；


帧类型 3/4，且 $B>K_{1024}$：启用码块 CRC24B，此后每个逻辑码块加 24 bit CRC。


满逻辑块的消息容量是：
$K_{\mathrm{msg}}=K_{1024}-24$
Polar 非冻结位数仍为：
$K_{\mathrm{blk}}=K_{1024}$

2. CRC 每个逻辑码块重新加载种子
CRC 参数为：
verilogPOLY = 24'hB2B117seed = crc_seed
广播场景使用：
verilogcrc_seed = 24'h555555
递推为：
verilogfb = r[23] ^ din;r_next =    {r[22:0], 1'b0} ^    (fb ? 24'hB2B117 : 24'd0);
crc_load 在：
verilogSB_FULL_INITSB_LAST_INIT
有效，因此每个新的逻辑 CRC 码块都会重新加载种子。
从 SB_FULL_INIT 转入 SB_LAST_INIT 时可能连续加载两次种子，但中间没有输入消息位，不会改变结果，只是重复装载，逻辑正确。

3. CRC 只计算原始消息，不计算前补零
虚拟序列为：
$V=0^{\mathrm{pad}}\parallel\mathrm{message}\parallel\mathrm{CRC24B}$
但 CRC 生成器使能条件是：
verilogcrc_en =    (state == S_ASM) &&    !cur_fz &&    in_msg &&    crc_on;
因此 CRC 只计算：
Plain textmessage
不计算：
Plain text前补零CRC字段自身Polar冻结位
这一点已经完全确认。

4. CRC 按高位优先附加
消息最后一位进入 LFSR 后，下一拍 crc_val 已经是最终余数。
CRC 字段的输出顺序是：
Plain textcrc_val[23]crc_val[22]...crc_val[0]
因为：
verilogcrc_rev[0]  = crc_val[23];crc_rev[23] = crc_val[0];vbit = crc_rev[vgap];
所以不存在“第一位 CRC 取到更新前状态”的时序问题。

5. vpos 是非冻结信息序列位置，不是自然叶索引
只有当前位置不是 Polar 冻结位时：
verilogvpos <= vpos + 1'b1;
因此编码关系为：
Plain text自然u索引    ↓ 根据 frozen mask 跳过冻结位非冻结序列c[0], c[1], ...    ↓pad || message || CRC
也就是说：


Polar 冻结位：固定为 0，不占用 vpos；


前补零：占用非冻结位置，但值固定为 0；


消息和 CRC：占用非冻结位置，值来自逻辑码块。


这意味着 SCL 中前补零应当作为 known-zero 位，强制判 0，但不能把它当作 Polar 冻结位统计。

6. 末逻辑块拆分时，CRC不能在每个Polar子块重置
当末逻辑块拆成：
Plain textN=512N=256N=128N=64
多个 Polar 子块时，以下状态都跨子块连续保持：
verilogvposmsg_shcrc_valpadvKmsg_cur
因此它们共同承载一个：
$0^{\mathrm{pad}}\parallel\mathrm{message}\parallel\mathrm{CRC24B}$
CRC 种子只在 SB_LAST_INIT 加载一次，绝不能在每个 Polar 子块开始时重置。

CA-SCL 的 CRC 检查方式
译码端采用与编码端相同的：
verilogPOLY = 24'hB2B117seed = crc_seed
对候选路径执行：


跳过前补零；


输入候选消息位；


再输入候选的 24 个 CRC 位；


最终状态为零则 CRC 通过。


即：
verilogcrc_pass = (crc_state == 24'd0);
这与“先计算消息余数，再逐位比较收到的 CRC”是等价的。后续硬件采用前一种方式，便于跨 Polar 子块连续更新。

正式开始 SCL 的实现边界
为了避免后面推翻接口，确定采用两层结构。
第一层：单 Polar 子块 SCL 核
Plain textscl_decoder_core
负责：


参数化 LIST_SIZE，默认 4；


$L$ 条路径并行执行；


信息位进行 $L\rightarrow2L$ 扩展；


根据 PM 剪枝回 $L$；


Polar 冻结位强制为 0；


当前子块的前补零位也强制为 0；


输出 $L$ 条候选的非冻结序列和路径度量。


参数先锁定为：
verilogparameter integer LIST_SIZE = 4;parameter integer PM_W      = 24;parameter integer PE_PER_PATH = 1;

第二层：逻辑码块 CA-SCL 管理器
Plain textca_scl_group
负责：


多个 Polar 子块之间的候选组合；


CRC 状态跨子块延续；


组合路径度量累加；


$L\times L\rightarrow L$ 组间剪枝；


逻辑码块结束时优先选择 CRC 通过且 PM 最小的路径；


无路径通过 CRC 时退化为全局 PM 最小路径。


因此 CRC 不会错误地在每个 Polar 子块中独立检查。

代码编写顺序
接下来按这个顺序实现，不再修改总体架构：


scl_pm_update.v：PM 扩展与饱和累加；


scl_pruner.v：参数化 $2L\rightarrow L$ 剪枝；


scl_llr_mem.v、scl_beta_mem.v、scl_uhat_mem.v；


scl_controller.v 和 scl_datapath.v；


scl_decoder_core.v；


crc24b_path_update.v；


ca_scl_group.v；


自检 TB。


CRC编码逻辑已经确认无误，可以正式开始写 SCL。第一阶段先完成单 Polar 子块的参数化 SCL 核，接口从一开始就保留全部 $L$ 条候选，确保随后接入 CRC24B 时不需要重构。

---

### User

要分那么多模块吗，你推荐什么样

---

### ChatGPT

不用拆成十几个小模块。针对你现在的代码规模、Vivado 和“优先速度”的要求，我推荐采用 6 个核心模块 + 1 个可选 CRC 外层模块，这是功能清晰和工程复杂度之间比较合适的方案。
推荐结构
Plain textca_scl_decoder_top.v          ← 完整CA-SCL顶层，可后加入└── scl_decoder_core.v        ← 单个Polar子块SCL核心    ├── scl_controller.v    ├── scl_datapath.v    ├── scl_llr_mem.v    ├── scl_path_mem.v    ├── scl_pruner.v    ├── sc_pe.v               ← 复用现有模块    └── frozen_gen.v          ← 复用现有模块        └── polar_reliability_rom.v
1. scl_decoder_core.v
相当于你现在的 sc_decoder_core.v，负责：


配置 $N、K$；


串行装载 LLR；


启动 SCL；


接收列表剪枝结果；


输出最佳路径或全部 $L$ 条候选；


对外隐藏内部路径编号和存储结构。


它只做模块连接和顶层状态管理，不放复杂算法。

2. scl_controller.v
由当前 sc_controller.v 改造，保留：
verilogcur_depthelement_indexcurrent_leafphase[]merge_second_writedepth_base()
新增：
verilogactive_path_maskpath_bank_mappath_metriccandidate_parentcandidate_bit
负责：


DFS 树调度；


冻结位处理；


信息位路径分裂；


启动剪枝；


剪枝后路径映射更新；


控制最终最优路径输出。


路径管理不要再单独拆一个 path_manager.v，直接放进控制器即可。

3. scl_datapath.v
负责计算部分：


实例化 LIST_SIZE 个 sc_pe；


每条有效路径并行执行 $f/g$；


计算叶节点 LLR 绝对值；


更新候选 PM；


根据控制器结果写回 LLR、beta 和 $u$。


路径度量的简单更新逻辑也放在这里，不再单独建立 scl_pm_update.v。
例如：
verilogcandidate_pm_0 =    path_pm + (leaf_llr[INT_W-1] ? leaf_abs : 0);candidate_pm_1 =    path_pm + (leaf_llr[INT_W-1] ? 0 : leaf_abs);
这样可以减少很多小模块和总线接口。

4. scl_llr_mem.v
LLR 存储单独保留，因为它：


位宽较大；


每条路径需要两个读操作数；


最可能使用 BRAM、LUTRAM 或分 Bank RAM；


后期会针对 FPGA 型号重点优化。


建议内部采用路径 Bank：
verilogllr_mem[path_bank][address]
对外增加：
verilogrd_path_ard_path_bwr_path
默认 $L=4$ 时，4 条路径并行读取。
不建议把 LLR 和 beta、u_hat 全塞进一个存储模块，否则端口会变得很乱，也不利于 Vivado 分别推断不同类型的 RAM。

5. scl_path_mem.v
将以下内容放到一个模块中：
Plain textbeta存储u_hat存储CRC状态路径有效标志
原因是这些都属于路径状态，而且容量相对不大：


beta：$L(2N-1)$ bit；


u_hat：$LN$ bit；


CRC：$24L$ bit；


路径标志：很少。


PM 可以放在控制器寄存器里，因为排序时控制器需要直接使用。
beta_mem 和 uhat_mem 在该模块内仍然使用两个独立数组，只是共用一个路径状态模块：
verilogreg beta_mem [0:LIST_SIZE-1][0:MEM_DEPTH-1];reg uhat_mem [0:LIST_SIZE-1][0:NMAX-1];reg [23:0] crc_state [0:LIST_SIZE-1];

6. scl_pruner.v
剪枝最好独立，因为它是 SCL 与 SC 最大的新增计算模块。
输入：
Plain text2L个candidate_pm2L个parent_path2L个candidate_bit2L个valid
输出：
Plain text最优L个PM对应父路径对应判决位
默认 $L=4$：
Plain text8个候选 → 选出最优4个
该模块独立的好处是：


可以单独写 TB；


可以先用简单组合排序；


后续替换成流水 Bitonic 排序网络时，不需要修改控制器和数据通路；


$L=2、4、8$ 可以统一参数化。


这是唯一值得单独拆出的“小算法模块”。

CRC 外层是否必须单独拆
建议单独保留：
Plain textca_scl_decoder_top.v
但第一步可以暂时不写。
原因是你的 CRC24B 对应的是逻辑码块，而一个逻辑码块有时会拆成多个 Polar 子块。单 Polar 子块核心只知道：
Plain textNK冻结位LLR
而 CRC 外层需要知道：
Plain text当前子块是否属于同一逻辑码块前补零长度消息长度是否最后一个子块CRC seed
这是两种完全不同的控制层级。强行把它们全部写进 scl_decoder_core.v，核心会变得非常难维护。
CRC 外层内部不用再拆：
Plain textcrc24b_update.vgroup_merge.vfinal_selector.v
这些逻辑都直接放在 ca_scl_decoder_top.v 中即可。

最终文件数量
新增或重写
Plain text1. scl_decoder_core.v2. scl_controller.v3. scl_datapath.v4. scl_llr_mem.v5. scl_path_mem.v6. scl_pruner.v7. ca_scl_decoder_top.v   // 第二阶段加入
直接复用
Plain textsc_pe.vfrozen_gen.vpolar_reliability_rom.v
也就是第一阶段实际上只需要维护 6 个 SCL 文件。
不推荐两种极端结构
全部放进一个模块
不推荐写成一个五六千行的：
Plain textscl_decoder.v
因为路径剪枝、存储映射和 DFS 状态机混在一起后，仿真出错很难定位，而且不会因为写在同一个文件里就更快。
拆成十几个极小模块
也没有必要拆出：
Plain textpm_update.vabs_llr.vpath_copy.vpath_manager.vcrc_update.vbest_path_select.v
这些逻辑规模小，直接合并到数据通路、控制器和 CRC 顶层中更合适。
Vivado 正常综合时可以跨普通模块边界优化，所以模块数量本身通常不会导致速度下降。真正需要避免的是给各层大量使用：
verilog(* DONT_TOUCH = "true" *)(* KEEP_HIERARCHY = "yes" *)
或者把每个小模块都单独做 OOC 综合。
推荐的最终方案
采用：
Plain text共享DFS调度+ L条路径并行PE+ 独立LLR多Bank+ 合并beta/uhat/CRC路径存储+ 独立2L→L剪枝器+ 外层逻辑码块CRC管理
默认参数：
verilogparameter integer LIST_SIZE   = 4;parameter integer PE_PER_PATH = 1;parameter integer PM_W        = 24;parameter integer CRC_W       = 24;parameter [23:0] CRC_POLY     = 24'hB2B117;
第一步先写并单独验证 scl_pruner.v，因为路径剪枝正确后，后面的控制器和存储路径映射才有可靠基础。

---

### User

给我完整scl_pruner

---

### ChatGPT

下面给你一版完整、可综合、兼容 Vivado/Icarus 的参数化 scl_pruner.v。
这版采用：


默认 LIST_SIZE=4；


输入 $2L$ 个候选，输出最优 $L$ 个；


Bitonic 排序网络，综合时完全展开；


有效候选优先；


PM 越小越优；


PM 相同时按父路径、判决位、原候选编号稳定排序；


默认增加一级输出寄存器；


支持 L=1/2/4/8 等 2 的整数次幂；


输出结果按 PM 从小到大排列，rank=0 是最佳路径。


verilog// =============================================================================// scl_pruner.v// =============================================================================// SCL 路径剪枝模块：从 2L 个候选路径中选择路径度量最小的 L 个候选。//// 推荐候选排列方式：////     candidate_index = 2 * parent_path + candidate_bit//// 例如 LIST_SIZE=4：////     cand[0] = parent0, u=0//     cand[1] = parent0, u=1//     cand[2] = parent1, u=0//     cand[3] = parent1, u=1//     ...//     cand[6] = parent3, u=0//     cand[7] = parent3, u=1//// 但模块本身不依赖该排列，只按照输入的：////     cand_valid//     cand_pm//     cand_parent//     cand_bit//// 完成排序。//// 排序优先级：////     1. valid=1 的候选优于 valid=0 的候选//     2. 路径度量 PM 较小者优先//     3. PM 相同时，父路径编号较小者优先//     4. 父路径相同时，candidate_bit=0 优先//     5. 仍然相同时，原候选索引较小者优先//// 输出：////     sel_xxx_bus[0]              = 最优候选 rank 0//     sel_xxx_bus[1]              = 次优候选 rank 1//     ...//     sel_xxx_bus[LIST_SIZE-1]    = 第 L 优候选//// 时序模式：////     REGISTER_OUTPUT = 1：//         输入 in_valid 在某个上升沿被采样，结果在该上升沿后输出，//         out_valid 拉高一个周期。模块内部无反压，in_ready 恒为1。////     REGISTER_OUTPUT = 0：//         纯组合输出，out_valid = in_valid。//         适合功能仿真，但不推荐直接用于高频率设计。//// 注意：//     本模块只负责选出幸存候选，不负责复制 LLR、beta、u_hat。//     路径复制或路径Bank重命名应由 scl_controller 根据：////         sel_parent_bus//         sel_bit_bus////     完成。// =============================================================================module scl_pruner #(    // -------------------------------------------------------------------------    // SCL 列表大小，要求为2的整数次幂    // -------------------------------------------------------------------------    parameter integer LIST_SIZE = 4,    // 路径度量位宽    parameter integer PM_W = 24,    // 路径编号位宽    //    // LIST_SIZE=4时 PATH_W=2    // LIST_SIZE=1时强制保持1位，避免零位宽    // -------------------------------------------------------------------------    parameter integer PATH_W =        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),    // 2L个候选的索引位宽    //    // LIST_SIZE=4时：    //     CAND_NUM=8    //     CAND_W=3    // -------------------------------------------------------------------------    parameter integer CAND_W =        ((2 * LIST_SIZE) <= 2)        ? 1        : $clog2(2 * LIST_SIZE),    // 1：输出增加一级寄存器    // 0：纯组合输出    parameter integer REGISTER_OUTPUT = 1)(    input  wire                              clk,    input  wire                              rst_n,    // =========================================================================    // 输入握手    // =========================================================================    // 当前2L个候选有效    input  wire                              in_valid,    // 本模块无反压，恒为1    output wire                              in_ready,    // =========================================================================    // 2L个候选输入    // =========================================================================    //    // 第i个候选字段位于：    //    //     cand_pm_bus[    //         i*PM_W +: PM_W    //     ]    //    //     cand_parent_bus[    //         i*PATH_W +: PATH_W    //     ]    //    //     cand_bit_bus[i]    //     cand_valid_bus[i]    // =========================================================================    input  wire [(2*LIST_SIZE)*PM_W-1:0]     cand_pm_bus,    input  wire [(2*LIST_SIZE)*PATH_W-1:0]   cand_parent_bus,    input  wire [(2*LIST_SIZE)-1:0]          cand_bit_bus,    input  wire [(2*LIST_SIZE)-1:0]          cand_valid_bus,    // =========================================================================    // 最优L个候选输出    // =========================================================================    output wire                              out_valid,    // rank=0 是路径度量最小的最佳候选    output wire [LIST_SIZE*PM_W-1:0]         sel_pm_bus,    output wire [LIST_SIZE*PATH_W-1:0]       sel_parent_bus,    output wire [LIST_SIZE-1:0]              sel_bit_bus,    output wire [LIST_SIZE-1:0]              sel_valid_bus,    // 被选中候选在原2L输入中的索引，主要用于调试和路径映射    output wire [LIST_SIZE*CAND_W-1:0]       sel_index_bus);    // =========================================================================    // 常量    // =========================================================================    localparam integer CAND_NUM = 2 * LIST_SIZE;    // 当前实现随时可接收一组新候选    assign in_ready = 1'b1;    // =========================================================================    // 工作数组    // =========================================================================    //    // Bitonic排序网络在综合时展开为固定比较交换网络。    // 使用blocking assignment描述每一级组合比较交换。    // =========================================================================    reg [PM_W-1:0]   work_pm     [0:CAND_NUM-1];    reg [PATH_W-1:0] work_parent [0:CAND_NUM-1];    reg              work_bit    [0:CAND_NUM-1];    reg              work_valid  [0:CAND_NUM-1];    reg [CAND_W-1:0] work_index  [0:CAND_NUM-1];    // 交换临时变量    reg [PM_W-1:0]   temp_pm;    reg [PATH_W-1:0] temp_parent;    reg              temp_bit;    reg              temp_valid;    reg [CAND_W-1:0] temp_index;    // 排序循环变量    integer sort_i;    integer sort_j;    integer sort_k;    integer sort_ixj;    // 输出打包循环变量    integer out_i;    // =========================================================================    // 组合排序结果    // =========================================================================    reg [LIST_SIZE*PM_W-1:0]     sel_pm_comb;    reg [LIST_SIZE*PATH_W-1:0]   sel_parent_comb;    reg [LIST_SIZE-1:0]          sel_bit_comb;    reg [LIST_SIZE-1:0]          sel_valid_comb;    reg [LIST_SIZE*CAND_W-1:0]   sel_index_comb;    // =========================================================================    // 候选大小比较函数    // =========================================================================    //    // 返回1表示候选A的排序优先级比候选B低，即：    //    //     A > B    //    // 如果执行升序排列，A > B 时交换A和B。    // =========================================================================    function item_greater;        input                   valid_a;        input [PM_W-1:0]        pm_a;        input [PATH_W-1:0]      parent_a;        input                   bit_a;        input [CAND_W-1:0]      index_a;        input                   valid_b;        input [PM_W-1:0]        pm_b;        input [PATH_W-1:0]      parent_b;        input                   bit_b;        input [CAND_W-1:0]      index_b;        begin            // -------------------------------------------------------------            // 有效候选始终优于无效候选            // -------------------------------------------------------------            if (valid_a != valid_b) begin                // A无效、B有效时，A更大                item_greater = !valid_a;            end            // -------------------------------------------------------------            // 两者均无效            //            // 按原候选索引排序，使仿真结果完全确定。            // -------------------------------------------------------------            else if (!valid_a) begin                item_greater = (index_a > index_b);            end            // -------------------------------------------------------------            // 首先比较路径度量            // -------------------------------------------------------------            else if (pm_a != pm_b) begin                item_greater = (pm_a > pm_b);            end            // -------------------------------------------------------------            // PM相同，父路径编号较小者优先            // -------------------------------------------------------------            else if (parent_a != parent_b) begin                item_greater = (parent_a > parent_b);            end            // -------------------------------------------------------------            // 父路径也相同，u=0优先            // -------------------------------------------------------------            else if (bit_a != bit_b) begin                item_greater = (bit_a > bit_b);            end            // -------------------------------------------------------------            // 完全相同则按原候选索引稳定排序            // -------------------------------------------------------------            else begin                item_greater = (index_a > index_b);            end        end    endfunction    // =========================================================================    // Bitonic排序网络    // =========================================================================    //    // 标准Bitonic排序算法：    //    //     k = 2,4,8,...,CAND_NUM    //         j = k/2,k/4,...,1    //             对 i 与 i XOR j 执行比较交换    //    // CAND_NUM必须为2的整数次幂。    //    // 对 LIST_SIZE=4：    //    //     CAND_NUM = 8    //    // 最终形成8输入升序排序网络，前4项即为幸存路径。    // =========================================================================    always @* begin        // ---------------------------------------------------------------------        // 默认值        // ---------------------------------------------------------------------        temp_pm     = {PM_W{1'b0}};        temp_parent = {PATH_W{1'b0}};        temp_bit    = 1'b0;        temp_valid  = 1'b0;        temp_index  = {CAND_W{1'b0}};        sel_pm_comb     = {(LIST_SIZE*PM_W){1'b0}};        sel_parent_comb = {(LIST_SIZE*PATH_W){1'b0}};        sel_bit_comb    = {LIST_SIZE{1'b0}};        sel_valid_comb  = {LIST_SIZE{1'b0}};        sel_index_comb  = {(LIST_SIZE*CAND_W){1'b0}};        // ---------------------------------------------------------------------        // 解包2L个候选        // ---------------------------------------------------------------------        for (sort_i = 0;             sort_i < CAND_NUM;             sort_i = sort_i + 1) begin            work_pm[sort_i] =                cand_pm_bus[                    sort_i*PM_W +: PM_W                ];            work_parent[sort_i] =                cand_parent_bus[                    sort_i*PATH_W +: PATH_W                ];            work_bit[sort_i] =                cand_bit_bus[sort_i];            work_valid[sort_i] =                cand_valid_bus[sort_i];            work_index[sort_i] =                sort_i[CAND_W-1:0];        end        // ---------------------------------------------------------------------        // Bitonic比较交换网络        // ---------------------------------------------------------------------        for (sort_k = 2;             sort_k <= CAND_NUM;             sort_k = sort_k * 2) begin            for (sort_j = sort_k / 2;                 sort_j > 0;                 sort_j = sort_j / 2) begin                for (sort_i = 0;                     sort_i < CAND_NUM;                     sort_i = sort_i + 1) begin                    sort_ixj = sort_i ^ sort_j;                    // 每一对只处理一次                    if (sort_ixj > sort_i) begin                        // =====================================================                        // 升序区                        // =====================================================                        if ((sort_i & sort_k) == 0) begin                            if (item_greater(                                work_valid[sort_i],                                work_pm[sort_i],                                work_parent[sort_i],                                work_bit[sort_i],                                work_index[sort_i],                                work_valid[sort_ixj],                                work_pm[sort_ixj],                                work_parent[sort_ixj],                                work_bit[sort_ixj],                                work_index[sort_ixj]                            )) begin                                // ---------------------------------------------                                // 交换PM                                // ---------------------------------------------                                temp_pm =                                    work_pm[sort_i];                                work_pm[sort_i] =                                    work_pm[sort_ixj];                                work_pm[sort_ixj] =                                    temp_pm;                                // ---------------------------------------------                                // 交换父路径                                // ---------------------------------------------                                temp_parent =                                    work_parent[sort_i];                                work_parent[sort_i] =                                    work_parent[sort_ixj];                                work_parent[sort_ixj] =                                    temp_parent;                                // ---------------------------------------------                                // 交换候选判决位                                // ---------------------------------------------                                temp_bit =                                    work_bit[sort_i];                                work_bit[sort_i] =                                    work_bit[sort_ixj];                                work_bit[sort_ixj] =                                    temp_bit;                                // ---------------------------------------------                                // 交换有效标志                                // ---------------------------------------------                                temp_valid =                                    work_valid[sort_i];                                work_valid[sort_i] =                                    work_valid[sort_ixj];                                work_valid[sort_ixj] =                                    temp_valid;                                // ---------------------------------------------                                // 交换原始候选索引                                // ---------------------------------------------                                temp_index =                                    work_index[sort_i];                                work_index[sort_i] =                                    work_index[sort_ixj];                                work_index[sort_ixj] =                                    temp_index;                            end                        end                        // =====================================================                        // 降序区                        // =====================================================                        else begin                            if (item_greater(                                work_valid[sort_ixj],                                work_pm[sort_ixj],                                work_parent[sort_ixj],                                work_bit[sort_ixj],                                work_index[sort_ixj],                                work_valid[sort_i],                                work_pm[sort_i],                                work_parent[sort_i],                                work_bit[sort_i],                                work_index[sort_i]                            )) begin                                // ---------------------------------------------                                // 交换PM                                // ---------------------------------------------                                temp_pm =                                    work_pm[sort_i];                                work_pm[sort_i] =                                    work_pm[sort_ixj];                                work_pm[sort_ixj] =                                    temp_pm;                                // ---------------------------------------------                                // 交换父路径                                // ---------------------------------------------                                temp_parent =                                    work_parent[sort_i];                                work_parent[sort_i] =                                    work_parent[sort_ixj];                                work_parent[sort_ixj] =                                    temp_parent;                                // ---------------------------------------------                                // 交换候选判决位                                // ---------------------------------------------                                temp_bit =                                    work_bit[sort_i];                                work_bit[sort_i] =                                    work_bit[sort_ixj];                                work_bit[sort_ixj] =                                    temp_bit;                                // ---------------------------------------------                                // 交换有效标志                                // ---------------------------------------------                                temp_valid =                                    work_valid[sort_i];                                work_valid[sort_i] =                                    work_valid[sort_ixj];                                work_valid[sort_ixj] =                                    temp_valid;                                // ---------------------------------------------                                // 交换原始候选索引                                // ---------------------------------------------                                temp_index =                                    work_index[sort_i];                                work_index[sort_i] =                                    work_index[sort_ixj];                                work_index[sort_ixj] =                                    temp_index;                            end                        end                    end                end            end        end        // ---------------------------------------------------------------------        // 排序完成后，取最前面的L个候选        // ---------------------------------------------------------------------        for (out_i = 0;             out_i < LIST_SIZE;             out_i = out_i + 1) begin            sel_pm_comb[                out_i*PM_W +: PM_W            ] =                work_pm[out_i];            sel_parent_comb[                out_i*PATH_W +: PATH_W            ] =                work_parent[out_i];            sel_bit_comb[out_i] =                work_bit[out_i];            sel_valid_comb[out_i] =                work_valid[out_i];            sel_index_comb[                out_i*CAND_W +: CAND_W            ] =                work_index[out_i];        end    end    // =========================================================================    // 输出模式    // =========================================================================    generate        if (REGISTER_OUTPUT != 0) begin : g_registered_output            reg                            out_valid_reg;            reg [LIST_SIZE*PM_W-1:0]       sel_pm_reg;            reg [LIST_SIZE*PATH_W-1:0]     sel_parent_reg;            reg [LIST_SIZE-1:0]            sel_bit_reg;            reg [LIST_SIZE-1:0]            sel_valid_reg;            reg [LIST_SIZE*CAND_W-1:0]     sel_index_reg;            always @(posedge clk or negedge rst_n) begin                if (!rst_n) begin                    out_valid_reg  <= 1'b0;                    sel_pm_reg     <= {(LIST_SIZE*PM_W){1'b0}};                    sel_parent_reg <= {(LIST_SIZE*PATH_W){1'b0}};                    sel_bit_reg    <= {LIST_SIZE{1'b0}};                    sel_valid_reg  <= {LIST_SIZE{1'b0}};                    sel_index_reg  <= {(LIST_SIZE*CAND_W){1'b0}};                end                else begin                    out_valid_reg <= in_valid;                    if (in_valid) begin                        sel_pm_reg     <= sel_pm_comb;                        sel_parent_reg <= sel_parent_comb;                        sel_bit_reg    <= sel_bit_comb;                        sel_valid_reg  <= sel_valid_comb;                        sel_index_reg  <= sel_index_comb;                    end                end            end            assign out_valid      = out_valid_reg;            assign sel_pm_bus     = sel_pm_reg;            assign sel_parent_bus = sel_parent_reg;            assign sel_bit_bus    = sel_bit_reg;            assign sel_valid_bus  = sel_valid_reg;            assign sel_index_bus  = sel_index_reg;        end        else begin : g_combinational_output            assign out_valid      = in_valid;            assign sel_pm_bus     = sel_pm_comb;            assign sel_parent_bus = sel_parent_comb;            assign sel_bit_bus    = sel_bit_comb;            assign sel_valid_bus  = sel_valid_comb;            assign sel_index_bus  = sel_index_comb;        end    endgenerate    // =========================================================================    // 参数合法性检查    // =========================================================================    //    // 仅用于仿真检查，综合工具一般会忽略initial中的系统任务。    // =========================================================================    initial begin        if (LIST_SIZE < 1) begin            $display(                "scl_pruner ERROR: LIST_SIZE=%0d，必须大于等于1",                LIST_SIZE            );            $finish;        end        if ((LIST_SIZE & (LIST_SIZE - 1)) != 0) begin            $display(                "scl_pruner ERROR: LIST_SIZE=%0d，必须为2的整数次幂",                LIST_SIZE            );            $finish;        end        if (PM_W < 1) begin            $display(                "scl_pruner ERROR: PM_W=%0d，必须大于等于1",                PM_W            );            $finish;        end        if ((REGISTER_OUTPUT != 0) &&            (REGISTER_OUTPUT != 1)) begin            $display(                "scl_pruner ERROR: REGISTER_OUTPUT只能为0或1"            );            $finish;        end    endendmodule
与控制器连接时的候选打包
默认推荐按照“每条父路径产生两个候选”打包：
veriloggenvar p;generate    for (p = 0; p < LIST_SIZE; p = p + 1) begin : g_pack_candidate        // 父路径p、判决0        assign cand_pm_bus[            (2*p)*PM_W +: PM_W        ] = candidate_pm_0[p];        assign cand_parent_bus[            (2*p)*PATH_W +: PATH_W        ] = p[PATH_W-1:0];        assign cand_bit_bus[2*p] = 1'b0;        assign cand_valid_bus[2*p] =            active_path_mask[p];        // 父路径p、判决1        assign cand_pm_bus[            (2*p+1)*PM_W +: PM_W        ] = candidate_pm_1[p];        assign cand_parent_bus[            (2*p+1)*PATH_W +: PATH_W        ] = p[PATH_W-1:0];        assign cand_bit_bus[2*p+1] = 1'b1;        assign cand_valid_bus[2*p+1] =            active_path_mask[p];    endendgenerate
实例化方式：
veriloglocalparam integer LIST_SIZE = 4;localparam integer PATH_W    = $clog2(LIST_SIZE);localparam integer PM_W      = 24;scl_pruner #(    .LIST_SIZE      (LIST_SIZE),    .PM_W           (PM_W),    .PATH_W         (PATH_W),    .REGISTER_OUTPUT(1))u_scl_pruner (    .clk             (clk),    .rst_n           (rst_n),    .in_valid        (pruner_in_valid),    .in_ready        (pruner_in_ready),    .cand_pm_bus     (candidate_pm_bus),    .cand_parent_bus (candidate_parent_bus),    .cand_bit_bus    (candidate_bit_bus),    .cand_valid_bus  (candidate_valid_bus),    .out_valid       (pruner_out_valid),    .sel_pm_bus      (selected_pm_bus),    .sel_parent_bus  (selected_parent_bus),    .sel_bit_bus     (selected_bit_bus),    .sel_valid_bus   (selected_valid_bus),    .sel_index_bus   (selected_index_bus));
默认 LIST_SIZE=4 时，综合得到的是 8 输入 Bitonic 排序网络，取前 4 项。REGISTER_OUTPUT=1 时，控制器在 pruner_in_valid 拉高后，下一拍检查 pruner_out_valid，再提交新的路径映射。

---

### User

控制器连接时的候选打包,这是写在哪的

---

### ChatGPT

这段不是写在 scl_pruner.v 里面，也不是写在 testbench 里。
按照目前推荐的结构，应该写在：
Plain textscl_decoder_core.v
位置就在：
Plain text候选路径度量信号声明→ 候选打包→ 实例化 scl_pruner→ 将剪枝结果送回 scl_controller
也就是说，scl_decoder_core.v 负责把控制器、数据通路和剪枝器连接起来。

推荐的模块关系
Plain textscl_controller    │    ├── active_path_mask    ├── pruner_in_valid    │    ▼scl_datapath    │    ├── 每条路径的 candidate_pm_0    └── 每条路径的 candidate_pm_1    │    ▼scl_decoder_core    │    ├── 将上述候选打包成总线    └── 实例化 scl_pruner            │            ▼       剪枝结果返回 controller
因此，scl_decoder_core.v 相当于总装配模块。

一、在 scl_decoder_core.v 中声明信号
放在内部连线区域，例如你现在 sc_decoder_core.v 中：
verilog// controller与datapath内部连线
附近。
verilog// =============================================================================// SCL 参数// =============================================================================localparam integer PATH_W =    (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE);localparam integer CAND_NUM =    2 * LIST_SIZE;localparam integer CAND_W =    (CAND_NUM <= 2) ? 1 : $clog2(CAND_NUM);// =============================================================================// 路径状态// =============================================================================// 当前有效路径wire [LIST_SIZE-1:0] active_path_mask;// =============================================================================// datapath产生的候选路径度量// =============================================================================//// 第p条路径对应：//// candidate_pm_0_bus[p*PM_W +: PM_W]// candidate_pm_1_bus[p*PM_W +: PM_W]//wire [LIST_SIZE*PM_W-1:0] candidate_pm_0_bus;wire [LIST_SIZE*PM_W-1:0] candidate_pm_1_bus;// =============================================================================// 送入pruner的2L个候选// =============================================================================wire [CAND_NUM*PM_W-1:0]   candidate_pm_bus;wire [CAND_NUM*PATH_W-1:0] candidate_parent_bus;wire [CAND_NUM-1:0]        candidate_bit_bus;wire [CAND_NUM-1:0]        candidate_valid_bus;// =============================================================================// pruner握手// =============================================================================wire pruner_in_valid;wire pruner_in_ready;wire pruner_out_valid;// =============================================================================// pruner选择结果// =============================================================================wire [LIST_SIZE*PM_W-1:0]   selected_pm_bus;wire [LIST_SIZE*PATH_W-1:0] selected_parent_bus;wire [LIST_SIZE-1:0]        selected_bit_bus;wire [LIST_SIZE-1:0]        selected_valid_bus;wire [LIST_SIZE*CAND_W-1:0] selected_index_bus;
注意，顶层参数里需要增加：
verilogparameter integer LIST_SIZE = 4,parameter integer PM_W      = 24
例如：
verilogmodule scl_decoder_core #(    parameter integer NMAX      = 1024,    parameter integer LLR_W     = 8,    parameter integer INT_W     = 10,    parameter integer MAX_LOG   = 10,    parameter integer MEM_DEPTH = 2 * NMAX - 1,    parameter integer ADDR_W    = 11,    parameter integer INDEX_W   = 11,    parameter integer LIST_SIZE = 4,    parameter integer PM_W      = 24)(

二、候选打包写在 scl_decoder_core.v
建议放在 scl_datapath 实例化之后、scl_pruner 实例化之前。
verilog// =============================================================================// SCL候选路径打包// =============================================================================//// 候选排列：//// candidate[2*p]     = 父路径p扩展判决0// candidate[2*p + 1] = 父路径p扩展判决1//// 例如LIST_SIZE=4：//// 0 = path0, u=0// 1 = path0, u=1// 2 = path1, u=0// 3 = path1, u=1// 4 = path2, u=0// 5 = path2, u=1// 6 = path3, u=0// 7 = path3, u=1// =============================================================================genvar pack_p;generate    for (        pack_p = 0;        pack_p < LIST_SIZE;        pack_p = pack_p + 1    ) begin : g_pack_candidate        // -------------------------------------------------------------        // 当前父路径编号        // -------------------------------------------------------------        localparam [PATH_W-1:0] PARENT_ID =            pack_p;        // -------------------------------------------------------------        // 候选0：当前路径判决u=0        // -------------------------------------------------------------        assign candidate_pm_bus[            (2 * pack_p) * PM_W +: PM_W        ] =            candidate_pm_0_bus[                pack_p * PM_W +: PM_W            ];        assign candidate_parent_bus[            (2 * pack_p) * PATH_W +: PATH_W        ] =            PARENT_ID;        assign candidate_bit_bus[            2 * pack_p        ] =            1'b0;        assign candidate_valid_bus[            2 * pack_p        ] =            active_path_mask[pack_p];        // -------------------------------------------------------------        // 候选1：当前路径判决u=1        // -------------------------------------------------------------        assign candidate_pm_bus[            (2 * pack_p + 1) * PM_W +: PM_W        ] =            candidate_pm_1_bus[                pack_p * PM_W +: PM_W            ];        assign candidate_parent_bus[            (2 * pack_p + 1) * PATH_W +: PATH_W        ] =            PARENT_ID;        assign candidate_bit_bus[            2 * pack_p + 1        ] =            1'b1;        assign candidate_valid_bus[            2 * pack_p + 1        ] =            active_path_mask[pack_p];    endendgenerate
这里用：
veriloglocalparam [PATH_W-1:0] PARENT_ID = pack_p;
比直接写：
verilogpack_p[PATH_W-1:0]
兼容性更好，因为 pack_p 是 genvar，并不是普通逻辑向量。

三、紧接着实例化 scl_pruner
verilog// =============================================================================// SCL路径剪枝器// =============================================================================scl_pruner #(    .LIST_SIZE       (LIST_SIZE),    .PM_W            (PM_W),    .PATH_W          (PATH_W),    .CAND_W          (CAND_W),    .REGISTER_OUTPUT (1))u_scl_pruner (    .clk             (clk),    .rst_n           (rst_n),    .in_valid        (pruner_in_valid),    .in_ready        (pruner_in_ready),    .cand_pm_bus     (candidate_pm_bus),    .cand_parent_bus (candidate_parent_bus),    .cand_bit_bus    (candidate_bit_bus),    .cand_valid_bus  (candidate_valid_bus),    .out_valid       (pruner_out_valid),    .sel_pm_bus      (selected_pm_bus),    .sel_parent_bus  (selected_parent_bus),    .sel_bit_bus     (selected_bit_bus),    .sel_valid_bus   (selected_valid_bus),    .sel_index_bus   (selected_index_bus));

四、这些信号分别从哪里来
candidate_pm_0_bus 和 candidate_pm_1_bus
由 scl_datapath.v 输出。
所以 scl_datapath 需要新增端口：
verilogoutput wire [LIST_SIZE*PM_W-1:0] candidate_pm_0_bus,output wire [LIST_SIZE*PM_W-1:0] candidate_pm_1_bus
它根据每条路径当前的：
Plain text路径PM叶节点LLR
计算两个候选度量。
例如路径 $p$：
verilogcandidate_pm_0 =    path_pm +    (        leaf_llr < 0        ? abs_llr        : 0    );candidate_pm_1 =    path_pm +    (        leaf_llr >= 0        ? abs_llr        : 0    );

active_path_mask
由 scl_controller.v 输出。
控制器新增端口：
verilogoutput reg [LIST_SIZE-1:0] active_path_mask
初始化时只有路径 0 有效：
verilogactive_path_mask <= {{(LIST_SIZE-1){1'b0}}, 1'b1};
也就是默认 $L=4$：
Plain textactive_path_mask = 4'b0001
随着信息位分裂和剪枝，逐渐增加到：
Plain textactive_path_mask = 4'b1111

pruner_in_valid
由 scl_controller.v 输出。
当控制器已经计算完当前信息位的 $2L$ 个候选 PM 时，拉高一个周期：
verilogpruner_in_valid <= 1'b1;
由于你的剪枝器设置：
verilog.REGISTER_OUTPUT(1)
所以时序为：
Plain text第T拍：pruner_in_valid = 1，输入2L个候选第T+1拍：pruner_out_valid = 1，输出最优L个
控制器在 pruner_out_valid 为 1 时读取：
verilogselected_pm_busselected_parent_busselected_bit_busselected_valid_bus
然后完成路径更新。

五、剪枝结果送回控制器
scl_controller 需要增加输入端口：
veriloginput wire                          pruner_out_valid,input wire [LIST_SIZE*PM_W-1:0]    selected_pm_bus,input wire [LIST_SIZE*PATH_W-1:0]  selected_parent_bus,input wire [LIST_SIZE-1:0]         selected_bit_bus,input wire [LIST_SIZE-1:0]         selected_valid_bus
控制器输出：
verilogoutput reg pruner_in_valid
连接示例：
verilogscl_controller #(    .NMAX      (NMAX),    .MAX_LOG   (MAX_LOG),    .ADDR_W    (ADDR_W),    .INDEX_W   (INDEX_W),    .LIST_SIZE (LIST_SIZE),    .PM_W      (PM_W),    .PATH_W    (PATH_W))u_controller (    .clk                 (clk),    .rst_n               (rst_n),    // 其他控制接口省略    .active_path_mask    (active_path_mask),    .pruner_in_valid     (pruner_in_valid),    .pruner_in_ready     (pruner_in_ready),    .pruner_out_valid    (pruner_out_valid),    .selected_pm_bus     (selected_pm_bus),    .selected_parent_bus (selected_parent_bus),    .selected_bit_bus    (selected_bit_bus),    .selected_valid_bus  (selected_valid_bus));

六、为什么建议写在 scl_decoder_core.v
因为这些信号来自三个不同模块：
Plain textactive_path_mask    来自controllercandidate_pm_0/1    来自datapathselected_xxx    来自pruner
如果把候选打包写在 scl_controller.v：


必须把所有候选 PM 拉进控制器；


控制器端口会非常宽；


控制器同时承担状态机和排序连线，结构混乱。


如果写在 scl_datapath.v：


datapath 需要知道 active path 和父路径管理；


数据运算和路径管理耦合。


放在 scl_decoder_core.v 最合适，因为它本来就负责模块间接线。
最终放置顺序
你的 scl_decoder_core.v 建议按以下顺序写：
Plain text1. 参数和localparam2. 配置状态机3. frozen_gen4. controller/datapath/pruner内部连线声明5. scl_datapath实例6. 候选路径打包generate7. scl_pruner实例8. scl_controller实例9. 顶层配置/码块状态控制
所以这段候选打包代码的准确位置就是：
Plain textscl_datapath实例之后scl_pruner实例之前

---

### User

那下面写哪个模块的代码

---

### ChatGPT

下面先写 scl_llr_mem.v，暂时不要直接写控制器。
原因是 SCL 最关键的变化不是排序，而是：

剪枝后，新的逻辑路径怎样继续访问其父路径原有的 LLR 状态。

如果先写控制器，之后 LLR 存储选择“整路径复制、路径映射还是写时复制”发生变化，控制器接口也要跟着重写。
推荐顺序是：
Plain text1. scl_pruner.v       已完成2. scl_llr_mem.v      下一步3. scl_path_mem.v     beta + uhat4. scl_datapath.v     多路径PE、候选PM计算5. scl_controller.v   DFS调度、分裂和剪枝提交6. scl_decoder_core.v 模块连接和候选打包7. CA-SCL CRC外层
scl_llr_mem.v 准备采用的结构
考虑你优先高速度，下一版不会使用“一个 PE 在四条路径之间轮询”，而是：
Plain textLIST_SIZE=4├── path 0 LLR读写端口├── path 1 LLR读写端口├── path 2 LLR读写端口└── path 3 LLR读写端口
接口会参数化：
verilogparameter integer LIST_SIZE = 4;
每条路径同周期可获得两个 LLR：
verilogrd_data_a_bus[path]rd_data_b_bus[path]
并写入一个 PE 结果：
verilogwr_data_bus[path]
根信道 LLR 对所有路径相同，因此根层数据只装载一次；路径相关的中间 LLR 状态再按路径存储。这样比简单复制四份根 LLR 更合理。
此外会预留路径复制/映射接口，供剪枝后处理“两个幸存候选来自同一父路径”的情况。下一步就写完整的 scl_llr_mem.v。

---

### User

我现在想新开一个对话，整理所有你需要的已知信息，生成一个指令，让新对话能完美衔接现在对话，或者可以告诉新对话还需要我重新给他提供哪些信息如果概括不好概括的话

---

### ChatGPT

可以新开对话。下面这段直接复制到新对话作为第一条指令，能把当前设计决策、编码规则和下一步任务完整衔接起来。

可直接复制到新对话的衔接指令
Plain text我正在把一套 Verilog Polar SC 译码器升级为参数化 SCL/CA-SCL 译码器。请严格延续下面已经确定的设计，不要重新从零规划，也不要擅自改动编码位序和 CRC 规则。============================================================一、开发环境和总体目标============================================================1. 编程语言：Verilog-2001，优先兼容 Vivado，同时兼容 Icarus/Verilator。2. 工具：Vivado。3. FPGA 型号暂未确定。4. 优先级：速度优先，其次才是资源。5. Polar 码最大码长：   NMAX = 1024   MAX_LOG = 10   支持 N = 64/128/256/512/1024。6. 信道 LLR 位宽：   LLR_W = 8   内部 LLR 位宽：   INT_W = 10。7. SCL 列表大小必须参数化：   parameter integer LIST_SIZE = 4   默认 L=4，最好支持 L=1/2/4/8，限制为2的整数次幂。8. 路径度量位宽暂定：   parameter integer PM_W = 24。9. 默认每条路径一个 PE：   PE_PER_PATH = 1。   L=4 时希望4条路径并行计算，而不是一个PE轮流计算4条路径。10. 第一阶段实现单个 Polar 子块 SCL 核；第二阶段再接逻辑码块级 CRC24B 管理。============================================================二、现有 SC 译码器结构============================================================已有模块：1. sc_decoder_core.v2. sc_controller.v3. sc_datapath.v4. sc_pe.v5. sc_llr_mem.v6. sc_beta_mem.v7. sc_uhat_mem.v8. frozen_gen.v9. polar_reliability_rom.v现有 SC 是：- 单路径；- 单 PE；- DFS 深度优先树遍历；- phase 分为：  PH_F：计算左子节点 LLR  PH_G：计算右子节点 LLR  PH_C：beta 合并- 使用：  cur_depth  element_index  current_leaf  phase[]  merge_second_write- 每层工作区地址采用 depth_base()；- 总存储深度：  MEM_DEPTH = 2*NMAX-1；- 当前存储结构依赖 DFS 对不同深度工作区进行复用。SCL 不要求原样保留旧 sc_controller，但应复用其正确的：- DFS树调度思想；- PH_F/PH_G/PH_C执行顺序；- depth_base地址关系；- beta合并规则。推荐架构是：共享一套树调度器+ LIST_SIZE 条路径并行 PE+ 路径化 LLR/beta/u_hat 存储+ 参数化 2L→L 路径剪枝器。不要简单地让单 PE 在所有路径之间逐条轮询，除非明确说明只是低速功能验证版本。============================================================三、现有 PE 算法============================================================sc_pe.v 已经完成，可以直接复用。f 运算采用 min-sum：f(a,b) =sign(a) XOR sign(b) × min(abs(a),abs(b))g 运算：beta=0：b+abeta=1：b-a包含有符号饱和处理。LLR 定义为：LLR >= 0：倾向比特0LLR < 0：倾向比特1叶节点硬判决是 LLR 符号位。============================================================四、路径度量规则============================================================采用硬件友好的近似路径度量。令：hard_bit = llr[INT_W-1]abs_llr  = |llr|候选 u=0：PM0 = PM_old + ((hard_bit == 1) ? abs_llr : 0)候选 u=1：PM1 = PM_old + ((hard_bit == 0) ? abs_llr : 0)冻结位或其他已知固定0位不分裂，但仍按候选 u=0 更新 PM：PM_new = PM0PM 累加必须使用无符号饱和，不能溢出回绕。============================================================五、已经完成的 scl_pruner.v============================================================已经生成了完整的参数化 scl_pruner.v。功能：- 输入2*LIST_SIZE个候选；- 输出最优LIST_SIZE个；- 默认 LIST_SIZE=4，即8选4；- 参数：  LIST_SIZE  PM_W  PATH_W  CAND_W  REGISTER_OUTPUT- LIST_SIZE要求为2的整数次幂；- REGISTER_OUTPUT默认等于1；- 使用固定展开的 Bitonic 比较交换网络；- 输入字段：  cand_pm_bus  cand_parent_bus  cand_bit_bus  cand_valid_bus- 输出字段：  sel_pm_bus  sel_parent_bus  sel_bit_bus  sel_valid_bus  sel_index_bus- 排序优先级：  1. valid=1优先；  2. PM小者优先；  3. parent编号小者优先；  4. bit=0优先；  5. 原candidate index小者优先。- 输出rank 0是最佳候选。候选固定按下面方式打包：candidate[2*p]：  parent=p  bit=0  pm=candidate_pm_0[p]candidate[2*p+1]：  parent=p  bit=1  pm=candidate_pm_1[p]候选打包逻辑不写在 pruner 内，而应写在 scl_decoder_core.v 中：scl_datapath实例→ 候选总线打包→ scl_pruner实例→ 剪枝结果送回scl_controller。我会重新提供 scl_pruner.v 的完整代码，请不要重新生成另一个不兼容版本。============================================================六、推荐模块数量============================================================第一阶段不要拆成十几个小模块，推荐：1. scl_decoder_core.v2. scl_controller.v3. scl_datapath.v4. scl_llr_mem.v5. scl_path_mem.v6. scl_pruner.v7. sc_pe.v，直接复用8. frozen_gen.v，直接复用9. polar_reliability_rom.v，直接复用其中 scl_path_mem.v 内部可以同时管理：- beta_mem- uhat_mem- 必要的路径状态PM主要由controller/datapath管理。第二阶段增加：10. ca_scl_decoder_top.v不需要把 abs、PM更新、best-path-select 等简单逻辑继续拆成大量小文件。============================================================七、Polar编码和比特顺序============================================================现有编码模块包括：- polar_encoder.v- polar_butterfly.v- polar_encode_chain.v- polar_encode_stream.v- code_block_concat.v- crc_gen.v编码顺序已经确认：1. 消息比特 a0 先输入；2. 非冻结序列按自然顺序填入：   u[0],u[1],...,u[N-1]；3. frozen[n]=1时u[n]=0；4. 非冻结位依次填入 c[0],c[1],...；5. Polar蝶形没有额外bit reversal；6. 码字按：   d[0],d[1],...,d[N-1]   串行输出；7. 译码端根LLR地址0对应d[0]。无噪声测试时可使用：code_bit=0 → LLR=+64code_bit=1 → LLR=-64即：llr[i] = d[i] ? -8'sd64 : 8'sd64============================================================八、冻结集规则============================================================frozen_gen 根据 polar_reliability_rom 生成冻结掩码。可靠度序列：- rank 0最不可靠；- rank 1023最可靠；- 从高rank向低rank扫描；- 取索引<N的最高可靠K个位置作为非冻结位；- frozen[i]=1表示冻结；- frozen[i]=0表示非冻结。============================================================九、CRC24B编码规则，必须完全按现有工程实现============================================================不要使用常见的 CRC24B 掩码 24'h800063。本工程 CRC24B 参数必须使用：POLY = 24'hB2B117seed = crc_seed广播类通常：crc_seed = 24'h555555LFSR更新规则：fb = r[23] ^ dinr_next =    {r[22:0],1'b0}    XOR    (fb ? 24'hB2B117 : 24'd0)消息输入顺序为MSB-first，即a0先进入。CRC生成完成后，CRC字段追加顺序是：crc_val[23],crc_val[22],...crc_val[0]CRC检查时，将候选消息位和接收到的24个CRC位以相同顺序输入同一个LFSR，最终状态为0表示CRC通过。============================================================十、CRC并非所有码块都有============================================================帧类型2：- 不使用CRC。帧类型3/4：- B <= K1024时，单块，不添加码块CRC；- B > K1024时，启用码块CRC24B；- 每个逻辑码块重新加载CRC seed；- 满块消息容量：  Kmsg = K1024 - 24；- Polar非冻结位总数仍为K1024。CRC只计算原始消息位，不计算：- 前补零；- Polar冻结位；- CRC字段本身。逻辑非冻结序列是：V = 前补零 || 消息 || CRC24B其中前补零占用Polar非冻结位置，但数值是接收端已知的0。因此SCL中应区分：1. Polar冻结位：强制0，不分裂；2. 前补零对应的非冻结位：也是已知0，不分裂；3. 消息位和CRC位：允许0/1路径分裂。建议单Polar子块配置增加：known_zero_count_cfg表示该Polar子块开头若干个“非冻结序列位置”是已知前补零。不要把前补零简单算成Polar冻结位，因为它仍占用K。============================================================十一、逻辑码块可能拆成多个Polar子块============================================================类型3/4的最后一个逻辑CRC码块可能拆成多个Polar子块，例如：N=512N=256N=128N=64这些子块共同承载同一个：前补零 || 消息 || CRC24B以下状态跨子块连续：- vpos- 消息位置- CRC状态- padding剩余量CRC seed只在该逻辑码块开始时加载一次，不能在每个Polar子块重新加载。因此第一阶段的 scl_decoder_core 只负责单个Polar子块SCL。CRC24B和多个Polar子块的候选组合放到第二阶段的：ca_scl_decoder_top.v中处理。不要在每个Polar子块结束后独立做CRC选择，否则会提前丢弃后续能够通过CRC的路径。============================================================十二、TB和黄金数据============================================================我不提供原来的完整TB，新对话应自行编写自检TB。不需要我人工提供一组已知正确的LLR和SC结果。可以通过现有编码器自动生成黄金数据：固定消息→ crc_gen生成CRC→ frozen_gen生成冻结集→ 构造u_ref→ polar_butterfly编码得到d→ 映射为±64的LLR→ 送入SCL→ 比较译码u_hat与u_ref。至少测试：1. 全零消息；2. 全一消息；3. 0101交替消息；4. 固定随机消息；5. 无噪声强LLR；6. 部分弱LLR；7. 少量符号翻转，构造SC失败但SCL成功的情况。============================================================十三、当前下一步============================================================scl_pruner.v已经完成。下一步需要写完整的：scl_llr_mem.v但在写代码前，请先简短说明采用的物理存储策略和端口设计，然后直接给完整可综合代码，不要只给框架或伪代码。目标是高速度，因此不要直接采用“每次路径分裂就串行复制整条2047项LLR存储”的低速方案。当前优先考虑：- 逻辑路径与物理Bank分离；- 根信道LLR只装载一次或通过共享Bank访问；- 中间LLR按路径/物理Bank管理；- 路径分裂通过Bank映射或写时复制处理；- 两个子路径来自同一父路径时不能在后续写入中互相覆盖；- 应为每条并行路径提供两个LLR读取操作数；- 需要考虑Vivado的RAM推断和时序；- 不能假设大容量组合读寄存器阵列一定能高频运行。当前物理Bank映射/COW的具体接口尚未最终编码，这是下一步需要完成的设计任务。请不要假装该接口已经定稿。收到我重新提供的现有代码和scl_pruner后，从scl_llr_mem.v继续。

新对话必须重新提供的代码
新对话无法自动看到当前对话里粘贴的大段 Verilog，因此代码仍需重新上传。最稳妥的是把下面文件打包为一个 .zip 上传。
继续写 scl_llr_mem.v 的最低文件
Plain textsc_llr_mem.vsc_controller.vsc_datapath.vsc_decoder_core.vsc_pe.vscl_pruner.v
还建议同时给：
Plain textsc_beta_mem.vsc_uhat_mem.vfrozen_gen.vpolar_reliability_rom.v
后续接 CRC24B 时再提供
Plain textcrc_gen.vpolar_encode_chain.vpolar_encode_stream.vpolar_encoder.vpolar_butterfly.vcode_block_concat.v
其中 polar_reliability_rom.v 很长，适合直接上传文件，不要再次整段粘贴。
不需要重新提供


原完整 testbench；


人工计算的 LLR；


人工计算的 SC 输出；


FPGA 型号，目前未知不影响功能设计；


编码器截图。


为了真正“无缝衔接”，新对话第一轮上传以下内容即可：
Plain text上面的衔接指令+ 现有SC译码器全部.v文件+ 已生成的scl_pruner.v
然后直接说：
Plain text请从完整 scl_llr_mem.v 开始，先确认存储架构，再给出代码。

