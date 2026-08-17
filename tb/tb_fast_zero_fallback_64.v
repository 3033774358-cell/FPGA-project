`timescale 1ns/1ps

// =============================================================================
// tb_fast_zero_fallback_64.v
// =============================================================================
//
// 专项 RTL 测试：确认 Rate-1 节点遇到内部计算产生的 LLR==0 时，
// 真正触发 zero fallback，且最终输出与 baseline 流水 SC 一致。
//
// 配置：N=64, K=16, n_log=6（frozen 掩码由工程内 frozen_gen +
// polar_reliability_rom 生成，不手写）。
//
// 信道输入 64 个 LLR 本身没有 0，但 SC 内部 f/g 计算会产生精确 0，
// 从而触发 fallback。Python reference model 已确认：
//   fallback_count = 1
//   Fast 输出 == baseline SC 输出
//   u_hat=1 的自然索引 = {31,45,47,53,54,55,57,59,60,61}
//
// 观测：fallback_seen（fd_zero_seen 置位）、zero_hit_seen（fast_zero_hit），
// 以及 fallback 时刻的 cur_depth / current_leaf / fd_state / fd_gap 快照。
// 若 fallback 未触发则 $fatal。
// =============================================================================
module tb_fast_zero_fallback_64;
    localparam NMAX  = 1024;
    localparam LLR_W = 8;
    localparam INT_W = 10;
    localparam N     = 64;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst_n = 1'b0;

    // ---------------- sc_decoder_core 接口 ----------------
    reg         config_start;
    reg [3:0]   n_log_cfg;
    reg [10:0]  k_cfg;
    wire        config_ready;
    wire        config_busy;
    wire        config_done;
    wire        config_error;

    reg         block_start;
    wire        block_ready;
    wire        block_busy;
    wire        block_done;

    reg  signed [LLR_W-1:0] llr_in;
    reg         llr_in_valid;
    wire        llr_in_ready;

    wire        u_valid;
    reg         u_ready;
    wire        u_bit;
    wire [10:0] u_index;
    wire        u_last;

    sc_decoder_core #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (10),
        .MEM_DEPTH (2*NMAX-1),
        .ADDR_W    (11),
        .INDEX_W   (11)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .config_start(config_start),
        .n_log_cfg   (n_log_cfg),
        .k_cfg       (k_cfg),
        .config_ready(config_ready),
        .config_busy (config_busy),
        .config_done (config_done),
        .config_error(config_error),
        .block_start (block_start),
        .block_ready (block_ready),
        .block_busy  (block_busy),
        .block_done  (block_done),
        .llr_in      (llr_in),
        .llr_in_valid(llr_in_valid),
        .llr_in_ready(llr_in_ready),
        .u_valid     (u_valid),
        .u_ready     (u_ready),
        .u_bit       (u_bit),
        .u_index     (u_index),
        .u_last      (u_last)
    );

    // ---------------- 观测与结果寄存器 ----------------
    reg [63:0] got;
    integer    u_count = 0;
    reg        fallback_seen = 1'b0;
    reg        zero_hit_seen = 1'b0;
    reg [3:0]  depth_at_fallback;
    reg [10:0] leaf_at_fallback;
    reg [1:0]  fd_state_at_fallback;
    reg        fd_gap_at_fallback;

    integer i;
    integer errors = 0;

    // 收集 u_hat
    always @(posedge clk) begin
        if (u_valid && u_ready) begin
            got[u_index] = u_bit;
            u_count = u_count + 1;
        end
    end

    // zero_hit_seen：datapath 确实检测到内部 LLR==0（fast_zero_hit 有效）。
    // 仅观测，不代表 controller 一定执行了 fallback。
    always @(posedge clk) begin
        if (!rst_n) begin
            zero_hit_seen <= 1'b0;
        end
        else if (dut.fast_zero_hit) begin
            zero_hit_seen <= 1'b1;
        end
    end

    // fallback_seen：controller 真正进入 fallback 判定周期。
    //
    // 判定条件与 controller 的 fd_gap 分支完全一致：
    //   fd_state == FD_TRANSFORM(2'd2) 且 fd_gap == 1
    //   且 (fd_zero_seen || fast_zero_hit)
    //
    // 该条件只在 DECIDE -> 第一个 TRANSFORM 之间的 gap 周期成立
    // （TRANSFORM pass 之间的 gap 里 fd_zero_seen 已清零、
    //  fast_zero_hit 为 0，不会误判）。
    always @(posedge clk) begin
        if (!rst_n) begin
            fallback_seen <= 1'b0;
        end
        else if (dut.u_controller.fd_gap &&
                 (dut.u_controller.fd_state == 2'd2) &&
                 (dut.u_controller.fd_zero_seen || dut.fast_zero_hit)) begin
            fallback_seen <= 1'b1;
            depth_at_fallback  <= dut.u_controller.cur_depth;
            leaf_at_fallback   <= dut.u_controller.current_leaf;
            fd_state_at_fallback <= dut.u_controller.fd_state;
            fd_gap_at_fallback <= dut.u_controller.fd_gap;
            $display("[FALLBACK] time=%0t depth=%0d leaf=%0d fd_state=%0d fd_gap=%0b",
                     $time,
                     dut.u_controller.cur_depth,
                     dut.u_controller.current_leaf,
                     dut.u_controller.fd_state,
                     dut.u_controller.fd_gap);
        end
    end

    // 输入 LLR（自然索引 0..63）
    reg signed [LLR_W-1:0] llr_vec [0:63];
    initial begin
        llr_vec[ 0] = -3;  llr_vec[ 1] = -14; llr_vec[ 2] = -7;  llr_vec[ 3] = -6;
        llr_vec[ 4] = -20; llr_vec[ 5] = -15; llr_vec[ 6] = 9;   llr_vec[ 7] = 1;
        llr_vec[ 8] = 6;   llr_vec[ 9] = 14;  llr_vec[10] = -9;  llr_vec[11] = -19;
        llr_vec[12] = 2;   llr_vec[13] = -10; llr_vec[14] = 2;   llr_vec[15] = 15;
        llr_vec[16] = 16;  llr_vec[17] = 14;  llr_vec[18] = -7;  llr_vec[19] = -13;
        llr_vec[20] = 19;  llr_vec[21] = -3;  llr_vec[22] = 15;  llr_vec[23] = 16;
        llr_vec[24] = -7;  llr_vec[25] = 16;  llr_vec[26] = -2;  llr_vec[27] = 16;
        llr_vec[28] = -3;  llr_vec[29] = 15;  llr_vec[30] = -12; llr_vec[31] = -14;
        llr_vec[32] = -4;  llr_vec[33] = -14; llr_vec[34] = 7;   llr_vec[35] = -10;
        llr_vec[36] = -14; llr_vec[37] = -17; llr_vec[38] = 2;   llr_vec[39] = -9;
        llr_vec[40] = 20;  llr_vec[41] = -14; llr_vec[42] = 12;  llr_vec[43] = 1;
        llr_vec[44] = -3;  llr_vec[45] = 17;  llr_vec[46] = -16; llr_vec[47] = -2;
        llr_vec[48] = 1;   llr_vec[49] = -10; llr_vec[50] = -4;  llr_vec[51] = -4;
        llr_vec[52] = -16; llr_vec[53] = -20; llr_vec[54] = 6;   llr_vec[55] = -4;
        llr_vec[56] = 6;   llr_vec[57] = -20; llr_vec[58] = -17; llr_vec[59] = -14;
        llr_vec[60] = -5;  llr_vec[61] = -19; llr_vec[62] = -1;  llr_vec[63] = -13;
    end

    // 期望 u_hat=1 的位置
    reg [63:0] expect = 64'b0;
    initial begin
        expect[31] = 1'b1;
        expect[45] = 1'b1;
        expect[47] = 1'b1;
        expect[53] = 1'b1;
        expect[54] = 1'b1;
        expect[55] = 1'b1;
        expect[57] = 1'b1;
        expect[59] = 1'b1;
        expect[60] = 1'b1;
        expect[61] = 1'b1;
    end

    initial begin
        config_start = 1'b0;
        n_log_cfg    = 4'd6;
        k_cfg        = 11'd16;
        block_start  = 1'b0;
        llr_in       = {LLR_W{1'b0}};
        llr_in_valid = 1'b0;
        u_ready      = 1'b1;

        $display("== tb_fast_zero_fallback_64: N=64 K=16 ==");

        // 复位
        @(negedge clk);
        rst_n = 1'b1;

        // 配置
        @(negedge clk);
        config_start = 1'b1;
        n_log_cfg    = 4'd6;
        k_cfg        = 11'd16;
        @(negedge clk);
        config_start = 1'b0;

        while (!config_done) @(posedge clk);
        @(posedge clk);
        if (config_error) begin
            $display("ERROR config_error asserted");
            errors = errors + 1;
        end

        // 启动码块
        @(negedge clk);
        block_start = 1'b1;
        @(negedge clk);
        block_start = 1'b0;

        // 串行输入 64 个 LLR（valid/ready 握手）
        for (i = 0; i < N; i = i + 1) begin
            while (!llr_in_ready) @(posedge clk);
            @(negedge clk);
            llr_in       = llr_vec[i];
            llr_in_valid = 1'b1;
            @(posedge clk);
            #1;
        end
        @(negedge clk);
        llr_in_valid = 1'b0;

        // 等待译码完成
        while (!block_done) @(posedge clk);
        @(posedge clk);
        #1;

        // ---------------- 检查 ----------------
        if (u_count != N) begin
            $display("ERROR u_count=%0d expect=%0d", u_count, N);
            errors = errors + 1;
        end

        if (got !== expect) begin
            $display("ERROR u_hat mismatch");
            for (i = 0; i < N; i = i + 1)
                if (got[i] !== expect[i])
                    $display("  mismatch@%0d got=%b expect=%b", i, got[i], expect[i]);
            errors = errors + 1;
        end

        if (!zero_hit_seen) begin
            $display("FAIL: zero LLR was never detected");
            $fatal(1, "tb_fast_zero_fallback_64: zero_hit_seen=0");
        end

        if (!fallback_seen) begin
            $display("FAIL: Rate-1 fallback was not executed");
            $fatal(1, "tb_fast_zero_fallback_64: fallback_seen=0");
        end

        $display("  fallback_seen=%b zero_hit_seen=%b", fallback_seen, zero_hit_seen);
        $display("  fallback snapshot: cur_depth=%0d current_leaf=%0d fd_state=%0d fd_gap=%b",
                 depth_at_fallback, leaf_at_fallback,
                 fd_state_at_fallback, fd_gap_at_fallback);
        $display("  final cur_depth=%0d current_leaf=%0d",
                 dut.u_controller.cur_depth, dut.u_controller.current_leaf);

        if (errors == 0)
            $display("RESULT: tb_fast_zero_fallback_64 PASS");
        else
            $display("RESULT: tb_fast_zero_fallback_64 FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
