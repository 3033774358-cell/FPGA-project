`timescale 1ns/1ps

// =============================================================================
// sc_bc_n256_system_tb.v
// N=256、K=128，正式sc_controller + 现有sc_datapath系统级无噪声环回测试。
// 编码：d=u*F^(x8)，无bit reversal；d=0映射+40，d=1映射-40。
// frozen[i]=1表示u[i]冻结为0。NMAX仍固定1024。
// =============================================================================
module sc_bc_n256_system_tb;

    parameter integer NMAX      = 1024;
    parameter integer N         = 256;
    parameter integer K         = 128;
    parameter integer N_LOG     = 8;
    parameter integer LLR_W     = 8;
    parameter integer INT_W     = 10;
    parameter integer MAX_LOG   = 10;
    parameter integer MEM_DEPTH = 2*NMAX-1;
    parameter integer ADDR_W    = 11;
    parameter integer INDEX_W   = 11;
    parameter integer TIMEOUT_CYCLES = 30000;

    // N=256、K=128固定冻结掩码；bit i对应u[i]。
    localparam [N-1:0] FROZEN_N256_K128 =
        256'h00000000000001170001011F013F7FFF0001037F177F7FFF177F7FFFFFFFFFFF;

    reg clk;
    reg rst_n;

    reg                         load_start;
    reg [3:0]                   n_log;
    reg signed [LLR_W-1:0]      llr_in;
    reg                         llr_in_valid;
    wire                        llr_in_ready;
    wire                        load_busy;
    wire                        load_done;

    reg [NMAX-1:0]              frozen_bits;
    wire                        decode_busy;
    wire                        decode_done;

    wire [ADDR_W-1:0]           llr_rd_addr_a;
    wire [ADDR_W-1:0]           llr_rd_addr_b;
    wire signed [INT_W-1:0]     llr_rd_data_a;
    wire signed [INT_W-1:0]     llr_rd_data_b;
    wire                        pe_mode_g;
    wire                        llr_wr_en;
    wire [ADDR_W-1:0]           llr_wr_addr;
    wire signed [INT_W-1:0]     pe_result;

    wire [ADDR_W-1:0]           beta_rd_addr_a;
    wire [ADDR_W-1:0]           beta_rd_addr_b;
    wire                        beta_rd_data_a;
    wire                        beta_rd_data_b;
    wire                        beta_wr_en;
    wire [ADDR_W-1:0]           beta_wr_addr;
    wire                        beta_wr_data;
    wire [1:0]                  beta_wr_mode;
    wire                        beta_selected_data;

    wire                        leaf_decision_en;
    wire                        leaf_frozen;
    wire [INDEX_W-1:0]          leaf_index;
    wire [ADDR_W-1:0]           leaf_beta_wr_addr;
    wire                        leaf_decision;

    wire                        output_start;
    wire                        output_busy;
    wire                        output_done;
    wire                        u_valid;
    reg                         u_ready;
    wire                        u_bit;
    wire [10:0]                 u_index;
    wire                        u_last;

    // Fast-SSC 接口
    reg                         fast_rom_start;
    wire                        fast_rom_done;
    wire [10:0]                 type_rom_addr;
    wire [1:0]                  type_rom_data;
    wire                        beta_force0;
    wire [1:0]                  fast_op;
    wire [ADDR_W-1:0]           fast_base;
    wire [INDEX_W-1:0]          fast_uhat_base;
    wire [ADDR_W-1:0]           fast_chunk;
    wire [3:0]                  fast_pass;
    wire [3:0]                  fast_len_log;
    wire                        fast_zero_hit;

    integer error_count;
    integer check_count;
    integer case_count;

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // =========================================================================
    // B数据通路
    // =========================================================================

    sc_datapath #(
        .NMAX(NMAX),
        .LLR_W(LLR_W),
        .INT_W(INT_W),
        .MAX_LOG(MAX_LOG),
        .MEM_DEPTH(MEM_DEPTH),
        .ADDR_W(ADDR_W),
        .INDEX_W(INDEX_W)
    ) u_datapath (
        .clk(clk),
        .rst_n(rst_n),

        .load_start(load_start),
        .n_log(n_log),
        .llr_in(llr_in),
        .llr_in_valid(llr_in_valid),
        .llr_in_ready(llr_in_ready),
        .load_busy(load_busy),
        .load_done(load_done),

        .llr_rd_addr_a(llr_rd_addr_a),
        .llr_rd_addr_b(llr_rd_addr_b),
        .llr_rd_data_a(llr_rd_data_a),
        .llr_rd_data_b(llr_rd_data_b),

        .pe_mode_g(pe_mode_g),
        .llr_wr_en(llr_wr_en),
        .llr_wr_addr(llr_wr_addr),
        .pe_result(pe_result),

        .beta_rd_addr_a(beta_rd_addr_a),
        .beta_rd_data_a(beta_rd_data_a),
        .beta_rd_addr_b(beta_rd_addr_b),
        .beta_rd_data_b(beta_rd_data_b),

        .beta_wr_en(beta_wr_en),
        .beta_wr_addr(beta_wr_addr),
        .beta_wr_data(beta_wr_data),
        .beta_wr_mode(beta_wr_mode),
        .beta_selected_data(beta_selected_data),

        .leaf_decision_en(leaf_decision_en),
        .leaf_frozen(leaf_frozen),
        .leaf_index(leaf_index),
        .leaf_beta_wr_addr(leaf_beta_wr_addr),
        .leaf_decision(leaf_decision),

        .output_start(output_start),
        .output_busy(output_busy),
        .output_done(output_done),
        .u_valid(u_valid),
        .u_ready(u_ready),
        .u_bit(u_bit),
        .u_index(u_index),
        .u_last(u_last),

        .frozen_bits(frozen_bits),
        .beta_force0(beta_force0),
        .fast_op(fast_op),
        .fast_base(fast_base),
        .fast_uhat_base(fast_uhat_base),
        .fast_chunk(fast_chunk),
        .fast_pass(fast_pass),
        .fast_len_log(fast_len_log),

        .fast_zero_hit(fast_zero_hit)
    );

    // =========================================================================
    // 正式C控制器
    // load_done直接启动译码
    // =========================================================================

    sc_controller #(
        .NMAX(NMAX),
        .MAX_LOG(MAX_LOG),
        .ADDR_W(ADDR_W),
        .INDEX_W(INDEX_W)
    ) u_controller (
        .clk(clk),
        .rst_n(rst_n),

        .decode_start(load_done),
        .n_log(n_log),
        .frozen_bits(frozen_bits),

        .decode_busy(decode_busy),
        .decode_done(decode_done),

        .llr_rd_addr_a(llr_rd_addr_a),
        .llr_rd_addr_b(llr_rd_addr_b),
        .pe_mode_g(pe_mode_g),
        .llr_wr_en(llr_wr_en),
        .llr_wr_addr(llr_wr_addr),

        .beta_rd_addr_a(beta_rd_addr_a),
        .beta_rd_addr_b(beta_rd_addr_b),
        .beta_wr_en(beta_wr_en),
        .beta_wr_addr(beta_wr_addr),
        .beta_wr_data(beta_wr_data),
        .beta_wr_mode(beta_wr_mode),

        .leaf_decision_en(leaf_decision_en),
        .leaf_frozen(leaf_frozen),
        .leaf_index(leaf_index),
        .leaf_beta_wr_addr(leaf_beta_wr_addr),

        .output_start(output_start),
        .output_done(output_done),

        .type_rom_addr(type_rom_addr),
        .type_rom_data(type_rom_data),
        .beta_force0(beta_force0),
        .fast_op(fast_op),
        .fast_base(fast_base),
        .fast_uhat_base(fast_uhat_base),
        .fast_chunk(fast_chunk),
        .fast_pass(fast_pass),
        .fast_len_log(fast_len_log),

        .fast_zero_hit(fast_zero_hit)
    );

    // Fast-SSC 节点类型 ROM
    sc_fast_node_rom #(
        .NMAX    (NMAX),
        .MAX_LOG (MAX_LOG),
        .ADDR_W  (ADDR_W)
    ) u_fast_node_rom (
        .clk         (clk),
        .rst_n       (rst_n),
        .fill_start  (fast_rom_start),
        .n_log       (n_log),
        .frozen_mask (frozen_bits),
        .fill_done   (fast_rom_done),
        .rd_addr     (type_rom_addr),
        .rd_data     (type_rom_data)
    );

    // =========================================================================
    // 无bit reversal Polar编码黄金模型
    // =========================================================================

    task polar_encode;
        input  [N-1:0] u_in;
        output [N-1:0] d_out;

        reg [N-1:0] work;

        integer m;
        integer base;
        integer j;

        begin
            work = u_in;
            m = 1;

            while (m < N) begin
                for (base = 0;
                     base < N;
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
    // 生成满足冻结位约束的测试u
    // =========================================================================

    task build_u;
        input integer pattern;
        output [N-1:0] u_out;

        integer i;
        integer r;

        begin
            u_out = {N{1'b0}};

            for (i = 0; i < N; i = i + 1) begin
                if (!FROZEN_N256_K128[i]) begin
                    case (pattern)
                        1: begin
                            u_out[i] = i % 2;
                        end

                        2: begin
                            u_out[i] = 1'b1;
                        end

                        3: begin
                            u_out[i] =
                                ((((i*13)+7) % 5) < 2);
                        end

                        default: begin
                            r = $random;
                            u_out[i] = r & 1;
                        end
                    endcase
                end
            end
        end
    endtask

    // =========================================================================
    // 完整N=256测试
    // =========================================================================

    task run_case;
        input integer case_id;
        input [N-1:0] expected_u;

        reg [N-1:0] encoded_d;
        reg signed [INT_W-1:0] expected_llr;

        reg fire;
        reg stalled;
        reg hold_bit;
        reg [10:0] hold_index;
        reg hold_last;

        integer i;
        integer input_index;
        integer output_count;
        integer timeout_count;
        integer monitor_cycle;
        integer output_done_count;
        integer decode_done_count;
        integer last_pause_done;
        integer frozen_count;
        integer info_count;
        integer start_wait;

        begin
            case_count = case_count + 1;

            polar_encode(expected_u, encoded_d);

            frozen_count = 0;
            info_count   = 0;

            // -------------------------------------------------------------
            // 检查掩码和输入u是否合法
            // -------------------------------------------------------------

            for (i = 0; i < N; i = i + 1) begin
                if (FROZEN_N256_K128[i]) begin
                    frozen_count = frozen_count + 1;
                    check_count  = check_count + 1;

                    if (expected_u[i] !== 1'b0) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: frozen u[%0d] is not zero",
                            case_id,
                            i
                        );
                    end
                end
                else begin
                    info_count = info_count + 1;
                end
            end

            check_count = check_count + 2;

            if (frozen_count != N-K) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: frozen count expected=%0d actual=%0d",
                    N-K,
                    frozen_count
                );
            end

            if (info_count != K) begin
                error_count = error_count + 1;

                $display(
                    "ERROR: info count expected=%0d actual=%0d",
                    K,
                    info_count
                );
            end

            $display("------------------------------------------------------------");
            $display(
                "CASE %0d START, N=%0d K=%0d",
                case_id,
                N,
                K
            );

            // -------------------------------------------------------------
            // 设置N=256及冻结位掩码
            // -------------------------------------------------------------

            @(negedge clk);

            n_log = 4'd8;

            frozen_bits = {NMAX{1'b0}};
            frozen_bits[N-1:0] = FROZEN_N256_K128;

            // Fast-SSC：填充节点类型 ROM
            fast_rom_start = 1'b1;
            @(posedge clk);
            #1;
            fast_rom_start = 1'b0;
            while (!fast_rom_done) begin
                @(posedge clk);
            end

            llr_in       = {LLR_W{1'b0}};
            llr_in_valid = 1'b0;
            u_ready      = 1'b0;

            load_start = 1'b1;

            @(posedge clk);
            #1;

            check_count = check_count + 2;

            if (load_busy !== 1'b1) begin
                error_count = error_count + 1;
                $display(
                    "ERROR CASE%0d: load_busy did not assert",
                    case_id
                );
            end

            if (llr_in_ready !== 1'b1) begin
                error_count = error_count + 1;
                $display(
                    "ERROR CASE%0d: llr_in_ready did not assert",
                    case_id
                );
            end

            @(negedge clk);

            load_start = 1'b0;

            // -------------------------------------------------------------
            // 输入256个信道LLR
            // -------------------------------------------------------------

            for (input_index = 0;
                 input_index < N;
                 input_index = input_index + 1) begin

                // 多个位置插入valid暂停
                if ((input_index == 63)  ||
                    (input_index == 129) ||
                    (input_index == 200)) begin

                    llr_in_valid = 1'b0;
                    llr_in       = {LLR_W{1'b0}};

                    @(posedge clk);
                    #1;

                    check_count = check_count + 2;

                    if (load_busy !== 1'b1) begin
                        error_count = error_count + 1;
                        $display(
                            "ERROR CASE%0d: load_busy dropped during pause",
                            case_id
                        );
                    end

                    if (load_done !== 1'b0) begin
                        error_count = error_count + 1;
                        $display(
                            "ERROR CASE%0d: load_done asserted during pause",
                            case_id
                        );
                    end

                    @(negedge clk);
                end

                while (llr_in_ready !== 1'b1) begin
                    @(negedge clk);
                end

                if (encoded_d[input_index]) begin
                    llr_in = -8'sd40;
                end
                else begin
                    llr_in = 8'sd40;
                end

                llr_in_valid = 1'b1;

                @(posedge clk);
                #1;

                check_count = check_count + 2;

                if (input_index < N-1) begin
                    if (load_busy !== 1'b1) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: load_busy dropped at input %0d",
                            case_id,
                            input_index
                        );
                    end

                    if (load_done !== 1'b0) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: load_done early at input %0d",
                            case_id,
                            input_index
                        );
                    end
                end
                else begin
                    if (load_busy !== 1'b0) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: load_busy did not clear",
                            case_id
                        );
                    end

                    if (load_done !== 1'b1) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: load_done missing",
                            case_id
                        );
                    end
                end

                if (input_index < N-1) begin
                    @(negedge clk);
                end
            end

            // -------------------------------------------------------------
            // 检查根LLR地址0～255
            // -------------------------------------------------------------

            for (i = 0; i < N; i = i + 1) begin
                if (encoded_d[i]) begin
                    expected_llr = -10'sd40;
                end
                else begin
                    expected_llr = 10'sd40;
                end

                check_count = check_count + 1;

                if (u_datapath.u_sc_llr_mem.llr_mem[i]
                    !== expected_llr) begin

                    error_count = error_count + 1;

                    $display(
                        "ERROR CASE%0d: root LLR[%0d] expected=%0d actual=%0d",
                        case_id,
                        i,
                        $signed(expected_llr),
                        $signed(
                            u_datapath.u_sc_llr_mem.llr_mem[i]
                        )
                    );
                end
            end

            // -------------------------------------------------------------
            // load_done自动启动controller
            // -------------------------------------------------------------

            @(negedge clk);

            llr_in_valid = 1'b0;
            llr_in       = {LLR_W{1'b0}};

            start_wait = 0;

            while ((decode_busy !== 1'b1) &&
                   (start_wait < 10)) begin

                @(posedge clk);
                #1;

                start_wait = start_wait + 1;
            end

            check_count = check_count + 1;

            if (decode_busy !== 1'b1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: controller did not start",
                    case_id
                );
            end

            // -------------------------------------------------------------
            // 等待译码并检查u_hat输出
            // -------------------------------------------------------------

            output_count      = 0;
            timeout_count     = 0;
            monitor_cycle     = 0;
            output_done_count = 0;
            decode_done_count = 0;
            last_pause_done   = 0;

            while ((decode_done !== 1'b1) &&
                   (timeout_count < TIMEOUT_CYCLES)) begin

                @(negedge clk);

                if (u_valid &&
                    (u_index == N-1) &&
                    !last_pause_done) begin

                    u_ready         = 1'b0;
                    last_pause_done = 1;
                end
                else if (((monitor_cycle % 11) == 3) ||
                         ((monitor_cycle % 17) == 7)) begin

                    u_ready = 1'b0;
                end
                else begin
                    u_ready = 1'b1;
                end

                #1;

                fire   = 1'b0;
                stalled = 1'b0;

                if (u_valid) begin
                    check_count = check_count + 3;

                    if (u_index !== output_count) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: u_index expected=%0d actual=%0d",
                            case_id,
                            output_count,
                            u_index
                        );
                    end

                    if (u_bit !== expected_u[output_count]) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: u[%0d] expected=%b actual=%b",
                            case_id,
                            output_count,
                            expected_u[output_count],
                            u_bit
                        );
                    end

                    if (u_last !== (output_count == N-1)) begin
                        error_count = error_count + 1;

                        $display(
                            "ERROR CASE%0d: u_last error at index=%0d",
                            case_id,
                            output_count
                        );
                    end

                    if (u_ready) begin
                        fire = 1'b1;
                    end
                    else begin
                        stalled   = 1'b1;
                        hold_bit  = u_bit;
                        hold_index = u_index;
                        hold_last = u_last;
                    end
                end

                @(posedge clk);
                #1;

                if (stalled) begin
                    check_count = check_count + 1;

                    if (!u_valid ||
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

                if (output_done) begin
                    output_done_count = output_done_count + 1;
                end

                if (decode_done) begin
                    decode_done_count = decode_done_count + 1;
                end

                monitor_cycle = monitor_cycle + 1;
                timeout_count = timeout_count + 1;
            end

            check_count = check_count + 4;

            if (timeout_count >= TIMEOUT_CYCLES) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: timeout, output_count=%0d",
                    case_id,
                    output_count
                );
            end

            if (output_count != N) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: output count expected=%0d actual=%0d",
                    case_id,
                    N,
                    output_count
                );
            end

            if (output_done_count != 1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: output_done count=%0d",
                    case_id,
                    output_done_count
                );
            end

            if (decode_done_count != 1) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: decode_done count=%0d",
                    case_id,
                    decode_done_count
                );
            end

            // -------------------------------------------------------------
            // 检查uhat_mem和根beta
            // -------------------------------------------------------------

            for (i = 0; i < N; i = i + 1) begin
                check_count = check_count + 2;

                if (u_datapath.u_sc_uhat_mem.uhat_mem[i]
                    !== expected_u[i]) begin

                    error_count = error_count + 1;

                    $display(
                        "ERROR CASE%0d: uhat_mem[%0d] expected=%b actual=%b",
                        case_id,
                        i,
                        expected_u[i],
                        u_datapath.u_sc_uhat_mem.uhat_mem[i]
                    );
                end

                if (u_datapath.u_sc_beta_mem.beta_mem[i]
                    !== encoded_d[i]) begin

                    error_count = error_count + 1;

                    $display(
                        "ERROR CASE%0d: root beta[%0d] expected=%b actual=%b",
                        case_id,
                        i,
                        encoded_d[i],
                        u_datapath.u_sc_beta_mem.beta_mem[i]
                    );
                end
            end

            // -------------------------------------------------------------
            // done和busy结束检查
            // -------------------------------------------------------------

            @(posedge clk);
            #1;

            check_count = check_count + 2;

            if (decode_done !== 1'b0) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: decode_done longer than one cycle",
                    case_id
                );
            end

            if (decode_busy !== 1'b0) begin
                error_count = error_count + 1;

                $display(
                    "ERROR CASE%0d: decode_busy did not clear",
                    case_id
                );
            end

            @(negedge clk);

            u_ready = 1'b0;

            $display(
                "CASE %0d COMPLETE, output=%0d, cycles=%0d",
                case_id,
                output_count,
                timeout_count
            );
        end
    endtask

    // =========================================================================
    // 主测试
    // =========================================================================

    reg [N-1:0] test_u1;
    reg [N-1:0] test_u2;
    reg [N-1:0] test_u3;
    reg [N-1:0] test_u4;

    initial begin
        error_count = 0;
        check_count = 0;
        case_count  = 0;

        rst_n = 1'b0;

        load_start   = 1'b0;
        n_log        = 4'd8;
        llr_in       = {LLR_W{1'b0}};
        llr_in_valid = 1'b0;
        fast_rom_start = 1'b0;

        frozen_bits = {NMAX{1'b0}};
        frozen_bits[N-1:0] = FROZEN_N256_K128;

        u_ready = 1'b0;

        #22;

        rst_n = 1'b1;

        @(posedge clk);
        #1;

        check_count = check_count + 7;

        if (load_busy !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset load_busy");
        end

        if (load_done !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset load_done");
        end

        if (llr_in_ready !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset llr_in_ready");
        end

        if (decode_busy !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset decode_busy");
        end

        if (decode_done !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset decode_done");
        end

        if (output_busy !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset output_busy");
        end

        if (u_valid !== 0) begin
            error_count = error_count + 1;
            $display("ERROR reset u_valid");
        end

        build_u(1, test_u1);
        build_u(2, test_u2);
        build_u(3, test_u3);
        build_u(4, test_u4);

        run_case(1, test_u1);
        run_case(2, test_u2);
        run_case(3, test_u3);
        run_case(4, test_u4);

        #20;

        $display("============================================================");
        $display("sc_bc_n256_system_tb completed");
        $display("Total cases  = %0d", case_count);
        $display("Total checks = %0d", check_count);
        $display("Error count  = %0d", error_count);

        if (error_count == 0) begin
            $display("RESULT: sc_bc_n256_system_tb PASS");
        end
        else begin
            $display("RESULT: sc_bc_n256_system_tb FAIL");
        end

        $display("============================================================");

        $finish;
    end

    initial begin
        #10000000;

        $display(
            "RESULT: sc_bc_n256_system_tb GLOBAL TIMEOUT"
        );

        $finish;
    end

endmodule
