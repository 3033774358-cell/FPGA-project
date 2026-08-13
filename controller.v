// =============================================================================
// sc_controller.v
// =============================================================================
// Polar SC译码器通用控制器
//
// 功能：
//   1. 控制已有sc_datapath完成SC译码树的深度优先遍历；
//   2. 支持运行时n_log变化；
//   3. 正式支持：
//          n_log = 6、7、8、9、10
//          N     = 64、128、256、512、1024
//   4. 也允许n_log=1～5，用于N=2、4、8、16、32的小规模回归测试；
//   5. 使用单个PE，每周期完成一个f或g运算；
//   6. 叶节点按自然顺序phi=0～N-1完成判决；
//   7. 所有叶节点完成后启动sc_uhat_mem串行输出；
//   8. 等待output_done后产生decode_done单周期脉冲。
//
// -----------------------------------------------------------------------------
// 编码与SC数学关系
// -----------------------------------------------------------------------------
// 编码器：
//
//      d = u * F^(⊗n)
//
// 不执行bit reversal。
//
// 对长度M的当前节点：
//
//      half = M/2
//
// 左子节点：
//
//      alpha_left[k]
//          = f(alpha_parent[k],
//              alpha_parent[k+half])
//
// 右子节点：
//
//      alpha_right[k]
//          = g(alpha_parent[k],
//              alpha_parent[k+half],
//              beta_left[k])
//
// beta合并：
//
//      beta_parent[k]
//          = beta_left[k] XOR beta_right[k]
//
//      beta_parent[k+half]
//          = beta_right[k]
//
// -----------------------------------------------------------------------------
// DFS工作区
// -----------------------------------------------------------------------------
// 当前设计固定NMAX=1024，物理工作区按“每一深度一段区域”布置：
//
//      depth 0  base = 0       size = 1024
//      depth 1  base = 1024    size = 512
//      depth 2  base = 1536    size = 256
//      depth 3  base = 1792    size = 128
//      depth 4  base = 1920    size = 64
//      depth 5  base = 1984    size = 32
//      depth 6  base = 2016    size = 16
//      depth 7  base = 2032    size = 8
//      depth 8  base = 2040    size = 4
//      depth 9  base = 2044    size = 2
//      depth 10 base = 2046    size = 1
//
// 深度基地址公式：
//
//      depth_base(0) = 0
//
//      depth_base(d)
//          = 2*NMAX - (NMAX >> (d-1)), d>=1
//
// DFS过程中，同一深度只保存当前递归路径上的一个节点，因此不需要为同一
// 深度的所有节点分别分配地址。
//
// -----------------------------------------------------------------------------
// 每层phase含义
// -----------------------------------------------------------------------------
// PH_F：
//      当前内部节点尚未完成左子节点。
//      逐元素执行f，随后下降到左子树。
//
// PH_G：
//      左子树已完成。
//      逐元素执行g，同时把beta_left复制到父层低半区域保存，随后下降右子树。
//
// PH_C：
//      右子树已完成。
//      将beta_left和beta_right合并回当前节点。
//
// -----------------------------------------------------------------------------
// beta单写口处理
// -----------------------------------------------------------------------------
// sc_beta_mem只有一个同步写端口，因此每个元素的beta合并使用两个周期：
//
//      第1周期：
//          parent[k] = left[k] XOR right[k]
//
//      第2周期：
//          parent[k+half] = right[k]
//
// -----------------------------------------------------------------------------
// 启动流程
// -----------------------------------------------------------------------------
// 推荐系统连接方式：
//
//      1. 外部向sc_datapath发送load_start；
//      2. 串行装载N个信道LLR；
//      3. sc_datapath产生load_done；
//      4. 可以将load_done直接连接到本模块decode_start；
//      5. 本控制器开始SC译码；
//      6. 根beta合并完成后，本模块产生output_start；
//      7. sc_uhat_mem串行输出完整u_hat；
//      8. sc_datapath产生output_done；
//      9. 本模块产生decode_done单周期脉冲。
//
// 时序假设：
//   - LLR存储器为组合读、同步写；
//   - beta存储器为组合读、同步写；
//   - sc_pe为组合运算；
//   - 本控制器在一个周期内给出读地址、写地址和写使能，数据在该周期
//     结束的上升沿写入存储器。
// =============================================================================

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

    // 读延迟相位(存储器改同步读BRAM后): 0=地址相(给读地址,不写不推进);
    // 1=执行相(寄存读数据已到,PE算,写回,推进状态)。每步用2拍换取BRAM。
    reg rd_ph;

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

        // 读延迟门控: 存储器同步读, 地址相(rd_ph=0)只发读地址、不写;
        // 写使能仅在执行相(rd_ph=1, 读数据已有效)有效, 避免用到未就绪数据。
        if (state == ST_DECODE && !rd_ph) begin
            llr_wr_en        = 1'b0;
            beta_wr_en       = 1'b0;
            leaf_decision_en = 1'b0;
        end
    end

    // =========================================================================
    // 主时序控制
    // =========================================================================

    // 复位方式: **同步复位** (原为异步 negedge rst_n)。
    //   原因: 本块的 state/cur_depth 经 datapath 驱动 sc_llr_mem 的 BRAM 写地址,
    //   Vivado DRC REQP-1839 警告"BRAM 地址由带异步复位的寄存器驱动"——异步复位瞬间
    //   地址不跟时钟对齐地突变, 可能污染存储内容, 且该路径默认不做时序分析。
    //   改同步复位后地址仅在时钟沿变化, 告警消除; 亦是 Xilinx 对 FPGA 的推荐做法。
    //   行为差异: 复位在下一个时钟沿生效(而非立即), 自由运行时钟下等效。
    always @(posedge clk) begin
        if (!rst_n) begin
            state              <= ST_IDLE;
            decode_busy        <= 1'b0;
            decode_done        <= 1'b0;

            cur_depth          <= 4'd0;
            element_index      <= {INDEX_W{1'b0}};
            current_leaf       <= {INDEX_W{1'b0}};
            merge_second_write <= 1'b0;
            rd_ph              <= 1'b0;

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
                        rd_ph              <= 1'b0;   // 从地址相开始

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

                  if (!rd_ph) begin
                    rd_ph <= 1'b1;   // 地址相: 给读地址, 等 BRAM 寄存读一拍, 本拍不写不推进
                  end else begin
                    rd_ph <= 1'b0;   // 执行相: 读数据已有效, PE算+写回本拍完成, 推进状态
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
                  end   // else (执行相)
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