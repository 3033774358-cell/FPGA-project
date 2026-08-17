`timescale 1ns/1ps

// =============================================================================
// sc_uhat_mem.v
// =============================================================================
//
// SC 译码器最终判决位 u_hat 存储与串行输出模块
//
// =============================================================================
// 一、模块功能
// =============================================================================
//
// 1. 保存 SC 译码过程中得到的叶节点最终判决：
//
//        u_hat[phi]
//
//    写入索引 phi 使用自然顺序：
//
//        phi = 0      → u_hat[0]
//        phi = 1      → u_hat[1]
//        ...
//        phi = N-1    → u_hat[N-1]
//
// 2. 全部叶节点译码完成后，由外部控制模块拉高 output_start，
//    本模块开始按照自然顺序串行输出：
//
//        u_hat[0]、u_hat[1]、...、u_hat[N-1]
//
// 3. 串行输出采用 valid/ready 握手机制：
//
//        u_valid = 1：当前 u_bit、u_index、u_last 有效
//        u_ready = 1：下游能够接收当前输出
//
//    只有在 u_valid && u_ready 同时为 1 时，输出索引才会推进。
//
// 4. 输出包含冻结位；冻结位在输出阶段由 frozen_bits 掩码强制判 0。
//
// =============================================================================
// 存储物理结构（2026-08-12 面积优化重构）
// =============================================================================
//
// 原实现：1024 x 1bit 寄存器数组，复位时整块清零。
// 面积问题：整数组复位使 Vivado 无法推断 LUTRAM/BRAM，1024 个存储位
//          退化为 FF + 16 路宽读 + 1 路串行读共 17 棵 1024:1 MUX，
//          即报告中的 ~26K LUT。
//
// 新结构（端口、时序、算法不变）：
//
//   copyA : 8 x (128 x 1bit) 分布式 RAM，两个读端口：
//           raddr0 = Fast-SSC TRANSFORM 读 A，raddr1 = 串行输出读；
//   copyB : 8 x (128 x 1bit) 分布式 RAM，一个读端口：
//           raddr = Fast-SSC TRANSFORM 读 B；
//   两个副本同步写入（叶节点单写 + Fast-SSC 8 路宽写），宽写优先。
//
//   地址低 3 位选 bank，高 7 位选 word；TRANSFORM 的 A/B 两路各 8 个
//   连续地址分别落到 8 个不同 bank，一个周期并行读 16 个 uhat 位。
//
// 复位策略：真实存储体不做内容清零（输出阶段冻结位由 frozen_bits 掩码
//          强制判 0；信息位在输出前必然已写入）。保留“仿真观察影子数组
//          uhat_mem”（ifndef SYNTHESIS，含复位清零），供 tb_256/tb_1024
//          层次化检查，综合时不产生任何硬件。
//
// 读延迟保持 1 拍：宽读输出经顶层寄存器采样；串行输出为组合读。
//
// =============================================================================

module sc_uhat_mem #(
    parameter integer NMAX = 1024,

    // 固定配置 NMAX=1024 时，需要 11 位表示：
    // 0～1023 的索引以及 active_n=1024
    parameter integer INDEX_W = 11,

    // Fast-SSC: P 路宽读/写端口位宽
    parameter integer FAST_P = 8
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
    output wire                     u_last,

    // =========================================================================
    // Fast-SSC 宽读/宽写接口
    // =========================================================================

    input  wire [NMAX-1:0]          frozen_bits,

    input  wire [FAST_P-1:0]        wr_vec_en,
    input  wire [INDEX_W-1:0]       wr_vec_index,
    input  wire [FAST_P-1:0]        wr_vec_bits,

    input  wire [INDEX_W-1:0]       rd_vec_addr_a,
    output wire [FAST_P-1:0]        rd_vec_data_a,

    input  wire [INDEX_W-1:0]       rd_vec_addr_b,
    output wire [FAST_P-1:0]        rd_vec_data_b
);

    // =========================================================================
    // 组合几何量
    // =========================================================================

    localparam integer BANK_DEPTH = NMAX / FAST_P;      // 128
    localparam integer BANK_AW    = $clog2(BANK_DEPTH); // 7

    // =========================================================================
    // 输出控制寄存器
    // =========================================================================

    // 当前码长 N
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
    // copyA / copyB 每 bank 的写控制
    // =========================================================================
    //
    // 与原实现一致：
    //   - 仅在输出空闲（!output_busy）时允许写入；
    //   - 宽写（wr_vec_en）覆盖普通单写。
    //
    // bank b 对应的宽写 lane = (b - wr_vec_index[2:0]) & 7。
    // =========================================================================

    wire qa0 [0:FAST_P-1];
    wire qa1 [0:FAST_P-1];
    wire qb0 [0:FAST_P-1];

    genvar gb;
    generate
        for (gb = 0; gb < FAST_P; gb = gb + 1)
        begin : gen_bank

            wire [INDEX_W:0] vec_lane_addr =
                {1'b0, wr_vec_index} +
                ((gb - wr_vec_index[2:0]) & (FAST_P-1));

            wire vec_we =
                (!output_busy) &&
                wr_vec_en[(gb - wr_vec_index[2:0]) & (FAST_P-1)];

            wire single_we =
                (!output_busy) &&
                wr_en && (wr_index[2:0] == gb);

            wire bank_we =
                single_we | vec_we;

            wire [BANK_AW-1:0] bank_waddr =
                vec_we
                ? vec_lane_addr[9:3]
                : wr_index[9:3];

            wire bank_wdata =
                vec_we
                ? wr_vec_bits[(gb - wr_vec_index[2:0]) & (FAST_P-1)]
                : wr_bit;

            // ---------- copyA：宽读 A + 串行读 ----------

            wire [INDEX_W:0] vec_a_lane_addr =
                {1'b0, rd_vec_addr_a} +
                ((gb - rd_vec_addr_a[2:0]) & (FAST_P-1));

            sc_bit_bank_2r #(
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_bank_a (
                .clk    (clk),
                .we     (bank_we),
                .waddr  (bank_waddr),
                .wdata  (bank_wdata),
                .raddr0 (vec_a_lane_addr < NMAX
                             ? vec_a_lane_addr[9:3]
                             : {BANK_AW{1'b0}}),
                .rdata0 (qa0[gb]),
                .raddr1 (output_index[9:3]),
                .rdata1 (qa1[gb])
            );

            // ---------- copyB：宽读 B ----------

            wire [INDEX_W:0] vec_b_lane_addr =
                {1'b0, rd_vec_addr_b} +
                ((gb - rd_vec_addr_b[2:0]) & (FAST_P-1));

            sc_bit_bank #(
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_bank_b (
                .clk   (clk),
                .we    (bank_we),
                .waddr (bank_waddr),
                .wdata (bank_wdata),
                .raddr (vec_b_lane_addr < NMAX
                            ? vec_b_lane_addr[9:3]
                            : {BANK_AW{1'b0}}),
                .rdata (qb0[gb])
            );

        end
    endgenerate

    // =========================================================================
    // Fast-SSC 宽同步读（注册输出，1 拍延迟）
    // =========================================================================

    reg [FAST_P-1:0] rd_vec_data_a_r;
    reg [FAST_P-1:0] rd_vec_data_b_r;

    genvar gv;
    generate
        for (gv = 0; gv < FAST_P; gv = gv + 1)
        begin : gen_rd_vec

            wire [INDEX_W:0] lane_addr_a =
                {1'b0, rd_vec_addr_a} + gv;

            wire [INDEX_W:0] lane_addr_b =
                {1'b0, rd_vec_addr_b} + gv;

            always @(posedge clk) begin
                if (lane_addr_a < NMAX)
                    rd_vec_data_a_r[gv] <=
                        qa0[(rd_vec_addr_a[2:0] + gv) & (FAST_P-1)];
                else
                    rd_vec_data_a_r[gv] <= 1'b0;

                if (lane_addr_b < NMAX)
                    rd_vec_data_b_r[gv] <=
                        qb0[(rd_vec_addr_b[2:0] + gv) & (FAST_P-1)];
                else
                    rd_vec_data_b_r[gv] <= 1'b0;
            end

        end
    endgenerate

    assign rd_vec_data_a = rd_vec_data_a_r;
    assign rd_vec_data_b = rd_vec_data_b_r;

    // =========================================================================
    // 输出数据
    // =========================================================================

    // Fast-SSC: 冻结位输出强制为 0
    assign u_bit =
        frozen_bits[output_index]
        ? 1'b0
        : qa1[output_index[2:0]];

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

    // =========================================================================
    // 仿真观察影子数组（仅仿真，不综合）
    // =========================================================================
    //
    // tb_256 / tb_1024 通过层次引用 u_sc_uhat_mem.uhat_mem[i] 检查
    // 译码结果。真实存储为 bank 阵列，因此保留与真实存储同步更新的
    // 仿真影子数组（含复位清零，与原实现一致）。
    // 该数组在综合（SYNTHESIS 宏定义）时被完全排除。
    // =========================================================================

`ifndef SYNTHESIS

    reg uhat_mem [0:NMAX-1];

    integer sri;
    integer swi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (sri = 0; sri < NMAX; sri = sri + 1) begin
                uhat_mem[sri] <= 1'b0;
            end
        end
        else begin
            if (!output_busy) begin
                if (wr_en) begin
                    uhat_mem[wr_index] <= wr_bit;
                end

                if (|wr_vec_en) begin
                    for (swi = 0; swi < FAST_P; swi = swi + 1) begin
                        if (wr_vec_en[swi]) begin
                            uhat_mem[wr_vec_index + swi] <= wr_vec_bits[swi];
                        end
                    end
                end
            end
        end
    end

`endif

endmodule


// =============================================================================
// sc_bit_bank_2r：1bit 分布式 RAM bank（1 写 + 2 组合读）
// =============================================================================

module sc_bit_bank_2r #(
    parameter integer DEPTH = 128,
    parameter integer AW    = 7
)(
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire             wdata,
    input  wire [AW-1:0]    raddr0,
    output wire             rdata0,
    input  wire [AW-1:0]    raddr1,
    output wire             rdata1
);

    (* ram_style = "distributed" *)
    reg ram [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
        end
    end

    assign rdata0 = ram[raddr0];
    assign rdata1 = ram[raddr1];

endmodule
