`timescale 1ns/1ps

// =============================================================================
// sc_datapath.v
// =============================================================================
//
// SC 译码器 B 部分顶层数据通路模块
//
// =============================================================================
// 一、模块功能
// =============================================================================
//
// 本模块组合以下已经完成的子模块：
//
// 1. sc_pe
//    执行 min-sum f 运算和 g 运算；
//
// 2. sc_llr_mem
//    串行装载根节点信道 LLR；
//    保存 SC 译码过程中产生的中间层 LLR；
//
// 3. sc_beta_mem
//    保存叶节点判决和内部节点部分和 beta；
//
// 4. sc_uhat_mem
//    保存最终判决 u_hat；
//    全部译码完成后，按照自然顺序串行输出 u_hat[0:N-1]。
//
// =============================================================================
// 二、本模块负责的操作
// =============================================================================
//
// 1. 从 LLR 存储器同时读取两个 LLR：
//
//        a = llr_mem[llr_rd_addr_a]
//        b = llr_mem[llr_rd_addr_b]
//
// 2. 从 beta 存储器读取 g 运算所需的 beta：
//
//        beta = beta_mem[beta_rd_addr_a]
//
// 3. 调用 sc_pe 执行：
//
//        pe_mode_g = 0：
//
//            y = f(a,b)
//
//        pe_mode_g = 1：
//
//            y = g(a,b,beta)
//              = beta ? b-a : b+a
//
// 4. 在 llr_wr_en 有效时，将 PE 结果同步写回 LLR 存储器：
//
//        llr_mem[llr_wr_addr] <= pe_result
//
// 5. 生成叶节点最终判决：
//
//        leaf_frozen = 1：
//
//            leaf_decision = 0
//
//        leaf_frozen = 0：
//
//            leaf_decision = leaf_llr[INT_W-1]
//
//    因为本项目的符号约定为：
//
//        LLR >= 0：倾向比特0
//        LLR <  0：倾向比特1
//
// 6. leaf_decision_en 有效时，将同一个叶节点判决同时写入：
//
//        uhat_mem[leaf_index]
//
//        beta_mem[leaf_beta_wr_addr]
//
// 7. 支持内部节点 beta 更新写回：
//
//        beta_wr_mode = 00：写入 beta_wr_data
//        beta_wr_mode = 01：写入 beta_rd_data_a XOR beta_rd_data_b
//        beta_wr_mode = 10：写入 beta_rd_data_a
//        beta_wr_mode = 11：写入 beta_rd_data_b
//
// 8. 启动并输出完整 u_hat：
//
//        u_hat[0]、u_hat[1]、...、u_hat[N-1]
//
// =============================================================================
// 三、本模块不负责的操作
// =============================================================================
//
// 本模块不负责：
//
// 1. SC 树深度优先遍历；
// 2. 生成 f/g 运算顺序；
// 3. 生成 LLR 读写地址；
// 4. 生成 beta 读写地址；
// 5. 判断何时到达叶节点；
// 6. 生成冻结集；
// 7. 生成 leaf_frozen；
// 8. 决定 beta 回传顺序；
// 9. 决定何时启动 u_hat 输出；
// 10. bit reversal；
// 11. CRC、信息位提取、码块拼接等功能。
//
// 上述功能均由后续正式 C 控制模块负责。
//
// =============================================================================
// 四、LLR 和 beta 存储布局
// =============================================================================
//
// LLR 存储器和 beta 存储器均采用 DFS 当前深度工作区布局。
//
// 最大码长 NMAX=1024 时：
//
//     depth 0 ：base=0，    size=1024
//     depth 1 ：base=1024， size=512
//     depth 2 ：base=1536， size=256
//     depth 3 ：base=1792， size=128
//     depth 4 ：base=1920， size=64
//     depth 5 ：base=1984， size=32
//     depth 6 ：base=2016， size=16
//     depth 7 ：base=2032， size=8
//     depth 8 ：base=2040， size=4
//     depth 9 ：base=2044， size=2
//     depth 10：base=2046， size=1
//
// 总存储深度：
//
//     MEM_DEPTH = 2*NMAX-1
//
// NMAX=1024 时：
//
//     MEM_DEPTH = 2047
//     有效地址范围为 0～2046
//     ADDR_W = 11
//
// =============================================================================
// 五、beta 部分和合并
// =============================================================================
//
// 对于长度为 node_len 的父节点，其左右子节点 beta 合并关系为：
//
//     parent_beta[i]
//         = left_beta[i] XOR right_beta[i]
//
//     parent_beta[i + node_len/2]
//         = right_beta[i]
//
// 因此可以分别使用：
//
//     beta_wr_mode = 2'b01
//     beta_wr_mode = 2'b11
//
// 完成父节点 beta 更新。
//
// =============================================================================
// 六、beta 写入优先级
// =============================================================================
//
// sc_beta_mem 只有一个同步写端口。
//
// 当 leaf_decision_en 与 beta_wr_en 同周期有效时：
//
//     leaf_decision_en 优先
//
// 即叶节点判决写入优先于普通内部节点 beta 写入。
//
// 正式控制器正常情况下不应让两种写操作同时有效。
// 这里设置固定优先级是为了保证硬件行为确定。
//
// =============================================================================
// 七、组合读取与同步写回时序
// =============================================================================
//
// 当前第一版 sc_llr_mem 和 sc_beta_mem 均使用组合读：
//
//     设置读地址
//         ↓
//     组合读出数据
//         ↓
//     sc_pe 组合计算
//         ↓
//     时钟上升沿同步写回
//
// 后续如果将存储器替换成同步 RAM/BRAM，C 控制模块需要增加读取等待周期。
//
// =============================================================================

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