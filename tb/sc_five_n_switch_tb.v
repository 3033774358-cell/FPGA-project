`timescale 1ns/1ps

// =============================================================================
// sc_five_n_switch_tb.v
// -----------------------------------------------------------------------------
// 连续切换并验证五种运行时码长：
//     N=64, 128, 256, 512, 1024
// 每种采用 K=N/2，使用 DUT 内部 frozen_gen 生成的冻结掩码。
// 验证内容：
//   1) 配置完成与冻结位数量；
//   2) 对应N个LLR被装载；
//   3) 无噪声SC译码输出等于原始u；
//   4) u_index/u_last/valid-ready反压；
//   5) 一个码块结束后可重新配置下一种N。
// =============================================================================
module sc_five_n_switch_tb;

    parameter integer NMAX      = 1024;
    parameter integer LLR_W     = 8;
    parameter integer INT_W     = 10;
    parameter integer MAX_LOG   = 10;
    parameter integer MEM_DEPTH = 2 * NMAX - 1;
    parameter integer ADDR_W    = 11;
    parameter integer INDEX_W   = 11;

    parameter integer TIMEOUT_CYCLES       = 180000;
    parameter integer INPUT_TIMEOUT_CYCLES = 5000;

    // =========================================================================
    // 时钟与复位
    // =========================================================================

    reg clk;
    reg rst_n;

    // =========================================================================
    // 配置接口
    // =========================================================================

    reg         config_start;
    reg  [3:0]  n_log_cfg;
    reg  [10:0] k_cfg;

    wire config_ready;
    wire config_busy;
    wire config_done;
    wire config_error;

    // =========================================================================
    // 码块启动接口
    // =========================================================================

    reg  block_start;

    wire block_ready;
    wire block_busy;
    wire block_done;

    // =========================================================================
    // LLR输入接口
    // =========================================================================

    reg signed [LLR_W-1:0] llr_in;
    reg                     llr_in_valid;

    wire                    llr_in_ready;

    // =========================================================================
    // 译码输出接口
    // =========================================================================

    wire                    u_valid;
    reg                     u_ready;
    wire                    u_bit;
    wire [INDEX_W-1:0]      u_index;
    wire                    u_last;

    // =========================================================================
    // 测试统计
    // =========================================================================

    integer error_count;
    integer check_count;
    integer case_count;

    // 0：复位
    // 1：配置冻结掩码
    // 2：装载LLR
    // 3：等待译码和输出
    integer stage_debug;

    // =========================================================================
    // 黄金数据
    // =========================================================================

    reg [NMAX-1:0] u_ref;
    reg [NMAX-1:0] d_ref;

    // =========================================================================
    // 时钟
    // =========================================================================

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;

    // =========================================================================
    // DUT
    // =========================================================================

    sc_decoder_core #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (MAX_LOG),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    )
    dut (
        .clk          (clk),
        .rst_n        (rst_n),

        .config_start (config_start),
        .n_log_cfg    (n_log_cfg),
        .k_cfg        (k_cfg),
        .config_ready (config_ready),
        .config_busy  (config_busy),
        .config_done  (config_done),
        .config_error (config_error),

        .block_start  (block_start),
        .block_ready  (block_ready),
        .block_busy   (block_busy),
        .block_done   (block_done),

        .llr_in       (llr_in),
        .llr_in_valid (llr_in_valid),
        .llr_in_ready (llr_in_ready),

        .u_valid      (u_valid),
        .u_ready      (u_ready),
        .u_bit        (u_bit),
        .u_index      (u_index),
        .u_last       (u_last)
    );

    // =========================================================================
    // 可变N、无bit reversal Polar编码黄金模型
    // =========================================================================

    task polar_encode_runtime;

        input integer current_n;
        input [NMAX-1:0] u_in;

        output [NMAX-1:0] d_out;

        reg [NMAX-1:0] work;

        integer m;
        integer base;
        integer j;

        begin
            work = {NMAX{1'b0}};

            for (j = 0;
                 j < current_n;
                 j = j + 1) begin

                work[j] = u_in[j];
            end

            m = 1;

            while (m < current_n) begin

                for (base = 0;
                     base < current_n;
                     base = base + 2*m) begin

                    for (j = 0;
                         j < m;
                         j = j + 1) begin

                        work[base+j] =
                            work[base+j] ^
                            work[base+j+m];
                    end
                end

                m = m << 1;
            end

            d_out = work;
        end

    endtask

    // =========================================================================
    // 单个码长配置与译码任务
    // =========================================================================

    task run_one_length;

        input integer case_id;
        input [3:0] selected_n_log;
        input [10:0] selected_k;

        integer current_n;

        integer i;
        integer frozen_count;
        integer info_count;

        integer input_count;
        integer input_fire;

        integer output_count;
        integer timeout_count;
        integer monitor_cycle;
        integer pause_done;

        integer fire;
        integer stalled;

        reg hold_bit;
        reg [INDEX_W-1:0] hold_index;
        reg hold_last;

        begin
            case_count = case_count + 1;
            current_n  = (1 << selected_n_log);

            $display("------------------------------------------------------------");

            stage_debug = 1;

            $display(
                "CASE %0d CONFIG START: N=%0d K=%0d",
                case_id,
                current_n,
                selected_k
            );

            // -----------------------------------------------------------------
            // 1. 配置当前N/K
            // -----------------------------------------------------------------

            while (config_ready !== 1'b1) begin
                @(negedge clk);
            end

            n_log_cfg    = selected_n_log;
            k_cfg        = selected_k;
            config_start = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);

            config_start = 1'b0;

            // -----------------------------------------------------------------
            // 等待冻结掩码生成完成
            // -----------------------------------------------------------------

            timeout_count = 0;

            while ((config_done !== 1'b1) &&
                   (timeout_count < 3000)) begin

                @(posedge clk);
                #1;

                timeout_count = timeout_count + 1;
            end

            check_count = check_count + 3;

            if (config_done !== 1'b1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: config timeout",
                    case_id
                );
            end

            if (config_error !== 1'b0) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: config_error asserted",
                    case_id
                );
            end

            if (block_ready !== 1'b1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: block_ready missing after config",
                    case_id
                );
            end

            // -----------------------------------------------------------------
            // 2. 检查冻结掩码并构造合法u
            // -----------------------------------------------------------------

            frozen_count = 0;
            info_count   = 0;
            u_ref        = {NMAX{1'b0}};

            for (i = 0;
                 i < current_n;
                 i = i + 1) begin

                if (dut.frozen_mask[i]) begin
                    frozen_count = frozen_count + 1;
                    u_ref[i]     = 1'b0;
                end
                else begin
                    info_count = info_count + 1;

                    // 不同N产生不同但确定的测试图样。
                    u_ref[i] =
                        ((((i * (case_id + 5)) + 3) % 7) < 3);
                end
            end

            // frozen_gen要求i>=N的位置保持冻结。
            for (i = current_n;
                 i < NMAX;
                 i = i + 1) begin

                check_count = check_count + 1;

                if (dut.frozen_mask[i] !== 1'b1) begin
                    error_count = error_count + 1;

                    $display(
                        "ERROR CASE%0d: frozen_mask[%0d] above N is not 1",
                        case_id,
                        i
                    );
                end
            end

            check_count = check_count + 2;

            if (frozen_count != (current_n-selected_k)) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: frozen count expected=%0d actual=%0d",
                    case_id,
                    current_n-selected_k,
                    frozen_count
                );
            end

            if (info_count != selected_k) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: info count expected=%0d actual=%0d",
                    case_id,
                    selected_k,
                    info_count
                );
            end

            // -----------------------------------------------------------------
            // Polar编码
            // -----------------------------------------------------------------

            polar_encode_runtime(
                current_n,
                u_ref,
                d_ref
            );

            // -----------------------------------------------------------------
            // 3. 启动码块
            // -----------------------------------------------------------------

            @(negedge clk);

            block_start = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);

            block_start = 1'b0;

            // -----------------------------------------------------------------
            // 输入N个LLR
            // -----------------------------------------------------------------

            input_count  = 0;
            timeout_count = 0;
            stage_debug   = 2;

            // valid/ready是否成交，必须在上升沿之前锁存。
            //
            // 最后一个LLR被接收后，llr_in_ready会在该上升沿之后拉低。
            // 如果上升沿后再检查ready，就会漏计最后一个LLR。
            while ((input_count < current_n) &&
                   (timeout_count < INPUT_TIMEOUT_CYCLES)) begin

                @(negedge clk);

                if (llr_in_ready === 1'b1) begin

                    if (d_ref[input_count] == 1'b1) begin
                        llr_in = -8'sd40;
                    end
                    else begin
                        llr_in = 8'sd40;
                    end

                    llr_in_valid = 1'b1;
                end
                else begin
                    llr_in       = {LLR_W{1'b0}};
                    llr_in_valid = 1'b0;
                end

                #1;

                // 在有效上升沿之前记录本拍是否发生传输。
                input_fire =
                    ((llr_in_ready === 1'b1) &&
                     (llr_in_valid === 1'b1));

                @(posedge clk);
                #1;

                if (input_fire) begin
                    input_count = input_count + 1;
                end

                timeout_count = timeout_count + 1;
            end

            @(negedge clk);

            llr_in_valid = 1'b0;
            llr_in       = {LLR_W{1'b0}};

            check_count = check_count + 1;

            if (input_count != current_n) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: LLR input timeout expected=%0d actual=%0d ready=%b load_busy=%b load_done=%b",
                    case_id,
                    current_n,
                    input_count,
                    llr_in_ready,
                    dut.load_busy,
                    dut.load_done
                );
            end
            else begin
                $display(
                    "CASE %0d LLR LOAD COMPLETE: N=%0d",
                    case_id,
                    current_n
                );
            end

            // -----------------------------------------------------------------
            // 4. 等待并检查N个输出
            // -----------------------------------------------------------------

            stage_debug   = 3;
            output_count  = 0;
            timeout_count = 0;
            monitor_cycle = 0;
            pause_done    = 0;

            while ((block_done !== 1'b1) &&
                   (timeout_count < TIMEOUT_CYCLES)) begin

                @(negedge clk);

                // 最后一个输出强制暂停一个周期。
                if ((u_valid == 1'b1) &&
                    (u_index == current_n-1) &&
                    (pause_done == 0)) begin

                    u_ready    = 1'b0;
                    pause_done = 1;
                end
                else if (((monitor_cycle % 19) == 5) ||
                         ((monitor_cycle % 31) == 11)) begin

                    u_ready = 1'b0;
                end
                else begin
                    u_ready = 1'b1;
                end

                #1;

                fire    = 0;
                stalled = 0;

                if (u_valid == 1'b1) begin

                    check_count = check_count + 3;

                    if (u_index !==
                        output_count[INDEX_W-1:0]) begin

                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: u_index expected=%0d actual=%0d",
                            case_id,
                            output_count,
                            u_index
                        );
                    end

                    if (u_bit !== u_ref[output_count]) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: u[%0d] expected=%b actual=%b",
                            case_id,
                            output_count,
                            u_ref[output_count],
                            u_bit
                        );
                    end

                    if (u_last !==
                        (output_count == current_n-1)) begin

                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: u_last mismatch at %0d",
                            case_id,
                            output_count
                        );
                    end

                    if (u_ready == 1'b1) begin
                        fire = 1;
                    end
                    else begin
                        stalled    = 1;
                        hold_bit   = u_bit;
                        hold_index = u_index;
                        hold_last  = u_last;
                    end
                end

                @(posedge clk);
                #1;

                // 反压期间输出必须保持不变。
                if (stalled) begin
                    check_count = check_count + 1;

                    if ((u_valid !== 1'b1) ||
                        (u_bit   !== hold_bit) ||
                        (u_index !== hold_index) ||
                        (u_last  !== hold_last)) begin

                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: output changed under backpressure",
                            case_id
                        );
                    end
                end

                if (fire) begin
                    output_count = output_count + 1;
                end

                monitor_cycle = monitor_cycle + 1;
                timeout_count = timeout_count + 1;
            end

            // -----------------------------------------------------------------
            // 完成检查
            // -----------------------------------------------------------------

            check_count = check_count + 3;

            if (timeout_count >= TIMEOUT_CYCLES) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: decode timeout",
                    case_id
                );
            end

            if (output_count != current_n) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: output count expected=%0d actual=%0d",
                    case_id,
                    current_n,
                    output_count
                );
            end

            if (block_done !== 1'b1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: block_done missing",
                    case_id
                );
            end

            // -----------------------------------------------------------------
            // block_done应保持一个周期，随后重新回到block_ready
            // -----------------------------------------------------------------

            @(posedge clk);
            #1;

            check_count = check_count + 2;

            if (block_done !== 1'b0) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: block_done longer than one cycle",
                    case_id
                );
            end

            if (block_ready !== 1'b1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: block_ready did not return",
                    case_id
                );
            end

            @(negedge clk);

            u_ready = 1'b0;

            $display(
                "CASE %0d PASS POINT: N=%0d K=%0d output=%0d cycles=%0d",
                case_id,
                current_n,
                selected_k,
                output_count,
                timeout_count
            );
        end

    endtask

    // =========================================================================
    // 主流程：五种N依次切换
    // =========================================================================

    initial begin

        error_count = 0;
        check_count = 0;
        case_count  = 0;
        stage_debug = 0;

        rst_n         = 1'b0;

        config_start  = 1'b0;
        n_log_cfg     = 4'd6;
        k_cfg         = 11'd32;

        block_start   = 1'b0;

        llr_in        = {LLR_W{1'b0}};
        llr_in_valid  = 1'b0;

        u_ready       = 1'b0;

        u_ref         = {NMAX{1'b0}};
        d_ref         = {NMAX{1'b0}};

        // ---------------------------------------------------------------------
        // 复位
        // ---------------------------------------------------------------------

        #22;

        rst_n = 1'b1;

        @(posedge clk);
        #1;

        check_count = check_count + 4;

        if (config_ready !== 1'b1) begin
            error_count = error_count + 1;
            $display("ERROR RESET: config_ready is not 1");
        end

        if (config_busy !== 1'b0) begin
            error_count = error_count + 1;
            $display("ERROR RESET: config_busy is not 0");
        end

        if (block_ready !== 1'b0) begin
            error_count = error_count + 1;

            $display(
                "ERROR RESET: block_ready must be 0 before first config"
            );
        end

        if (u_valid !== 1'b0) begin
            error_count = error_count + 1;
            $display("ERROR RESET: u_valid is not 0");
        end

        // ---------------------------------------------------------------------
        // 五种正式码长，统一采用码率1/2
        // ---------------------------------------------------------------------

        run_one_length(
            1,
            4'd6,
            11'd32
        ); // N=64

        run_one_length(
            2,
            4'd7,
            11'd64
        ); // N=128

        run_one_length(
            3,
            4'd8,
            11'd128
        ); // N=256

        run_one_length(
            4,
            4'd9,
            11'd256
        ); // N=512

        run_one_length(
            5,
            4'd10,
            11'd512
        ); // N=1024

        // ---------------------------------------------------------------------
        // 测试总结
        // ---------------------------------------------------------------------

        #20;

        $display("============================================================");
        $display("sc_five_n_switch_tb completed");
        $display("Total cases  = %0d", case_count);
        $display("Total checks = %0d", check_count);
        $display("Error count  = %0d", error_count);

        if (error_count == 0) begin
            $display("RESULT: sc_five_n_switch_tb PASS");
        end
        else begin
            $display("RESULT: sc_five_n_switch_tb FAIL");
        end

        $display("============================================================");

        $finish;
    end

    // =========================================================================
    // 全局超时和状态诊断
    // =========================================================================

    initial begin

        #40000000;

        $display("============================================================");
        $display("RESULT: sc_five_n_switch_tb GLOBAL TIMEOUT");

        $display(
            "stage_debug=%0d case_count=%0d",
            stage_debug,
            case_count
        );

        $display(
            "config_ready=%b config_busy=%b config_done=%b config_error=%b",
            config_ready,
            config_busy,
            config_done,
            config_error
        );

        $display(
            "block_ready=%b block_busy=%b block_done=%b",
            block_ready,
            block_busy,
            block_done
        );

        $display(
            "llr_in_valid=%b llr_in_ready=%b",
            llr_in_valid,
            llr_in_ready
        );

        $display(
            "u_valid=%b u_ready=%b u_index=%0d u_last=%b",
            u_valid,
            u_ready,
            u_index,
            u_last
        );

        $display(
            "core_state=%0d load_busy=%b load_done=%b decode_busy=%b decode_done=%b output_busy=%b output_done=%b",
            dut.state,
            dut.load_busy,
            dut.load_done,
            dut.decode_busy,
            dut.decode_done,
            dut.output_busy,
            dut.output_done
        );

        $display("============================================================");

        $finish;
    end

endmodule