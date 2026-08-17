`timescale 1ns/1ps

// =============================================================================
// tb_llr_vec_bounds.v
// =============================================================================
//
// 专项验证 sc_llr_mem 的 Fast 宽读越界保护：
//
//   MEM_DEPTH = 2047，合法地址 0..2046，FAST_P = 8。
//   rd_vec_addr = 2044 时，8 路宽读应返回：
//     lane0 -> mem[2044]
//     lane1 -> mem[2045]
//     lane2 -> mem[2046]
//     lane3..lane7 -> 0（越界补 0，不允许访问 2047..2051）
//
// 期望：无 X、无非法下标、无 warning。
// =============================================================================
module tb_llr_vec_bounds;
    localparam NMAX     = 1024;
    localparam LLR_W    = 8;
    localparam INT_W    = 10;
    localparam MEM_DEPTH = 2 * NMAX - 1;   // 2047
    localparam ADDR_W   = 11;
    localparam N_W      = 11;
    localparam FAST_P   = 8;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    reg                    load_start;
    reg [3:0]              n_log;
    reg signed [LLR_W-1:0] llr_in;
    reg                    llr_in_valid;
    wire                   llr_in_ready;
    wire                   load_busy;
    wire                   load_done;

    reg                    wr_en;
    reg [ADDR_W-1:0]       wr_addr;
    reg signed [INT_W-1:0] wr_data;

    reg [ADDR_W-1:0]       rd_addr_a;
    wire signed [INT_W-1:0] rd_data_a;
    reg [ADDR_W-1:0]       rd_addr_b;
    wire signed [INT_W-1:0] rd_data_b;

    reg [ADDR_W-1:0]       rd_vec_addr;
    wire [(FAST_P*INT_W)-1:0] rd_vec_data;

    sc_llr_mem #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (10),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .N_W       (N_W),
        .FAST_P    (FAST_P)
    ) u_mem (
        .clk          (clk),
        .rst_n        (rst_n),
        .load_start   (load_start),
        .n_log        (n_log),
        .llr_in       (llr_in),
        .llr_in_valid (llr_in_valid),
        .llr_in_ready (llr_in_ready),
        .load_busy    (load_busy),
        .load_done    (load_done),
        .wr_en        (wr_en),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .rd_addr_a    (rd_addr_a),
        .rd_data_a    (rd_data_a),
        .rd_addr_b    (rd_addr_b),
        .rd_data_b    (rd_data_b),
        .rd_vec_addr  (rd_vec_addr),
        .rd_vec_data  (rd_vec_data)
    );

    integer errors = 0;

    task check_lane;
        input integer lane;
        input integer expect;
        reg signed [INT_W-1:0] got;
        begin
            got = $signed(rd_vec_data[lane*INT_W +: INT_W]);
            if (got !== expect) begin
                $display("ERROR lane%0d expect=%0d actual=%0d",
                         lane, expect, got);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        load_start   = 1'b0;
        n_log        = 4'd10;
        llr_in       = {LLR_W{1'b0}};
        llr_in_valid = 1'b0;
        wr_en        = 1'b0;
        wr_addr      = {ADDR_W{1'b0}};
        wr_data      = {INT_W{1'b0}};
        rd_addr_a    = {ADDR_W{1'b0}};
        rd_addr_b    = {ADDR_W{1'b0}};
        rd_vec_addr  = {ADDR_W{1'b0}};

        // 复位：negedge 释放，posedge 采样
        @(negedge clk);
        rst_n = 1'b1;

        // 写入 2044 / 2045 / 2046：
        // 全部在 negedge 准备输入，DUT 在 posedge 采样，避免 race。
        @(negedge clk);
        wr_en   = 1'b1;
        wr_addr = 11'd2044;
        wr_data = 10'sd100;

        @(negedge clk);
        wr_addr = 11'd2045;
        wr_data = -10'sd200;

        @(negedge clk);
        wr_addr = 11'd2046;
        wr_data = 10'sd300;

        @(negedge clk);
        wr_en = 1'b0;

        // rd_vec_addr = 2044：lane0..2 读到写入值，lane3..7 应为 0
        @(negedge clk);
        rd_vec_addr = 11'd2044;
        // 2026-08-12：存储器改为同步读，需等一拍再采样
        @(posedge clk);
        #1;
        check_lane(0, 100);
        check_lane(1, -200);
        check_lane(2, 300);
        check_lane(3, 0);
        check_lane(4, 0);
        check_lane(5, 0);
        check_lane(6, 0);
        check_lane(7, 0);

        // rd_vec_addr = 2046：lane0=300，其余越界应为 0
        @(negedge clk);
        rd_vec_addr = 11'd2046;
        // 2026-08-12：存储器改为同步读，需等一拍再采样
        @(posedge clk);
        #1;
        check_lane(0, 300);
        check_lane(1, 0);
        check_lane(2, 0);
        check_lane(7, 0);

        // 普通读端口不受影响
        @(negedge clk);
        rd_addr_a = 11'd2044;
        rd_addr_b = 11'd2046;
        // 2026-08-12：存储器改为同步读，需等一拍再采样
        @(posedge clk);
        #1;
        if ($signed(rd_data_a) !== 100) begin
            $display("ERROR rd_data_a expect=100 actual=%0d", $signed(rd_data_a));
            errors = errors + 1;
        end
        if ($signed(rd_data_b) !== 300) begin
            $display("ERROR rd_data_b expect=300 actual=%0d", $signed(rd_data_b));
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("RESULT: tb_llr_vec_bounds PASS");
        end else begin
            $display("RESULT: tb_llr_vec_bounds FAIL (%0d errors)", errors);
        end
        $finish;
    end
endmodule
