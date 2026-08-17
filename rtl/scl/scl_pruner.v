// =============================================================================
// scl_pruner.v
// =============================================================================
// SCL 路径剪枝模块：从 2L 个候选路径中选择路径度量最小的 L 个候选。
//
// 推荐候选排列方式：
//
//     candidate_index = 2 * parent_path + candidate_bit
//
// 例如 LIST_SIZE=4：
//
//     cand[0] = parent0, u=0
//     cand[1] = parent0, u=1
//     cand[2] = parent1, u=0
//     cand[3] = parent1, u=1
//     ...
//     cand[6] = parent3, u=0
//     cand[7] = parent3, u=1
//
// 但模块本身不依赖该排列，只按照输入的：
//
//     cand_valid
//     cand_pm
//     cand_parent
//     cand_bit
//
// 完成排序。
//
// 排序优先级：
//
//     1. valid=1 的候选优于 valid=0 的候选
//     2. 路径度量 PM 较小者优先
//     3. PM 相同时，父路径编号较小者优先
//     4. 父路径相同时，candidate_bit=0 优先
//     5. 仍然相同时，原候选索引较小者优先
//
// 输出：
//
//     sel_xxx_bus[0]              = 最优候选 rank 0
//     sel_xxx_bus[1]              = 次优候选 rank 1
//     ...
//     sel_xxx_bus[LIST_SIZE-1]    = 第 L 优候选
//
// 时序模式：
//
//     REGISTER_OUTPUT = 1：
//         输入 in_valid 在某个上升沿被采样，结果在该上升沿后输出，
//         out_valid 拉高一个周期。模块内部无反压，in_ready 恒为1。
//
//     REGISTER_OUTPUT = 0：
//         纯组合输出，out_valid = in_valid。
//         适合功能仿真，但不推荐直接用于高频率设计。
//
// 注意：
//     本模块只负责选出幸存候选，不负责复制 LLR、beta、u_hat。
//     路径复制或路径Bank重命名应由 scl_controller 根据：
//
//         sel_parent_bus
//         sel_bit_bus
//
//     完成。
// =============================================================================

