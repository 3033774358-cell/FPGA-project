`timescale 1ns/1ps

// =============================================================================
// tb_scl_decoder_core_full.v
// =============================================================================
// Full regression test for the validated single-Polar-subblock SCL core.
//
// v2 fix:
// block_done/decode_done is a one-cycle registered pulse. The wait loops sample
// it at #1 after each positive edge so the nonblocking assignment has settled.
// This prevents the old TB from missing the pulse and running to guard timeout.
//
// No RTL algorithm is changed in this stage.
//
// DUT A: LIST_SIZE=4 SCL core.
// DUT B: LIST_SIZE=1 SC-equivalent core, used only for the deterministic
//        "SC fails but SCL succeeds" comparison.
//
// Golden-data chain:
//   message pattern
//   -> natural non-frozen placement in u[0]..u[N-1]
//   -> project butterfly without extra bit reversal
//   -> d[0]..d[N-1]
//   -> signed channel LLR stream
//   -> decoded natural-order u_hat comparison
//
// Covered cases:
//   1. N=64, K=8, known_zero=2, all-zero payload, strong LLR.
//   2. N=64, K=8, known_zero=2, all-one payload, strong LLR.
//   3. N=64, K=8, known_zero=2, alternating payload, output backpressure.
//   4. N=64, K=8, known_zero=2, fixed pseudo-random payload.
//   5. N=64, K=8, known_zero=2, weak but sign-correct LLR.
//   6. N=128, K=16, known_zero=3 reconfiguration smoke test.
//   7. N=64, K=8, known_zero=0 deterministic noisy vector:
//        LIST_SIZE=1 gives a wrong u_hat, LIST_SIZE=4 recovers u_ref.
// =============================================================================

module tb_scl_decoder_core_full;

    localparam integer NMAX      = 1024;
    localparam integer LLR_W     = 8;
    localparam integer INT_W     = 10;
    localparam integer MAX_LOG   = 10;
    localparam integer PM_W      = 24;
    localparam integer INDEX_W   = $clog2(NMAX) + 1;

    localparam integer SCL_L     = 4;
    localparam integer SCL_PATH_W =
        (SCL_L <= 1) ? 1 : $clog2(SCL_L);

    localparam integer SC_L      = 1;
    localparam integer SC_PATH_W = 1;

    reg clk;
    reg rst_n;

    // =========================================================================
    // LIST_SIZE=4 SCL core signals
    // =========================================================================

    reg                                  scl_config_start;
    reg [3:0]                            scl_n_log_cfg;
    reg [10:0]                           scl_k_cfg;
    reg [INDEX_W-1:0]                    scl_known_zero_cfg;

    wire                                 scl_config_ready;
    wire                                 scl_config_busy;
    wire                                 scl_config_done;
    wire                                 scl_config_error;

    reg                                  scl_block_start;
    wire                                 scl_block_ready;
    wire                                 scl_block_busy;
    wire                                 scl_block_done;
    wire                                 scl_block_error;

    reg signed [LLR_W-1:0]               scl_llr_in;
    reg                                  scl_llr_in_valid;
    wire                                 scl_llr_in_ready;

    wire                                 scl_u_valid;
    reg                                  scl_u_ready;
    wire                                 scl_u_bit;
    wire [INDEX_W-1:0]                   scl_u_index;
    wire                                 scl_u_last;

    wire [SCL_L-1:0]                     scl_path_active_bus;
    wire [SCL_L*PM_W-1:0]                scl_path_pm_bus;
    wire                                 scl_best_valid;
    wire [SCL_PATH_W-1:0]                scl_best_path;
    wire [PM_W-1:0]                      scl_best_pm;

    // =========================================================================
    // LIST_SIZE=1 SC-equivalent core signals
    // =========================================================================

    reg                                  sc_config_start;
    reg [3:0]                            sc_n_log_cfg;
    reg [10:0]                           sc_k_cfg;
    reg [INDEX_W-1:0]                    sc_known_zero_cfg;

    wire                                 sc_config_ready;
    wire                                 sc_config_busy;
    wire                                 sc_config_done;
    wire                                 sc_config_error;

    reg                                  sc_block_start;
    wire                                 sc_block_ready;
    wire                                 sc_block_busy;
    wire                                 sc_block_done;
    wire                                 sc_block_error;

    reg signed [LLR_W-1:0]               sc_llr_in;
    reg                                  sc_llr_in_valid;
    wire                                 sc_llr_in_ready;

    wire                                 sc_u_valid;
    reg                                  sc_u_ready;
    wire                                 sc_u_bit;
    wire [INDEX_W-1:0]                   sc_u_index;
    wire                                 sc_u_last;

    wire [SC_L-1:0]                      sc_path_active_bus;
    wire [SC_L*PM_W-1:0]                 sc_path_pm_bus;
    wire                                 sc_best_valid;
    wire [SC_PATH_W-1:0]                 sc_best_path;
    wire [PM_W-1:0]                      sc_best_pm;

    // =========================================================================
    // Golden vectors and scoreboard state
    // =========================================================================

    reg u_ref   [0:NMAX-1];
    reg d_ref   [0:NMAX-1];
    reg signed [LLR_W-1:0] llr_vec [0:NMAX-1];

    integer active_n;
    integer active_n_log;
    integer active_k;
    integer active_known;

    integer errors;
    integer checks;

    integer scl_out_count;
    integer scl_mismatch_count;
    integer scl_last_count;
    integer scl_ready_cycle;
    integer scl_backpressure_enable;
    integer scl_score_enable;

    integer sc_out_count;
    integer sc_mismatch_count;
    integer sc_last_count;
    integer sc_score_enable;

    integer i;

    // =========================================================================
    // DUT instances
    // =========================================================================

    scl_decoder_core #(
        .NMAX                    (NMAX),
        .LLR_W                   (LLR_W),
        .INT_W                   (INT_W),
        .MAX_LOG                 (MAX_LOG),
        .LIST_SIZE               (SCL_L),
        .PM_W                    (PM_W),
        .REGISTER_LLR_READ_OUTPUT(1),
        .REGISTER_PRUNER_OUTPUT  (1)
    ) dut_scl (
        .clk                  (clk),
        .rst_n                (rst_n),

        .config_start         (scl_config_start),
        .n_log_cfg            (scl_n_log_cfg),
        .k_cfg                (scl_k_cfg),
        .known_zero_count_cfg (scl_known_zero_cfg),
        .config_ready         (scl_config_ready),
        .config_busy          (scl_config_busy),
        .config_done          (scl_config_done),
        .config_error         (scl_config_error),

        .block_start          (scl_block_start),
        .block_ready          (scl_block_ready),
        .block_busy           (scl_block_busy),
        .block_done           (scl_block_done),
        .block_error          (scl_block_error),

        .llr_in               (scl_llr_in),
        .llr_in_valid         (scl_llr_in_valid),
        .llr_in_ready         (scl_llr_in_ready),

        .u_valid              (scl_u_valid),
        .u_ready              (scl_u_ready),
        .u_bit                (scl_u_bit),
        .u_index              (scl_u_index),
        .u_last               (scl_u_last),

        .path_active_bus      (scl_path_active_bus),
        .path_pm_bus          (scl_path_pm_bus),
        .best_valid           (scl_best_valid),
        .best_path            (scl_best_path),
        .best_pm              (scl_best_pm)
    );

    scl_decoder_core #(
        .NMAX                    (NMAX),
        .LLR_W                   (LLR_W),
        .INT_W                   (INT_W),
        .MAX_LOG                 (MAX_LOG),
        .LIST_SIZE               (SC_L),
        .PM_W                    (PM_W),
        .REGISTER_LLR_READ_OUTPUT(1),
        .REGISTER_PRUNER_OUTPUT  (1)
    ) dut_sc (
        .clk                  (clk),
        .rst_n                (rst_n),

        .config_start         (sc_config_start),
        .n_log_cfg            (sc_n_log_cfg),
        .k_cfg                (sc_k_cfg),
        .known_zero_count_cfg (sc_known_zero_cfg),
        .config_ready         (sc_config_ready),
        .config_busy          (sc_config_busy),
        .config_done          (sc_config_done),
        .config_error         (sc_config_error),

        .block_start          (sc_block_start),
        .block_ready          (sc_block_ready),
        .block_busy           (sc_block_busy),
        .block_done           (sc_block_done),
        .block_error          (sc_block_error),

        .llr_in               (sc_llr_in),
        .llr_in_valid         (sc_llr_in_valid),
        .llr_in_ready         (sc_llr_in_ready),

        .u_valid              (sc_u_valid),
        .u_ready              (sc_u_ready),
        .u_bit                (sc_u_bit),
        .u_index              (sc_u_index),
        .u_last               (sc_u_last),

        .path_active_bus      (sc_path_active_bus),
        .path_pm_bus          (sc_path_pm_bus),
        .best_valid           (sc_best_valid),
        .best_path            (sc_best_path),
        .best_pm              (sc_best_pm)
    );

    always #5 clk = ~clk;

    // =========================================================================
    // Generic checker
    // =========================================================================

    task check_true;
        input condition;
        input [8*160-1:0] message;
        begin
            checks = checks + 1;

            if (condition) begin
                $display("PASS: %0s", message);
            end
            else begin
                errors = errors + 1;
                $display("FAIL: %0s time=%0t", message, $time);
            end
        end
    endtask

    // =========================================================================
    // Configuration tasks
    // =========================================================================

    task configure_scl;
        input [3:0] nlog_value;
        input [10:0] k_value;
        input [INDEX_W-1:0] known_value;
        integer guard;
        begin
            guard = 0;
            while (!scl_config_ready && (guard < 5000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check_true(scl_config_ready, "SCL config_ready before configuration");

            @(negedge clk);
            scl_n_log_cfg    = nlog_value;
            scl_k_cfg        = k_value;
            scl_known_zero_cfg = known_value;
            scl_config_start = 1'b1;

            @(negedge clk);
            scl_config_start = 1'b0;

            guard = 0;
            while (!scl_config_done && !scl_config_error &&
                   (guard < 5000)) begin
                @(posedge clk);
                guard = guard + 1;
            end

            check_true(!scl_config_error, "SCL valid configuration has no error");
            check_true(scl_config_done, "SCL configuration completes");
            check_true(scl_block_ready, "SCL block_ready after configuration");
        end
    endtask

    task configure_sc;
        input [3:0] nlog_value;
        input [10:0] k_value;
        input [INDEX_W-1:0] known_value;
        integer guard;
        begin
            guard = 0;
            while (!sc_config_ready && (guard < 5000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check_true(sc_config_ready, "SC config_ready before configuration");

            @(negedge clk);
            sc_n_log_cfg    = nlog_value;
            sc_k_cfg        = k_value;
            sc_known_zero_cfg = known_value;
            sc_config_start = 1'b1;

            @(negedge clk);
            sc_config_start = 1'b0;

            guard = 0;
            while (!sc_config_done && !sc_config_error &&
                   (guard < 5000)) begin
                @(posedge clk);
                guard = guard + 1;
            end

            check_true(!sc_config_error, "SC valid configuration has no error");
            check_true(sc_config_done, "SC configuration completes");
            check_true(sc_block_ready, "SC block_ready after configuration");
        end
    endtask

    // =========================================================================
    // Golden-vector construction
    // =========================================================================

    task clear_vectors;
        integer idx;
        begin
            for (idx = 0; idx < NMAX; idx = idx + 1) begin
                u_ref[idx]   = 1'b0;
                d_ref[idx]   = 1'b0;
                llr_vec[idx] = {LLR_W{1'b0}};
            end
        end
    endtask

    task build_u_pattern;
        input integer pattern_id;
        integer idx;
        integer nonfrozen_seen;
        integer payload_seen;
        reg [15:0] lfsr;
        begin
            nonfrozen_seen = 0;
            payload_seen   = 0;
            lfsr           = 16'hA5C3;

            for (idx = 0; idx < active_n; idx = idx + 1) begin
                u_ref[idx] = 1'b0;

                if (!dut_scl.frozen_mask[idx]) begin
                    if (nonfrozen_seen < active_known) begin
                        u_ref[idx] = 1'b0;
                    end
                    else begin
                        case (pattern_id)
                            0: u_ref[idx] = 1'b0;
                            1: u_ref[idx] = 1'b1;
                            2: u_ref[idx] = payload_seen[0];
                            3: begin
                                u_ref[idx] = lfsr[0];
                                lfsr = {lfsr[0] ^ lfsr[2] ^
                                        lfsr[3] ^ lfsr[5],
                                        lfsr[15:1]};
                            end
                            default: u_ref[idx] = 1'b0;
                        endcase

                        payload_seen = payload_seen + 1;
                    end

                    nonfrozen_seen = nonfrozen_seen + 1;
                end
            end

            check_true(
                nonfrozen_seen == active_k,
                "frozen mask contains exactly configured K positions"
            );
        end
    endtask

    task build_special_sc_fail_u;
        integer idx;
        integer nonfrozen_seen;
        begin
            for (idx = 0; idx < active_n; idx = idx + 1)
                u_ref[idx] = 1'b0;

            // For N=64, K=8 the current reliability ROM selects:
            // 31, 47, 55, 59, 60, 61, 62, 63.
            check_true(!dut_scl.frozen_mask[31], "special vector index31 is non-frozen");
            check_true(!dut_scl.frozen_mask[47], "special vector index47 is non-frozen");
            check_true(!dut_scl.frozen_mask[55], "special vector index55 is non-frozen");
            check_true(!dut_scl.frozen_mask[59], "special vector index59 is non-frozen");
            check_true(!dut_scl.frozen_mask[60], "special vector index60 is non-frozen");
            check_true(!dut_scl.frozen_mask[61], "special vector index61 is non-frozen");
            check_true(!dut_scl.frozen_mask[62], "special vector index62 is non-frozen");
            check_true(!dut_scl.frozen_mask[63], "special vector index63 is non-frozen");

            u_ref[31] = 1'b1;
            u_ref[47] = 1'b1;
            u_ref[55] = 1'b0;
            u_ref[59] = 1'b1;
            u_ref[60] = 1'b1;
            u_ref[61] = 1'b1;
            u_ref[62] = 1'b0;
            u_ref[63] = 1'b1;

            nonfrozen_seen = 0;
            for (idx = 0; idx < active_n; idx = idx + 1)
                if (!dut_scl.frozen_mask[idx])
                    nonfrozen_seen = nonfrozen_seen + 1;

            check_true(
                nonfrozen_seen == 8,
                "special vector uses the expected K=8 frozen set"
            );
        end
    endtask

    task polar_encode_reference;
        integer idx;
        integer stage;
        integer step_value;
        integer span_value;
        integer base_value;
        integer branch;
        begin
            for (idx = 0; idx < active_n; idx = idx + 1)
                d_ref[idx] = u_ref[idx];

            step_value = 1;

            for (stage = 0; stage < active_n_log; stage = stage + 1) begin
                span_value = step_value << 1;

                for (base_value = 0;
                     base_value < active_n;
                     base_value = base_value + span_value) begin
                    for (branch = 0;
                         branch < step_value;
                         branch = branch + 1) begin
                        d_ref[base_value + branch] =
                            d_ref[base_value + branch] ^
                            d_ref[base_value + branch + step_value];
                    end
                end

                step_value = step_value << 1;
            end
        end
    endtask

    task build_strong_llr;
        integer idx;
        begin
            for (idx = 0; idx < active_n; idx = idx + 1)
                llr_vec[idx] =
                    d_ref[idx] ? -8'sd64 : 8'sd64;
        end
    endtask

    task build_weak_correct_llr;
        integer idx;
        integer magnitude;
        begin
            for (idx = 0; idx < active_n; idx = idx + 1) begin
                magnitude = 1 + ((idx * 7 + 3) % 15);

                if (d_ref[idx])
                    llr_vec[idx] = -magnitude;
                else
                    llr_vec[idx] = magnitude;
            end
        end
    endtask

    task build_special_noisy_llr;
        begin
            // Deterministic quantized channel vector. Software reference with
            // the same min-sum, PM and tie rules gives:
            //   LIST_SIZE=1 best PM = 142, wrong bits 55/59/60/61;
            //   LIST_SIZE=4 best PM = 100, exact u_ref recovery.
            llr_vec[0]  =  8'sd15;
            llr_vec[1]  = -8'sd5;
            llr_vec[2]  =  8'sd0;
            llr_vec[3]  =  8'sd0;
            llr_vec[4]  = -8'sd2;
            llr_vec[5]  = -8'sd3;
            llr_vec[6]  = -8'sd17;
            llr_vec[7]  = -8'sd2;
            llr_vec[8]  =  8'sd11;
            llr_vec[9]  = -8'sd8;
            llr_vec[10] =  8'sd3;
            llr_vec[11] = -8'sd1;
            llr_vec[12] = -8'sd20;
            llr_vec[13] =  8'sd6;
            llr_vec[14] = -8'sd18;
            llr_vec[15] = -8'sd15;
            llr_vec[16] = -8'sd17;
            llr_vec[17] = -8'sd12;
            llr_vec[18] = -8'sd18;
            llr_vec[19] = -8'sd2;
            llr_vec[20] =  8'sd2;
            llr_vec[21] =  8'sd5;
            llr_vec[22] = -8'sd1;
            llr_vec[23] =  8'sd4;
            llr_vec[24] = -8'sd4;
            llr_vec[25] =  8'sd23;
            llr_vec[26] = -8'sd18;
            llr_vec[27] =  8'sd13;
            llr_vec[28] =  8'sd22;
            llr_vec[29] = -8'sd5;
            llr_vec[30] =  8'sd11;
            llr_vec[31] =  8'sd20;
            llr_vec[32] =  8'sd2;
            llr_vec[33] = -8'sd4;
            llr_vec[34] =  8'sd1;
            llr_vec[35] = -8'sd11;
            llr_vec[36] =  8'sd4;
            llr_vec[37] =  8'sd0;
            llr_vec[38] =  8'sd8;
            llr_vec[39] = -8'sd2;
            llr_vec[40] = -8'sd3;
            llr_vec[41] =  8'sd20;
            llr_vec[42] =  8'sd9;
            llr_vec[43] =  8'sd22;
            llr_vec[44] =  8'sd23;
            llr_vec[45] = -8'sd7;
            llr_vec[46] =  8'sd23;
            llr_vec[47] =  8'sd11;
            llr_vec[48] =  8'sd21;
            llr_vec[49] = -8'sd3;
            llr_vec[50] =  8'sd18;
            llr_vec[51] =  8'sd19;
            llr_vec[52] =  8'sd3;
            llr_vec[53] = -8'sd11;
            llr_vec[54] =  8'sd3;
            llr_vec[55] = -8'sd1;
            llr_vec[56] = -8'sd8;
            llr_vec[57] = -8'sd14;
            llr_vec[58] =  8'sd1;
            llr_vec[59] =  8'sd3;
            llr_vec[60] = -8'sd15;
            llr_vec[61] =  8'sd11;
            llr_vec[62] = -8'sd20;
            llr_vec[63] = -8'sd6;
        end
    endtask

    // =========================================================================
    // Block-driving tasks
    // =========================================================================

    task reset_scl_scoreboard;
        input integer backpressure_value;
        begin
            scl_out_count           = 0;
            scl_mismatch_count      = 0;
            scl_last_count          = 0;
            scl_ready_cycle         = 0;
            scl_backpressure_enable = backpressure_value;
            scl_score_enable        = 1;
        end
    endtask

    task reset_sc_scoreboard;
        begin
            sc_out_count      = 0;
            sc_mismatch_count = 0;
            sc_last_count     = 0;
            sc_score_enable   = 1;
        end
    endtask

    task run_scl_block;
        integer idx;
        integer guard;
        begin
            guard = 0;
            while (!scl_block_ready && (guard < 5000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check_true(scl_block_ready, "SCL ready before block_start");

            @(negedge clk);
            scl_block_start = 1'b1;

            @(negedge clk);
            scl_block_start = 1'b0;

            guard = 0;
            while (!scl_llr_in_ready && (guard < 500)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check_true(scl_llr_in_ready, "SCL root loader becomes ready");

            for (idx = 0; idx < active_n; idx = idx + 1) begin
                while (!scl_llr_in_ready)
                    @(posedge clk);

                @(negedge clk);
                scl_llr_in       = llr_vec[idx];
                scl_llr_in_valid = 1'b1;

                @(posedge clk);
            end

            @(negedge clk);
            scl_llr_in_valid = 1'b0;
            scl_llr_in       = {LLR_W{1'b0}};

            guard = 0;
            while (!scl_block_done && !scl_block_error &&
                   (guard < 1000000)) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end

            check_true(
                guard < 1000000,
                "SCL block_done observed before timeout"
            );
            check_true(!scl_block_error, "SCL block has no controller error");
            check_true(scl_block_done, "SCL block_done asserted");
            check_true(scl_out_count == active_n, "SCL streams exactly N u_hat bits");
            check_true(scl_last_count == 1, "SCL u_last asserts exactly once");
            check_true(scl_mismatch_count == 0, "SCL u_hat equals u_ref");

            @(posedge clk);
            #1;
            check_true(scl_block_ready, "SCL core returns to block_ready");

            scl_score_enable = 0;
            scl_backpressure_enable = 0;
        end
    endtask

    task run_sc_block;
        integer idx;
        integer guard;
        begin
            guard = 0;
            while (!sc_block_ready && (guard < 5000)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check_true(sc_block_ready, "SC ready before block_start");

            @(negedge clk);
            sc_block_start = 1'b1;

            @(negedge clk);
            sc_block_start = 1'b0;

            guard = 0;
            while (!sc_llr_in_ready && (guard < 500)) begin
                @(posedge clk);
                guard = guard + 1;
            end
            check_true(sc_llr_in_ready, "SC root loader becomes ready");

            for (idx = 0; idx < active_n; idx = idx + 1) begin
                while (!sc_llr_in_ready)
                    @(posedge clk);

                @(negedge clk);
                sc_llr_in       = llr_vec[idx];
                sc_llr_in_valid = 1'b1;

                @(posedge clk);
            end

            @(negedge clk);
            sc_llr_in_valid = 1'b0;
            sc_llr_in       = {LLR_W{1'b0}};

            guard = 0;
            while (!sc_block_done && !sc_block_error &&
                   (guard < 1000000)) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end

            check_true(
                guard < 1000000,
                "SC block_done observed before timeout"
            );
            check_true(!sc_block_error, "SC block has no controller error");
            check_true(sc_block_done, "SC block_done asserted");
            check_true(sc_out_count == active_n, "SC streams exactly N u_hat bits");
            check_true(sc_last_count == 1, "SC u_last asserts exactly once");

            @(posedge clk);
            #1;
            check_true(sc_block_ready, "SC core returns to block_ready");

            sc_score_enable = 0;
        end
    endtask

    // =========================================================================
    // Output scoreboards and backpressure
    // =========================================================================

    always @(posedge clk) begin
        if (!rst_n) begin
            scl_u_ready     <= 1'b1;
            scl_ready_cycle <= 0;
        end
        else begin
            if (scl_backpressure_enable != 0) begin
                scl_ready_cycle <= scl_ready_cycle + 1;
                scl_u_ready <= ((scl_ready_cycle % 7) != 3) &&
                               ((scl_ready_cycle % 7) != 4);
            end
            else begin
                scl_u_ready <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            scl_out_count      <= 0;
            scl_mismatch_count <= 0;
            scl_last_count     <= 0;
        end
        else if ((scl_score_enable != 0) &&
                 scl_u_valid && scl_u_ready) begin
            checks = checks + 1;

            if (scl_u_index !== scl_out_count[INDEX_W-1:0]) begin
                errors = errors + 1;
                scl_mismatch_count <= scl_mismatch_count + 1;
                $display(
                    "FAIL: SCL u_index got=%0d expected=%0d time=%0t",
                    scl_u_index, scl_out_count, $time
                );
            end
            else if (scl_u_bit !== u_ref[scl_out_count]) begin
                errors = errors + 1;
                scl_mismatch_count <= scl_mismatch_count + 1;
                $display(
                    "FAIL: SCL u_hat[%0d] got=%0b expected=%0b time=%0t",
                    scl_out_count, scl_u_bit,
                    u_ref[scl_out_count], $time
                );
            end

            if (scl_u_last)
                scl_last_count <= scl_last_count + 1;

            scl_out_count <= scl_out_count + 1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sc_u_ready         <= 1'b1;
            sc_out_count       <= 0;
            sc_mismatch_count  <= 0;
            sc_last_count      <= 0;
        end
        else begin
            sc_u_ready <= 1'b1;

            if ((sc_score_enable != 0) &&
                sc_u_valid && sc_u_ready) begin
                checks = checks + 1;

                if (sc_u_index !== sc_out_count[INDEX_W-1:0]) begin
                    errors = errors + 1;
                    $display(
                        "FAIL: SC u_index got=%0d expected=%0d time=%0t",
                        sc_u_index, sc_out_count, $time
                    );
                end
                else if (sc_u_bit !== u_ref[sc_out_count]) begin
                    sc_mismatch_count <= sc_mismatch_count + 1;
                end

                if (sc_u_last)
                    sc_last_count <= sc_last_count + 1;

                sc_out_count <= sc_out_count + 1;
            end
        end
    end

    // =========================================================================
    // Main regression sequence
    // =========================================================================

    initial begin
        clk                  = 1'b0;
        rst_n                = 1'b0;

        scl_config_start     = 1'b0;
        scl_n_log_cfg        = 4'd0;
        scl_k_cfg            = 11'd0;
        scl_known_zero_cfg   = {INDEX_W{1'b0}};
        scl_block_start      = 1'b0;
        scl_llr_in           = {LLR_W{1'b0}};
        scl_llr_in_valid     = 1'b0;
        scl_u_ready          = 1'b1;

        sc_config_start      = 1'b0;
        sc_n_log_cfg         = 4'd0;
        sc_k_cfg             = 11'd0;
        sc_known_zero_cfg    = {INDEX_W{1'b0}};
        sc_block_start       = 1'b0;
        sc_llr_in            = {LLR_W{1'b0}};
        sc_llr_in_valid      = 1'b0;
        sc_u_ready           = 1'b1;

        errors               = 0;
        checks               = 0;

        active_n             = 64;
        active_n_log         = 6;
        active_k             = 8;
        active_known         = 2;

        scl_out_count        = 0;
        scl_mismatch_count   = 0;
        scl_last_count       = 0;
        scl_ready_cycle      = 0;
        scl_backpressure_enable = 0;
        scl_score_enable     = 0;

        sc_out_count         = 0;
        sc_mismatch_count    = 0;
        sc_last_count        = 0;
        sc_score_enable      = 0;

        clear_vectors();

        repeat (8) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        repeat (3) @(posedge clk);

        // ---------------------------------------------------------------------
        // N=64, K=8, two known-zero non-frozen positions
        // ---------------------------------------------------------------------

        configure_scl(4'd6, 11'd8, 11'd2);

        $display("---- CASE 1: all-zero payload, strong LLR ----");
        build_u_pattern(0);
        polar_encode_reference();
        build_strong_llr();
        reset_scl_scoreboard(0);
        run_scl_block();
        check_true(scl_best_valid, "case1 SCL best path is valid");
        check_true(scl_best_pm == 0, "case1 noiseless best PM is zero");

        $display("---- CASE 2: all-one payload, strong LLR ----");
        build_u_pattern(1);
        polar_encode_reference();
        build_strong_llr();
        reset_scl_scoreboard(0);
        run_scl_block();
        check_true(scl_best_valid, "case2 SCL best path is valid");
        check_true(scl_best_pm == 0, "case2 noiseless best PM is zero");

        $display("---- CASE 3: alternating payload with output backpressure ----");
        build_u_pattern(2);
        polar_encode_reference();
        build_strong_llr();
        reset_scl_scoreboard(1);
        run_scl_block();
        check_true(scl_best_valid, "case3 SCL best path is valid");
        check_true(scl_best_pm == 0, "case3 noiseless best PM is zero");

        $display("---- CASE 4: fixed pseudo-random payload ----");
        build_u_pattern(3);
        polar_encode_reference();
        build_strong_llr();
        reset_scl_scoreboard(0);
        run_scl_block();
        check_true(scl_best_valid, "case4 SCL best path is valid");
        check_true(scl_best_pm == 0, "case4 noiseless best PM is zero");

        $display("---- CASE 5: weak but sign-correct LLR ----");
        build_u_pattern(3);
        polar_encode_reference();
        build_weak_correct_llr();
        reset_scl_scoreboard(0);
        run_scl_block();
        check_true(scl_best_valid, "case5 SCL best path is valid");
        check_true(scl_best_pm == 0, "case5 sign-correct best PM is zero");

        // ---------------------------------------------------------------------
        // Dynamic N reconfiguration smoke test
        // ---------------------------------------------------------------------

        $display("---- CASE 6: N=128 K=16 reconfiguration smoke test ----");
        active_n       = 128;
        active_n_log   = 7;
        active_k       = 16;
        active_known   = 3;

        configure_scl(4'd7, 11'd16, 11'd3);
        build_u_pattern(3);
        polar_encode_reference();
        build_strong_llr();
        reset_scl_scoreboard(0);
        run_scl_block();
        check_true(scl_best_valid, "case6 SCL best path is valid");
        check_true(scl_best_pm == 0, "case6 noiseless best PM is zero");

        // ---------------------------------------------------------------------
        // Deterministic SC-fail / SCL-success case
        // ---------------------------------------------------------------------

        $display("---- CASE 7: deterministic SC fail, SCL success ----");
        active_n       = 64;
        active_n_log   = 6;
        active_k       = 8;
        active_known   = 0;

        configure_scl(4'd6, 11'd8, 11'd0);
        configure_sc (4'd6, 11'd8, 11'd0);

        build_special_sc_fail_u();
        polar_encode_reference();
        build_special_noisy_llr();

        reset_scl_scoreboard(0);
        run_scl_block();

        check_true(
            scl_mismatch_count == 0,
            "case7 LIST_SIZE=4 recovers the transmitted u_ref"
        );
        check_true(scl_best_valid, "case7 SCL best path is valid");

        reset_sc_scoreboard();
        run_sc_block();

        check_true(
            sc_mismatch_count > 0,
            "case7 LIST_SIZE=1 produces at least one wrong u_hat bit"
        );
        check_true(sc_best_valid, "case7 SC best path is valid");

        if (errors == 0)
            $display(
                "PASS: tb_scl_decoder_core_full completed %0d checks.",
                checks
            );
        else
            $display(
                "FAIL: tb_scl_decoder_core_full errors=%0d checks=%0d.",
                errors, checks
            );

        $finish;
    end

    initial begin
        #100000000;
        $display(
            "FAIL: tb_scl_decoder_core_full timeout time=%0t scl_state=%0d scl_ctrl_state=%0d sc_state=%0d sc_ctrl_state=%0d",
            $time,
            dut_scl.state,
            dut_scl.u_controller.state,
            dut_sc.state,
            dut_sc.u_controller.state
        );
        $finish;
    end

endmodule
