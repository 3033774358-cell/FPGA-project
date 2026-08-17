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
    parameter integer INDEX_W   = 11,

    // Fast-SSC: 快速节点并行路数（P 路宽读/写）
    parameter integer FAST_P    = 8
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
    output wire                         u_last,

    // =========================================================================
    // Fast-SSC 接口
    // =========================================================================
    //
    // frozen_bits   : 冻结位掩码，输出阶段把冻结位强制判 0
    // beta_force0   : PH_G 中左子树为 Rate-0 时，PE 的 beta 输入强制为 0
    // fast_op       : 1=DECIDE（读 P 个 LLR，写 beta/uhat 原始硬判决）
    //                 2=TRANSFORM（uhat 区 P 路原位蝴蝶变换）
    // fast_base     : 快速节点所在深度工作区基地址（LLR/beta）
    // fast_uhat_base: 快速节点第一个叶子的自然索引
    // fast_chunk    : 当前处理的 P 位块序号
    // fast_pass     : 变换级数（2^pass 为对距离）
    // fast_len_log  : 快速节点长度 log2
    // =========================================================================

    input  wire [NMAX-1:0]              frozen_bits,

    input  wire                         beta_force0,

    input  wire [1:0]                   fast_op,
    input  wire [ADDR_W-1:0]            fast_base,
    input  wire [INDEX_W-1:0]           fast_uhat_base,
    input  wire [ADDR_W-1:0]            fast_chunk,
    input  wire [3:0]                   fast_pass,
    input  wire [3:0]                   fast_len_log,

    // Fast-SSC: 当前 DECIDE pipeline 中捕获的这一组有效 Rate-1 LLR
    // 是否存在至少一个值严格等于 0（用于 Rate-1 零 LLR 回退判定）
    output wire                         fast_zero_hit
);

    // =========================================================================
    // 内部信号：PE
    // =========================================================================

    wire signed [INT_W-1:0] pe_y;
    wire                    pe_beta;

    // 2026-08-12：将 *_d1 流水线寄存器声明前移到使用位置之前，
    // 修复 Verilog 声明顺序错误（xvlog 严格报错；综合器可容忍）。
    reg                    pe_mode_g_d1;
    reg                    beta_force0_d1;

    reg                    llr_wr_en_d1;
    reg [ADDR_W-1:0]       llr_wr_addr_d1;

    reg                    beta_wr_en_d1;
    reg [ADDR_W-1:0]       beta_wr_addr_d1;
    reg                    beta_wr_data_d1;
    reg [1:0]              beta_wr_mode_d1;

    reg                    leaf_decision_en_d1;
    reg                    leaf_frozen_d1;
    reg [INDEX_W-1:0]      leaf_index_d1;
    reg [ADDR_W-1:0]       leaf_beta_wr_addr_d1;

    // Fast-SSC 宽读/宽写内部连线
    wire [(FAST_P*INT_W)-1:0] llr_rd_vec_data;
    wire [FAST_P-1:0]         uhat_rd_vec_data_a;
    wire [FAST_P-1:0]         uhat_rd_vec_data_b;

    // g运算使用beta读端口A
    // Fast-SSC: 左子树为 Rate-0 时强制 beta=0（g 退化为加法）
    // 2026-08-12：beta_rd_data_a 为同步读输出（寄存器），与 1 拍延迟的
    // beta_force0_d1 对齐后直接作为 PE 输入。
    assign pe_beta = beta_force0_d1 ? 1'b0 : beta_rd_data_a;

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
        leaf_frozen_d1
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
        case (beta_wr_mode_d1)

            BETA_SRC_DIRECT: begin
                beta_selected_data_reg = beta_wr_data_d1;
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
        leaf_decision_en_d1 | beta_wr_en_d1;

    assign beta_mem_wr_addr =
        leaf_decision_en_d1
        ? leaf_beta_wr_addr_d1
        : beta_wr_addr_d1;

    assign beta_mem_wr_data =
        leaf_decision_en_d1
        ? leaf_decision
        : beta_selected_data_reg;

    // =========================================================================
    // Pipeline stage-1 registers
    // =========================================================================
    //
    // Cycle T  : controller issues read addresses and write controls.
    // Edge T+1: memories register the read data (synchronous read output);
    //           write controls are latched into the *_d1 registers.
    // Cycle T+1: PE / beta mux / leaf decision compute from the registered
    //           memory outputs (llr_rd_data_a/b, beta_rd_data_a/b, *_vec_data).
    // Edge T+2: result written back to the memories.
    //
    // Each micro-operation therefore takes 2 clock cycles from issue to
    // writeback commit. sc_controller inserts bubbles at descend / leaf
    // return boundaries to satisfy the data dependencies.
    //
    // 2026-08-12：读数据不再在 datapath 内再打一拍（llr_a_d1 等已删除），
    // 存储器自身的同步读输出寄存器承担该级，端到端时序不变。
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_mode_g_d1        <= 1'b0;
            beta_force0_d1      <= 1'b0;

            llr_wr_en_d1        <= 1'b0;
            llr_wr_addr_d1      <= {ADDR_W{1'b0}};

            beta_wr_en_d1       <= 1'b0;
            beta_wr_addr_d1     <= {ADDR_W{1'b0}};
            beta_wr_data_d1     <= 1'b0;
            beta_wr_mode_d1     <= 2'b00;

            leaf_decision_en_d1 <= 1'b0;
            leaf_frozen_d1      <= 1'b0;
            leaf_index_d1       <= {INDEX_W{1'b0}};
            leaf_beta_wr_addr_d1<= {ADDR_W{1'b0}};
        end
        else begin
            pe_mode_g_d1        <= pe_mode_g;
            beta_force0_d1      <= beta_force0;

            llr_wr_en_d1        <= llr_wr_en;
            llr_wr_addr_d1      <= llr_wr_addr;

            beta_wr_en_d1       <= beta_wr_en;
            beta_wr_addr_d1     <= beta_wr_addr;
            beta_wr_data_d1     <= beta_wr_data;
            beta_wr_mode_d1     <= beta_wr_mode;

            leaf_decision_en_d1 <= leaf_decision_en;
            leaf_frozen_d1      <= leaf_frozen;
            leaf_index_d1       <= leaf_index;
            leaf_beta_wr_addr_d1<= leaf_beta_wr_addr;
        end
    end

    // =========================================================================
    // Fast-SSC fast-node unit (Rate-1 vector decode)
    // =========================================================================
    //
    // DECIDE   (fast_op=1): read P LLRs at fast_base + chunk*P, per-lane
    //                       hard decisions written to beta_mem (beta_v)
    //                       and uhat_mem (raw).
    // TRANSFORM(fast_op=2): in-place butterfly on uhat_mem:
    //                       uhat[k] ^= uhat[k + 2^fast_pass]
    //                       for lanes with bit fast_pass of (chunk*P+i) == 0.
    // Lane mask             : chunk*P + i < 2^fast_len_log.
    // Pipeline              : issue at T, capture d1 at T+1, commit at T+2.
    //
    // 2026-08-12：存储器改为同步读后，DECIDE/TRANSFORM 的读数据直接使用
    // 存储器的注册输出（llr_rd_vec_data / uhat_rd_vec_data_*），不再在
    // datapath 内二次打拍；写侧 *_d1 延迟寄存器保留，端到端时序不变。
    // fast_chunk * FAST_P 改为移位（FAST_P 为常量 2 的幂）。
    // =========================================================================

    localparam integer LOG2_FAST_P = $clog2(FAST_P);

    wire [ADDR_W-1:0]  fd_llr_rd_addr =
        fast_base + (fast_chunk << LOG2_FAST_P);

    wire [INDEX_W-1:0] fd_uhat_rd_a =
        fast_uhat_base + (fast_chunk << LOG2_FAST_P);

    wire [INDEX_W-1:0] fd_uhat_rd_b =
        fast_uhat_base + (fast_chunk << LOG2_FAST_P) +
        (11'd1 << fast_pass);

    wire [FAST_P-1:0] fd_decide_mask;
    wire [FAST_P-1:0] fd_tf_mask;

    generate
        genvar fdi;
        for (fdi = 0; fdi < FAST_P; fdi = fdi + 1)
        begin : gen_fast_mask
            assign fd_decide_mask[fdi] =
                (((fast_chunk << LOG2_FAST_P) + fdi) <
                 (11'd1 << fast_len_log));

            assign fd_tf_mask[fdi] =
                (((fast_chunk << LOG2_FAST_P) + fdi) <
                 (11'd1 << fast_len_log)) &&
                ((((fast_chunk << LOG2_FAST_P) + fdi) &
                  (11'd1 << fast_pass)) == 0);
        end
    endgenerate

    // ---- fast path pipeline stage-1 registers -------------------------------

    reg  fd_decide_d1;
    reg  fd_transform_d1;
    reg [FAST_P-1:0]       fd_decide_mask_d1;
    reg [FAST_P-1:0]       fd_tf_mask_d1;
    reg [ADDR_W-1:0]       fd_beta_addr_d1;
    reg [INDEX_W-1:0]      fd_uhat_addr_d1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fd_decide_d1      <= 1'b0;
            fd_transform_d1   <= 1'b0;
            fd_decide_mask_d1 <= {FAST_P{1'b0}};
            fd_tf_mask_d1     <= {FAST_P{1'b0}};
            fd_beta_addr_d1   <= {ADDR_W{1'b0}};
            fd_uhat_addr_d1   <= {INDEX_W{1'b0}};
        end
        else begin
            fd_decide_d1      <= (fast_op == 2'd1);
            fd_transform_d1   <= (fast_op == 2'd2);
            fd_decide_mask_d1 <= fd_decide_mask;
            fd_tf_mask_d1     <= fd_tf_mask;
            fd_beta_addr_d1   <= fast_base + (fast_chunk << LOG2_FAST_P);
            fd_uhat_addr_d1   <= fast_uhat_base + (fast_chunk << LOG2_FAST_P);
        end
    end

    // ---- stage-2 compute and wide write data --------------------------------

    wire [FAST_P-1:0] fd_dec_bits;
    wire [FAST_P-1:0] fd_tf_bits;

    generate
        genvar fdi2;
        for (fdi2 = 0; fdi2 < FAST_P; fdi2 = fdi2 + 1)
        begin : gen_dec_bits
            // hard decision: LLR sign bit（llr_rd_vec_data 为同步读输出，
            // 与 fd_decide_d1 对齐：DECIDE 下发于 T，数据 T+1 有效）
            assign fd_dec_bits[fdi2] =
                llr_rd_vec_data[fdi2*INT_W + INT_W - 1];
        end

        genvar fdi3;
        for (fdi3 = 0; fdi3 < FAST_P; fdi3 = fdi3 + 1)
        begin : gen_tf_bits
            assign fd_tf_bits[fdi3] =
                uhat_rd_vec_data_a[fdi3] ^ uhat_rd_vec_data_b[fdi3];
        end
    endgenerate

    wire [FAST_P-1:0] beta_wr_vec_en =
        fd_decide_d1 ? fd_decide_mask_d1 : {FAST_P{1'b0}};

    wire [FAST_P-1:0] uhat_wr_vec_en =
        (fd_decide_d1 ? fd_decide_mask_d1 : {FAST_P{1'b0}}) |
        (fd_transform_d1 ? fd_tf_mask_d1 : {FAST_P{1'b0}});

    wire [FAST_P-1:0] uhat_wr_vec_bits =
        fd_transform_d1 ? fd_tf_bits : fd_dec_bits;

    wire [INDEX_W-1:0] uhat_wr_vec_index = fd_uhat_addr_d1;

    // ---- Rate-1 零 LLR 检测 ------------------------------------------------
    //
    // 仅检查有效 lane（fd_decide_mask_d1[lane]==1）且该 lane 的完整 LLR
    // 数值严格等于 0。越界补出来的 0 因掩码为 0 不会触发 fallback。

    wire [FAST_P-1:0] fd_zero_lane;

    generate
        genvar fdz;
        for (fdz = 0; fdz < FAST_P; fdz = fdz + 1)
        begin : gen_zero_lane
            assign fd_zero_lane[fdz] =
                fd_decide_d1 &&
                fd_decide_mask_d1[fdz] &&
                (llr_rd_vec_data[fdz*INT_W +: INT_W] ==
                 {INT_W{1'b0}});
        end
    endgenerate

    assign fast_zero_hit = |fd_zero_lane;

    // =========================================================================
    // Processing Element
    // =========================================================================

    sc_pe #(
        .W(INT_W)
    )
    u_sc_pe (
        .a      (llr_rd_data_a),
        .b      (llr_rd_data_b),
        .mode_g (pe_mode_g_d1),
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
        .N_W       (INDEX_W),
        .FAST_P    (FAST_P)
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

        .wr_en        (llr_wr_en_d1),
        .wr_addr      (llr_wr_addr_d1),
        .wr_data      (pe_y),

        .rd_addr_a    (llr_rd_addr_a),
        .rd_data_a    (llr_rd_data_a),

        .rd_addr_b    (llr_rd_addr_b),
        .rd_data_b    (llr_rd_data_b),

        .rd_vec_addr  (fd_llr_rd_addr),
        .rd_vec_data  (llr_rd_vec_data)
    );

    // =========================================================================
    // beta 存储器
    // =========================================================================

    sc_beta_mem #(
        .NMAX      (NMAX),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .FAST_P    (FAST_P)
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
        .rd_data_b (beta_rd_data_b),

        .wr_vec_en   (beta_wr_vec_en),
        .wr_vec_addr (fd_beta_addr_d1),
        .wr_vec_data (fd_dec_bits)
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
        .INDEX_W (INDEX_W),
        .FAST_P  (FAST_P)
    )
    u_sc_uhat_mem (
        .clk          (clk),
        .rst_n        (rst_n),

        .wr_en        (leaf_decision_en_d1),
        .wr_index     (leaf_index_d1),
        .wr_bit       (leaf_decision),

        .output_start (output_start),
        .n_log        (n_log),

        .output_busy  (output_busy),
        .output_done  (output_done),

        .u_valid      (u_valid),
        .u_ready      (u_ready),
        .u_bit        (u_bit),
        .u_index      (u_index),
        .u_last       (u_last),

        .frozen_bits    (frozen_bits),

        .wr_vec_en      (uhat_wr_vec_en),
        .wr_vec_index   (uhat_wr_vec_index),
        .wr_vec_bits    (uhat_wr_vec_bits),

        .rd_vec_addr_a  (fd_uhat_rd_a),
        .rd_vec_data_a  (uhat_rd_vec_data_a),

        .rd_vec_addr_b  (fd_uhat_rd_b),
        .rd_vec_data_b  (uhat_rd_vec_data_b)
    );

endmodule