module scl_pruner #(
    // -------------------------------------------------------------------------
    // SCL 列表大小，要求为2的整数次幂
    // -------------------------------------------------------------------------
    parameter integer LIST_SIZE = 4,

    // 路径度量位宽
    parameter integer PM_W = 24,

    // 路径编号位宽
    //
    // LIST_SIZE=4时 PATH_W=2
    // LIST_SIZE=1时强制保持1位，避免零位宽
    // -------------------------------------------------------------------------
    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),

    // 2L个候选的索引位宽
    //
    // LIST_SIZE=4时：
    //     CAND_NUM=8
    //     CAND_W=3
    // -------------------------------------------------------------------------
    parameter integer CAND_W =
        ((2 * LIST_SIZE) <= 2)
        ? 1
        : $clog2(2 * LIST_SIZE),

    // 1：输出增加一级寄存器
    // 0：纯组合输出
    parameter integer REGISTER_OUTPUT = 1
)(
    input  wire                              clk,
    input  wire                              rst_n,

    // =========================================================================
    // 输入握手
    // =========================================================================

    // 当前2L个候选有效
    input  wire                              in_valid,

    // 本模块无反压，恒为1
    output wire                              in_ready,

    // =========================================================================
    // 2L个候选输入
    // =========================================================================
    //
    // 第i个候选字段位于：
    //
    //     cand_pm_bus[
    //         i*PM_W +: PM_W
    //     ]
    //
    //     cand_parent_bus[
    //         i*PATH_W +: PATH_W
    //     ]
    //
    //     cand_bit_bus[i]
    //     cand_valid_bus[i]
    // =========================================================================

    input  wire [(2*LIST_SIZE)*PM_W-1:0]     cand_pm_bus,

    input  wire [(2*LIST_SIZE)*PATH_W-1:0]   cand_parent_bus,

    input  wire [(2*LIST_SIZE)-1:0]          cand_bit_bus,

    input  wire [(2*LIST_SIZE)-1:0]          cand_valid_bus,

    // =========================================================================
    // 最优L个候选输出
    // =========================================================================

    output wire                              out_valid,

    // rank=0 是路径度量最小的最佳候选
    output wire [LIST_SIZE*PM_W-1:0]         sel_pm_bus,

    output wire [LIST_SIZE*PATH_W-1:0]       sel_parent_bus,

    output wire [LIST_SIZE-1:0]              sel_bit_bus,

    output wire [LIST_SIZE-1:0]              sel_valid_bus,

    // 被选中候选在原2L输入中的索引，主要用于调试和路径映射
    output wire [LIST_SIZE*CAND_W-1:0]       sel_index_bus
);

    // =========================================================================
    // 常量
    // =========================================================================

    localparam integer CAND_NUM = 2 * LIST_SIZE;

    // 当前实现随时可接收一组新候选
    assign in_ready = 1'b1;

    // =========================================================================
    // 工作数组
    // =========================================================================
    //
    // Bitonic排序网络在综合时展开为固定比较交换网络。
    // 使用blocking assignment描述每一级组合比较交换。
    // =========================================================================

    reg [PM_W-1:0]   work_pm     [0:CAND_NUM-1];
    reg [PATH_W-1:0] work_parent [0:CAND_NUM-1];
    reg              work_bit    [0:CAND_NUM-1];
    reg              work_valid  [0:CAND_NUM-1];
    reg [CAND_W-1:0] work_index  [0:CAND_NUM-1];

    // 交换临时变量
    reg [PM_W-1:0]   temp_pm;
    reg [PATH_W-1:0] temp_parent;
    reg              temp_bit;
    reg              temp_valid;
    reg [CAND_W-1:0] temp_index;

    // 排序循环变量
    integer sort_i;
    integer sort_j;
    integer sort_k;
    integer sort_ixj;

    // 输出打包循环变量
    integer out_i;

    // =========================================================================
    // 组合排序结果
    // =========================================================================

    reg [LIST_SIZE*PM_W-1:0]     sel_pm_comb;
    reg [LIST_SIZE*PATH_W-1:0]   sel_parent_comb;
    reg [LIST_SIZE-1:0]          sel_bit_comb;
    reg [LIST_SIZE-1:0]          sel_valid_comb;
    reg [LIST_SIZE*CAND_W-1:0]   sel_index_comb;

    // =========================================================================
    // 候选大小比较函数
    // =========================================================================
    //
    // 返回1表示候选A的排序优先级比候选B低，即：
    //
    //     A > B
    //
    // 如果执行升序排列，A > B 时交换A和B。
    // =========================================================================

    function item_greater;

        input                   valid_a;
        input [PM_W-1:0]        pm_a;
        input [PATH_W-1:0]      parent_a;
        input                   bit_a;
        input [CAND_W-1:0]      index_a;

        input                   valid_b;
        input [PM_W-1:0]        pm_b;
        input [PATH_W-1:0]      parent_b;
        input                   bit_b;
        input [CAND_W-1:0]      index_b;

        begin
            // -------------------------------------------------------------
            // 有效候选始终优于无效候选
            // -------------------------------------------------------------
            if (valid_a != valid_b) begin
                // A无效、B有效时，A更大
                item_greater = !valid_a;
            end

            // -------------------------------------------------------------
            // 两者均无效
            //
            // 按原候选索引排序，使仿真结果完全确定。
            // -------------------------------------------------------------
            else if (!valid_a) begin
                item_greater = (index_a > index_b);
            end

            // -------------------------------------------------------------
            // 首先比较路径度量
            // -------------------------------------------------------------
            else if (pm_a != pm_b) begin
                item_greater = (pm_a > pm_b);
            end

            // -------------------------------------------------------------
            // PM相同，父路径编号较小者优先
            // -------------------------------------------------------------
            else if (parent_a != parent_b) begin
                item_greater = (parent_a > parent_b);
            end

            // -------------------------------------------------------------
            // 父路径也相同，u=0优先
            // -------------------------------------------------------------
            else if (bit_a != bit_b) begin
                item_greater = (bit_a > bit_b);
            end

            // -------------------------------------------------------------
            // 完全相同则按原候选索引稳定排序
            // -------------------------------------------------------------
            else begin
                item_greater = (index_a > index_b);
            end
        end
    endfunction

    // =========================================================================
    // Bitonic排序网络
    // =========================================================================
    //
    // 标准Bitonic排序算法：
    //
    //     k = 2,4,8,...,CAND_NUM
    //         j = k/2,k/4,...,1
    //             对 i 与 i XOR j 执行比较交换
    //
    // CAND_NUM必须为2的整数次幂。
    //
    // 对 LIST_SIZE=4：
    //
    //     CAND_NUM = 8
    //
    // 最终形成8输入升序排序网络，前4项即为幸存路径。
    // =========================================================================

    always @* begin

        // ---------------------------------------------------------------------
        // 默认值
        // ---------------------------------------------------------------------

        temp_pm     = {PM_W{1'b0}};
        temp_parent = {PATH_W{1'b0}};
        temp_bit    = 1'b0;
        temp_valid  = 1'b0;
        temp_index  = {CAND_W{1'b0}};

        sel_pm_comb     = {(LIST_SIZE*PM_W){1'b0}};
        sel_parent_comb = {(LIST_SIZE*PATH_W){1'b0}};
        sel_bit_comb    = {LIST_SIZE{1'b0}};
        sel_valid_comb  = {LIST_SIZE{1'b0}};
        sel_index_comb  = {(LIST_SIZE*CAND_W){1'b0}};

        // ---------------------------------------------------------------------
        // 解包2L个候选
        // ---------------------------------------------------------------------

        for (sort_i = 0;
             sort_i < CAND_NUM;
             sort_i = sort_i + 1) begin

            work_pm[sort_i] =
                cand_pm_bus[
                    sort_i*PM_W +: PM_W
                ];

            work_parent[sort_i] =
                cand_parent_bus[
                    sort_i*PATH_W +: PATH_W
                ];

            work_bit[sort_i] =
                cand_bit_bus[sort_i];

            work_valid[sort_i] =
                cand_valid_bus[sort_i];

            work_index[sort_i] =
                sort_i[CAND_W-1:0];
        end

        // ---------------------------------------------------------------------
        // Bitonic比较交换网络
        // ---------------------------------------------------------------------

        for (sort_k = 2;
             sort_k <= CAND_NUM;
             sort_k = sort_k * 2) begin

            for (sort_j = sort_k / 2;
                 sort_j > 0;
                 sort_j = sort_j / 2) begin

                for (sort_i = 0;
                     sort_i < CAND_NUM;
                     sort_i = sort_i + 1) begin

                    sort_ixj = sort_i ^ sort_j;

                    // 每一对只处理一次
                    if (sort_ixj > sort_i) begin

                        // =====================================================
                        // 升序区
                        // =====================================================

                        if ((sort_i & sort_k) == 0) begin

                            if (item_greater(
                                work_valid[sort_i],
                                work_pm[sort_i],
                                work_parent[sort_i],
                                work_bit[sort_i],
                                work_index[sort_i],

                                work_valid[sort_ixj],
                                work_pm[sort_ixj],
                                work_parent[sort_ixj],
                                work_bit[sort_ixj],
                                work_index[sort_ixj]
                            )) begin

                                // ---------------------------------------------
                                // 交换PM
                                // ---------------------------------------------

                                temp_pm =
                                    work_pm[sort_i];

                                work_pm[sort_i] =
                                    work_pm[sort_ixj];

                                work_pm[sort_ixj] =
                                    temp_pm;

                                // ---------------------------------------------
                                // 交换父路径
                                // ---------------------------------------------

                                temp_parent =
                                    work_parent[sort_i];

                                work_parent[sort_i] =
                                    work_parent[sort_ixj];

                                work_parent[sort_ixj] =
                                    temp_parent;

                                // ---------------------------------------------
                                // 交换候选判决位
                                // ---------------------------------------------

                                temp_bit =
                                    work_bit[sort_i];

                                work_bit[sort_i] =
                                    work_bit[sort_ixj];

                                work_bit[sort_ixj] =
                                    temp_bit;

                                // ---------------------------------------------
                                // 交换有效标志
                                // ---------------------------------------------

                                temp_valid =
                                    work_valid[sort_i];

                                work_valid[sort_i] =
                                    work_valid[sort_ixj];

                                work_valid[sort_ixj] =
                                    temp_valid;

                                // ---------------------------------------------
                                // 交换原始候选索引
                                // ---------------------------------------------

                                temp_index =
                                    work_index[sort_i];

                                work_index[sort_i] =
                                    work_index[sort_ixj];

                                work_index[sort_ixj] =
                                    temp_index;
                            end
                        end

                        // =====================================================
                        // 降序区
                        // =====================================================

                        else begin

                            if (item_greater(
                                work_valid[sort_ixj],
                                work_pm[sort_ixj],
                                work_parent[sort_ixj],
                                work_bit[sort_ixj],
                                work_index[sort_ixj],

                                work_valid[sort_i],
                                work_pm[sort_i],
                                work_parent[sort_i],
                                work_bit[sort_i],
                                work_index[sort_i]
                            )) begin

                                // ---------------------------------------------
                                // 交换PM
                                // ---------------------------------------------

                                temp_pm =
                                    work_pm[sort_i];

                                work_pm[sort_i] =
                                    work_pm[sort_ixj];

                                work_pm[sort_ixj] =
                                    temp_pm;

                                // ---------------------------------------------
                                // 交换父路径
                                // ---------------------------------------------

                                temp_parent =
                                    work_parent[sort_i];

                                work_parent[sort_i] =
                                    work_parent[sort_ixj];

                                work_parent[sort_ixj] =
                                    temp_parent;

                                // ---------------------------------------------
                                // 交换候选判决位
                                // ---------------------------------------------

                                temp_bit =
                                    work_bit[sort_i];

                                work_bit[sort_i] =
                                    work_bit[sort_ixj];

                                work_bit[sort_ixj] =
                                    temp_bit;

                                // ---------------------------------------------
                                // 交换有效标志
                                // ---------------------------------------------

                                temp_valid =
                                    work_valid[sort_i];

                                work_valid[sort_i] =
                                    work_valid[sort_ixj];

                                work_valid[sort_ixj] =
                                    temp_valid;

                                // ---------------------------------------------
                                // 交换原始候选索引
                                // ---------------------------------------------

                                temp_index =
                                    work_index[sort_i];

                                work_index[sort_i] =
                                    work_index[sort_ixj];

                                work_index[sort_ixj] =
                                    temp_index;
                            end
                        end
                    end
                end
            end
        end

        // ---------------------------------------------------------------------
        // 排序完成后，取最前面的L个候选
        // ---------------------------------------------------------------------

        for (out_i = 0;
             out_i < LIST_SIZE;
             out_i = out_i + 1) begin

            sel_pm_comb[
                out_i*PM_W +: PM_W
            ] =
                work_pm[out_i];

            sel_parent_comb[
                out_i*PATH_W +: PATH_W
            ] =
                work_parent[out_i];

            sel_bit_comb[out_i] =
                work_bit[out_i];

            sel_valid_comb[out_i] =
                work_valid[out_i];

            sel_index_comb[
                out_i*CAND_W +: CAND_W
            ] =
                work_index[out_i];
        end
    end

    // =========================================================================
    // 输出模式
    // =========================================================================

    generate
        if (REGISTER_OUTPUT != 0) begin : g_registered_output

            reg                            out_valid_reg;
            reg [LIST_SIZE*PM_W-1:0]       sel_pm_reg;
            reg [LIST_SIZE*PATH_W-1:0]     sel_parent_reg;
            reg [LIST_SIZE-1:0]            sel_bit_reg;
            reg [LIST_SIZE-1:0]            sel_valid_reg;
            reg [LIST_SIZE*CAND_W-1:0]     sel_index_reg;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_valid_reg  <= 1'b0;
                    sel_pm_reg     <= {(LIST_SIZE*PM_W){1'b0}};
                    sel_parent_reg <= {(LIST_SIZE*PATH_W){1'b0}};
                    sel_bit_reg    <= {LIST_SIZE{1'b0}};
                    sel_valid_reg  <= {LIST_SIZE{1'b0}};
                    sel_index_reg  <= {(LIST_SIZE*CAND_W){1'b0}};
                end
                else begin
                    out_valid_reg <= in_valid;

                    if (in_valid) begin
                        sel_pm_reg     <= sel_pm_comb;
                        sel_parent_reg <= sel_parent_comb;
                        sel_bit_reg    <= sel_bit_comb;
                        sel_valid_reg  <= sel_valid_comb;
                        sel_index_reg  <= sel_index_comb;
                    end
                end
            end

            assign out_valid      = out_valid_reg;
            assign sel_pm_bus     = sel_pm_reg;
            assign sel_parent_bus = sel_parent_reg;
            assign sel_bit_bus    = sel_bit_reg;
            assign sel_valid_bus  = sel_valid_reg;
            assign sel_index_bus  = sel_index_reg;

        end
        else begin : g_combinational_output

            assign out_valid      = in_valid;
            assign sel_pm_bus     = sel_pm_comb;
            assign sel_parent_bus = sel_parent_comb;
            assign sel_bit_bus    = sel_bit_comb;
            assign sel_valid_bus  = sel_valid_comb;
            assign sel_index_bus  = sel_index_comb;

        end
    endgenerate

    // =========================================================================
    // 参数合法性检查
    // =========================================================================
    //
    // 仅用于仿真检查，综合工具一般会忽略initial中的系统任务。
    // =========================================================================

    initial begin
        if (LIST_SIZE < 1) begin
            $display(
                "scl_pruner ERROR: LIST_SIZE=%0d，必须大于等于1",
                LIST_SIZE
            );
            $finish;
        end

        if ((LIST_SIZE & (LIST_SIZE - 1)) != 0) begin
            $display(
                "scl_pruner ERROR: LIST_SIZE=%0d，必须为2的整数次幂",
                LIST_SIZE
            );
            $finish;
        end

        if (PM_W < 1) begin
            $display(
                "scl_pruner ERROR: PM_W=%0d，必须大于等于1",
                PM_W
            );
            $finish;
        end

        if ((REGISTER_OUTPUT != 0) &&
            (REGISTER_OUTPUT != 1)) begin

            $display(
                "scl_pruner ERROR: REGISTER_OUTPUT只能为0或1"
            );
            $finish;
        end
    end

endmodule