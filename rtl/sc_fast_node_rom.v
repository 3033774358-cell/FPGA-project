`timescale 1ns/1ps

// =============================================================================
// sc_fast_node_rom.v
// =============================================================================
//
// Fast-SSC 节点类型 ROM。
//
// 在配置阶段（frozen_gen 完成后）由 sc_decoder_core 触发一次填充：
//
//    bottom-up 自底向上计算每个节点的类型：
//      叶子  : frozen -> Rate-0，info -> Rate-1
//      内部  : 两子节点均为 Rate-0 -> Rate-0
//              两子节点均为 Rate-1 -> Rate-1
//              其它              -> 普通（NORMAL）
//
// 存储按堆编号索引：
//
//    heap(depth, pos) = (2^depth - 1) + pos
//
// 控制器通过 rd_addr/rd_data 组合读端口查询子节点类型。
//
// -----------------------------------------------------------------------------
// 存储物理结构（2026-08-17 面积优化重构）
// -----------------------------------------------------------------------------
//
// 原实现：2047 x 2bit 单一寄存器数组 + 组合读；写 always 块带异步复位，
// Vivado 拒绝 RAM 推断（Synth 8-4767），退化为 4094 个 FF + 2047:1 读 MUX，
// 即报告中的 ~7.1K LUT + 4.1K FF。
//
// 新结构（端口、时序、算法完全不变）：
//
//   copyA : 8 x (256 x 2bit) 分布式 RAM，1 组合读口 —— 只服务外部 rd_addr；
//   copyB : 8 x (256 x 2bit) 分布式 RAM，2 组合读口 —— 填充阶段读左右子类型；
//   两个副本同步写入（每个填充周期恰好 1 次写，自底向上保证写先于读）。
//
//   地址低 3 位选 bank，高 8 位选 word；组合读延迟为 0 拍（与原实现一致），
//   控制器/数据通路时序与周期数零改动。
//
// 复位策略：真实存储体不做内容清零；仅控制寄存器（filling/fill_depth/
// fill_pos/fill_done）保留异步复位。仿真观察影子数组 type_ram 放
// ifndef SYNTHESIS，综合时完全排除。
//
// =============================================================================

module sc_fast_node_rom #(
    parameter integer NMAX    = 1024,
    parameter integer MAX_LOG = 10,
    parameter integer ADDR_W  = 11
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // 填充接口
    input  wire                 fill_start,
    input  wire [3:0]           n_log,
    input  wire [NMAX-1:0]      frozen_mask,
    output reg                  fill_done,

    // 组合读接口
    input  wire [ADDR_W-1:0]    rd_addr,
    output wire [1:0]           rd_data
);

    localparam [1:0] T_NORMAL = 2'd0;
    localparam [1:0] T_R0     = 2'd1;
    localparam [1:0] T_R1     = 2'd2;

    // =========================================================================
    // 填充控制状态机（与原实现一致；仅控制寄存器复位）
    // =========================================================================

    reg        filling;
    reg [3:0]  fill_depth;
    reg [10:0] fill_pos;      // 当前深度内的节点位置（堆偏移）

    wire [10:0] fill_heap =
        (11'd1 << fill_depth) - 11'd1 + fill_pos;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            filling    <= 1'b0;
            fill_done  <= 1'b0;
            fill_depth <= 4'd0;
            fill_pos   <= 11'd0;
        end
        else begin
            fill_done <= 1'b0;

            if (fill_start && !filling) begin
                filling    <= 1'b1;
                fill_depth <= n_log;
                fill_pos   <= (11'd1 << n_log) - 11'd1;
            end
            else if (filling) begin

                if (fill_pos == 11'd0) begin
                    if (fill_depth == 4'd0) begin
                        filling   <= 1'b0;
                        fill_done <= 1'b1;
                    end
                    else begin
                        fill_depth <= fill_depth - 4'd1;
                        fill_pos   <= (11'd1 << (fill_depth - 4'd1)) - 11'd1;
                    end
                end
                else begin
                    fill_pos <= fill_pos - 11'd1;
                end
            end
        end
    end

    // =========================================================================
    // 存储体：copyA（外部组合读）/ copyB（填充时子类型组合读）
    // =========================================================================
    //
    // 地址低 3 位选 bank，高 8 位选 word。bank b 的写使能 =
    // filling && (fill_heap[2:0] == b)，即每个填充周期最多 1 个 bank 写。
    // 外部读与子类型读均为组合读（与原寄存器数组一致）。
    // =========================================================================

    localparam integer BANK_DEPTH = (2 * NMAX) / 8;   // 256
    localparam integer BANK_AW    = ADDR_W - 3;       // 8

    wire [1:0] qa  [0:7];
    wire [1:0] qb0 [0:7];
    wire [1:0] qb1 [0:7];

    // 叶子类型
    wire [1:0] fill_leaf_val =
        frozen_mask[fill_pos] ? T_R0 : T_R1;

    // 内部节点类型（组合读 copyB 两个子节点）
    wire [10:0] child_l = 2 * fill_heap + 1;
    wire [10:0] child_r = 2 * fill_heap + 2;

    wire [1:0] child_l_type = qb0[child_l[2:0]];
    wire [1:0] child_r_type = qb1[child_r[2:0]];

    wire [1:0] fill_value =
        ((child_l_type == T_R0) && (child_r_type == T_R0)) ? T_R0 :
        ((child_l_type == T_R1) && (child_r_type == T_R1)) ? T_R1 :
        T_NORMAL;

    wire [1:0] fill_wdata =
        (fill_depth == n_log) ? fill_leaf_val : fill_value;

    genvar gb;
    generate
        for (gb = 0; gb < 8; gb = gb + 1)
        begin : gen_bank

            wire bank_we =
                filling && (fill_heap[2:0] == gb[2:0]);

            sc_type_bank #(
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_bank_a (
                .clk   (clk),
                .we    (bank_we),
                .waddr (fill_heap[ADDR_W-1:3]),
                .wdata (fill_wdata),
                .raddr (rd_addr[ADDR_W-1:3]),
                .rdata (qa[gb])
            );

            sc_type_bank_2r #(
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_bank_b (
                .clk    (clk),
                .we     (bank_we),
                .waddr  (fill_heap[ADDR_W-1:3]),
                .wdata  (fill_wdata),
                .raddr0 (child_l[ADDR_W-1:3]),
                .rdata0 (qb0[gb]),
                .raddr1 (child_r[ADDR_W-1:3]),
                .rdata1 (qb1[gb])
            );
        end
    endgenerate

    // =========================================================================
    // 外部组合读：bank 选择（低 3 位）
    // =========================================================================

    assign rd_data = qa[rd_addr[2:0]];

    // =========================================================================
    // 仿真观察影子数组（仅仿真，不综合）
    // =========================================================================

`ifndef SYNTHESIS

    reg [1:0] type_ram [0:2*NMAX-2];

    integer sri;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (sri = 0; sri < 2*NMAX-1; sri = sri + 1) begin
                type_ram[sri] <= 2'd0;
            end
        end
        else begin
            if (filling) begin
                type_ram[fill_heap] <= fill_wdata;
            end
        end
    end

`endif

endmodule

// =============================================================================
// sc_type_bank：2bit 分布式 RAM bank（1 写 + 1 组合读）
// =============================================================================

module sc_type_bank #(
    parameter integer DEPTH = 256,
    parameter integer AW    = 8
)(
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire [1:0]       wdata,
    input  wire [AW-1:0]    raddr,
    output wire [1:0]       rdata
);

    (* ram_style = "distributed" *)
    reg [1:0] ram [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
        end
    end

    assign rdata = ram[raddr];

endmodule

// =============================================================================
// sc_type_bank_2r：2bit 分布式 RAM bank（1 写 + 2 组合读）
// =============================================================================

module sc_type_bank_2r #(
    parameter integer DEPTH = 256,
    parameter integer AW    = 8
)(
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire [1:0]       wdata,
    input  wire [AW-1:0]    raddr0,
    output wire [1:0]       rdata0,
    input  wire [AW-1:0]    raddr1,
    output wire [1:0]       rdata1
);

    (* ram_style = "distributed" *)
    reg [1:0] ram [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
        end
    end

    assign rdata0 = ram[raddr0];
    assign rdata1 = ram[raddr1];

endmodule
