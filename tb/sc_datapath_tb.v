`timescale 1ns/1ps

// =============================================================================
// sc_datapath_tb.v
// =============================================================================
//
// SC 译码器 B 部分顶层数据通路自检测试平台
//
// 被测模块：
//
//     sc_datapath
//
// sc_datapath 内部包含：
//
//     sc_pe
//     sc_llr_mem
//     sc_beta_mem
//     sc_uhat_mem
//
// =============================================================================
// 测试内容
// =============================================================================
//
// 1. 复位状态；
//
// 2. N=64 根节点 LLR 串行装载：
//
//        第0个输入写入地址0；
//        第63个输入写入地址63；
//        不反序，不执行bit reversal；
//
// 3. 输入LLR从8位符号扩展到10位；
//
// 4. valid暂停周期不消耗输入；
//
// 5. f运算及LLR写回；
//
// 6. g运算：
//
//        beta=0：b+a
//        beta=1：b-a
//
// 7. PE计算结果正、负饱和后写回；
//
// 8. beta写数据选择：
//
//        00：直接数据
//        01：A XOR B
//        10：A
//        11：B
//
// 9. 叶节点判决：
//
//        frozen=1：强制判决0
//        frozen=0：使用叶节点LLR符号位
//
// 10. 叶节点判决同时写入：
//
//        beta_mem
//        uhat_mem
//
// 11. leaf_decision_en和beta_wr_en同时有效时：
//
//        叶节点beta写入优先；
//
// 12. N=64完整u_hat输出；
//
// 13. valid/ready反压时：
//
//        u_bit、u_index、u_last保持不变；
//
// 14. 输出过程中再次output_start应被忽略；
//
// 15. output_done只保持一个时钟周期。
//
// =============================================================================
// 仿真说明
// =============================================================================
//
// 本测试运行时间约几十微秒以内。
//
// Vivado中建议使用：
//
//        Run All
//
// =============================================================================

module sc_datapath_tb;

    // =========================================================================
    // 参数
    // =========================================================================

    parameter integer NMAX      = 1024;
    parameter integer LLR_W     = 8;
    parameter integer INT_W     = 10;
    parameter integer MAX_LOG   = 10;
    parameter integer MEM_DEPTH = 2 * NMAX - 1;
    parameter integer ADDR_W    = 11;
    parameter integer INDEX_W   = 11;

    // =========================================================================
    // 时钟与复位
    // =========================================================================

    reg clk;
    reg rst_n;

    // =========================================================================
    // 根节点串行装载接口
    // =========================================================================

    reg                              load_start;
    reg  [3:0]                       n_log;
    reg  signed [LLR_W-1:0]          llr_in;
    reg                              llr_in_valid;

    wire                             llr_in_ready;
    wire                             load_busy;
    wire                             load_done;

    // =========================================================================
    // LLR和PE接口
    // =========================================================================

    reg  [ADDR_W-1:0]                llr_rd_addr_a;
    reg  [ADDR_W-1:0]                llr_rd_addr_b;

    wire signed [INT_W-1:0]          llr_rd_data_a;
    wire signed [INT_W-1:0]          llr_rd_data_b;

    reg                              pe_mode_g;

    reg                              llr_wr_en;
    reg  [ADDR_W-1:0]                llr_wr_addr;

    wire signed [INT_W-1:0]          pe_result;

    // =========================================================================
    // beta接口
    // =========================================================================

    reg  [ADDR_W-1:0]                beta_rd_addr_a;
    wire                             beta_rd_data_a;

    reg  [ADDR_W-1:0]                beta_rd_addr_b;
    wire                             beta_rd_data_b;

    reg                              beta_wr_en;
    reg  [ADDR_W-1:0]                beta_wr_addr;
    reg                              beta_wr_data;
    reg  [1:0]                       beta_wr_mode;

    wire                             beta_selected_data;

    // =========================================================================
    // 叶节点判决接口
    // =========================================================================

    reg                              leaf_decision_en;
    reg                              leaf_frozen;
    reg  [INDEX_W-1:0]               leaf_index;
    reg  [ADDR_W-1:0]                leaf_beta_wr_addr;

    wire                             leaf_decision;

    // =========================================================================
    // u_hat输出接口
    // =========================================================================

    reg                              output_start;

    wire                             output_busy;
    wire                             output_done;

    wire                             u_valid;
    reg                              u_ready;
    wire                             u_bit;
    wire [10:0]                      u_index;
    wire                             u_last;

    // Fast-SSC 接口（本 TB 仅测普通数据通路，快速节点保持关闭）
    wire [NMAX-1:0] fast_frozen_tie  = {NMAX{1'b0}};
    wire            fast_force0_tie  = 1'b0;
    wire [1:0]      fast_op_tie      = 2'd0;
    wire [ADDR_W-1:0] fast_base_tie  = {ADDR_W{1'b0}};
    wire [INDEX_W-1:0] fast_uhat_tie = {INDEX_W{1'b0}};
    wire [ADDR_W-1:0] fast_chunk_tie = {ADDR_W{1'b0}};
    wire [3:0]      fast_pass_tie    = 4'd0;
    wire [3:0]      fast_len_tie     = 4'd0;
    wire            fast_zero_hit_unused;

    // =========================================================================
    // 参考模型
    // =========================================================================

    reg signed [LLR_W-1:0] llr_reference [0:63];
    reg                    u_reference   [0:63];

    integer error_count;
    integer check_count;
    integer i;

    // =========================================================================
    // DUT实例
    // =========================================================================

    sc_datapath #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (MAX_LOG),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    )
    dut (
        .clk                 (clk),
        .rst_n               (rst_n),

        .load_start          (load_start),
        .n_log               (n_log),
        .llr_in              (llr_in),
        .llr_in_valid        (llr_in_valid),
        .llr_in_ready        (llr_in_ready),
        .load_busy           (load_busy),
        .load_done           (load_done),

        .llr_rd_addr_a       (llr_rd_addr_a),
        .llr_rd_addr_b       (llr_rd_addr_b),
        .llr_rd_data_a       (llr_rd_data_a),
        .llr_rd_data_b       (llr_rd_data_b),

        .pe_mode_g           (pe_mode_g),
        .llr_wr_en           (llr_wr_en),
        .llr_wr_addr         (llr_wr_addr),
        .pe_result           (pe_result),

        .beta_rd_addr_a      (beta_rd_addr_a),
        .beta_rd_data_a      (beta_rd_data_a),

        .beta_rd_addr_b      (beta_rd_addr_b),
        .beta_rd_data_b      (beta_rd_data_b),

        .beta_wr_en          (beta_wr_en),
        .beta_wr_addr        (beta_wr_addr),
        .beta_wr_data        (beta_wr_data),
        .beta_wr_mode        (beta_wr_mode),
        .beta_selected_data  (beta_selected_data),

        .leaf_decision_en    (leaf_decision_en),
        .leaf_frozen         (leaf_frozen),
        .leaf_index          (leaf_index),
        .leaf_beta_wr_addr   (leaf_beta_wr_addr),
        .leaf_decision       (leaf_decision),

        .output_start        (output_start),
        .output_busy         (output_busy),
        .output_done         (output_done),

        .u_valid             (u_valid),
        .u_ready             (u_ready),
        .u_bit               (u_bit),
        .u_index             (u_index),
        .u_last              (u_last),

        .frozen_bits     (fast_frozen_tie),
        .beta_force0     (fast_force0_tie),
        .fast_op         (fast_op_tie),
        .fast_base       (fast_base_tie),
        .fast_uhat_base  (fast_uhat_tie),
        .fast_chunk      (fast_chunk_tie),
        .fast_pass       (fast_pass_tie),
        .fast_len_log    (fast_len_tie),

        .fast_zero_hit   (fast_zero_hit_unused)
    );

    // =========================================================================
    // 时钟
    // =========================================================================

    initial begin
        clk = 1'b0;
    end

    always #5 clk = ~clk;

    // =========================================================================
    // 错误报告任务
    // =========================================================================

    task report_error;

        input [8*120-1:0] message;

        begin
            error_count = error_count + 1;
            $display("ERROR: %s", message);
        end

    endtask

    // =========================================================================
    // 检查LLR读端口A
    // =========================================================================

    task check_llr_a;

        input [ADDR_W-1:0] address;
        input integer expected_value;
        input [8*80-1:0] message;

        reg signed [INT_W-1:0] expected_vector;

        begin
            expected_vector = expected_value;

            llr_rd_addr_a = address;
            // 2026-08-12：存储器改为同步读，需等一拍再采样
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (llr_rd_data_a !== expected_vector) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: %s address=%0d expected=%0d actual=%0d",
                    message,
                    address,
                    expected_value,
                    $signed(llr_rd_data_a)
                );
            end
        end

    endtask

    // =========================================================================
    // 检查两个LLR组合读端口
    // =========================================================================

    task check_llr_pair;

        input [ADDR_W-1:0] address_a;
        input integer expected_a;

        input [ADDR_W-1:0] address_b;
        input integer expected_b;

        input [8*80-1:0] message;

        reg signed [INT_W-1:0] expected_vector_a;
        reg signed [INT_W-1:0] expected_vector_b;

        begin
            expected_vector_a = expected_a;
            expected_vector_b = expected_b;

            llr_rd_addr_a = address_a;
            llr_rd_addr_b = address_b;

            // 2026-08-12：存储器改为同步读，需等一拍再采样
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (llr_rd_data_a !== expected_vector_a) begin
                error_count = error_count + 1;

                $display(
                    "ERROR A: %s address=%0d expected=%0d actual=%0d",
                    message,
                    address_a,
                    expected_a,
                    $signed(llr_rd_data_a)
                );
            end

            check_count = check_count + 1;

            if (llr_rd_data_b !== expected_vector_b) begin
                error_count = error_count + 1;

                $display(
                    "ERROR B: %s address=%0d expected=%0d actual=%0d",
                    message,
                    address_b,
                    expected_b,
                    $signed(llr_rd_data_b)
                );
            end
        end

    endtask

    // =========================================================================
    // beta直接写入
    // =========================================================================

    task write_beta_direct;

        input [ADDR_W-1:0] address;
        input data_value;

        begin
            @(negedge clk);

            leaf_decision_en = 1'b0;

            beta_wr_en   = 1'b1;
            beta_wr_addr = address;
            beta_wr_data = data_value;
            beta_wr_mode = 2'b00;

            @(posedge clk);
            #1;

            beta_wr_en = 1'b0;
        end

    endtask

    // =========================================================================
    // 检查beta地址
    // =========================================================================

    task check_beta_a;

        input [ADDR_W-1:0] address;
        input expected_value;
        input [8*80-1:0] message;

        begin
            beta_rd_addr_a = address;
            // 2026-08-12：存储器改为同步读，需等一拍再采样
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (beta_rd_data_a !== expected_value) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: %s beta_address=%0d expected=%b actual=%b",
                    message,
                    address,
                    expected_value,
                    beta_rd_data_a
                );
            end
        end

    endtask

    // =========================================================================
    // 执行一次beta选择写回
    // =========================================================================

    task execute_beta_write;

        input [ADDR_W-1:0] read_address_a;
        input [ADDR_W-1:0] read_address_b;
        input [1:0] mode_value;
        input [ADDR_W-1:0] write_address;
        input expected_value;

        begin
            @(negedge clk);

            beta_rd_addr_a = read_address_a;
            beta_rd_addr_b = read_address_b;

            beta_wr_mode = mode_value;
            beta_wr_addr = write_address;
            beta_wr_en   = 1'b1;

            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (beta_selected_data !== expected_value) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: beta selected data mismatch mode=%b expected=%b actual=%b",
                    mode_value,
                    expected_value,
                    beta_selected_data
                );
            end

            @(posedge clk);
            #1;

            beta_wr_en = 1'b0;

            beta_rd_addr_a = write_address;
            // 2026-08-12：同步读，需等一拍
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (beta_rd_data_a !== expected_value) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: beta writeback mismatch address=%0d expected=%b actual=%b",
                    write_address,
                    expected_value,
                    beta_rd_data_a
                );
            end
        end

    endtask

    // =========================================================================
    // 执行一次PE运算并写回LLR存储器
    // =========================================================================

    task execute_pe_write;

        input mode_g_value;

        input [ADDR_W-1:0] address_a;
        input [ADDR_W-1:0] address_b;
        input [ADDR_W-1:0] beta_address;

        input [ADDR_W-1:0] destination_address;

        input integer expected_result;

        reg signed [INT_W-1:0] expected_vector;

        begin
            expected_vector = expected_result;

            @(negedge clk);

            llr_rd_addr_a  = address_a;
            llr_rd_addr_b  = address_b;
            beta_rd_addr_a = beta_address;

            pe_mode_g   = mode_g_value;
            llr_wr_addr = destination_address;
            llr_wr_en   = 1'b1;

            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (pe_result !== expected_vector) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: PE result mismatch mode_g=%b expected=%0d actual=%0d",
                    mode_g_value,
                    expected_result,
                    $signed(pe_result)
                );
            end

            @(posedge clk);
            #1;

            llr_wr_en = 1'b0;

            llr_rd_addr_a = destination_address;
            // 2026-08-12：同步读，需等一拍
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (llr_rd_data_a !== expected_vector) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: LLR writeback mismatch address=%0d expected=%0d actual=%0d",
                    destination_address,
                    expected_result,
                    $signed(llr_rd_data_a)
                );
            end
        end

    endtask

    // =========================================================================
    // 执行一次叶节点判决
    // =========================================================================

    task execute_leaf_decision;

        input integer phi;
        input frozen_value;
        input expected_value;

        begin
            @(negedge clk);

            llr_rd_addr_a = phi;

            leaf_index        = phi;
            leaf_frozen       = frozen_value;
            leaf_beta_wr_addr = 11'd2046;
            leaf_decision_en  = 1'b1;

            beta_wr_en = 1'b0;

            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (leaf_decision !== expected_value) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: leaf decision mismatch phi=%0d frozen=%b llr=%0d expected=%b actual=%b",
                    phi,
                    frozen_value,
                    $signed(llr_rd_data_a),
                    expected_value,
                    leaf_decision
                );
            end

            @(posedge clk);
            #1;

            leaf_decision_en = 1'b0;

            beta_rd_addr_a = 11'd2046;
            // 2026-08-12：同步读，需等一拍
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (beta_rd_data_a !== expected_value) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: leaf beta write mismatch phi=%0d expected=%b actual=%b",
                    phi,
                    expected_value,
                    beta_rd_data_a
                );
            end
        end

    endtask

    // =========================================================================
    // N=64根节点LLR装载
    // =========================================================================

    task load_n64;

        integer index_value;

        begin
            // -----------------------------------------------------------------
            // 启动装载
            // -----------------------------------------------------------------

            @(negedge clk);

            n_log        = 4'd6;
            load_start   = 1'b1;
            llr_in_valid = 1'b0;

            @(posedge clk);
            #1;

            load_start = 1'b0;

            check_count = check_count + 1;

            if (load_busy !== 1'b1) begin
                report_error("load_busy did not assert after load_start");
            end

            check_count = check_count + 1;

            if (llr_in_ready !== 1'b1) begin
                report_error("llr_in_ready did not assert during loading");
            end

            // -----------------------------------------------------------------
            // 依次输入64个LLR
            // -----------------------------------------------------------------

            for (index_value = 0;
                 index_value < 64;
                 index_value = index_value + 1) begin

                // 在索引10之前插入一个valid暂停周期
                if (index_value == 10) begin
                    @(negedge clk);

                    llr_in_valid = 1'b0;
                    llr_in       = {LLR_W{1'b0}};

                    @(posedge clk);
                    #1;

                    check_count = check_count + 1;

                    if (load_busy !== 1'b1) begin
                        report_error("load_busy dropped during valid pause");
                    end

                    check_count = check_count + 1;

                    if (load_done !== 1'b0) begin
                        report_error("load_done asserted during valid pause");
                    end
                end

                @(negedge clk);

                llr_in       = llr_reference[index_value];
                llr_in_valid = 1'b1;

                @(posedge clk);
                #1;

                if (index_value < 63) begin
                    check_count = check_count + 1;

                    if (load_busy !== 1'b1) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR: load_busy dropped before final LLR at index=%0d",
                            index_value
                        );
                    end

                    check_count = check_count + 1;

                    if (load_done !== 1'b0) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR: load_done asserted early at index=%0d",
                            index_value
                        );
                    end
                end
                else begin
                    check_count = check_count + 1;

                    if (load_busy !== 1'b0) begin
                        report_error("load_busy did not clear after final LLR");
                    end

                    check_count = check_count + 1;

                    if (load_done !== 1'b1) begin
                        report_error("load_done did not assert after final LLR");
                    end
                end
            end

            @(negedge clk);
            llr_in_valid = 1'b0;

            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (load_done !== 1'b0) begin
                report_error("load_done remained high for more than one cycle");
            end

            check_count = check_count + 1;

            if (llr_in_ready !== 1'b0) begin
                report_error("llr_in_ready remained high after loading");
            end
        end

    endtask

    // =========================================================================
    // 检查完整N=64串行输出
    // =========================================================================

    task check_n64_output;

        integer accepted_count;
        integer cycle_count;
        integer restart_injected;

        reg ready_value;
        reg expected_last;

        begin
            accepted_count  = 0;
            cycle_count     = 0;
            restart_injected = 0;

            // -----------------------------------------------------------------
            // 启动输出
            // -----------------------------------------------------------------

            @(negedge clk);

            n_log        = 4'd6;
            output_start = 1'b1;
            u_ready      = 1'b0;

            @(posedge clk);
            #1;

            output_start = 1'b0;

            check_count = check_count + 1;

            if (output_busy !== 1'b1) begin
                report_error("output_busy did not assert after output_start");
            end

            check_count = check_count + 1;

            if (u_valid !== 1'b1) begin
                report_error("u_valid did not assert after output_start");
            end

            check_count = check_count + 1;

            if (u_index !== 11'd0) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: first output index expected=0 actual=%0d",
                    u_index
                );
            end

            // -----------------------------------------------------------------
            // 接收全部64个输出
            // -----------------------------------------------------------------

            while (accepted_count < 64) begin
                @(negedge clk);

                // 周期性插入反压
                if (((cycle_count % 7) == 2) ||
                    ((cycle_count % 11) == 5)) begin

                    ready_value = 1'b0;
                end
                else begin
                    ready_value = 1'b1;
                end

                // 最后一个输出至少暂停一个周期
                if ((accepted_count == 63) &&
                    ((cycle_count % 2) == 0)) begin

                    ready_value = 1'b0;
                end

                u_ready = ready_value;

                // 输出过程中尝试重新启动N=1024输出
                if ((accepted_count >= 10) &&
                    (restart_injected == 0)) begin

                    output_start   = 1'b1;
                    n_log         = 4'd10;
                    restart_injected = 1;
                end
                else begin
                    output_start = 1'b0;
                    n_log        = 4'd6;
                end

                #1;

                expected_last = (accepted_count == 63);

                check_count = check_count + 1;

                if (u_valid !== 1'b1) begin
                    error_count = error_count + 1;

                    $display(
                        "ERROR: u_valid dropped early at index=%0d",
                        accepted_count
                    );
                end

                check_count = check_count + 1;

                if (u_index !== accepted_count) begin
                    error_count = error_count + 1;

                    $display(
                        "ERROR: u_index mismatch expected=%0d actual=%0d ready=%b",
                        accepted_count,
                        u_index,
                        ready_value
                    );
                end

                check_count = check_count + 1;

                if (u_bit !== u_reference[accepted_count]) begin
                    error_count = error_count + 1;

                    $display(
                        "ERROR: u_bit mismatch index=%0d expected=%b actual=%b",
                        accepted_count,
                        u_reference[accepted_count],
                        u_bit
                    );
                end

                check_count = check_count + 1;

                if (u_last !== expected_last) begin
                    error_count = error_count + 1;

                    $display(
                        "ERROR: u_last mismatch index=%0d expected=%b actual=%b",
                        accepted_count,
                        expected_last,
                        u_last
                    );
                end

                @(posedge clk);
                #1;

                output_start = 1'b0;
                n_log        = 4'd6;

                if (ready_value == 1'b1) begin
                    accepted_count = accepted_count + 1;

                    if (accepted_count == 64) begin
                        check_count = check_count + 1;

                        if (output_busy !== 1'b0) begin
                            report_error("output_busy did not clear after final handshake");
                        end

                        check_count = check_count + 1;

                        if (u_valid !== 1'b0) begin
                            report_error("u_valid did not clear after final handshake");
                        end

                        check_count = check_count + 1;

                        if (output_done !== 1'b1) begin
                            report_error("output_done did not assert after final handshake");
                        end
                    end
                    else begin
                        check_count = check_count + 1;

                        if (output_done !== 1'b0) begin
                            error_count = error_count + 1;

                            $display(
                                "ERROR: output_done asserted early after accepted_count=%0d",
                                accepted_count
                            );
                        end
                    end
                end
                else begin
                    // 反压期间索引和输出值必须保持
                    check_count = check_count + 1;

                    if (u_index !== accepted_count) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR: u_index changed during backpressure expected=%0d actual=%0d",
                            accepted_count,
                            u_index
                        );
                    end

                    check_count = check_count + 1;

                    if (u_bit !== u_reference[accepted_count]) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR: u_bit changed during backpressure index=%0d",
                            accepted_count
                        );
                    end

                    check_count = check_count + 1;

                    if (u_last !== expected_last) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR: u_last changed during backpressure index=%0d",
                            accepted_count
                        );
                    end

                    check_count = check_count + 1;

                    if (output_done !== 1'b0) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR: output_done asserted during backpressure index=%0d",
                            accepted_count
                        );
                    end
                end

                cycle_count = cycle_count + 1;
            end

            // output_done必须在下一周期恢复为0
            @(posedge clk);
            #1;

            check_count = check_count + 1;

            if (output_done !== 1'b0) begin
                report_error("output_done remained high for more than one cycle");
            end

            check_count = check_count + 1;

            if (output_busy !== 1'b0) begin
                report_error("output_busy asserted after output completion");
            end

            @(negedge clk);

            u_ready      = 1'b0;
            output_start = 1'b0;
        end

    endtask

    // =========================================================================
    // 主测试流程
    // =========================================================================

    initial begin
        error_count = 0;
        check_count = 0;

        rst_n = 1'b0;

        load_start   = 1'b0;
        n_log        = 4'd6;
        llr_in       = {LLR_W{1'b0}};
        llr_in_valid = 1'b0;

        llr_rd_addr_a = {ADDR_W{1'b0}};
        llr_rd_addr_b = {ADDR_W{1'b0}};

        pe_mode_g   = 1'b0;
        llr_wr_en   = 1'b0;
        llr_wr_addr = {ADDR_W{1'b0}};

        beta_rd_addr_a = {ADDR_W{1'b0}};
        beta_rd_addr_b = {ADDR_W{1'b0}};

        beta_wr_en   = 1'b0;
        beta_wr_addr = {ADDR_W{1'b0}};
        beta_wr_data = 1'b0;
        beta_wr_mode = 2'b00;

        leaf_decision_en  = 1'b0;
        leaf_frozen       = 1'b0;
        leaf_index        = {INDEX_W{1'b0}};
        leaf_beta_wr_addr = {ADDR_W{1'b0}};

        output_start = 1'b0;
        u_ready      = 1'b0;

        // ---------------------------------------------------------------------
        // 构造N=64输入LLR
        // ---------------------------------------------------------------------

        for (i = 0; i < 64; i = i + 1) begin
            llr_reference[i] =
                ((i * 37) % 255) - 127;
        end

        // 覆盖前几个值，便于执行定向PE测试
        llr_reference[0] = -8'sd32;
        llr_reference[1] =  8'sd20;

        llr_reference[2] = -8'sd1;
        llr_reference[3] =  8'sd0;

        llr_reference[4] =  8'sd127;
        llr_reference[5] =  8'sd127;

        llr_reference[6] = -8'sd128;
        llr_reference[7] = -8'sd128;

        // ---------------------------------------------------------------------
        // 复位
        // ---------------------------------------------------------------------

        #22;
        rst_n = 1'b1;

        @(posedge clk);
        #1;

        $display("TEST 1: reset state");

        check_count = check_count + 1;

        if (load_busy !== 1'b0) begin
            report_error("load_busy is not zero after reset");
        end

        check_count = check_count + 1;

        if (load_done !== 1'b0) begin
            report_error("load_done is not zero after reset");
        end

        check_count = check_count + 1;

        if (llr_in_ready !== 1'b0) begin
            report_error("llr_in_ready is not zero after reset");
        end

        check_count = check_count + 1;

        if (output_busy !== 1'b0) begin
            report_error("output_busy is not zero after reset");
        end

        check_count = check_count + 1;

        if (output_done !== 1'b0) begin
            report_error("output_done is not zero after reset");
        end

        check_count = check_count + 1;

        if (u_valid !== 1'b0) begin
            report_error("u_valid is not zero after reset");
        end

        // ---------------------------------------------------------------------
        // 根节点LLR装载
        // ---------------------------------------------------------------------

        $display("TEST 2: load N=64 root LLR values");

        load_n64;

        // ---------------------------------------------------------------------
        // 自然顺序、双组合读及符号扩展
        // ---------------------------------------------------------------------

        $display("TEST 3: natural-order loading and sign extension");

        check_llr_pair(
            11'd0,
            -32,
            11'd1,
            20,
            "root addresses 0 and 1"
        );

        check_llr_pair(
            11'd2,
            -1,
            11'd3,
            0,
            "sign extension of -1 and zero"
        );

        check_llr_pair(
            11'd4,
            127,
            11'd6,
            -128,
            "sign extension of 127 and -128"
        );

        check_llr_a(
            11'd63,
            $signed(llr_reference[63]),
            "last root LLR"
        );

        // ---------------------------------------------------------------------
        // beta基础写入
        // ---------------------------------------------------------------------

        $display("TEST 4: beta direct writes");

        write_beta_direct(11'd1100, 1'b1);
        write_beta_direct(11'd1101, 1'b0);

        check_beta_a(
            11'd1100,
            1'b1,
            "beta one"
        );

        check_beta_a(
            11'd1101,
            1'b0,
            "beta zero"
        );

        // ---------------------------------------------------------------------
        // f/g运算和LLR写回
        // ---------------------------------------------------------------------

        $display("TEST 5: f and g PE writeback operations");

        // f(-32,20)=-20
        execute_pe_write(
            1'b0,
            11'd0,
            11'd1,
            11'd1101,
            11'd1024,
            -20
        );

        // g(-32,20,0)=20+(-32)=-12
        execute_pe_write(
            1'b1,
            11'd0,
            11'd1,
            11'd1101,
            11'd1025,
            -12
        );

        // g(-32,20,1)=20-(-32)=52
        execute_pe_write(
            1'b1,
            11'd0,
            11'd1,
            11'd1100,
            11'd1026,
            52
        );

        // ---------------------------------------------------------------------
        // PE饱和结果写回
        // ---------------------------------------------------------------------

        $display("TEST 6: positive and negative saturation writeback");

        // 127+127=254
        execute_pe_write(
            1'b1,
            11'd4,
            11'd5,
            11'd1101,
            11'd1027,
            254
        );

        // 254+254=508
        execute_pe_write(
            1'b1,
            11'd1027,
            11'd1027,
            11'd1101,
            11'd1028,
            508
        );

        // 508+508=1016，饱和为511
        execute_pe_write(
            1'b1,
            11'd1028,
            11'd1028,
            11'd1101,
            11'd1029,
            511
        );

        // b-a=-128-511=-639，饱和为-512
        execute_pe_write(
            1'b1,
            11'd1029,
            11'd6,
            11'd1100,
            11'd1030,
            -512
        );

        // ---------------------------------------------------------------------
        // beta数据选择功能
        // ---------------------------------------------------------------------

        $display("TEST 7: beta XOR, A and B source selection");

        // beta[1100]=1，beta[1101]=0

        // XOR：1 XOR 0 = 1
        execute_beta_write(
            11'd1100,
            11'd1101,
            2'b01,
            11'd1200,
            1'b1
        );

        // 选择A：1
        execute_beta_write(
            11'd1100,
            11'd1101,
            2'b10,
            11'd1201,
            1'b1
        );

        // 选择B：0
        execute_beta_write(
            11'd1100,
            11'd1101,
            2'b11,
            11'd1202,
            1'b0
        );

        // 直接数据：1
        @(negedge clk);

        beta_wr_en   = 1'b1;
        beta_wr_addr = 11'd1203;
        beta_wr_data = 1'b1;
        beta_wr_mode = 2'b00;

        @(posedge clk);
        #1;

        check_count = check_count + 1;

        if (beta_selected_data !== 1'b1) begin
            report_error("beta direct source selection mismatch");
        end

        @(posedge clk);
        #1;

        beta_wr_en = 1'b0;

        check_beta_a(
            11'd1203,
            1'b1,
            "beta direct write mode"
        );

        // ---------------------------------------------------------------------
        // 叶节点写优先级
        // ---------------------------------------------------------------------

        $display("TEST 8: leaf beta write priority");

        // 先把普通beta目标地址1600写为1
        write_beta_direct(11'd1600, 1'b1);

        @(negedge clk);

        // 叶节点判决：
        // 地址0的LLR=-32，但冻结，因此判决0
        llr_rd_addr_a    = 11'd0;
        leaf_frozen      = 1'b1;
        leaf_index       = 11'd0;
        leaf_beta_wr_addr = 11'd2046;
        leaf_decision_en = 1'b1;

        // 同周期尝试普通beta写：
        // beta[1600]尝试从1改为0
        beta_wr_en   = 1'b1;
        beta_wr_addr = 11'd1600;
        beta_wr_data = 1'b0;
        beta_wr_mode = 2'b00;

        @(posedge clk);
        #1;

        check_count = check_count + 1;

        if (leaf_decision !== 1'b0) begin
            report_error("frozen leaf decision is not zero");
        end

        @(posedge clk);
        #1;

        leaf_decision_en = 1'b0;
        beta_wr_en       = 1'b0;

        // 叶节点地址应写入0
        check_beta_a(
            11'd2046,
            1'b0,
            "leaf beta priority destination"
        );

        // 普通beta地址应保持原来的1
        check_beta_a(
            11'd1600,
            1'b1,
            "normal beta write should be ignored during leaf write"
        );

        // ---------------------------------------------------------------------
        // 生成全部N=64叶节点判决
        // ---------------------------------------------------------------------

        $display("TEST 9: generate 64 leaf decisions");

        for (i = 0; i < 64; i = i + 1) begin

            // 每5个位置设置一个冻结位
            if ((i % 5) == 0) begin
                u_reference[i] = 1'b0;

                execute_leaf_decision(
                    i,
                    1'b1,
                    1'b0
                );
            end
            else begin
                u_reference[i] =
                    llr_reference[i][LLR_W-1];

                execute_leaf_decision(
                    i,
                    1'b0,
                    llr_reference[i][LLR_W-1]
                );
            end
        end

        // 显式检查几个典型叶节点
        check_count = check_count + 1;

        if (u_reference[0] !== 1'b0) begin
            report_error("reference frozen decision at phi=0 is incorrect");
        end

        check_count = check_count + 1;

        if (u_reference[2] !== 1'b1) begin
            report_error("reference negative-LLR decision at phi=2 is incorrect");
        end

        check_count = check_count + 1;

        if (u_reference[3] !== 1'b0) begin
            report_error("reference zero-LLR decision at phi=3 is incorrect");
        end

        // ---------------------------------------------------------------------
        // 完整u_hat串行输出
        // ---------------------------------------------------------------------

        $display("TEST 10: N=64 u_hat output with backpressure");

        check_n64_output;

        // ---------------------------------------------------------------------
        // 总结
        // ---------------------------------------------------------------------

        #20;

        $display("============================================================");
        $display("sc_datapath_tb completed");
        $display("Total checks = %0d", check_count);
        $display("Error count  = %0d", error_count);

        if (error_count == 0) begin
            $display("RESULT: sc_datapath_tb PASS");
        end
        else begin
            $display("RESULT: sc_datapath_tb FAIL");
        end

        $display("============================================================");

        $finish;
    end

    // =========================================================================
    // 超时保护
    // =========================================================================

    initial begin
        #500000;

        $display("============================================================");
        $display("RESULT: sc_datapath_tb TIMEOUT");
        $display("Simulation did not finish within 500 us");
        $display("============================================================");

        $finish;
    end

endmodule
