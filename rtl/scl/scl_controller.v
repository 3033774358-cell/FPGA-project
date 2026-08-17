`timescale 1ns/1ps

// =============================================================================
// scl_controller.v
// =============================================================================
// Shared DFS controller for one Polar SCL sub-block.
//
// This controller is matched to the current balanced scl_datapath interface:
//   * synchronous LLR request/valid protocol;
//   * one-cycle synchronous beta read protocol;
//   * LIST_SIZE parallel PE lanes, one PE per logical path;
//   * registered external scl_pruner;
//   * balanced scl_path_mem beta mapping and survivor traceback.
//
// Tree schedule
// -----------------------------------------------------------------------------
//   PH_F: generate the complete left-child LLR layer.
//   PH_G: preserve beta_left in the parent low half and generate the complete
//         right-child LLR layer.
//   PH_C: merge beta_right with the preserved beta_left.
//
// The controller deliberately allows only one LLR operation in flight.  All
// logical paths still execute in parallel through the LIST_SIZE PE lanes.  This
// keeps the controller simple and deterministic while preserving the required
// path-level parallelism.
//
// Known-zero rule
// -----------------------------------------------------------------------------
// frozen_bits[i] = 1 always forces u[i]=0.
// For non-frozen positions, the first known_zero_count_cfg positions in natural
// non-frozen order are also forced to zero, but remain non-frozen Polar slots.
// Later non-frozen positions are split and passed to scl_pruner.
//
// Important timing contracts
// -----------------------------------------------------------------------------
// * llr_rd_req is a one-cycle request. The datapath converts the synchronous
//   LLR response into pe_result_valid; llr_wr_en is asserted only when that
//   PE result-valid pulse is returned.
// * During PH_G, beta_left is written when beta_rd_valid arrives; the PE result
//   may arrive later when REGISTER_LLR_READ_OUTPUT=1.
// * beta_wr_commit is asserted on the last PH_G beta-left preservation write
//   and on the last PH_C high-half write.
// * prune_in_valid is asserted only in the leaf_eval_valid cycle.  The supplied
//   scl_pruner has in_ready permanently high.
// * prune_commit_en is asserted only with the registered prune_out_valid pulse.
// =============================================================================

module scl_controller #(
    parameter integer NMAX      = 1024,
    parameter integer MAX_LOG   = 10,
    parameter integer LIST_SIZE = 4,

    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),

    parameter integer DEPTH_W =
        ((MAX_LOG + 1) <= 2) ? 1 : $clog2(MAX_LOG + 1),

    parameter integer MEM_DEPTH = 2 * NMAX - 1,
    parameter integer ADDR_W    = $clog2(MEM_DEPTH),
    parameter integer INDEX_W   = $clog2(NMAX) + 1
)(
    input  wire                              clk,
    input  wire                              rst_n,

    // -------------------------------------------------------------------------
    // Decode configuration and status
    // -------------------------------------------------------------------------
    input  wire                              decode_start,
    input  wire [3:0]                        n_log,
    input  wire [NMAX-1:0]                   frozen_bits,
    input  wire [INDEX_W-1:0]                known_zero_count_cfg,

    output reg                               decode_busy,
    output reg                               decode_done,
    output reg                               decode_error,

    // Start a new sub-block path state: path0 active, PM0=0.
    output reg                               path_init,

    // -------------------------------------------------------------------------
    // LLR request/response and PE writeback
    // -------------------------------------------------------------------------
    output reg                               llr_rd_req,
    output reg  [DEPTH_W-1:0]                llr_rd_depth,
    output reg  [ADDR_W-1:0]                 llr_rd_addr_a,
    output reg  [ADDR_W-1:0]                 llr_rd_addr_b,
    output reg                               pe_mode_g,
    input  wire                              pe_result_valid,

    output reg                               llr_wr_en,
    output reg  [DEPTH_W-1:0]                llr_wr_depth,
    output reg  [ADDR_W-1:0]                 llr_wr_addr,
    input  wire                              llr_write_conflict,

    // -------------------------------------------------------------------------
    // beta request/response and writeback
    // -------------------------------------------------------------------------
    output reg                               beta_rd_req,
    output reg  [ADDR_W-1:0]                 beta_rd_addr_a,
    output reg  [ADDR_W-1:0]                 beta_rd_addr_b,
    input  wire                              beta_rd_valid,

    output reg                               beta_wr_en,
    output reg  [ADDR_W-1:0]                 beta_wr_addr,
    output reg  [LIST_SIZE-1:0]              beta_wr_direct_bus,
    output reg  [1:0]                        beta_wr_mode,
    output reg                               beta_wr_commit,
    input  wire                              beta_write_accepted,

    // -------------------------------------------------------------------------
    // Leaf operation
    // -------------------------------------------------------------------------
    output reg  [INDEX_W-1:0]                leaf_index,
    output reg  [ADDR_W-1:0]                 leaf_beta_addr,
    input  wire                              leaf_eval_valid,
    output reg                               fixed_leaf_commit_en,

    // -------------------------------------------------------------------------
    // External registered scl_pruner handshake
    // -------------------------------------------------------------------------
    output reg                               prune_in_valid,
    input  wire                              prune_in_ready,
    input  wire                              prune_out_valid,
    output reg                               prune_commit_en,

    // -------------------------------------------------------------------------
    // Best path and natural-order output control
    // -------------------------------------------------------------------------
    input  wire                              best_valid,
    input  wire [PATH_W-1:0]                 best_path,

    output reg                               output_start,
    output reg  [PATH_W-1:0]                 output_path,
    input  wire                              output_done
);

    // =========================================================================
    // Constants
    // =========================================================================

    localparam [1:0] PH_F = 2'b00;
    localparam [1:0] PH_G = 2'b01;
    localparam [1:0] PH_C = 2'b10;

    localparam [1:0] BETA_SRC_DIRECT = 2'b00;
    localparam [1:0] BETA_SRC_XOR    = 2'b01;
    localparam [1:0] BETA_SRC_A      = 2'b10;
    localparam [1:0] BETA_SRC_B      = 2'b11;

    localparam [3:0] ST_IDLE         = 4'd0;
    localparam [3:0] ST_INIT         = 4'd1;
    localparam [3:0] ST_DISPATCH     = 4'd2;
    localparam [3:0] ST_F_REQ        = 4'd3;
    localparam [3:0] ST_F_WAIT       = 4'd4;
    localparam [3:0] ST_G_REQ        = 4'd5;
    localparam [3:0] ST_G_WAIT       = 4'd6;
    localparam [3:0] ST_LEAF_REQ     = 4'd7;
    localparam [3:0] ST_LEAF_WAIT    = 4'd8;
    localparam [3:0] ST_PRUNE_WAIT   = 4'd9;
    localparam [3:0] ST_C_LOW_REQ    = 4'd10;
    localparam [3:0] ST_C_LOW_WAIT   = 4'd11;
    localparam [3:0] ST_C_HIGH_REQ   = 4'd12;
    localparam [3:0] ST_C_HIGH_WAIT  = 4'd13;
    localparam [3:0] ST_OUTPUT_START = 4'd14;
    localparam [3:0] ST_OUTPUT_WAIT  = 4'd15;

    // =========================================================================
    // Configuration and DFS state
    // =========================================================================

    reg [3:0]               state;
    reg [3:0]               n_log_q;
    reg [NMAX-1:0]          frozen_bits_q;
    reg [INDEX_W-1:0]       known_zero_count_q;

    reg [DEPTH_W-1:0]       cur_depth;
    reg [INDEX_W-1:0]       element_index;
    reg [INDEX_W-1:0]       current_leaf;
    reg [INDEX_W-1:0]       nonfrozen_seen;

    reg [1:0]               phase [0:MAX_LOG];

    // PH_G has two independently timed results: beta copy and PE writeback.
    reg                     g_beta_done;
    reg                     g_pe_done;

    integer reset_i;

    // =========================================================================
    // Address helpers and current geometry
    // =========================================================================

    function [ADDR_W-1:0] depth_base;
        input integer depth_value;
        integer base_value;
        begin
            if (depth_value <= 0)
                base_value = 0;
            else
                base_value = (2 * NMAX) -
                             (NMAX >> (depth_value - 1));

            depth_base = base_value[ADDR_W-1:0];
        end
    endfunction

    integer current_half_int;
    integer parent_base_int;
    integer child_base_int;
    integer leaf_base_int;
    integer parent_addr_a_int;
    integer parent_addr_b_int;
    integer child_addr_int;
    integer beta_parent_low_int;
    integer beta_parent_high_int;
    integer beta_child_int;

    reg current_leaf_frozen;
    reg current_leaf_known_zero;
    reg current_leaf_fixed;
    reg current_element_last;

    always @* begin
        current_half_int = 0;

        if (cur_depth < n_log_q)
            current_half_int = 1 << (n_log_q - cur_depth - 1);

        parent_base_int = depth_base(cur_depth);

        if (cur_depth < MAX_LOG)
            child_base_int = depth_base(cur_depth + 1'b1);
        else
            child_base_int = depth_base(MAX_LOG);

        leaf_base_int = depth_base(n_log_q);

        parent_addr_a_int = parent_base_int + element_index;
        parent_addr_b_int = parent_base_int + current_half_int + element_index;
        child_addr_int    = child_base_int + element_index;

        beta_parent_low_int  = parent_base_int + element_index;
        beta_parent_high_int = parent_base_int + current_half_int +
                               element_index;
        beta_child_int       = child_base_int + element_index;

        current_leaf_frozen = 1'b1;
        if (current_leaf < NMAX)
            current_leaf_frozen = frozen_bits_q[current_leaf];

        current_leaf_known_zero =
            (!current_leaf_frozen) &&
            (nonfrozen_seen < known_zero_count_q);

        current_leaf_fixed =
            current_leaf_frozen || current_leaf_known_zero;

        current_element_last = 1'b0;
        if (current_half_int > 0)
            current_element_last =
                (element_index == (current_half_int - 1));
    end

    // =========================================================================
    // Output/control combinational logic
    // =========================================================================

    always @* begin
        decode_busy          = (state != ST_IDLE);

        path_init            = 1'b0;

        llr_rd_req            = 1'b0;
        llr_rd_depth          = {DEPTH_W{1'b0}};
        llr_rd_addr_a         = {ADDR_W{1'b0}};
        llr_rd_addr_b         = {ADDR_W{1'b0}};
        pe_mode_g             = 1'b0;

        llr_wr_en             = 1'b0;
        llr_wr_depth          = {DEPTH_W{1'b0}};
        llr_wr_addr           = {ADDR_W{1'b0}};

        beta_rd_req           = 1'b0;
        beta_rd_addr_a        = {ADDR_W{1'b0}};
        beta_rd_addr_b        = {ADDR_W{1'b0}};

        beta_wr_en            = 1'b0;
        beta_wr_addr          = {ADDR_W{1'b0}};
        beta_wr_direct_bus    = {LIST_SIZE{1'b0}};
        beta_wr_mode          = BETA_SRC_DIRECT;
        beta_wr_commit        = 1'b0;

        leaf_index            = current_leaf;
        leaf_beta_addr        = leaf_base_int[ADDR_W-1:0];
        fixed_leaf_commit_en  = 1'b0;

        prune_in_valid        = 1'b0;
        prune_commit_en       = 1'b0;

        output_start          = 1'b0;

        case (state)
            ST_INIT: begin
                path_init = 1'b1;
            end

            ST_F_REQ: begin
                llr_rd_req    = 1'b1;
                llr_rd_depth  = cur_depth;
                llr_rd_addr_a = parent_addr_a_int[ADDR_W-1:0];
                llr_rd_addr_b = parent_addr_b_int[ADDR_W-1:0];
                pe_mode_g     = 1'b0;
            end

            ST_F_WAIT: begin
                if (pe_result_valid) begin
                    llr_wr_en    = 1'b1;
                    llr_wr_depth = cur_depth + 1'b1;
                    llr_wr_addr  = child_addr_int[ADDR_W-1:0];
                end
            end

            ST_G_REQ: begin
                llr_rd_req    = 1'b1;
                llr_rd_depth  = cur_depth;
                llr_rd_addr_a = parent_addr_a_int[ADDR_W-1:0];
                llr_rd_addr_b = parent_addr_b_int[ADDR_W-1:0];
                pe_mode_g     = 1'b1;

                beta_rd_req    = 1'b1;
                beta_rd_addr_a = beta_child_int[ADDR_W-1:0];
                beta_rd_addr_b = beta_child_int[ADDR_W-1:0];
            end

            ST_G_WAIT: begin
                if (beta_rd_valid && !g_beta_done) begin
                    beta_wr_en     = 1'b1;
                    beta_wr_addr   = beta_parent_low_int[ADDR_W-1:0];
                    beta_wr_mode   = BETA_SRC_A;
                    beta_wr_commit = current_element_last;
                end

                if (pe_result_valid && !g_pe_done) begin
                    llr_wr_en    = 1'b1;
                    llr_wr_depth = cur_depth + 1'b1;
                    llr_wr_addr  = child_addr_int[ADDR_W-1:0];
                end
            end

            ST_LEAF_REQ: begin
                llr_rd_req    = 1'b1;
                llr_rd_depth  = n_log_q;
                llr_rd_addr_a = leaf_base_int[ADDR_W-1:0];
                llr_rd_addr_b = leaf_base_int[ADDR_W-1:0];
                pe_mode_g     = 1'b0;
            end

            ST_LEAF_WAIT: begin
                if (leaf_eval_valid) begin
                    if (current_leaf_fixed)
                        fixed_leaf_commit_en = 1'b1;
                    else if (prune_in_ready)
                        prune_in_valid = 1'b1;
                end
            end

            ST_PRUNE_WAIT: begin
                if (prune_out_valid)
                    prune_commit_en = 1'b1;
            end

            ST_C_LOW_REQ: begin
                beta_rd_req    = 1'b1;
                beta_rd_addr_a = beta_parent_low_int[ADDR_W-1:0];
                beta_rd_addr_b = beta_child_int[ADDR_W-1:0];
            end

            ST_C_LOW_WAIT: begin
                if (beta_rd_valid) begin
                    beta_wr_en   = 1'b1;
                    beta_wr_addr = beta_parent_low_int[ADDR_W-1:0];
                    beta_wr_mode = BETA_SRC_XOR;
                end
            end

            ST_C_HIGH_REQ: begin
                beta_rd_req    = 1'b1;
                beta_rd_addr_a = beta_child_int[ADDR_W-1:0];
                beta_rd_addr_b = beta_child_int[ADDR_W-1:0];
            end

            ST_C_HIGH_WAIT: begin
                if (beta_rd_valid) begin
                    beta_wr_en     = 1'b1;
                    beta_wr_addr   = beta_parent_high_int[ADDR_W-1:0];
                    beta_wr_mode   = BETA_SRC_B;
                    beta_wr_commit = current_element_last;
                end
            end

            ST_OUTPUT_START: begin
                output_start = 1'b1;
            end

            default: begin
                // Defaults are intentional.
            end
        endcase
    end

    // =========================================================================
    // Sequential state machine
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_IDLE;
            n_log_q             <= 4'd0;
            frozen_bits_q       <= {NMAX{1'b1}};
            known_zero_count_q  <= {INDEX_W{1'b0}};

            cur_depth           <= {DEPTH_W{1'b0}};
            element_index       <= {INDEX_W{1'b0}};
            current_leaf        <= {INDEX_W{1'b0}};
            nonfrozen_seen      <= {INDEX_W{1'b0}};

            g_beta_done         <= 1'b0;
            g_pe_done           <= 1'b0;

            output_path         <= {PATH_W{1'b0}};
            decode_done         <= 1'b0;
            decode_error        <= 1'b0;

            for (reset_i = 0; reset_i <= MAX_LOG;
                 reset_i = reset_i + 1)
                phase[reset_i] <= PH_F;
        end
        else begin
            decode_done <= 1'b0;

            // The conflict signal is combinational with the attempted write.
            if (llr_write_conflict)
                decode_error <= 1'b1;

            case (state)
                ST_IDLE: begin
                    cur_depth      <= {DEPTH_W{1'b0}};
                    element_index  <= {INDEX_W{1'b0}};
                    current_leaf   <= {INDEX_W{1'b0}};
                    nonfrozen_seen <= {INDEX_W{1'b0}};
                    g_beta_done    <= 1'b0;
                    g_pe_done      <= 1'b0;

                    if (decode_start) begin
                        decode_error <= 1'b0;

                        if ((n_log >= 1) && (n_log <= MAX_LOG)) begin
                            n_log_q            <= n_log;
                            frozen_bits_q      <= frozen_bits;
                            known_zero_count_q <= known_zero_count_cfg;
                            output_path        <= {PATH_W{1'b0}};

                            for (reset_i = 0; reset_i <= MAX_LOG;
                                 reset_i = reset_i + 1)
                                phase[reset_i] <= PH_F;

                            state <= ST_INIT;
                        end
                        else begin
                            decode_error <= 1'b1;
                        end
                    end
                end

                ST_INIT: begin
                    state <= ST_DISPATCH;
                end

                ST_DISPATCH: begin
                    if (cur_depth == n_log_q)
                        state <= ST_LEAF_REQ;
                    else begin
                        case (phase[cur_depth])
                            PH_F: state <= ST_F_REQ;
                            PH_G: state <= ST_G_REQ;
                            default: state <= ST_C_LOW_REQ;
                        endcase
                    end
                end

                ST_F_REQ: begin
                    state <= ST_F_WAIT;
                end

                ST_F_WAIT: begin
                    if (pe_result_valid) begin
                        if (current_element_last) begin
                            phase[cur_depth] <= PH_G;

                            if (cur_depth < MAX_LOG)
                                phase[cur_depth + 1'b1] <= PH_F;

                            cur_depth     <= cur_depth + 1'b1;
                            element_index <= {INDEX_W{1'b0}};
                        end
                        else begin
                            element_index <= element_index + 1'b1;
                        end

                        state <= ST_DISPATCH;
                    end
                end

                ST_G_REQ: begin
                    g_beta_done <= 1'b0;
                    g_pe_done   <= 1'b0;
                    state       <= ST_G_WAIT;
                end

                ST_G_WAIT: begin
                    if (beta_write_accepted && !g_beta_done)
                        g_beta_done <= 1'b1;

                    if (pe_result_valid && !g_pe_done)
                        g_pe_done <= 1'b1;

                    if ((g_beta_done || beta_write_accepted) &&
                        (g_pe_done || pe_result_valid)) begin

                        g_beta_done <= 1'b0;
                        g_pe_done   <= 1'b0;

                        if (current_element_last) begin
                            phase[cur_depth] <= PH_C;

                            if (cur_depth < MAX_LOG)
                                phase[cur_depth + 1'b1] <= PH_F;

                            cur_depth     <= cur_depth + 1'b1;
                            element_index <= {INDEX_W{1'b0}};
                        end
                        else begin
                            element_index <= element_index + 1'b1;
                        end

                        state <= ST_DISPATCH;
                    end
                end

                ST_LEAF_REQ: begin
                    state <= ST_LEAF_WAIT;
                end

                ST_LEAF_WAIT: begin
                    if (leaf_eval_valid) begin
                        if (current_leaf_fixed) begin
                            if (!current_leaf_frozen)
                                nonfrozen_seen <= nonfrozen_seen + 1'b1;

                            current_leaf  <= current_leaf + 1'b1;
                            element_index <= {INDEX_W{1'b0}};

                            if (cur_depth != 0)
                                cur_depth <= cur_depth - 1'b1;

                            state <= ST_DISPATCH;
                        end
                        else if (prune_in_ready) begin
                            state <= ST_PRUNE_WAIT;
                        end
                        else begin
                            // The current scl_pruner promises in_ready=1.
                            decode_error <= 1'b1;
                        end
                    end
                end

                ST_PRUNE_WAIT: begin
                    if (prune_out_valid) begin
                        nonfrozen_seen <= nonfrozen_seen + 1'b1;
                        current_leaf   <= current_leaf + 1'b1;
                        element_index  <= {INDEX_W{1'b0}};

                        if (cur_depth != 0)
                            cur_depth <= cur_depth - 1'b1;

                        state <= ST_DISPATCH;
                    end
                end

                ST_C_LOW_REQ: begin
                    state <= ST_C_LOW_WAIT;
                end

                ST_C_LOW_WAIT: begin
                    if (beta_write_accepted)
                        state <= ST_C_HIGH_REQ;
                end

                ST_C_HIGH_REQ: begin
                    state <= ST_C_HIGH_WAIT;
                end

                ST_C_HIGH_WAIT: begin
                    if (beta_write_accepted) begin
                        if (current_element_last) begin
                            element_index <= {INDEX_W{1'b0}};

                            if (cur_depth == 0) begin
                                if (best_valid)
                                    output_path <= best_path;
                                else begin
                                    output_path  <= {PATH_W{1'b0}};
                                    decode_error <= 1'b1;
                                end

                                state <= ST_OUTPUT_START;
                            end
                            else begin
                                cur_depth <= cur_depth - 1'b1;
                                state     <= ST_DISPATCH;
                            end
                        end
                        else begin
                            element_index <= element_index + 1'b1;
                            state         <= ST_C_LOW_REQ;
                        end
                    end
                end

                ST_OUTPUT_START: begin
                    state <= ST_OUTPUT_WAIT;
                end

                ST_OUTPUT_WAIT: begin
                    if (output_done) begin
                        decode_done <= 1'b1;
                        state       <= ST_IDLE;
                    end
                end

                default: begin
                    state        <= ST_IDLE;
                    decode_error <= 1'b1;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (NMAX < 2 || ((NMAX & (NMAX - 1)) != 0)) begin
            $display("ERROR(scl_controller): NMAX must be a power of two >= 2.");
            $finish;
        end

        if ((LIST_SIZE < 1) ||
            ((LIST_SIZE & (LIST_SIZE - 1)) != 0)) begin
            $display("ERROR(scl_controller): LIST_SIZE must be a power of two.");
            $finish;
        end

        if (MEM_DEPTH != (2 * NMAX - 1)) begin
            $display("ERROR(scl_controller): MEM_DEPTH must equal 2*NMAX-1.");
            $finish;
        end
    end
`endif

endmodule
