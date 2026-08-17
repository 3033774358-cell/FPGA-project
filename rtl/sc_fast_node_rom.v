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

    reg [1:0] type_ram [0:2*NMAX-2];

    reg        filling;
    reg [3:0]  fill_depth;
    reg [10:0] fill_pos;      // 当前深度内的节点位置（堆偏移）

    assign rd_data = type_ram[rd_addr];

    wire [10:0] fill_heap = (11'd1 << fill_depth) - 11'd1 + fill_pos;

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

                if (fill_depth == n_log) begin
                    // 叶子节点
                    type_ram[fill_heap] <=
                        frozen_mask[fill_pos] ? T_R0 : T_R1;
                end
                else begin
                    // 内部节点：组合两个子节点类型
                    if ((type_ram[2*fill_heap + 1] == T_R0) &&
                        (type_ram[2*fill_heap + 2] == T_R0)) begin
                        type_ram[fill_heap] <= T_R0;
                    end
                    else if ((type_ram[2*fill_heap + 1] == T_R1) &&
                             (type_ram[2*fill_heap + 2] == T_R1)) begin
                        type_ram[fill_heap] <= T_R1;
                    end
                    else begin
                        type_ram[fill_heap] <= T_NORMAL;
                    end
                end

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

endmodule
