`timescale 1ns/1ps

// =============================================================================
// scl_datapath_balanced_v1.v
// =============================================================================
// Timing/area-balanced parallel datapath for one Polar SCL sub-block.
//
// Main blocks
// -----------------------------------------------------------------------------
// * LIST_SIZE parallel sc_pe instances.
// * scl_llr_mem: shared root LLR plus per-depth physical banks and path mapping.
// * balanced scl_path_mem:
//       beta: mirrored packed-bank RAM, one-cycle synchronous read;
//       u_hat: survivor history plus final traceback.
// * One saturated path metric register per logical path.
// * Fixed candidate packing:
//       candidate[2*p]   = parent p, decision 0;
//       candidate[2*p+1] = parent p, decision 1.
//
// Timing contract
// -----------------------------------------------------------------------------
// 1. LLR request:
//      llr_rd_req, depth and addresses are sampled together.
//      llr_rd_valid indicates the returned LLR buses.
//
// 2. beta request:
//      beta_rd_req and addresses are sampled together.
//      beta_rd_valid is asserted one cycle later.
//
// 3. Parallel PE alignment:
//      For PH_G, assert llr_rd_req and beta_rd_req in the same cycle.
//      This module delays beta and pe_mode_g as required so pe_result_bus is
//      aligned automatically with llr_rd_valid.  pe_result_valid marks the
//      valid PE result cycle.
//
// 4. LLR writeback:
//      Assert llr_wr_en in the pe_result_valid cycle.  The module masks writes
//      to active paths and prevents a stale PE result from being written.
//
// 5. beta update:
//      beta reads have one-cycle latency.  For XOR/A/B source modes, assert
//      beta_wr_en when beta_rd_valid is high.  Assert beta_wr_commit together
//      with the final write of one complete depth transaction.
//
// 6. Leaf handling:
//      leaf_eval_valid equals llr_rd_valid.  Candidate buses and fixed PM0 are
//      valid in that cycle.  A fixed-zero leaf commit must be asserted while
//      leaf_eval_valid is high.  A split leaf is committed later using the
//      registered pruner outputs and prune_commit_en.
// =============================================================================

module scl_datapath #(
    parameter integer NMAX       = 1024,
    parameter integer LLR_W      = 8,
    parameter integer INT_W      = 10,
    parameter integer MAX_LOG    = 10,
    parameter integer LIST_SIZE  = 4,
    parameter integer PM_W       = 24,

    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),
    parameter integer DEPTH_W =
        ((MAX_LOG + 1) <= 2) ? 1 : $clog2(MAX_LOG + 1),

    parameter integer MEM_DEPTH  = 2 * NMAX - 1,
    parameter integer ADDR_W     = $clog2(MEM_DEPTH),
    parameter integer INDEX_W    = $clog2(NMAX) + 1,

    parameter integer BRAM_MIN_DEPTH           = 64,
    parameter integer REGISTER_LLR_READ_OUTPUT = 1
)(
    input  wire                                  clk,
    input  wire                                  rst_n,

    // =========================================================================
    // Root-channel LLR loading
    // =========================================================================
    input  wire                                  load_start,
    input  wire [3:0]                            n_log,
    input  wire signed [LLR_W-1:0]               llr_in,
    input  wire                                  llr_in_valid,
    output wire                                  llr_in_ready,
    output wire                                  load_busy,
    output wire                                  load_done,

    // New Polar sub-block: path0 active and PM0=0.
    input  wire                                  path_init,

    // =========================================================================
    // LLR read request / response
    // =========================================================================
    input  wire                                  llr_rd_req,
    input  wire [DEPTH_W-1:0]                    llr_rd_depth,
    input  wire [ADDR_W-1:0]                     llr_rd_addr_a,
    input  wire [ADDR_W-1:0]                     llr_rd_addr_b,
    output wire                                  llr_rd_valid,
    output wire signed [LIST_SIZE*INT_W-1:0]     llr_rd_data_a_bus,
    output wire signed [LIST_SIZE*INT_W-1:0]     llr_rd_data_b_bus,

    // =========================================================================
    // beta read request / response
    // =========================================================================
    input  wire                                  beta_rd_req,
    input  wire [ADDR_W-1:0]                     beta_rd_addr_a,
    input  wire [ADDR_W-1:0]                     beta_rd_addr_b,
    output reg                                   beta_rd_valid,
    output wire [LIST_SIZE-1:0]                  beta_rd_data_a_bus,
    output wire [LIST_SIZE-1:0]                  beta_rd_data_b_bus,

    // =========================================================================
    // Parallel PE and LLR writeback
    // =========================================================================
    // pe_mode_g belongs to the same request as llr_rd_req.
    input  wire                                  pe_mode_g,
    output wire                                  pe_result_valid,
    output wire signed [LIST_SIZE*INT_W-1:0]     pe_result_bus,

    input  wire                                  llr_wr_en,
    input  wire [DEPTH_W-1:0]                    llr_wr_depth,
    input  wire [ADDR_W-1:0]                     llr_wr_addr,
    output wire                                  llr_write_conflict,

    // =========================================================================
    // beta write micro-operation
    // =========================================================================
    input  wire                                  beta_wr_en,
    input  wire [ADDR_W-1:0]                     beta_wr_addr,
    input  wire [LIST_SIZE-1:0]                  beta_wr_direct_bus,
    input  wire [1:0]                            beta_wr_mode,
    input  wire                                  beta_wr_commit,
    output wire [LIST_SIZE-1:0]                  beta_selected_data_bus,
    output wire                                  beta_write_accepted,

    // =========================================================================
    // Leaf handling
    // =========================================================================
    input  wire [INDEX_W-1:0]                    leaf_index,
    input  wire [ADDR_W-1:0]                     leaf_beta_addr,

    output wire                                  leaf_eval_valid,

    // Frozen Polar bit or known-zero non-frozen position.
    input  wire                                  fixed_leaf_commit_en,

    // Candidate buses presented to the external scl_pruner.
    output reg  [2*LIST_SIZE*PM_W-1:0]           cand_pm_bus,
    output reg  [2*LIST_SIZE*PATH_W-1:0]         cand_parent_bus,
    output reg  [2*LIST_SIZE-1:0]                cand_bit_bus,
    output reg  [2*LIST_SIZE-1:0]                cand_valid_bus,

    output reg  [LIST_SIZE-1:0]                  leaf_hard_bit_bus,
    output reg  [LIST_SIZE*INT_W-1:0]            leaf_abs_llr_bus,

    // Registered pruner result. Destination logical path equals output rank.
    input  wire                                  prune_commit_en,
    input  wire [LIST_SIZE*PM_W-1:0]             sel_pm_bus,
    input  wire [LIST_SIZE*PATH_W-1:0]           sel_parent_bus,
    input  wire [LIST_SIZE-1:0]                  sel_bit_bus,
    input  wire [LIST_SIZE-1:0]                  sel_valid_bus,

    // =========================================================================
    // Path status / metric observation
    // =========================================================================
    output wire [LIST_SIZE-1:0]                  path_active_bus,
    output reg  [LIST_SIZE*PM_W-1:0]             path_pm_bus,

    output reg                                   best_valid,
    output reg  [PATH_W-1:0]                     best_path,
    output reg  [PM_W-1:0]                       best_pm,

    // =========================================================================
    // Final selected-path natural-order u_hat stream
    // =========================================================================
    input  wire                                  output_start,
    input  wire [PATH_W-1:0]                     output_path,
    output wire                                  output_busy,
    output wire                                  output_done,
    output wire                                  u_valid,
    input  wire                                  u_ready,
    output wire                                  u_bit,
    output wire [INDEX_W-1:0]                    u_index,
    output wire                                  u_last
);

    localparam [PM_W-1:0] PM_MAX = {PM_W{1'b1}};

    localparam [1:0] BETA_SRC_DIRECT = 2'b00;
    localparam [1:0] BETA_SRC_XOR    = 2'b01;
    localparam [1:0] BETA_SRC_A      = 2'b10;
    localparam [1:0] BETA_SRC_B      = 2'b11;

`ifndef SYNTHESIS
    initial begin
        if ((LIST_SIZE < 1) ||
            ((LIST_SIZE & (LIST_SIZE - 1)) != 0)) begin
            $display("ERROR(scl_datapath): LIST_SIZE must be a power of two.");
            $finish;
        end

        if (PM_W < INT_W) begin
            $display("ERROR(scl_datapath): PM_W must be >= INT_W.");
            $finish;
        end

        if (INT_W < LLR_W) begin
            $display("ERROR(scl_datapath): INT_W must be >= LLR_W.");
            $finish;
        end

        if (MEM_DEPTH != (2*NMAX-1)) begin
            $display("ERROR(scl_datapath): MEM_DEPTH must equal 2*NMAX-1.");
            $finish;
        end
    end
