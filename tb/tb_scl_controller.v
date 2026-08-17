`timescale 1ns/1ps

// =============================================================================
// tb_scl_controller.v
// =============================================================================
// Independent self-checking testbench for scl_controller.
//
// The testbench uses a small N=4 decode on an NMAX=16 workspace.  It models:
//   * LLR/PE response later than beta response;
//   * registered pruner out_valid;
//   * beta write acceptance;
//   * delayed u_hat output_done.
//
// Leaf configuration:
//   leaf0: Polar frozen       -> fixed zero
//   leaf1: first non-frozen   -> known zero
//   leaf2: non-frozen         -> split/prune
//   leaf3: non-frozen         -> split/prune
// =============================================================================

module tb_scl_controller;

    localparam integer NMAX      = 16;
    localparam integer MAX_LOG   = 4;
    localparam integer LIST_SIZE = 4;
    localparam integer PATH_W    = 2;
    localparam integer DEPTH_W   = 3;
    localparam integer MEM_DEPTH = 31;
    localparam integer ADDR_W    = 5;
    localparam integer INDEX_W   = 5;

    reg clk;
    reg rst_n;

    reg                       decode_start;
    reg [3:0]                 n_log;
    reg [NMAX-1:0]            frozen_bits;
    reg [INDEX_W-1:0]         known_zero_count_cfg;

    wire                      decode_busy;
    wire                      decode_done;
    wire                      decode_error;
    wire                      path_init;

    wire                      llr_rd_req;
    wire [DEPTH_W-1:0]        llr_rd_depth;
    wire [ADDR_W-1:0]         llr_rd_addr_a;
    wire [ADDR_W-1:0]         llr_rd_addr_b;
    wire                      pe_mode_g;

    wire                      llr_rd_valid;
    wire                      pe_result_valid;

    wire                      llr_wr_en;
    wire [DEPTH_W-1:0]        llr_wr_depth;
    wire [ADDR_W-1:0]         llr_wr_addr;
    reg                       llr_write_conflict;

    wire                      beta_rd_req;
    wire [ADDR_W-1:0]         beta_rd_addr_a;
    wire [ADDR_W-1:0]         beta_rd_addr_b;
    wire                      beta_rd_valid;

    wire                      beta_wr_en;
    wire [ADDR_W-1:0]         beta_wr_addr;
    wire [LIST_SIZE-1:0]      beta_wr_direct_bus;
    wire [1:0]                beta_wr_mode;
    wire                      beta_wr_commit;
    wire                      beta_write_accepted;

    wire [INDEX_W-1:0]        leaf_index;
    wire [ADDR_W-1:0]         leaf_beta_addr;
    wire                      leaf_eval_valid;
    wire                      fixed_leaf_commit_en;

    wire                      prune_in_valid;
    reg                       prune_in_ready;
    wire                      prune_out_valid;
    wire                      prune_commit_en;

    reg                       best_valid;
    reg [PATH_W-1:0]          best_path;

    wire                      output_start;
    wire [PATH_W-1:0]         output_path;
    wire                      output_done;

    integer errors;
    integer checks;
    integer cycle_count;

    integer path_init_count;
    integer llr_req_count;
    integer llr_wr_count;
    integer beta_req_count;
    integer beta_wr_count;
    integer beta_commit_count;
    integer fixed_count;
    integer prune_in_count;
    integer prune_commit_count;
    integer output_start_count;
    integer decode_done_count;

    integer exp_llr_req_depth [0:11];
    integer exp_llr_req_a     [0:11];
    integer exp_llr_req_b     [0:11];
    integer exp_llr_req_g     [0:11];

    integer exp_llr_wr_depth  [0:7];
    integer exp_llr_wr_addr   [0:7];

    integer exp_beta_req_a    [0:11];
    integer exp_beta_req_b    [0:11];

    integer exp_beta_wr_addr  [0:11];
    integer exp_beta_wr_mode  [0:11];
    integer exp_beta_wr_commit[0:11];

    reg llr_pipe_q1;
    reg llr_pipe_q2;
    reg beta_pipe_q;
    reg prune_pipe_q;
    reg [2:0] output_count_q;

    // Diagnostic state-stall tracker. These are testbench-only hierarchical
    // observations and do not change the controller interface or behavior.
    reg [3:0] last_dut_state;
    integer   same_state_cycles;
    integer   total_debug_cycles;

    assign llr_rd_valid    = llr_pipe_q2; // local datapath timing model; not a controller port
    assign pe_result_valid = llr_pipe_q2;
    assign leaf_eval_valid = llr_pipe_q2;

    assign beta_rd_valid = beta_pipe_q;

    assign beta_write_accepted =
        beta_wr_en &&
        ((beta_wr_mode == 2'b00) || beta_rd_valid);

    assign prune_out_valid = prune_pipe_q;
    assign output_done     = (output_count_q == 3'd1);

    scl_controller #(
        .NMAX      (NMAX),
        .MAX_LOG   (MAX_LOG),
        .LIST_SIZE (LIST_SIZE),
        .PATH_W    (PATH_W),
        .DEPTH_W   (DEPTH_W),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    ) dut (
        .clk                    (clk),
        .rst_n                  (rst_n),

        .decode_start           (decode_start),
        .n_log                  (n_log),
        .frozen_bits            (frozen_bits),
        .known_zero_count_cfg   (known_zero_count_cfg),
        .decode_busy            (decode_busy),
        .decode_done            (decode_done),
        .decode_error           (decode_error),
        .path_init              (path_init),

        .llr_rd_req             (llr_rd_req),
        .llr_rd_depth           (llr_rd_depth),
        .llr_rd_addr_a          (llr_rd_addr_a),
        .llr_rd_addr_b          (llr_rd_addr_b),
        .pe_mode_g              (pe_mode_g),
        .pe_result_valid        (pe_result_valid),
        .llr_wr_en              (llr_wr_en),
        .llr_wr_depth           (llr_wr_depth),
        .llr_wr_addr            (llr_wr_addr),
        .llr_write_conflict     (llr_write_conflict),

        .beta_rd_req            (beta_rd_req),
        .beta_rd_addr_a         (beta_rd_addr_a),
        .beta_rd_addr_b         (beta_rd_addr_b),
        .beta_rd_valid          (beta_rd_valid),
        .beta_wr_en             (beta_wr_en),
        .beta_wr_addr           (beta_wr_addr),
        .beta_wr_direct_bus     (beta_wr_direct_bus),
        .beta_wr_mode           (beta_wr_mode),
        .beta_wr_commit         (beta_wr_commit),
        .beta_write_accepted    (beta_write_accepted),

        .leaf_index             (leaf_index),
        .leaf_beta_addr         (leaf_beta_addr),
        .leaf_eval_valid        (leaf_eval_valid),
        .fixed_leaf_commit_en   (fixed_leaf_commit_en),

        .prune_in_valid         (prune_in_valid),
        .prune_in_ready         (prune_in_ready),
        .prune_out_valid        (prune_out_valid),
        .prune_commit_en        (prune_commit_en),

        .best_valid             (best_valid),
        .best_path              (best_path),
        .output_start           (output_start),
        .output_path            (output_path),
        .output_done            (output_done)
    );

    always #5 clk = ~clk;

    task check_true;
        input condition;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (condition)
                $display("PASS: %0s", message);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s time=%0t", message, $time);
            end
        end
    endtask

    task check_equal_int;
        input integer got;
        input integer expected;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (got == expected)
                $display("PASS: %0s", message);
            else begin
                errors = errors + 1;
                $display("FAIL: %0s got=%0d expected=%0d time=%0t",
                         message, got, expected, $time);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Response models
    // -------------------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            llr_pipe_q1 <= 1'b0;
            llr_pipe_q2 <= 1'b0;
            beta_pipe_q <= 1'b0;
            prune_pipe_q <= 1'b0;
            output_count_q <= 3'd0;
        end
        else begin
            llr_pipe_q1 <= llr_rd_req;
            llr_pipe_q2 <= llr_pipe_q1;
            beta_pipe_q <= beta_rd_req;
            prune_pipe_q <= prune_in_valid;

            if (output_start)
                output_count_q <= 3'd3;
            else if (output_count_q != 0)
                output_count_q <= output_count_q - 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Interface scoreboard
    // -------------------------------------------------------------------------

    always @(posedge clk) begin
        if (rst_n) begin
            cycle_count = cycle_count + 1;

            if (path_init)
                path_init_count = path_init_count + 1;

            if (llr_rd_req) begin
                if (llr_req_count < 12) begin
                    check_equal_int(llr_rd_depth,
                                    exp_llr_req_depth[llr_req_count],
                                    "LLR request depth follows DFS schedule");
                    check_equal_int(llr_rd_addr_a,
                                    exp_llr_req_a[llr_req_count],
                                    "LLR request operand A address is correct");
                    check_equal_int(llr_rd_addr_b,
                                    exp_llr_req_b[llr_req_count],
                                    "LLR request operand B address is correct");
                    check_equal_int(pe_mode_g,
                                    exp_llr_req_g[llr_req_count],
                                    "LLR request f/g mode is correct");
                end
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra LLR request time=%0t", $time);
                end

                llr_req_count = llr_req_count + 1;
            end

            if (llr_wr_en) begin
                check_true(pe_result_valid,
                           "LLR write occurs only with pe_result_valid");

                if (llr_wr_count < 8) begin
                    check_equal_int(llr_wr_depth,
                                    exp_llr_wr_depth[llr_wr_count],
                                    "LLR write depth is correct");
                    check_equal_int(llr_wr_addr,
                                    exp_llr_wr_addr[llr_wr_count],
                                    "LLR write address is correct");
                end
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra LLR write time=%0t", $time);
                end

                llr_wr_count = llr_wr_count + 1;
            end

            if (beta_rd_req) begin
                if (beta_req_count < 12) begin
                    check_equal_int(beta_rd_addr_a,
                                    exp_beta_req_a[beta_req_count],
                                    "beta request address A is correct");
                    check_equal_int(beta_rd_addr_b,
                                    exp_beta_req_b[beta_req_count],
                                    "beta request address B is correct");
                end
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra beta request time=%0t", $time);
                end

                beta_req_count = beta_req_count + 1;
            end

            if (beta_wr_en) begin
                check_true(beta_rd_valid,
                           "non-direct beta write waits for beta_rd_valid");
                check_true(beta_write_accepted,
                           "beta write is accepted by datapath contract");

                if (beta_wr_count < 12) begin
                    check_equal_int(beta_wr_addr,
                                    exp_beta_wr_addr[beta_wr_count],
                                    "beta write address is correct");
                    check_equal_int(beta_wr_mode,
                                    exp_beta_wr_mode[beta_wr_count],
                                    "beta write source mode is correct");
                    check_equal_int(beta_wr_commit,
                                    exp_beta_wr_commit[beta_wr_count],
                                    "beta mapping commit occurs on correct write");
                end
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra beta write time=%0t", $time);
                end

                if (beta_wr_commit)
                    beta_commit_count = beta_commit_count + 1;

                beta_wr_count = beta_wr_count + 1;
            end

            if (fixed_leaf_commit_en) begin
                check_true(leaf_eval_valid,
                           "fixed leaf commit is aligned with leaf_eval_valid");

                if (fixed_count == 0)
                    check_equal_int(leaf_index, 0,
                                    "leaf0 is committed as Polar frozen zero");
                else if (fixed_count == 1)
                    check_equal_int(leaf_index, 1,
                                    "leaf1 is committed as known non-frozen zero");
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra fixed leaf time=%0t", $time);
                end

                check_equal_int(leaf_beta_addr, 24,
                                "leaf beta workspace address is depth_base(2)");
                fixed_count = fixed_count + 1;
            end

            if (prune_in_valid) begin
                check_true(leaf_eval_valid,
                           "pruner input is aligned with leaf_eval_valid");
                check_true(prune_in_ready,
                           "pruner accepts candidate without backpressure");

                if (prune_in_count == 0)
                    check_equal_int(leaf_index, 2,
                                    "leaf2 is the first split leaf");
                else if (prune_in_count == 1)
                    check_equal_int(leaf_index, 3,
                                    "leaf3 is the second split leaf");
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra prune input time=%0t", $time);
                end

                prune_in_count = prune_in_count + 1;
            end

            if (prune_commit_en) begin
                check_true(prune_out_valid,
                           "prune commit is aligned with registered out_valid");

                if (prune_commit_count == 0)
                    check_equal_int(leaf_index, 2,
                                    "leaf2 survivor commit retains leaf index");
                else if (prune_commit_count == 1)
                    check_equal_int(leaf_index, 3,
                                    "leaf3 survivor commit retains leaf index");
                else begin
                    errors = errors + 1;
                    $display("FAIL: unexpected extra prune commit time=%0t", $time);
                end

                prune_commit_count = prune_commit_count + 1;
            end

            if (output_start) begin
                output_start_count = output_start_count + 1;
                check_equal_int(output_path, 2,
                                "output_start uses the datapath best path");
            end

            if (decode_done)
                decode_done_count = decode_done_count + 1;
        end
    end


    // -------------------------------------------------------------------------
    // Controller progress diagnostics
    // -------------------------------------------------------------------------
    //
    // State encoding:
    //   0 IDLE, 1 INIT, 2 DISPATCH, 3 F_REQ, 4 F_WAIT,
    //   5 G_REQ, 6 G_WAIT, 7 LEAF_REQ, 8 LEAF_WAIT,
    //   9 PRUNE_WAIT, 10 C_LOW_REQ, 11 C_LOW_WAIT,
    //   12 C_HIGH_REQ, 13 C_HIGH_WAIT,
    //   14 OUTPUT_START, 15 OUTPUT_WAIT.
    //
    // A legal request/wait state should normally complete in only a few cycles
    // with the response models in this TB. Staying in one state for more than
    // 12 cycles therefore identifies the missing handshake directly.
    always @(posedge clk) begin
        if (!rst_n) begin
            last_dut_state  = 4'hf;
            same_state_cycles = 0;
            total_debug_cycles = 0;
        end
        else begin
            total_debug_cycles = total_debug_cycles + 1;

            if (dut.state !== last_dut_state) begin
                $display(
                    "TRACE: t=%0t state=%0d depth=%0d elem=%0d leaf=%0d llr_req=%b pe_valid=%b beta_req=%b beta_valid=%b beta_wr=%b beta_accept=%b prune_in=%b prune_out=%b output_start=%b output_done=%b",
                    $time, dut.state, dut.cur_depth, dut.element_index,
                    dut.current_leaf,
                    llr_rd_req, pe_result_valid,
                    beta_rd_req, beta_rd_valid,
                    beta_wr_en, beta_write_accepted,
                    prune_in_valid, prune_out_valid,
                    output_start, output_done
                );
                last_dut_state = dut.state;
                same_state_cycles = 0;
            end
            else begin
                same_state_cycles = same_state_cycles + 1;
            end

            if ((dut.state != 4'd0) && (same_state_cycles > 12)) begin
                $display("FAIL: controller stalled");
                $display(
                    "STALL: t=%0t state=%0d depth=%0d elem=%0d leaf=%0d nonfrozen=%0d phase0=%0d phase1=%0d phase2=%0d",
                    $time, dut.state, dut.cur_depth, dut.element_index,
                    dut.current_leaf, dut.nonfrozen_seen,
                    dut.phase[0], dut.phase[1], dut.phase[2]
                );
                $display(
                    "STALL_IO: llr_req=%b pe_valid=%b llr_wr=%b conflict=%b beta_req=%b beta_valid=%b beta_wr=%b beta_accept=%b g_beta_done=%b g_pe_done=%b",
                    llr_rd_req, pe_result_valid, llr_wr_en,
                    llr_write_conflict, beta_rd_req, beta_rd_valid,
                    beta_wr_en, beta_write_accepted,
                    dut.g_beta_done, dut.g_pe_done
                );
                $display(
                    "STALL_LEAF: leaf_eval_valid=%b fixed_commit=%b prune_ready=%b prune_in=%b prune_out=%b prune_commit=%b best_valid=%b output_start=%b output_done=%b",
                    leaf_eval_valid, fixed_leaf_commit_en,
                    prune_in_ready, prune_in_valid, prune_out_valid,
                    prune_commit_en, best_valid, output_start, output_done
                );
                $finish;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Test sequence
    // -------------------------------------------------------------------------

    initial begin
        // Expected LLR request sequence for N=4, NMAX=16.
        exp_llr_req_depth[0]  = 0; exp_llr_req_a[0]  = 0;  exp_llr_req_b[0]  = 2;  exp_llr_req_g[0]  = 0;
        exp_llr_req_depth[1]  = 0; exp_llr_req_a[1]  = 1;  exp_llr_req_b[1]  = 3;  exp_llr_req_g[1]  = 0;
        exp_llr_req_depth[2]  = 1; exp_llr_req_a[2]  = 16; exp_llr_req_b[2]  = 17; exp_llr_req_g[2]  = 0;
        exp_llr_req_depth[3]  = 2; exp_llr_req_a[3]  = 24; exp_llr_req_b[3]  = 24; exp_llr_req_g[3]  = 0;
        exp_llr_req_depth[4]  = 1; exp_llr_req_a[4]  = 16; exp_llr_req_b[4]  = 17; exp_llr_req_g[4]  = 1;
        exp_llr_req_depth[5]  = 2; exp_llr_req_a[5]  = 24; exp_llr_req_b[5]  = 24; exp_llr_req_g[5]  = 0;
        exp_llr_req_depth[6]  = 0; exp_llr_req_a[6]  = 0;  exp_llr_req_b[6]  = 2;  exp_llr_req_g[6]  = 1;
        exp_llr_req_depth[7]  = 0; exp_llr_req_a[7]  = 1;  exp_llr_req_b[7]  = 3;  exp_llr_req_g[7]  = 1;
        exp_llr_req_depth[8]  = 1; exp_llr_req_a[8]  = 16; exp_llr_req_b[8]  = 17; exp_llr_req_g[8]  = 0;
        exp_llr_req_depth[9]  = 2; exp_llr_req_a[9]  = 24; exp_llr_req_b[9]  = 24; exp_llr_req_g[9]  = 0;
        exp_llr_req_depth[10] = 1; exp_llr_req_a[10] = 16; exp_llr_req_b[10] = 17; exp_llr_req_g[10] = 1;
        exp_llr_req_depth[11] = 2; exp_llr_req_a[11] = 24; exp_llr_req_b[11] = 24; exp_llr_req_g[11] = 0;

        exp_llr_wr_depth[0] = 1; exp_llr_wr_addr[0] = 16;
        exp_llr_wr_depth[1] = 1; exp_llr_wr_addr[1] = 17;
        exp_llr_wr_depth[2] = 2; exp_llr_wr_addr[2] = 24;
        exp_llr_wr_depth[3] = 2; exp_llr_wr_addr[3] = 24;
        exp_llr_wr_depth[4] = 1; exp_llr_wr_addr[4] = 16;
        exp_llr_wr_depth[5] = 1; exp_llr_wr_addr[5] = 17;
        exp_llr_wr_depth[6] = 2; exp_llr_wr_addr[6] = 24;
        exp_llr_wr_depth[7] = 2; exp_llr_wr_addr[7] = 24;

        exp_beta_req_a[0]  = 24; exp_beta_req_b[0]  = 24;
        exp_beta_req_a[1]  = 16; exp_beta_req_b[1]  = 24;
        exp_beta_req_a[2]  = 24; exp_beta_req_b[2]  = 24;
        exp_beta_req_a[3]  = 16; exp_beta_req_b[3]  = 16;
        exp_beta_req_a[4]  = 17; exp_beta_req_b[4]  = 17;
        exp_beta_req_a[5]  = 24; exp_beta_req_b[5]  = 24;
        exp_beta_req_a[6]  = 16; exp_beta_req_b[6]  = 24;
        exp_beta_req_a[7]  = 24; exp_beta_req_b[7]  = 24;
        exp_beta_req_a[8]  = 0;  exp_beta_req_b[8]  = 16;
        exp_beta_req_a[9]  = 16; exp_beta_req_b[9]  = 16;
        exp_beta_req_a[10] = 1;  exp_beta_req_b[10] = 17;
        exp_beta_req_a[11] = 17; exp_beta_req_b[11] = 17;

        exp_beta_wr_addr[0]   = 16; exp_beta_wr_mode[0]   = 2; exp_beta_wr_commit[0]   = 1;
        exp_beta_wr_addr[1]   = 16; exp_beta_wr_mode[1]   = 1; exp_beta_wr_commit[1]   = 0;
        exp_beta_wr_addr[2]   = 17; exp_beta_wr_mode[2]   = 3; exp_beta_wr_commit[2]   = 1;
        exp_beta_wr_addr[3]   = 0;  exp_beta_wr_mode[3]   = 2; exp_beta_wr_commit[3]   = 0;
        exp_beta_wr_addr[4]   = 1;  exp_beta_wr_mode[4]   = 2; exp_beta_wr_commit[4]   = 1;
        exp_beta_wr_addr[5]   = 16; exp_beta_wr_mode[5]   = 2; exp_beta_wr_commit[5]   = 1;
        exp_beta_wr_addr[6]   = 16; exp_beta_wr_mode[6]   = 1; exp_beta_wr_commit[6]   = 0;
        exp_beta_wr_addr[7]   = 17; exp_beta_wr_mode[7]   = 3; exp_beta_wr_commit[7]   = 1;
        exp_beta_wr_addr[8]   = 0;  exp_beta_wr_mode[8]   = 1; exp_beta_wr_commit[8]   = 0;
        exp_beta_wr_addr[9]   = 2;  exp_beta_wr_mode[9]   = 3; exp_beta_wr_commit[9]   = 0;
        exp_beta_wr_addr[10]  = 1;  exp_beta_wr_mode[10]  = 1; exp_beta_wr_commit[10]  = 0;
        exp_beta_wr_addr[11]  = 3;  exp_beta_wr_mode[11]  = 3; exp_beta_wr_commit[11]  = 1;

        clk = 1'b0;
        rst_n = 1'b0;
        decode_start = 1'b0;
        n_log = 4'd2;
        frozen_bits = {NMAX{1'b1}};
        frozen_bits[1] = 1'b0;
        frozen_bits[2] = 1'b0;
        frozen_bits[3] = 1'b0;
        known_zero_count_cfg = 1;

        llr_write_conflict = 1'b0;
        prune_in_ready = 1'b1;
        best_valid = 1'b1;
        best_path = 2;

        errors = 0;
        checks = 0;
        cycle_count = 0;
        path_init_count = 0;
        llr_req_count = 0;
        llr_wr_count = 0;
        beta_req_count = 0;
        beta_wr_count = 0;
        beta_commit_count = 0;
        fixed_count = 0;
        prune_in_count = 0;
        prune_commit_count = 0;
        output_start_count = 0;
        decode_done_count = 0;
        last_dut_state = 4'hf;
        same_state_cycles = 0;
        total_debug_cycles = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        @(negedge clk);
        decode_start = 1'b1;
        @(negedge clk);
        decode_start = 1'b0;

        wait (decode_done == 1'b1);
        @(posedge clk);
        #1;

        check_equal_int(path_init_count, 1,
                        "path_init is a single-cycle pulse");
        check_equal_int(llr_req_count, 12,
                        "N=4 DFS issues twelve LLR/leaf requests");
        check_equal_int(llr_wr_count, 8,
                        "N=4 DFS writes eight F/G results");
        check_equal_int(beta_req_count, 12,
                        "N=4 DFS issues twelve beta requests");
        check_equal_int(beta_wr_count, 12,
                        "N=4 DFS performs twelve beta writes");
        check_equal_int(beta_commit_count, 6,
                        "each internal node commits after PH_G and PH_C");
        check_equal_int(fixed_count, 2,
                        "one frozen and one known-zero leaf are fixed");
        check_equal_int(prune_in_count, 2,
                        "two information leaves are sent to pruner");
        check_equal_int(prune_commit_count, 2,
                        "two registered pruner results are committed");
        check_equal_int(output_start_count, 1,
                        "natural-order output starts once");
        check_equal_int(decode_done_count, 1,
                        "decode_done is a one-cycle completion pulse");
        check_true(!decode_busy,
                   "controller returns to idle after output_done");
        check_true(!decode_error,
                   "valid decode completes without controller error");

        // Invalid n_log must be rejected without starting a decode.
        n_log = 4'd0;
        @(negedge clk);
        decode_start = 1'b1;
        @(negedge clk);
        decode_start = 1'b0;
        @(negedge clk);

        check_true(decode_error,
                   "invalid n_log is reported");
        check_true(!decode_busy,
                   "invalid n_log does not enter decode_busy");
        check_equal_int(path_init_count, 1,
                        "invalid start does not generate another path_init");

        if (errors == 0)
            $display("PASS: tb_scl_controller completed %0d checks.", checks);
        else
            $display("FAIL: tb_scl_controller errors=%0d checks=%0d.",
                     errors, checks);

        $finish;
    end

    initial begin
        #5000;
        $display("FAIL: tb_scl_controller timeout at time=%0t", $time);
        $display(
            "TIMEOUT: state=%0d depth=%0d elem=%0d leaf=%0d phase0=%0d phase1=%0d phase2=%0d",
            dut.state, dut.cur_depth, dut.element_index, dut.current_leaf,
            dut.phase[0], dut.phase[1], dut.phase[2]
        );
        $display(
            "TIMEOUT_IO: llr_req=%b pe_valid=%b beta_req=%b beta_valid=%b beta_wr=%b beta_accept=%b prune_in=%b prune_out=%b output_start=%b output_done=%b",
            llr_rd_req, pe_result_valid, beta_rd_req, beta_rd_valid,
            beta_wr_en, beta_write_accepted, prune_in_valid,
            prune_out_valid, output_start, output_done
        );
        $finish;
    end

endmodule
