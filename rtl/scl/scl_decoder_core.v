`timescale 1ns/1ps

// =============================================================================
// scl_decoder_core.v
// =============================================================================
// Single Polar sub-block SCL decoder core.
//
// CA-SCL extension:
// EXPORT_ALL_PATHS=1 streams every final survivor without changing the
// validated DFS, LLR, beta, PM or pruning logic. Default 0 preserves the
// previously verified best-path-only behavior.
//
// This wrapper connects the already validated modules:
//   * frozen_gen
//   * scl_controller
//   * scl_datapath
//   * scl_pruner
//
// It deliberately does NOT perform CRC24B processing.  The logical-code-block
// CRC manager and cross-sub-block candidate handling remain in the later
// ca_scl_decoder_top layer.
//
// Usage
// -----------------------------------------------------------------------------
// 1. When config_ready=1, pulse config_start with n_log_cfg, k_cfg and
//    known_zero_count_cfg.
// 2. Wait for config_done.
// 3. When block_ready=1, pulse block_start.
// 4. Supply N=2^n_log_cfg root LLRs in natural codeword order d[0]..d[N-1].
// 5. Receive selected-path u_hat[0]..u_hat[N-1] from the natural-order stream.
// 6. block_done is a one-cycle pulse after the final output transaction.
//
// Bit and frozen-set conventions are inherited unchanged:
//   * root LLR address 0 corresponds to d[0];
//   * LLR >= 0 favors bit 0, LLR < 0 favors bit 1;
//   * frozen=1 forces zero;
//   * the first known_zero_count_cfg non-frozen positions are known zero but
//     remain members of K;
//   * all later non-frozen positions split through the 2L-to-L pruner.
// =============================================================================

module scl_decoder_core #(
    parameter integer NMAX      = 1024,
    parameter integer LLR_W     = 8,
    parameter integer INT_W     = 10,
    parameter integer MAX_LOG   = 10,
    parameter integer LIST_SIZE = 4,
    parameter integer PM_W      = 24,

    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),

    parameter integer DEPTH_W =
        ((MAX_LOG + 1) <= 2) ? 1 : $clog2(MAX_LOG + 1),

    parameter integer MEM_DEPTH = 2 * NMAX - 1,
    parameter integer ADDR_W    = $clog2(MEM_DEPTH),
    parameter integer INDEX_W   = $clog2(NMAX) + 1,

    parameter integer CAND_W =
        ((2 * LIST_SIZE) <= 2) ? 1 : $clog2(2 * LIST_SIZE),

    parameter integer BRAM_MIN_DEPTH           = 64,
    parameter integer REGISTER_LLR_READ_OUTPUT = 1,
    parameter integer REGISTER_PRUNER_OUTPUT   = 1,

    // 0: retain the validated behavior and stream only best_path.
    // 1: after tree decoding, stream every active survivor path in ascending
    //    logical-path order. The controller is released only after all paths
    //    have been exported.
    parameter integer EXPORT_ALL_PATHS          = 0
)(
    input  wire                                  clk,
    input  wire                                  rst_n,

    // =========================================================================
    // Polar sub-block configuration
    // =========================================================================
    input  wire                                  config_start,
    input  wire [3:0]                            n_log_cfg,
    input  wire [10:0]                           k_cfg,
    input  wire [INDEX_W-1:0]                    known_zero_count_cfg,

    output wire                                  config_ready,
    output reg                                   config_busy,
    output reg                                   config_done,
    output reg                                   config_error,

    // =========================================================================
    // One sub-block decode transaction
    // =========================================================================
    input  wire                                  block_start,
    output wire                                  block_ready,
    output wire                                  block_busy,
    output wire                                  block_done,
    output wire                                  block_error,

    // Root-channel LLR stream, natural order d[0], d[1], ..., d[N-1].
    input  wire signed [LLR_W-1:0]               llr_in,
    input  wire                                  llr_in_valid,
    output wire                                  llr_in_ready,

    // Selected best-PM path, natural u_hat order.
    output wire                                  u_valid,
    input  wire                                  u_ready,
    output wire                                  u_bit,
    output wire [INDEX_W-1:0]                    u_index,
    output wire                                  u_last,

    // Candidate-export metadata. Existing best-path users may leave these
    // ports unconnected. Values are qualified by u_valid.
    output wire [PATH_W-1:0]                     u_path,
    output wire [PM_W-1:0]                       u_path_pm,
    output wire                                  u_path_start,
    output wire                                  u_path_end,
    output wire                                  u_nonfrozen,
    output wire                                  candidate_set_done,

    // Observation ports retained for integration/debug and later CA-SCL use.
    output wire [LIST_SIZE-1:0]                  path_active_bus,
    output wire [LIST_SIZE*PM_W-1:0]             path_pm_bus,
    output wire                                  best_valid,
    output wire [PATH_W-1:0]                     best_path,
    output wire [PM_W-1:0]                       best_pm
);

    // =========================================================================
    // Configuration / wrapper state
    // =========================================================================

    localparam [2:0] ST_NO_CONFIG = 3'd0;
    localparam [2:0] ST_CFG_START = 3'd1;
    localparam [2:0] ST_CFG_WAIT  = 3'd2;
    localparam [2:0] ST_READY     = 3'd3;
    localparam [2:0] ST_ACTIVE    = 3'd4;

    localparam [3:0] MIN_LOG_CODE = 4'd6;
    localparam [3:0] MAX_LOG_CODE = MAX_LOG;

    reg [2:0] state;

    reg [3:0]              n_log_active;
    reg [10:0]             k_active;
    reg [INDEX_W-1:0]      known_zero_count_active;

    reg                    frozen_start;
    wire                   frozen_busy;
    wire                   frozen_done;

    // Keep this signal name stable for testbench and integration visibility.
    wire [NMAX-1:0]        frozen_mask;

    reg                    datapath_load_start;

    wire [11:0] cfg_n_value;
    wire        cfg_n_valid;
    wire        cfg_k_valid;
    wire        cfg_known_zero_valid;
    wire        cfg_valid;

    assign cfg_n_value = (12'd1 << n_log_cfg);

    assign cfg_n_valid =
        (n_log_cfg >= MIN_LOG_CODE) &&
        (n_log_cfg <= MAX_LOG_CODE) &&
        (cfg_n_value <= NMAX);

    assign cfg_k_valid =
        ({1'b0, k_cfg} <= cfg_n_value);

    assign cfg_known_zero_valid =
        (known_zero_count_cfg <= k_cfg);

    assign cfg_valid =
        cfg_n_valid &&
        cfg_k_valid &&
        cfg_known_zero_valid;

    assign config_ready =
        ((state == ST_NO_CONFIG) || (state == ST_READY)) &&
        !config_busy;

    assign block_ready = (state == ST_READY);

    // =========================================================================
    // Frozen-set generator
    // =========================================================================

    frozen_gen #(
        .NMAX(NMAX)
    ) u_frozen_gen (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (frozen_start),
        .n_log   (n_log_active),
        .K       (k_active),
        .busy    (frozen_busy),
        .done    (frozen_done),
        .frozen  (frozen_mask)
    );

    // =========================================================================
    // Controller/datapath/pruner interconnect
    // =========================================================================

    wire load_busy;
    wire load_done;

    wire decode_busy;
    wire decode_done;
    wire decode_error;

    wire path_init;

    // LLR control.
    wire                              llr_rd_req;
    wire [DEPTH_W-1:0]                llr_rd_depth;
    wire [ADDR_W-1:0]                 llr_rd_addr_a;
    wire [ADDR_W-1:0]                 llr_rd_addr_b;
    wire                              llr_rd_valid;
    wire signed [LIST_SIZE*INT_W-1:0] llr_rd_data_a_bus;
    wire signed [LIST_SIZE*INT_W-1:0] llr_rd_data_b_bus;
    wire                              pe_mode_g;
    wire                              pe_result_valid;
    wire signed [LIST_SIZE*INT_W-1:0] pe_result_bus;
    wire                              llr_wr_en;
    wire [DEPTH_W-1:0]                llr_wr_depth;
    wire [ADDR_W-1:0]                 llr_wr_addr;
    wire                              llr_write_conflict;

    // beta control.
    wire                              beta_rd_req;
    wire [ADDR_W-1:0]                 beta_rd_addr_a;
    wire [ADDR_W-1:0]                 beta_rd_addr_b;
    wire                              beta_rd_valid;
    wire [LIST_SIZE-1:0]              beta_rd_data_a_bus;
    wire [LIST_SIZE-1:0]              beta_rd_data_b_bus;
    wire                              beta_wr_en;
    wire [ADDR_W-1:0]                 beta_wr_addr;
    wire [LIST_SIZE-1:0]              beta_wr_direct_bus;
    wire [1:0]                        beta_wr_mode;
    wire                              beta_wr_commit;
    wire [LIST_SIZE-1:0]              beta_selected_data_bus;
    wire                              beta_write_accepted;

    // Leaf and candidate control.
    wire [INDEX_W-1:0]                leaf_index;
    wire [ADDR_W-1:0]                 leaf_beta_addr;
    wire                              leaf_eval_valid;
    wire                              fixed_leaf_commit_en;

    wire [2*LIST_SIZE*PM_W-1:0]       cand_pm_bus;
    wire [2*LIST_SIZE*PATH_W-1:0]     cand_parent_bus;
    wire [2*LIST_SIZE-1:0]            cand_bit_bus;
    wire [2*LIST_SIZE-1:0]            cand_valid_bus;
    wire [LIST_SIZE-1:0]              leaf_hard_bit_bus;
    wire [LIST_SIZE*INT_W-1:0]        leaf_abs_llr_bus;

    // Pruner handshake and selected candidates.
    wire                              prune_in_valid;
    wire                              prune_in_ready;
    wire                              prune_out_valid;
    wire                              prune_commit_en;
    wire [LIST_SIZE*PM_W-1:0]         sel_pm_bus;
    wire [LIST_SIZE*PATH_W-1:0]       sel_parent_bus;
    wire [LIST_SIZE-1:0]              sel_bit_bus;
    wire [LIST_SIZE-1:0]              sel_valid_bus;
    wire [LIST_SIZE*CAND_W-1:0]       sel_index_bus;

    // Final output control.
    wire                              ctrl_output_start;
    wire [PATH_W-1:0]                 ctrl_output_path;
    wire                              ctrl_output_done;

    wire                              dp_output_start;
    wire [PATH_W-1:0]                 dp_output_path;
    wire                              dp_output_busy;
    wire                              dp_output_done;

    wire                              dp_u_valid;
    wire                              dp_u_bit;
    wire [INDEX_W-1:0]                dp_u_index;
    wire                              dp_u_last;

    wire [PATH_W-1:0]                 export_path_tag;
    wire                              candidate_set_done_int;

    assign u_valid        = dp_u_valid;
    assign u_bit          = dp_u_bit;
    assign u_index        = dp_u_index;
    assign u_last         = dp_u_last;
    assign u_path         = export_path_tag;
    assign u_path_pm      =
        path_pm_bus[export_path_tag*PM_W +: PM_W];
    assign u_path_start   = dp_u_valid &&
                            (dp_u_index == {INDEX_W{1'b0}});
    assign u_path_end     = dp_u_valid && dp_u_last;
    assign u_nonfrozen    = dp_u_valid &&
                            !frozen_mask[dp_u_index];
    assign candidate_set_done = candidate_set_done_int;

    assign block_done  = decode_done;
    assign block_error = decode_error;

    assign block_busy =
        (state == ST_ACTIVE) ||
        load_busy ||
        decode_busy ||
        dp_output_busy;

    // =========================================================================
    // Shared DFS controller
    // =========================================================================

    scl_controller #(
        .NMAX      (NMAX),
        .MAX_LOG   (MAX_LOG),
        .LIST_SIZE (LIST_SIZE),
        .PATH_W    (PATH_W),
        .DEPTH_W   (DEPTH_W),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    ) u_controller (
        .clk                  (clk),
        .rst_n                (rst_n),

        .decode_start         (load_done),
        .n_log                (n_log_active),
        .frozen_bits          (frozen_mask),
        .known_zero_count_cfg (known_zero_count_active),

        .decode_busy          (decode_busy),
        .decode_done          (decode_done),
        .decode_error         (decode_error),

        .path_init            (path_init),

        .llr_rd_req           (llr_rd_req),
        .llr_rd_depth         (llr_rd_depth),
        .llr_rd_addr_a        (llr_rd_addr_a),
        .llr_rd_addr_b        (llr_rd_addr_b),
        .pe_mode_g            (pe_mode_g),
        .pe_result_valid      (pe_result_valid),

        .llr_wr_en            (llr_wr_en),
        .llr_wr_depth         (llr_wr_depth),
        .llr_wr_addr          (llr_wr_addr),
        .llr_write_conflict   (llr_write_conflict),

        .beta_rd_req          (beta_rd_req),
        .beta_rd_addr_a       (beta_rd_addr_a),
        .beta_rd_addr_b       (beta_rd_addr_b),
        .beta_rd_valid        (beta_rd_valid),

        .beta_wr_en           (beta_wr_en),
        .beta_wr_addr         (beta_wr_addr),
        .beta_wr_direct_bus   (beta_wr_direct_bus),
        .beta_wr_mode         (beta_wr_mode),
        .beta_wr_commit       (beta_wr_commit),
        .beta_write_accepted  (beta_write_accepted),

        .leaf_index           (leaf_index),
        .leaf_beta_addr       (leaf_beta_addr),
        .leaf_eval_valid      (leaf_eval_valid),
        .fixed_leaf_commit_en (fixed_leaf_commit_en),

        .prune_in_valid       (prune_in_valid),
        .prune_in_ready       (prune_in_ready),
        .prune_out_valid      (prune_out_valid),
        .prune_commit_en      (prune_commit_en),

        .best_valid           (best_valid),
        .best_path            (best_path),

        .output_start         (ctrl_output_start),
        .output_path          (ctrl_output_path),
        .output_done          (ctrl_output_done)
    );

    // =========================================================================
    // Parallel SCL datapath
    // =========================================================================

    scl_datapath #(
        .NMAX                    (NMAX),
        .LLR_W                   (LLR_W),
        .INT_W                   (INT_W),
        .MAX_LOG                 (MAX_LOG),
        .LIST_SIZE               (LIST_SIZE),
        .PM_W                    (PM_W),
        .PATH_W                  (PATH_W),
        .DEPTH_W                 (DEPTH_W),
        .MEM_DEPTH               (MEM_DEPTH),
        .ADDR_W                  (ADDR_W),
        .INDEX_W                 (INDEX_W),
        .BRAM_MIN_DEPTH          (BRAM_MIN_DEPTH),
        .REGISTER_LLR_READ_OUTPUT(REGISTER_LLR_READ_OUTPUT)
    ) u_datapath (
        .clk                    (clk),
        .rst_n                  (rst_n),

        .load_start             (datapath_load_start),
        .n_log                  (n_log_active),
        .llr_in                 (llr_in),
        .llr_in_valid           (llr_in_valid),
        .llr_in_ready           (llr_in_ready),
        .load_busy              (load_busy),
        .load_done              (load_done),

        .path_init              (path_init),

        .llr_rd_req             (llr_rd_req),
        .llr_rd_depth           (llr_rd_depth),
        .llr_rd_addr_a          (llr_rd_addr_a),
        .llr_rd_addr_b          (llr_rd_addr_b),
        .llr_rd_valid           (llr_rd_valid),
        .llr_rd_data_a_bus      (llr_rd_data_a_bus),
        .llr_rd_data_b_bus      (llr_rd_data_b_bus),

        .beta_rd_req            (beta_rd_req),
        .beta_rd_addr_a         (beta_rd_addr_a),
        .beta_rd_addr_b         (beta_rd_addr_b),
        .beta_rd_valid          (beta_rd_valid),
        .beta_rd_data_a_bus     (beta_rd_data_a_bus),
        .beta_rd_data_b_bus     (beta_rd_data_b_bus),

        .pe_mode_g              (pe_mode_g),
        .pe_result_valid        (pe_result_valid),
        .pe_result_bus          (pe_result_bus),

        .llr_wr_en              (llr_wr_en),
        .llr_wr_depth           (llr_wr_depth),
        .llr_wr_addr            (llr_wr_addr),
        .llr_write_conflict     (llr_write_conflict),

        .beta_wr_en             (beta_wr_en),
        .beta_wr_addr           (beta_wr_addr),
        .beta_wr_direct_bus     (beta_wr_direct_bus),
        .beta_wr_mode           (beta_wr_mode),
        .beta_wr_commit         (beta_wr_commit),
        .beta_selected_data_bus (beta_selected_data_bus),
        .beta_write_accepted    (beta_write_accepted),

        .leaf_index             (leaf_index),
        .leaf_beta_addr         (leaf_beta_addr),
        .leaf_eval_valid        (leaf_eval_valid),
        .fixed_leaf_commit_en   (fixed_leaf_commit_en),

        .cand_pm_bus            (cand_pm_bus),
        .cand_parent_bus        (cand_parent_bus),
        .cand_bit_bus           (cand_bit_bus),
        .cand_valid_bus         (cand_valid_bus),
        .leaf_hard_bit_bus      (leaf_hard_bit_bus),
        .leaf_abs_llr_bus       (leaf_abs_llr_bus),

        .prune_commit_en        (prune_commit_en),
        .sel_pm_bus             (sel_pm_bus),
        .sel_parent_bus         (sel_parent_bus),
        .sel_bit_bus            (sel_bit_bus),
        .sel_valid_bus          (sel_valid_bus),

        .path_active_bus        (path_active_bus),
        .path_pm_bus            (path_pm_bus),
        .best_valid             (best_valid),
        .best_path              (best_path),
        .best_pm                (best_pm),

        .output_start           (dp_output_start),
        .output_path            (dp_output_path),
        .output_busy            (dp_output_busy),
        .output_done            (dp_output_done),
        .u_valid                (dp_u_valid),
        .u_ready                (u_ready),
        .u_bit                  (dp_u_bit),
        .u_index                (dp_u_index),
        .u_last                 (dp_u_last)
    );


    // =========================================================================
    // Survivor-path export arbitration
    // =========================================================================
    //
    // The validated default path remains a direct controller-to-datapath
    // connection. EXPORT_ALL_PATHS=1 inserts a small sequencer only around the
    // traceback/output interface:
    //
    //   controller requests output
    //   -> output every active logical path
    //   -> acknowledge output_done to controller once
    //
    // Tree traversal, path metric updates, pruning and memories are unchanged.

    generate
        if (EXPORT_ALL_PATHS == 0) begin : g_best_only_output
            assign dp_output_start       = ctrl_output_start;
            assign dp_output_path        = ctrl_output_path;
            assign ctrl_output_done      = dp_output_done;
            assign export_path_tag       = ctrl_output_path;
            assign candidate_set_done_int = decode_done;
        end
        else begin : g_all_path_output
            localparam [1:0] EX_IDLE   = 2'd0;
            localparam [1:0] EX_START  = 2'd1;
            localparam [1:0] EX_WAIT   = 2'd2;
            localparam [1:0] EX_FINISH = 2'd3;

            reg [1:0]          ex_state;
            reg [PATH_W-1:0]   ex_path;
            reg                candidate_set_done_q;

            integer search_i;
            reg                first_found;
            reg [PATH_W-1:0]   first_path;
            reg                next_found;
            reg [PATH_W-1:0]   next_path;

            always @* begin
                first_found = 1'b0;
                first_path  = {PATH_W{1'b0}};

                for (search_i = 0;
                     search_i < LIST_SIZE;
                     search_i = search_i + 1) begin
                    if (!first_found && path_active_bus[search_i]) begin
                        first_found = 1'b1;
                        first_path  = search_i[PATH_W-1:0];
                    end
                end
            end

            always @* begin
                next_found = 1'b0;
                next_path  = {PATH_W{1'b0}};

                for (search_i = 0;
                     search_i < LIST_SIZE;
                     search_i = search_i + 1) begin
                    if (!next_found &&
                        (search_i > ex_path) &&
                        path_active_bus[search_i]) begin
                        next_found = 1'b1;
                        next_path  = search_i[PATH_W-1:0];
                    end
                end
            end

            assign dp_output_start = (ex_state == EX_START);
            assign dp_output_path  = ex_path;
            assign ctrl_output_done = (ex_state == EX_FINISH);
            assign export_path_tag = ex_path;
            assign candidate_set_done_int = candidate_set_done_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    ex_state              <= EX_IDLE;
                    ex_path               <= {PATH_W{1'b0}};
                    candidate_set_done_q  <= 1'b0;
                end
                else begin
                    candidate_set_done_q <= 1'b0;

                    case (ex_state)
                        EX_IDLE: begin
                            if (ctrl_output_start) begin
                                if (first_found) begin
                                    ex_path  <= first_path;
                                    ex_state <= EX_START;
                                end
                                else begin
                                    ex_state <= EX_FINISH;
                                end
                            end
                        end

                        EX_START: begin
                            ex_state <= EX_WAIT;
                        end

                        EX_WAIT: begin
                            if (dp_output_done) begin
                                if (next_found) begin
                                    ex_path  <= next_path;
                                    ex_state <= EX_START;
                                end
                                else begin
                                    ex_state <= EX_FINISH;
                                end
                            end
                        end

                        EX_FINISH: begin
                            candidate_set_done_q <= 1'b1;
                            ex_state             <= EX_IDLE;
                        end

                        default: begin
                            ex_state <= EX_IDLE;
                        end
                    endcase
                end
            end
        end
    endgenerate

    // =========================================================================
    // Fixed 2L-to-L pruner
    // =========================================================================

    scl_pruner #(
        .LIST_SIZE      (LIST_SIZE),
        .PM_W           (PM_W),
        .PATH_W         (PATH_W),
        .CAND_W         (CAND_W),
        .REGISTER_OUTPUT(REGISTER_PRUNER_OUTPUT)
    ) u_pruner (
        .clk            (clk),
        .rst_n          (rst_n),

        .in_valid       (prune_in_valid),
        .in_ready       (prune_in_ready),

        .cand_pm_bus    (cand_pm_bus),
        .cand_parent_bus(cand_parent_bus),
        .cand_bit_bus   (cand_bit_bus),
        .cand_valid_bus (cand_valid_bus),

        .out_valid      (prune_out_valid),
        .sel_pm_bus     (sel_pm_bus),
        .sel_parent_bus (sel_parent_bus),
        .sel_bit_bus    (sel_bit_bus),
        .sel_valid_bus  (sel_valid_bus),
        .sel_index_bus  (sel_index_bus)
    );

    // =========================================================================
    // Wrapper configuration / block sequencing
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                   <= ST_NO_CONFIG;
            n_log_active            <= MIN_LOG_CODE;
            k_active                <= 11'd0;
            known_zero_count_active <= {INDEX_W{1'b0}};

            frozen_start            <= 1'b0;
            datapath_load_start     <= 1'b0;

            config_busy             <= 1'b0;
            config_done             <= 1'b0;
            config_error            <= 1'b0;
        end
        else begin
            frozen_start        <= 1'b0;
            datapath_load_start <= 1'b0;
            config_done         <= 1'b0;
            config_error        <= 1'b0;

            case (state)
                ST_NO_CONFIG: begin
                    config_busy <= 1'b0;

                    if (config_start) begin
                        if (cfg_valid) begin
                            n_log_active            <= n_log_cfg;
                            k_active                <= k_cfg;
                            known_zero_count_active <= known_zero_count_cfg;
                            config_busy             <= 1'b1;
                            state                   <= ST_CFG_START;
                        end
                        else begin
                            config_error <= 1'b1;
                        end
                    end
                end

                ST_CFG_START: begin
                    config_busy  <= 1'b1;
                    frozen_start <= 1'b1;
                    state        <= ST_CFG_WAIT;
                end

                ST_CFG_WAIT: begin
                    config_busy <= 1'b1;

                    if (frozen_done) begin
                        config_busy <= 1'b0;
                        config_done <= 1'b1;
                        state       <= ST_READY;
                    end
                end

                ST_READY: begin
                    config_busy <= 1'b0;

                    // Reconfiguration has priority over a new block.
                    if (config_start) begin
                        if (cfg_valid) begin
                            n_log_active            <= n_log_cfg;
                            k_active                <= k_cfg;
                            known_zero_count_active <= known_zero_count_cfg;
                            config_busy             <= 1'b1;
                            state                   <= ST_CFG_START;
                        end
                        else begin
                            config_error <= 1'b1;
                        end
                    end
                    else if (block_start) begin
                        datapath_load_start <= 1'b1;
                        state               <= ST_ACTIVE;
                    end
                end

                ST_ACTIVE: begin
                    config_busy <= 1'b0;

                    if (decode_done || decode_error)
                        state <= ST_READY;
                end

                default: begin
                    state        <= ST_NO_CONFIG;
                    config_busy  <= 1'b0;
                    config_error <= 1'b1;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (NMAX != 1024) begin
            $display("WARNING(scl_decoder_core): frozen_gen reliability scan is defined for NMAX=1024; use NMAX=1024 for production.");
        end

        if ((LIST_SIZE < 1) ||
            ((LIST_SIZE & (LIST_SIZE - 1)) != 0)) begin
            $display("ERROR(scl_decoder_core): LIST_SIZE must be a power of two.");
            $finish;
        end

        if (REGISTER_PRUNER_OUTPUT != 1) begin
            $display("ERROR(scl_decoder_core): current scl_controller requires REGISTER_PRUNER_OUTPUT=1.");
            $finish;
        end

        if ((EXPORT_ALL_PATHS != 0) && (EXPORT_ALL_PATHS != 1)) begin
            $display("ERROR(scl_decoder_core): EXPORT_ALL_PATHS must be 0 or 1.");
            $finish;
        end
    end
`endif

endmodule