`endif

    // =========================================================================
    // Utility functions
    // =========================================================================

    function [INT_W-1:0] abs_llr;
        input signed [INT_W-1:0] value;
        begin
            if (value[INT_W-1])
                abs_llr = (~value) + {{(INT_W-1){1'b0}}, 1'b1};
            else
                abs_llr = value;
        end
    endfunction

    function [PM_W-1:0] pm_add_sat;
        input [PM_W-1:0]  old_pm;
        input [INT_W-1:0] penalty;
        reg [PM_W-1:0] penalty_ext;
        reg [PM_W:0]   sum_ext;
        begin
            penalty_ext = {{(PM_W-INT_W){1'b0}}, penalty};
            sum_ext = {1'b0, old_pm} + {1'b0, penalty_ext};

            if (sum_ext[PM_W])
                pm_add_sat = PM_MAX;
            else
                pm_add_sat = sum_ext[PM_W-1:0];
        end
    endfunction

    // =========================================================================
    // Path metric state and leaf candidate generation
    // =========================================================================

    reg [PM_W-1:0] path_pm [0:LIST_SIZE-1];

    integer pm_p;
    reg signed [INT_W-1:0] leaf_llr_tmp;
    reg [INT_W-1:0]        leaf_mag_tmp;
    reg                     leaf_hard_tmp;
    reg [PM_W-1:0]         pm0_tmp;
    reg [PM_W-1:0]         pm1_tmp;
    reg [LIST_SIZE*PM_W-1:0] fixed_pm0_bus;

    always @* begin
        path_pm_bus       = {LIST_SIZE*PM_W{1'b0}};
        cand_pm_bus       = {2*LIST_SIZE*PM_W{1'b0}};
        cand_parent_bus   = {2*LIST_SIZE*PATH_W{1'b0}};
        cand_bit_bus      = {2*LIST_SIZE{1'b0}};
        cand_valid_bus    = {2*LIST_SIZE{1'b0}};
        leaf_hard_bit_bus = {LIST_SIZE{1'b0}};
        leaf_abs_llr_bus  = {LIST_SIZE*INT_W{1'b0}};
        fixed_pm0_bus     = {LIST_SIZE*PM_W{1'b0}};

        leaf_llr_tmp  = {INT_W{1'b0}};
        leaf_mag_tmp  = {INT_W{1'b0}};
        leaf_hard_tmp = 1'b0;
        pm0_tmp       = {PM_W{1'b0}};
        pm1_tmp       = {PM_W{1'b0}};

        for (pm_p = 0; pm_p < LIST_SIZE; pm_p = pm_p + 1) begin
            path_pm_bus[pm_p*PM_W +: PM_W] = path_pm[pm_p];

            leaf_llr_tmp = llr_rd_data_a_bus[pm_p*INT_W +: INT_W];
            leaf_hard_tmp = leaf_llr_tmp[INT_W-1];
            leaf_mag_tmp  = abs_llr(leaf_llr_tmp);

            leaf_hard_bit_bus[pm_p] = leaf_hard_tmp;
            leaf_abs_llr_bus[pm_p*INT_W +: INT_W] = leaf_mag_tmp;

            pm0_tmp = pm_add_sat(
                path_pm[pm_p],
                leaf_hard_tmp ? leaf_mag_tmp : {INT_W{1'b0}}
            );

            pm1_tmp = pm_add_sat(
                path_pm[pm_p],
                leaf_hard_tmp ? {INT_W{1'b0}} : leaf_mag_tmp
            );

            fixed_pm0_bus[pm_p*PM_W +: PM_W] = pm0_tmp;

            cand_pm_bus[(2*pm_p)*PM_W +: PM_W] =
                path_active_bus[pm_p] ? pm0_tmp : PM_MAX;

            cand_pm_bus[(2*pm_p+1)*PM_W +: PM_W] =
                path_active_bus[pm_p] ? pm1_tmp : PM_MAX;

            cand_parent_bus[(2*pm_p)*PATH_W +: PATH_W] =
                pm_p[PATH_W-1:0];

            cand_parent_bus[(2*pm_p+1)*PATH_W +: PATH_W] =
                pm_p[PATH_W-1:0];

            cand_bit_bus[2*pm_p]     = 1'b0;
            cand_bit_bus[2*pm_p + 1] = 1'b1;

            cand_valid_bus[2*pm_p]     = path_active_bus[pm_p];
            cand_valid_bus[2*pm_p + 1] = path_active_bus[pm_p];
        end
    end

    assign leaf_eval_valid = llr_rd_valid;

    wire fixed_leaf_fire;
    assign fixed_leaf_fire = fixed_leaf_commit_en && leaf_eval_valid;

    integer pm_seq_p;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (pm_seq_p = 0; pm_seq_p < LIST_SIZE;
                 pm_seq_p = pm_seq_p + 1) begin
                if (pm_seq_p == 0)
                    path_pm[pm_seq_p] <= {PM_W{1'b0}};
                else
                    path_pm[pm_seq_p] <= PM_MAX;
            end
        end
        else if (path_init) begin
            for (pm_seq_p = 0; pm_seq_p < LIST_SIZE;
                 pm_seq_p = pm_seq_p + 1) begin
                if (pm_seq_p == 0)
                    path_pm[pm_seq_p] <= {PM_W{1'b0}};
                else
                    path_pm[pm_seq_p] <= PM_MAX;
            end
        end
        else if (prune_commit_en) begin
            for (pm_seq_p = 0; pm_seq_p < LIST_SIZE;
                 pm_seq_p = pm_seq_p + 1) begin
                if (sel_valid_bus[pm_seq_p])
                    path_pm[pm_seq_p] <=
                        sel_pm_bus[pm_seq_p*PM_W +: PM_W];
                else
                    path_pm[pm_seq_p] <= PM_MAX;
            end
        end
        else if (fixed_leaf_fire) begin
            for (pm_seq_p = 0; pm_seq_p < LIST_SIZE;
                 pm_seq_p = pm_seq_p + 1) begin
                if (path_active_bus[pm_seq_p])
                    path_pm[pm_seq_p] <=
                        fixed_pm0_bus[pm_seq_p*PM_W +: PM_W];
            end
        end
    end

    // =========================================================================
    // Best active path. Lower logical path id wins an exact PM tie.
    // =========================================================================

    integer best_p;
    always @* begin
        best_valid = 1'b0;
        best_path  = {PATH_W{1'b0}};
        best_pm    = PM_MAX;

        for (best_p = 0; best_p < LIST_SIZE; best_p = best_p + 1) begin
            if (path_active_bus[best_p]) begin
                if (!best_valid || (path_pm[best_p] < best_pm)) begin
                    best_valid = 1'b1;
                    best_path  = best_p[PATH_W-1:0];
                    best_pm    = path_pm[best_p];
                end
            end
        end
    end

    // =========================================================================
    // LLR memory
    // =========================================================================

    wire [LIST_SIZE-1:0] llr_wr_en_bus;
    wire                 llr_write_fire;

    assign llr_write_fire = llr_wr_en && pe_result_valid;
    assign llr_wr_en_bus  = {LIST_SIZE{llr_write_fire}} & path_active_bus;

    scl_llr_mem #(
        .NMAX                 (NMAX),
        .LLR_W                (LLR_W),
        .INT_W                (INT_W),
        .MAX_LOG              (MAX_LOG),
        .LIST_SIZE            (LIST_SIZE),
        .PATH_W               (PATH_W),
        .DEPTH_W              (DEPTH_W),
        .MEM_DEPTH            (MEM_DEPTH),
        .ADDR_W               (ADDR_W),
        .N_W                  (INDEX_W),
        .BRAM_MIN_DEPTH       (BRAM_MIN_DEPTH),
        .REGISTER_READ_OUTPUT (REGISTER_LLR_READ_OUTPUT),
        .BROADCAST_ROOT_TO_ALL_PATHS (1),
        .INFLIGHT_IDENTITY_READ      (1)
    ) u_scl_llr_mem (
        .clk                  (clk),
        .rst_n                (rst_n),

        .load_start           (load_start),
        .n_log                (n_log),
        .llr_in               (llr_in),
        .llr_in_valid         (llr_in_valid),
        .llr_in_ready         (llr_in_ready),
        .load_busy            (load_busy),
        .load_done            (load_done),

        .path_init            (path_init),
        .path_active_bus      (path_active_bus),
        .path_remap_en        (prune_commit_en),
        .remap_parent_bus     (sel_parent_bus),
        .remap_valid_bus      (sel_valid_bus),

        .rd_req               (llr_rd_req),
        .rd_depth             (llr_rd_depth),
        .rd_addr_a            (llr_rd_addr_a),
        .rd_addr_b            (llr_rd_addr_b),
        .rd_valid             (llr_rd_valid),
        .rd_data_a_bus        (llr_rd_data_a_bus),
        .rd_data_b_bus        (llr_rd_data_b_bus),

        .wr_depth             (llr_wr_depth),
        .wr_addr              (llr_wr_addr),
        .wr_en_bus            (llr_wr_en_bus),
        .wr_data_bus          (pe_result_bus),
        .write_conflict       (llr_write_conflict)
    );

    // =========================================================================
    // beta read valid and PE alignment pipeline
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            beta_rd_valid <= 1'b0;
        else
            beta_rd_valid <= beta_rd_req;
    end

    wire [LIST_SIZE-1:0] pe_beta_bus;
    wire                 pe_beta_valid;
    wire                 pe_mode_g_aligned;

    generate
        if (REGISTER_LLR_READ_OUTPUT == 0) begin : g_pe_align_one_cycle
            reg pe_mode_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    pe_mode_q <= 1'b0;
                else if (llr_rd_req)
                    pe_mode_q <= pe_mode_g;
            end

            assign pe_mode_g_aligned = pe_mode_q;
            assign pe_beta_bus       = beta_rd_data_a_bus;
            assign pe_beta_valid     = beta_rd_valid;
        end
        else begin : g_pe_align_two_cycle
            reg pe_mode_q1;
            reg pe_mode_q2;
            reg [LIST_SIZE-1:0] beta_data_q;
            reg                 beta_valid_q;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    pe_mode_q1 <= 1'b0;
                    pe_mode_q2 <= 1'b0;
                    beta_data_q <= {LIST_SIZE{1'b0}};
                    beta_valid_q <= 1'b0;
                end
                else begin
                    if (llr_rd_req)
                        pe_mode_q1 <= pe_mode_g;

                    pe_mode_q2 <= pe_mode_q1;
                    beta_valid_q <= beta_rd_valid;

                    if (beta_rd_valid)
                        beta_data_q <= beta_rd_data_a_bus;
                end
            end

            assign pe_mode_g_aligned = pe_mode_q2;
            assign pe_beta_bus       = beta_data_q;
            assign pe_beta_valid     = beta_valid_q;
        end
    endgenerate

    assign pe_result_valid =
        llr_rd_valid && (!pe_mode_g_aligned || pe_beta_valid);

    // =========================================================================
    // Parallel PE array
    // =========================================================================

    genvar pe_p;
    generate
        for (pe_p = 0; pe_p < LIST_SIZE; pe_p = pe_p + 1) begin : g_pe
            sc_pe #(
                .W(INT_W)
            ) u_sc_pe (
                .a      (llr_rd_data_a_bus[pe_p*INT_W +: INT_W]),
                .b      (llr_rd_data_b_bus[pe_p*INT_W +: INT_W]),
                .mode_g (pe_mode_g_aligned),
                .beta   (pe_beta_bus[pe_p]),
                .y      (pe_result_bus[pe_p*INT_W +: INT_W])
            );
        end
    endgenerate

    // =========================================================================
    // beta source selection
    // =========================================================================

    reg [LIST_SIZE-1:0] beta_selected_reg;
    integer beta_p;

    always @* begin
        beta_selected_reg = {LIST_SIZE{1'b0}};

        for (beta_p = 0; beta_p < LIST_SIZE; beta_p = beta_p + 1) begin
            case (beta_wr_mode)
                BETA_SRC_DIRECT:
                    beta_selected_reg[beta_p] = beta_wr_direct_bus[beta_p];

                BETA_SRC_XOR:
                    beta_selected_reg[beta_p] =
                        beta_rd_data_a_bus[beta_p] ^ beta_rd_data_b_bus[beta_p];

                BETA_SRC_A:
                    beta_selected_reg[beta_p] = beta_rd_data_a_bus[beta_p];

                BETA_SRC_B:
                    beta_selected_reg[beta_p] = beta_rd_data_b_bus[beta_p];

                default:
                    beta_selected_reg[beta_p] = 1'b0;
            endcase
        end
    end

    assign beta_selected_data_bus = beta_selected_reg;

    wire beta_source_ready;
    assign beta_source_ready =
        (beta_wr_mode == BETA_SRC_DIRECT) || beta_rd_valid;

    assign beta_write_accepted = beta_wr_en && beta_source_ready;

    // =========================================================================
    // Balanced path-state memory
    // =========================================================================

    wire [LIST_SIZE-1:0] fixed_zero_bus;
    assign fixed_zero_bus = {LIST_SIZE{1'b0}};

    scl_path_mem #(
        .NMAX      (NMAX),
        .MAX_LOG   (MAX_LOG),
        .LIST_SIZE (LIST_SIZE),
        .PATH_W    (PATH_W),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    ) u_scl_path_mem (
        .clk                  (clk),
        .rst_n                (rst_n),

        .path_init            (path_init),
        .path_active_bus      (path_active_bus),

        .clone_commit_en      (prune_commit_en),
        .clone_parent_bus     (sel_parent_bus),
        .clone_bit_bus        (sel_bit_bus),
        .clone_valid_bus      (sel_valid_bus),
        .clone_leaf_index     (leaf_index),
        .clone_leaf_beta_addr (leaf_beta_addr),

        .leaf_write_en        (fixed_leaf_fire),
        .leaf_bit_bus         (fixed_zero_bus),
        .leaf_index           (leaf_index),
        .leaf_beta_addr       (leaf_beta_addr),

        .beta_rd_addr_a       (beta_rd_addr_a),
        .beta_rd_addr_b       (beta_rd_addr_b),
        .beta_rd_data_a_bus   (beta_rd_data_a_bus),
        .beta_rd_data_b_bus   (beta_rd_data_b_bus),

        .beta_wr_en           (beta_write_accepted),
        .beta_wr_addr         (beta_wr_addr),
        .beta_wr_data_bus     (beta_selected_reg),
        .beta_wr_commit       (beta_wr_commit && beta_write_accepted),

        .output_start         (output_start),
        .n_log                (n_log),
        .output_path          (output_path),
        .output_busy          (output_busy),
        .output_done          (output_done),
        .u_valid              (u_valid),
        .u_ready              (u_ready),
        .u_bit                (u_bit),
        .u_index              (u_index),
        .u_last               (u_last)
    );

endmodule
