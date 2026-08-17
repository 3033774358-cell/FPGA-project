`timescale 1ns/1ps

// =============================================================================
// ca_scl_decoder_top.v
// =============================================================================
// Complete frame decoder for frame types 2 / 3 / 4.
//
// The segmentation rules mirror the uploaded polar_encode_chain exactly:
//
// Frame type 2
//   * no CRC;
//   * table-20/table-24 subdivision;
//   * subblock order 1024 -> 512 -> 256 -> 128 -> 64;
//   * the final insufficient subblock is coded with K = remaining bits
//     (no zero padding), matching the updated encoder.
//
// Frame types 3 / 4
//   * B <= K1024: one logical block, no block CRC;
//   * B > K1024: each logical block has CRC24B;
//   * full blocks use N=1024 and K=K1024;
//   * the last logical block may be split into 512/256/128/64 Polar
//     subblocks, all sharing one continuous
//       front padding || message || CRC24B
//     sequence.
//
// CA-SCL handling
// -----------------------------------------------------------------------------
// One physical scl_decoder_core is reused for all Polar subblocks.
//
// No-CRC subblocks:
//   select the local minimum-PM survivor and emit its message positions.
//
// CRC logical blocks:
//   1. export all local SCL survivors for every Polar subblock;
//   2. combine previous global survivors with current local survivors;
//   3. accumulate PM with saturation;
//   4. update one CRC24B state continuously across split subblocks;
//   5. prune the cross-product back to LIST_SIZE;
//   6. after the final subblock, choose the minimum-PM CRC-passing global
//      candidate;
//   7. if no candidate passes, behavior is selected by CRC_FAIL_FALLBACK:
//      output the minimum-PM fallback with crc_fail, or stop with error.
//
// The CRC rule is fixed:
//   POLY = 24'hB2B117
//   seed = crc_seed
//   update message bits and then received CRC bits, MSB-first
//   final remainder == 0 means pass
//
// External ordering
// -----------------------------------------------------------------------------
// Input encoded LLR stream:
//   g[0], g[1], ..., in the exact code_block_concat output order.
//   code bit 0 should normally be mapped to positive LLR and code bit 1 to
//   negative LLR.
//
// Output message stream:
//   a0, a1, ..., a[B-1].
//   Polar frozen bits, front-padding zeros and CRC24B bits are removed.
//
// Verilog-2001, synthesizable, one shared Polar SCL core.
// =============================================================================

module ca_scl_decoder_top #(
    parameter integer NMAX        = 1024,
    parameter integer MSG_MAX     = 2048,
    parameter integer LLR_W       = 8,
    parameter integer INT_W       = 10,
    parameter integer MAX_LOG     = 10,
    parameter integer LIST_SIZE   = 4,
    parameter integer PM_W        = 24,

    // The uploaded type-3/4 last-block rule can select at most four Polar
    // subblocks because q[3:0] selects 512/256/128/64 once each.
    parameter integer MAX_CB_SUBBLOCKS = 4,

    // 1: if no candidate passes CRC24B, output the deterministic
    //    minimum-PM candidate and assert crc_fail.
    // 0: stop with error and do not emit that logical block.
    parameter integer CRC_FAIL_FALLBACK = 1,

    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),

    parameter integer INDEX_W = $clog2(NMAX) + 1,

    parameter integer COMBO_MAX = LIST_SIZE * LIST_SIZE,

    parameter integer COMBO_W =
        (COMBO_MAX <= 1) ? 1 : $clog2(COMBO_MAX),

    parameter integer STAGE_W =
        (MAX_CB_SUBBLOCKS <= 1) ? 1 : $clog2(MAX_CB_SUBBLOCKS + 1)
)(
    input  wire                                  clk,
    input  wire                                  rst_n,

    // Frame configuration. Accepted only when cfg_ready=1.
    input  wire                                  cfg_start,
    input  wire [2:0]                            frame_type,
    input  wire [15:0]                           B,
    input  wire [3:0]                            mcs,
    input  wire [23:0]                           crc_seed,

    output wire                                  cfg_ready,
    output reg                                   busy,
    output reg                                   done,
    output reg                                   error,

    // Sticky over the current frame. Cleared on accepted cfg_start.
    // With CRC_FAIL_FALLBACK=1, a CRC-failed logical block emits the
    // deterministic minimum-PM fallback candidate.
    output reg                                   crc_fail,

    // Per-logical-CRC-block result pulse.
    output reg                                   cb_crc_valid,
    output reg                                   cb_crc_pass,

    // Encoded frame LLR stream in code-block-concatenation order.
    input  wire signed [LLR_W-1:0]               s_llr,
    input  wire                                  s_llr_valid,
    output wire                                  s_llr_ready,

    // Reconstructed original message, a0 first.
    output wire                                  m_valid,
    input  wire                                  m_ready,
    output wire                                  m_bit,
    output wire [15:0]                           m_index,
    output wire                                  m_last,

    // Observation/status.
    output reg  [7:0]                            polar_subblock_count,
    output reg  [7:0]                            logical_cb_count,
    output reg  [31:0]                           llr_count
);

    // =========================================================================
    // Protocol lookup tables copied from the uploaded encoder
    // =========================================================================

    function [4:0] tab22_r16;
        input [3:0] m;
        begin
            case (m)
                4'd0, 4'd2:  tab22_r16 = 5'd4;
                4'd1, 4'd3:  tab22_r16 = 5'd6;
                4'd4:        tab22_r16 = 5'd8;
                4'd5, 4'd9:  tab22_r16 = 5'd10;
                4'd6, 4'd10: tab22_r16 = 5'd12;
                4'd7, 4'd11: tab22_r16 = 5'd14;
                4'd8, 4'd12: tab22_r16 = 5'd16;
                default:     tab22_r16 = 5'd8;
            endcase
        end
    endfunction

    function [5:0] tab20;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  tab20 = {2'd0,2'd0,2'd0};
                4'd1:  tab20 = {2'd0,2'd0,2'd1};
                4'd2:  tab20 = {2'd0,2'd0,2'd2};
                4'd3:  tab20 = {2'd0,2'd1,2'd1};
                4'd4:  tab20 = {2'd0,2'd1,2'd2};
                4'd5:  tab20 = {2'd0,2'd2,2'd1};
                4'd6:  tab20 = {2'd0,2'd2,2'd2};
                4'd7:  tab20 = {2'd1,2'd1,2'd1};
                4'd8:  tab20 = {2'd1,2'd1,2'd2};
                4'd9:  tab20 = {2'd1,2'd2,2'd1};
                4'd10: tab20 = {2'd1,2'd2,2'd2};
                4'd11: tab20 = {2'd2,2'd1,2'd1};
                4'd12: tab20 = {2'd2,2'd1,2'd2};
                4'd13: tab20 = {2'd2,2'd2,2'd1};
                default: tab20 = {2'd2,2'd2,2'd2};
            endcase
        end
    endfunction

    function [9:0] tab23;
        input [4:0] r16v;
        input [1:0] nsel;
        begin
            case ({r16v, nsel})
                {5'd4, 2'd0}: tab23 = 10'd96;
                {5'd4, 2'd1}: tab23 = 10'd48;
                {5'd4, 2'd2}: tab23 = 10'd24;
                {5'd4, 2'd3}: tab23 = 10'd12;

                {5'd6, 2'd0}: tab23 = 10'd160;
                {5'd6, 2'd1}: tab23 = 10'd80;
                {5'd6, 2'd2}: tab23 = 10'd40;
                {5'd6, 2'd3}: tab23 = 10'd20;

                {5'd8, 2'd0}: tab23 = 10'd224;
                {5'd8, 2'd1}: tab23 = 10'd112;
                {5'd8, 2'd2}: tab23 = 10'd56;
                {5'd8, 2'd3}: tab23 = 10'd28;

                {5'd10,2'd0}: tab23 = 10'd288;
                {5'd10,2'd1}: tab23 = 10'd144;
                {5'd10,2'd2}: tab23 = 10'd72;
                {5'd10,2'd3}: tab23 = 10'd36;

                {5'd12,2'd0}: tab23 = 10'd352;
                {5'd12,2'd1}: tab23 = 10'd176;
                {5'd12,2'd2}: tab23 = 10'd88;
                {5'd12,2'd3}: tab23 = 10'd44;

                {5'd14,2'd0}: tab23 = 10'd416;
                {5'd14,2'd1}: tab23 = 10'd208;
                {5'd14,2'd2}: tab23 = 10'd104;
                {5'd14,2'd3}: tab23 = 10'd52;

                default:      tab23 = 10'd0;
            endcase
        end
    endfunction

    function [9:0] tab24;
        input [4:0] r16v;
        input [1:0] nsel;
        begin
            case ({r16v, nsel})
                {5'd10,2'd0}: tab24 = 10'd316;
                {5'd10,2'd1}: tab24 = 10'd156;
                {5'd10,2'd2}: tab24 = 10'd74;
                {5'd10,2'd3}: tab24 = 10'd36;

                {5'd12,2'd0}: tab24 = 10'd382;
                {5'd12,2'd1}: tab24 = 10'd189;
                {5'd12,2'd2}: tab24 = 10'd90;
                {5'd12,2'd3}: tab24 = 10'd45;

                {5'd14,2'd0}: tab24 = 10'd446;
                {5'd14,2'd1}: tab24 = 10'd221;
                {5'd14,2'd2}: tab24 = 10'd106;
                {5'd14,2'd3}: tab24 = 10'd53;

                default:      tab24 = 10'd0;
            endcase
        end
    endfunction

    function [10:0] mul012;
        input [1:0] c;
        input [9:0] kval;
        begin
            case (c)
                2'd0:    mul012 = 11'd0;
                2'd1:    mul012 = {1'b0, kval};
                default: mul012 = {kval, 1'b0};
            endcase
        end
    endfunction

    function [23:0] crc24_next;
        input [23:0] r;
        input        din;
        reg          fb;
        begin
            fb = r[23] ^ din;
            crc24_next =
                {r[22:0], 1'b0} ^
                (fb ? 24'hB2B117 : 24'd0);
        end
    endfunction

    function [PM_W-1:0] pm_sat_add;
        input [PM_W-1:0] a;
        input [PM_W-1:0] b;
        reg [PM_W:0] sum_ext;
        begin
            sum_ext = {1'b0, a} + {1'b0, b};

            if (sum_ext[PM_W])
                pm_sat_add = {PM_W{1'b1}};
            else
                pm_sat_add = sum_ext[PM_W-1:0];
        end
    endfunction

    function [10:0] overlap_len;
        input [10:0] seg_base;
        input [10:0] seg_len;
        input [10:0] msg_base;
        input [10:0] msg_len;
        reg [11:0] seg_end;
        reg [11:0] msg_end;
        reg [11:0] ov_start;
        reg [11:0] ov_end;
        begin
            seg_end = {1'b0, seg_base} + {1'b0, seg_len};
            msg_end = {1'b0, msg_base} + {1'b0, msg_len};

            ov_start =
                ({1'b0, seg_base} > {1'b0, msg_base}) ?
                {1'b0, seg_base} : {1'b0, msg_base};

            ov_end =
                (seg_end < msg_end) ? seg_end : msg_end;

            if (ov_end > ov_start)
                overlap_len = ov_end - ov_start;
            else
                overlap_len = 11'd0;
        end
    endfunction

    // =========================================================================
    // Main state encoding
    // =========================================================================

    localparam [5:0]
        ST_IDLE            = 6'd0,

        ST_B_FULL_INIT     = 6'd1,
        ST_B_LAST_INIT     = 6'd2,
        ST_B_QINIT         = 6'd3,
        ST_B_QLOOP         = 6'd4,
        ST_B_SUBNEXT       = 6'd5,

        ST_A_INIT          = 6'd6,
        ST_A_N1024         = 6'd7,
        ST_A_IDX           = 6'd8,
        ST_A_REM           = 6'd9,
        ST_A_N64           = 6'd10,
        ST_A_BLKNEXT       = 6'd11,
        ST_A_PAD           = 6'd12,

        ST_MAKE_DESC       = 6'd13,
        ST_CORE_CFG        = 6'd14,
        ST_CORE_CFG_WAIT   = 6'd15,
        ST_CORE_START      = 6'd16,
        ST_CORE_RUN        = 6'd17,

        ST_LOCAL_OUT_INIT  = 6'd18,
        ST_LOCAL_OUT       = 6'd19,

        ST_GLOBAL_INIT     = 6'd20,
        ST_COMBO_PREP      = 6'd21,
        ST_COMBO_FIND      = 6'd22,
        ST_COMBO_BITS      = 6'd23,

        ST_SEL_PREP        = 6'd24,
        ST_SEL_SCAN        = 6'd25,
        ST_SEL_PICK        = 6'd26,
        ST_SEL_COMMIT      = 6'd27,
        ST_SEL_POST        = 6'd28,

        ST_FINAL_SELECT    = 6'd29,
        ST_TRACEBACK       = 6'd30,
        ST_CRC_OUT_INIT    = 6'd31,
        ST_CRC_OUT         = 6'd32,

        ST_ROUTE           = 6'd33,
        ST_FRAME_DONE      = 6'd34,
        ST_ERROR           = 6'd35;

    localparam [1:0]
        ROUTE_B_FULL = 2'd0,
        ROUTE_B_SUB  = 2'd1,
        ROUTE_A      = 2'd2;

    reg [5:0] state;

    // =========================================================================
    // Latched frame configuration and derived constants
    // =========================================================================

    reg [2:0]  frame_type_l;
    reg [15:0] B_l;
    reg [3:0]  mcs_l;
    reg [23:0] crc_seed_l;
    reg [4:0]  r16;

    wire [10:0] K1024 = {r16, 6'b0};
    wire [10:0] KmL   = K1024 - 11'd24;
    wire [6:0]  Uu    = {(r16 - 5'd1), 2'b0};
    wire [10:0] U16   = {(r16 - 5'd1), 6'b0};

    wire [15:0] r16w    = {11'b0, r16};
    wire [15:0] thr1920 = (r16w << 7) - (r16w << 3);
    wire [15:0] r904    =
        (r16w << 5) +
        (r16w << 4) +
        (r16w << 3) +
        (r16w >> 1);
    wire [15:0] r128w   = (r16w << 3);

    wire cfg_frame_type_valid =
        (frame_type == 3'd2) ||
        (frame_type == 3'd3) ||
        (frame_type == 3'd4);

    wire cfg_type2_rate_valid =
        (frame_type != 3'd2) ||
        (tab22_r16(mcs) == 5'd10) ||
        (tab22_r16(mcs) == 5'd12) ||
        (tab22_r16(mcs) == 5'd14);

    wire cfg_values_valid =
        cfg_frame_type_valid &&
        (mcs <= 4'd12) &&
        (B != 16'd0) &&
        (B <= MSG_MAX) &&
        cfg_type2_rate_valid;

    assign cfg_ready =
        (state == ST_IDLE) || (state == ST_ERROR);

    // =========================================================================
    // Segmentation state
    // =========================================================================

    reg         use_crc;
    reg [15:0]  remaining;
    reg [15:0]  msg_remaining;

    reg [15:0]  tmpx;
    reg [10:0]  Kr;
    reg [4:0]   qv;
    reg [3:0]   subsel;

    reg [3:0]   c1024;
    reg [1:0]   c512;
    reg [1:0]   c256;
    reg [1:0]   c128;
    reg [5:0]   c64;
    reg [15:0]  km;
    reg [3:0]   idxA;
    reg signed [15:0] remA;

    // Logical-code-block sequence metadata.
    reg [10:0] logical_padv;
    reg [10:0] logical_kmsg;
    reg        logical_crc_on;
    reg [10:0] logical_vpos;

    reg [STAGE_W-1:0] crc_stage_idx;

    // Descriptor base generated by segmentation.
    reg [3:0]  base_nlog;
    reg [10:0] base_k;
    reg        base_cb_end;
    reg        base_frame_last;
    reg [1:0]  route_kind;

    // Current Polar subblock descriptor.
    reg [3:0]  desc_nlog;
    reg [10:0] desc_k;
    reg [10:0] desc_known_zero;
    reg [10:0] desc_msg_count;
    reg [10:0] desc_vbase;
    reg        desc_cb_start;
    reg        desc_cb_end;
    reg        desc_frame_last;
    reg        desc_crc_on;

    wire [10:0] pad_remaining_calc =
        (logical_vpos < logical_padv) ?
        (logical_padv - logical_vpos) :
        11'd0;

    wire [10:0] known_zero_calc =
        (pad_remaining_calc > base_k) ?
        base_k :
        pad_remaining_calc;

    wire [10:0] msg_overlap_calc =
        overlap_len(
            logical_vpos,
            base_k,
            logical_padv,
            logical_kmsg
        );

    // =========================================================================
    // Shared SCL core interface
    // =========================================================================

    reg                                   core_config_start;
    wire                                  core_config_ready;
    wire                                  core_config_busy;
    wire                                  core_config_done;
    wire                                  core_config_error;

    reg                                   core_block_start;
    wire                                  core_block_ready;
    wire                                  core_block_busy;
    wire                                  core_block_done;
    wire                                  core_block_error;

    wire signed [LLR_W-1:0]               core_llr_in = s_llr;
    wire                                  core_llr_in_valid;
    wire                                  core_llr_in_ready;

    wire                                  core_u_valid;
    wire                                  core_u_ready;
    wire                                  core_u_bit;
    wire [INDEX_W-1:0]                    core_u_index;
    wire                                  core_u_last;
    wire [PATH_W-1:0]                     core_u_path;
    wire [PM_W-1:0]                       core_u_path_pm;
    wire                                  core_u_path_start;
    wire                                  core_u_path_end;
    wire                                  core_u_nonfrozen;
    wire                                  core_candidate_set_done;

    wire [LIST_SIZE-1:0]                  core_path_active_bus;
    wire [LIST_SIZE*PM_W-1:0]             core_path_pm_bus;
    wire                                  core_best_valid;
    wire [PATH_W-1:0]                     core_best_path;
    wire [PM_W-1:0]                       core_best_pm;

    reg [10:0]                            core_llr_sent;
    reg                                   core_candidate_seen;
    reg                                   core_done_seen;

    assign core_llr_in_valid =
        (state == ST_CORE_RUN) &&
        (core_llr_sent < (11'd1 << desc_nlog)) &&
        s_llr_valid;

    assign s_llr_ready =
        (state == ST_CORE_RUN) &&
        (core_llr_sent < (11'd1 << desc_nlog)) &&
        core_llr_in_ready;

    assign core_u_ready = 1'b1;

    scl_decoder_core #(
        .NMAX                    (NMAX),
        .LLR_W                   (LLR_W),
        .INT_W                   (INT_W),
        .MAX_LOG                 (MAX_LOG),
        .LIST_SIZE               (LIST_SIZE),
        .PM_W                    (PM_W),
        .REGISTER_LLR_READ_OUTPUT(1),
        .REGISTER_PRUNER_OUTPUT  (1),
        .EXPORT_ALL_PATHS        (1)
    ) u_scl_core (
        .clk                  (clk),
        .rst_n                (rst_n),

        .config_start         (core_config_start),
        .n_log_cfg            (desc_nlog),
        .k_cfg                (desc_k),
        .known_zero_count_cfg (desc_known_zero),

        .config_ready         (core_config_ready),
        .config_busy          (core_config_busy),
        .config_done          (core_config_done),
        .config_error         (core_config_error),

        .block_start          (core_block_start),
        .block_ready          (core_block_ready),
        .block_busy           (core_block_busy),
        .block_done           (core_block_done),
        .block_error          (core_block_error),

        .llr_in               (core_llr_in),
        .llr_in_valid         (core_llr_in_valid),
        .llr_in_ready         (core_llr_in_ready),

        .u_valid              (core_u_valid),
        .u_ready              (core_u_ready),
        .u_bit                (core_u_bit),
        .u_index              (core_u_index),
        .u_last               (core_u_last),

        .u_path               (core_u_path),
        .u_path_pm            (core_u_path_pm),
        .u_path_start         (core_u_path_start),
        .u_path_end           (core_u_path_end),
        .u_nonfrozen          (core_u_nonfrozen),
        .candidate_set_done   (core_candidate_set_done),

        .path_active_bus      (core_path_active_bus),
        .path_pm_bus          (core_path_pm_bus),
        .best_valid           (core_best_valid),
        .best_path            (core_best_path),
        .best_pm              (core_best_pm)
    );

    // =========================================================================
    // Local survivor capture
    // =========================================================================

    // stage_bits[(stage * LIST_SIZE) + path][v_index_in_subblock]
    // No reset/whole-bank clear is required for this storage. Every valid
    // exported path overwrites exactly desc_k non-frozen bits before the bank
    // is consumed; local_valid gates all reads. Avoiding a bulk reset keeps the
    // candidate store eligible for memory inference.
    reg [NMAX-1:0] stage_bits
        [0:MAX_CB_SUBBLOCKS*LIST_SIZE-1];

    reg [10:0] stage_k
        [0:MAX_CB_SUBBLOCKS-1];

    reg [10:0] stage_vbase
        [0:MAX_CB_SUBBLOCKS-1];

    reg [PM_W-1:0] local_pm [0:LIST_SIZE-1];
    reg             local_valid [0:LIST_SIZE-1];
    reg [10:0]      local_kcount [0:LIST_SIZE-1];

    wire [STAGE_W-1:0] capture_stage =
        logical_crc_on ? crc_stage_idx : {STAGE_W{1'b0}};

    integer capture_check_i;
    reg local_capture_complete;

    always @* begin
        local_capture_complete = 1'b1;

        for (capture_check_i = 0;
             capture_check_i < LIST_SIZE;
             capture_check_i = capture_check_i + 1) begin
            if (core_path_active_bus[capture_check_i] &&
                (!local_valid[capture_check_i] ||
                 (local_kcount[capture_check_i] != desc_k))) begin
                local_capture_complete = 1'b0;
            end
        end
    end

    // =========================================================================
    // Cross-subblock global candidates
    // =========================================================================

    reg [PM_W-1:0] global_pm [0:LIST_SIZE-1];
    reg [23:0]     global_crc [0:LIST_SIZE-1];
    reg            global_valid [0:LIST_SIZE-1];

    reg [PM_W-1:0] next_global_pm [0:LIST_SIZE-1];
    reg [23:0]     next_global_crc [0:LIST_SIZE-1];
    reg            next_global_valid [0:LIST_SIZE-1];

    reg [PATH_W-1:0] hist_parent
        [0:MAX_CB_SUBBLOCKS*LIST_SIZE-1];

    reg [PATH_W-1:0] hist_local
        [0:MAX_CB_SUBBLOCKS*LIST_SIZE-1];

    reg [PATH_W-1:0] selected_local
        [0:MAX_CB_SUBBLOCKS-1];

    // Cross-product temporary records.
    reg [PM_W-1:0] combo_pm [0:COMBO_MAX-1];
    reg [23:0]     combo_crc [0:COMBO_MAX-1];
    reg [PATH_W-1:0] combo_parent [0:COMBO_MAX-1];
    reg [PATH_W-1:0] combo_local [0:COMBO_MAX-1];
    reg              combo_valid [0:COMBO_MAX-1];
    reg              combo_used [0:COMBO_MAX-1];

    reg [PATH_W:0]  pair_old;
    reg [PATH_W:0]  pair_local;
    reg [COMBO_W:0] combo_count;
    reg [10:0]      combo_bit_idx;
    reg [23:0]      combo_crc_work;
    reg [PM_W-1:0]  combo_pm_work;
    reg [PATH_W-1:0] combo_parent_work;
    reg [PATH_W-1:0] combo_local_work;

    wire combo_current_bit =
        stage_bits[
            crc_stage_idx*LIST_SIZE + combo_local_work
        ][combo_bit_idx];

    wire [11:0] combo_global_vpos =
        {1'b0, stage_vbase[crc_stage_idx]} +
        {1'b0, combo_bit_idx};

    wire combo_feed_crc =
        combo_global_vpos >= {1'b0, logical_padv};

    wire [23:0] combo_crc_after_bit =
        combo_feed_crc ?
        crc24_next(combo_crc_work, combo_current_bit) :
        combo_crc_work;

    // Serial top-L selector.
    reg [PATH_W:0]  select_rank;
    reg [COMBO_W:0] select_scan;
    reg              select_best_found;
    reg [COMBO_W-1:0] select_best_index;
    reg [PM_W-1:0]    select_best_pm;
    reg [PATH_W-1:0]  select_best_parent;
    reg [PATH_W-1:0]  select_best_local;

    wire [COMBO_W-1:0] select_scan_index_safe =
        (select_scan < COMBO_MAX) ?
        select_scan[COMBO_W-1:0] :
        {COMBO_W{1'b0}};

    wire scan_candidate_better =
        combo_valid[select_scan_index_safe] &&
        !combo_used[select_scan_index_safe] &&
        (
            !select_best_found ||
            (combo_pm[select_scan_index_safe] < select_best_pm) ||
            (
                combo_pm[select_scan_index_safe] == select_best_pm &&
                combo_parent[select_scan_index_safe] <
                select_best_parent
            ) ||
            (
                combo_pm[select_scan_index_safe] == select_best_pm &&
                combo_parent[select_scan_index_safe] ==
                select_best_parent &&
                combo_local[select_scan_index_safe] <
                select_best_local
            ) ||
            (
                combo_pm[select_scan_index_safe] == select_best_pm &&
                combo_parent[select_scan_index_safe] ==
                select_best_parent &&
                combo_local[select_scan_index_safe] ==
                select_best_local &&
                select_scan_index_safe < select_best_index
            )
        );

    // =========================================================================
    // Final CRC-assisted candidate selection
    // =========================================================================

    integer final_i;
    reg final_pass_found;
    reg [PATH_W-1:0] final_pass_index;
    reg [PM_W-1:0] final_pass_pm;

    reg final_any_found;
    reg [PATH_W-1:0] final_any_index;
    reg [PM_W-1:0] final_any_pm;

    always @* begin
        final_pass_found = 1'b0;
        final_pass_index = {PATH_W{1'b0}};
        final_pass_pm    = {PM_W{1'b1}};

        final_any_found = 1'b0;
        final_any_index = {PATH_W{1'b0}};
        final_any_pm    = {PM_W{1'b1}};

        for (final_i = 0;
             final_i < LIST_SIZE;
             final_i = final_i + 1) begin

            if (global_valid[final_i]) begin
                if (!final_any_found ||
                    (global_pm[final_i] < final_any_pm) ||
                    (
                        global_pm[final_i] == final_any_pm &&
                        final_i < final_any_index
                    )) begin
                    final_any_found = 1'b1;
                    final_any_index = final_i[PATH_W-1:0];
                    final_any_pm    = global_pm[final_i];
                end

                if ((global_crc[final_i] == 24'd0) &&
                    (
                        !final_pass_found ||
                        (global_pm[final_i] < final_pass_pm) ||
                        (
                            global_pm[final_i] == final_pass_pm &&
                            final_i < final_pass_index
                        )
                    )) begin
                    final_pass_found = 1'b1;
                    final_pass_index = final_i[PATH_W-1:0];
                    final_pass_pm    = global_pm[final_i];
                end
            end
        end
    end

    reg [PATH_W-1:0] final_selected_global;
    reg [STAGE_W-1:0] trace_stage;
    reg [PATH_W-1:0]  trace_global;
    reg [STAGE_W-1:0] final_last_stage;

    // =========================================================================
    // Message output
    // =========================================================================

    reg        m_valid_q;
    reg        m_bit_q;
    reg [15:0] m_index_q;
    reg        m_last_q;

    assign m_valid = m_valid_q;
    assign m_bit   = m_bit_q;
    assign m_index = m_index_q;
    assign m_last  = m_last_q;

    reg [15:0] msg_out_count;

    // Local no-CRC output scanner.
    reg [10:0] local_out_pos;
    reg [PATH_W-1:0] local_selected_path;

    wire [11:0] local_out_vpos =
        {1'b0, desc_vbase} +
        {1'b0, local_out_pos};

    wire local_out_is_message =
        (local_out_vpos >= {1'b0, logical_padv}) &&
        (
            local_out_vpos <
            ({1'b0, logical_padv} + {1'b0, logical_kmsg})
        );

    wire local_out_bit_value =
        stage_bits[local_selected_path][local_out_pos];

    // CRC-selected logical-block output scanner.
    reg [STAGE_W-1:0] crc_out_stage;
    reg [10:0]        crc_out_pos;

    wire [11:0] crc_out_vpos =
        {1'b0, stage_vbase[crc_out_stage]} +
        {1'b0, crc_out_pos};

    wire crc_out_is_message =
        (crc_out_vpos >= {1'b0, logical_padv}) &&
        (
            crc_out_vpos <
            ({1'b0, logical_padv} + {1'b0, logical_kmsg})
        );

    wire crc_out_bit_value =
        stage_bits[
            crc_out_stage*LIST_SIZE +
            selected_local[crc_out_stage]
        ][crc_out_pos];

    // =========================================================================
    // Main sequential machine
    // =========================================================================

    integer ri;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                 <= ST_IDLE;

            frame_type_l          <= 3'd2;
            B_l                   <= 16'd0;
            mcs_l                 <= 4'd0;
            crc_seed_l            <= 24'd0;
            r16                   <= 5'd8;

            busy                  <= 1'b0;
            done                  <= 1'b0;
            error                 <= 1'b0;
            crc_fail              <= 1'b0;
            cb_crc_valid          <= 1'b0;
            cb_crc_pass           <= 1'b0;

            polar_subblock_count  <= 8'd0;
            logical_cb_count      <= 8'd0;
            llr_count             <= 32'd0;
            msg_out_count         <= 16'd0;

            use_crc               <= 1'b0;
            remaining             <= 16'd0;
            msg_remaining         <= 16'd0;

            tmpx                  <= 16'd0;
            Kr                    <= 11'd0;
            qv                    <= 5'd0;
            subsel                <= 4'd0;

            c1024                 <= 4'd0;
            c512                  <= 2'd0;
            c256                  <= 2'd0;
            c128                  <= 2'd0;
            c64                   <= 6'd0;
            km                    <= 16'd0;
            idxA                  <= 4'd0;
            remA                  <= 16'sd0;

            logical_padv          <= 11'd0;
            logical_kmsg          <= 11'd0;
            logical_crc_on        <= 1'b0;
            logical_vpos          <= 11'd0;
            crc_stage_idx         <= {STAGE_W{1'b0}};

            base_nlog             <= 4'd6;
            base_k                <= 11'd0;
            base_cb_end           <= 1'b1;
            base_frame_last       <= 1'b1;
            route_kind            <= ROUTE_A;

            desc_nlog             <= 4'd6;
            desc_k                <= 11'd0;
            desc_known_zero       <= 11'd0;
            desc_msg_count        <= 11'd0;
            desc_vbase            <= 11'd0;
            desc_cb_start         <= 1'b0;
            desc_cb_end           <= 1'b0;
            desc_frame_last       <= 1'b0;
            desc_crc_on           <= 1'b0;

            core_config_start     <= 1'b0;
            core_block_start      <= 1'b0;
            core_llr_sent         <= 11'd0;
            core_candidate_seen   <= 1'b0;
            core_done_seen        <= 1'b0;

            pair_old              <= 0;
            pair_local            <= 0;
            combo_count           <= 0;
            combo_bit_idx         <= 0;
            combo_crc_work        <= 24'd0;
            combo_pm_work         <= {PM_W{1'b0}};
            combo_parent_work     <= {PATH_W{1'b0}};
            combo_local_work      <= {PATH_W{1'b0}};

            select_rank           <= 0;
            select_scan           <= 0;
            select_best_found     <= 1'b0;
            select_best_index     <= {COMBO_W{1'b0}};
            select_best_pm        <= {PM_W{1'b1}};
            select_best_parent    <= {PATH_W{1'b1}};
            select_best_local     <= {PATH_W{1'b1}};

            final_selected_global <= {PATH_W{1'b0}};
            trace_stage           <= {STAGE_W{1'b0}};
            trace_global          <= {PATH_W{1'b0}};
            final_last_stage      <= {STAGE_W{1'b0}};

            m_valid_q             <= 1'b0;
            m_bit_q               <= 1'b0;
            m_index_q             <= 16'd0;
            m_last_q              <= 1'b0;

            local_out_pos         <= 11'd0;
            local_selected_path   <= {PATH_W{1'b0}};
            crc_out_stage         <= {STAGE_W{1'b0}};
            crc_out_pos           <= 11'd0;

            for (ri = 0;
                 ri < MAX_CB_SUBBLOCKS*LIST_SIZE;
                 ri = ri + 1) begin
                hist_parent[ri] <= {PATH_W{1'b0}};
                hist_local[ri] <= {PATH_W{1'b0}};
            end

            for (ri = 0;
                 ri < MAX_CB_SUBBLOCKS;
                 ri = ri + 1) begin
                stage_k[ri] <= 11'd0;
                stage_vbase[ri] <= 11'd0;
                selected_local[ri] <= {PATH_W{1'b0}};
            end

            for (ri = 0; ri < LIST_SIZE; ri = ri + 1) begin
                local_pm[ri] <= {PM_W{1'b0}};
                local_valid[ri] <= 1'b0;
                local_kcount[ri] <= 11'd0;

                global_pm[ri] <= {PM_W{1'b0}};
                global_crc[ri] <= 24'd0;
                global_valid[ri] <= 1'b0;

                next_global_pm[ri] <= {PM_W{1'b0}};
                next_global_crc[ri] <= 24'd0;
                next_global_valid[ri] <= 1'b0;
            end

            for (ri = 0; ri < COMBO_MAX; ri = ri + 1) begin
                combo_pm[ri] <= {PM_W{1'b0}};
                combo_crc[ri] <= 24'd0;
                combo_parent[ri] <= {PATH_W{1'b0}};
                combo_local[ri] <= {PATH_W{1'b0}};
                combo_valid[ri] <= 1'b0;
                combo_used[ri] <= 1'b0;
            end
        end
        else begin
            done              <= 1'b0;
            cb_crc_valid      <= 1'b0;
            cb_crc_pass       <= 1'b0;
            core_config_start <= 1'b0;
            core_block_start  <= 1'b0;

            case (state)
                // =============================================================
                // Frame entry and validation
                // =============================================================

                ST_IDLE: begin
                    busy      <= 1'b0;
                    m_valid_q <= 1'b0;
                    m_last_q  <= 1'b0;

                    if (cfg_start) begin
                        if (cfg_values_valid) begin
                            frame_type_l <= frame_type;
                            B_l          <= B;
                            mcs_l        <= mcs;
                            crc_seed_l   <= crc_seed;
                            r16          <= tab22_r16(mcs);

                            busy         <= 1'b1;
                            error        <= 1'b0;
                            crc_fail     <= 1'b0;

                            polar_subblock_count <= 8'd0;
                            logical_cb_count     <= 8'd0;
                            llr_count            <= 32'd0;
                            msg_out_count        <= 16'd0;

                            use_crc      <= 1'b0;
                            remaining    <= B;
                            msg_remaining<= B;

                            if (frame_type == 3'd2)
                                state <= ST_A_INIT;
                            else
                                state <= ST_B_FULL_INIT;
                        end
                        else begin
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end
                    end
                end

                // =============================================================
                // Frame types 3 / 4 segmentation
                // =============================================================

                ST_B_FULL_INIT: begin
                    if ((use_crc && (remaining > {5'b0, KmL})) ||
                        (!use_crc && (remaining > {5'b0, K1024}))) begin

                        use_crc        <= 1'b1;

                        logical_padv   <= 11'd0;
                        logical_kmsg   <= KmL;
                        logical_crc_on <= 1'b1;
                        logical_vpos   <= 11'd0;
                        crc_stage_idx  <= {STAGE_W{1'b0}};

                        base_nlog      <= 4'd10;
                        base_k         <= K1024;
                        base_cb_end    <= 1'b1;
                        base_frame_last<= 1'b0;
                        route_kind     <= ROUTE_B_FULL;

                        state          <= ST_MAKE_DESC;
                    end
                    else begin
                        state <= ST_B_LAST_INIT;
                    end
                end

                ST_B_LAST_INIT: begin
                    logical_kmsg   <= remaining[10:0];
                    logical_crc_on <= use_crc;
                    logical_vpos   <= 11'd0;
                    crc_stage_idx  <= {STAGE_W{1'b0}};

                    Kr <= remaining[10:0] +
                          (use_crc ? 11'd24 : 11'd0);

                    state <= ST_B_QINIT;
                end

                ST_B_QINIT: begin
                    route_kind <= ROUTE_B_SUB;
                    subsel     <= 4'd0;

                    if (r16 == 5'd16) begin
                        logical_padv    <= 11'd0;
                        base_nlog       <= 4'd10;
                        base_k          <= Kr;
                        base_cb_end     <= 1'b1;
                        base_frame_last <= 1'b1;
                        state           <= ST_MAKE_DESC;
                    end
                    else if (Kr > U16) begin
                        logical_padv    <= K1024 - Kr;
                        base_nlog       <= 4'd10;
                        base_k          <= K1024;
                        base_cb_end     <= 1'b1;
                        base_frame_last <= 1'b1;
                        state           <= ST_MAKE_DESC;
                    end
                    else begin
                        tmpx  <= {5'b0, Kr};
                        qv    <= 5'd1;
                        state <= ST_B_QLOOP;
                    end
                end

                ST_B_QLOOP: begin
                    if (tmpx > {9'b0, Uu}) begin
                        tmpx <= tmpx - {9'b0, Uu};
                        qv   <= qv + 1'b1;
                    end
                    else begin
                        logical_padv <= {4'b0, Uu} - tmpx[10:0];

                        if (qv == 5'd16) begin
                            base_nlog       <= 4'd10;
                            base_k          <= U16;
                            base_cb_end     <= 1'b1;
                            base_frame_last <= 1'b1;
                            state           <= ST_MAKE_DESC;
                        end
                        else begin
                            subsel <= qv[3:0];
                            state  <= ST_B_SUBNEXT;
                        end
                    end
                end

                ST_B_SUBNEXT: begin
                    route_kind <= ROUTE_B_SUB;

                    if (subsel[3]) begin
                        base_nlog <= 4'd9;
                        base_k    <= {1'b0, tab23(r16, 2'd0)};
                        subsel[3] <= 1'b0;

                        base_cb_end <=
                            (subsel[2:0] == 3'b000);
                        base_frame_last <=
                            (subsel[2:0] == 3'b000);
                    end
                    else if (subsel[2]) begin
                        base_nlog <= 4'd8;
                        base_k    <= {1'b0, tab23(r16, 2'd1)};
                        subsel[2] <= 1'b0;

                        base_cb_end <=
                            (subsel[1:0] == 2'b00);
                        base_frame_last <=
                            (subsel[1:0] == 2'b00);
                    end
                    else if (subsel[1]) begin
                        base_nlog <= 4'd7;
                        base_k    <= {1'b0, tab23(r16, 2'd2)};
                        subsel[1] <= 1'b0;

                        base_cb_end <=
                            (subsel[0] == 1'b0);
                        base_frame_last <=
                            (subsel[0] == 1'b0);
                    end
                    else begin
                        base_nlog       <= 4'd6;
                        base_k          <= {1'b0, tab23(r16, 2'd3)};
                        subsel[0]       <= 1'b0;
                        base_cb_end     <= 1'b1;
                        base_frame_last <= 1'b1;
                    end

                    state <= ST_MAKE_DESC;
                end

                // =============================================================
                // Frame type 2 segmentation
                // =============================================================

                ST_A_INIT: begin
                    c1024 <= 4'd0;
                    km    <= B_l;

                    if (B_l > thr1920) begin
                        tmpx  <= B_l - r904;
                        state <= ST_A_N1024;
                    end
                    else begin
                        tmpx  <= B_l - 16'd1;
                        idxA  <= 4'd0;
                        state <= ST_A_IDX;
                    end
                end

                ST_A_N1024: begin
                    if (tmpx >= {5'b0, K1024}) begin
                        tmpx   <= tmpx - {5'b0, K1024};
                        km     <= km - {5'b0, K1024};
                        c1024  <= c1024 + 1'b1;
                    end
                    else begin
                        tmpx  <= km - 16'd1;
                        idxA  <= 4'd0;
                        state <= ST_A_IDX;
                    end
                end

                ST_A_IDX: begin
                    if ((tmpx >= r128w) &&
                        (idxA < 4'd14)) begin
                        tmpx <= tmpx - r128w;
                        idxA <= idxA + 1'b1;
                    end
                    else begin
                        {c512, c256, c128} <= tab20(idxA);
                        state <= ST_A_REM;
                    end
                end

                ST_A_REM: begin
                    remA <=
                        $signed({1'b0, km[14:0]}) -
                        $signed({5'b0,
                            mul012(c512, tab24(r16, 2'd0))}) -
                        $signed({5'b0,
                            mul012(c256, tab24(r16, 2'd1))}) -
                        $signed({5'b0,
                            mul012(c128, tab24(r16, 2'd2))});

                    c64  <= 6'd0;
                    state<= ST_A_N64;
                end

                ST_A_N64: begin
                    if ((remA > 0) &&
                        (tab24(r16, 2'd3) != 10'd0)) begin
                        remA <= remA -
                            $signed({5'b0,
                                {1'b0, tab24(r16, 2'd3)}});
                        c64  <= c64 + 1'b1;
                    end
                    else begin
                        state <= ST_A_BLKNEXT;
                    end
                end

                ST_A_BLKNEXT: begin
                    route_kind <= ROUTE_A;

                    logical_crc_on <= 1'b0;
                    logical_vpos   <= 11'd0;
                    crc_stage_idx  <= {STAGE_W{1'b0}};

                    if (c1024 != 0) begin
                        base_nlog <= 4'd10;
                        base_k    <= K1024;
                        c1024     <= c1024 - 1'b1;

                        base_frame_last <=
                            (c1024 == 4'd1) &&
                            (c512 == 0) &&
                            (c256 == 0) &&
                            (c128 == 0) &&
                            (c64 == 0);
                    end
                    else if (c512 != 0) begin
                        base_nlog <= 4'd9;
                        base_k    <= {1'b0, tab24(r16, 2'd0)};
                        c512      <= c512 - 1'b1;

                        base_frame_last <=
                            (c512 == 2'd1) &&
                            (c256 == 0) &&
                            (c128 == 0) &&
                            (c64 == 0);
                    end
                    else if (c256 != 0) begin
                        base_nlog <= 4'd8;
                        base_k    <= {1'b0, tab24(r16, 2'd1)};
                        c256      <= c256 - 1'b1;

                        base_frame_last <=
                            (c256 == 2'd1) &&
                            (c128 == 0) &&
                            (c64 == 0);
                    end
                    else if (c128 != 0) begin
                        base_nlog <= 4'd7;
                        base_k    <= {1'b0, tab24(r16, 2'd2)};
                        c128      <= c128 - 1'b1;

                        base_frame_last <=
                            (c128 == 2'd1) &&
                            (c64 == 0);
                    end
                    else begin
                        base_nlog <= 4'd6;
                        base_k    <= {1'b0, tab24(r16, 2'd3)};
                        c64       <= c64 - 1'b1;

                        base_frame_last <= (c64 == 6'd1);
                    end

                    base_cb_end <= 1'b1;
                    state       <= ST_A_PAD;
                end

                ST_A_PAD: begin
                    if (base_frame_last &&
                        (msg_remaining < {5'b0, base_k})) begin
                        // 类型2最后一码块: K=实际剩余比特, 不补零
                        base_k       <= msg_remaining[10:0];
                        logical_padv <= 11'd0;
                        logical_kmsg <= msg_remaining[10:0];
                    end
                    else begin
                        logical_padv <= 11'd0;
                        logical_kmsg <= base_k;
                    end

                    state <= ST_MAKE_DESC;
                end

                // =============================================================
                // Build and launch one Polar subblock
                // =============================================================

                ST_MAKE_DESC: begin
                    if (logical_crc_on &&
                        (crc_stage_idx >= MAX_CB_SUBBLOCKS)) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end
                    else begin
                        desc_nlog       <= base_nlog;
                        desc_k          <= base_k;
                        desc_known_zero <= known_zero_calc;
                        desc_msg_count  <= msg_overlap_calc;
                        desc_vbase      <= logical_vpos;
                        desc_cb_start   <=
                            (logical_vpos == 11'd0);
                        desc_cb_end     <= base_cb_end;
                        desc_frame_last <= base_frame_last;
                        desc_crc_on     <= logical_crc_on;

                        if (!logical_crc_on &&
                            (logical_vpos == 11'd0)) begin
                            logical_cb_count <=
                                logical_cb_count + 1'b1;
                        end

                        stage_k[capture_stage] <= base_k;
                        stage_vbase[capture_stage] <=
                            logical_vpos;

                        for (ri = 0;
                             ri < LIST_SIZE;
                             ri = ri + 1) begin
                            local_pm[ri] <= {PM_W{1'b0}};
                            local_valid[ri] <= 1'b0;
                            local_kcount[ri] <= 11'd0;

                        end

                        core_llr_sent       <= 11'd0;
                        core_candidate_seen <= 1'b0;
                        core_done_seen      <= 1'b0;

                        state <= ST_CORE_CFG;
                    end
                end

                ST_CORE_CFG: begin
                    if (core_config_ready) begin
                        core_config_start <= 1'b1;
                        state <= ST_CORE_CFG_WAIT;
                    end
                end

                ST_CORE_CFG_WAIT: begin
                    if (core_config_error) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end
                    else if (core_config_done) begin
                        state <= ST_CORE_START;
                    end
                end

                ST_CORE_START: begin
                    if (core_block_ready) begin
                        core_block_start <= 1'b1;
                        state <= ST_CORE_RUN;
                    end
                end

                ST_CORE_RUN: begin
                    if (s_llr_valid && s_llr_ready) begin
                        core_llr_sent <= core_llr_sent + 1'b1;
                        llr_count     <= llr_count + 1'b1;
                    end

                    if (core_u_valid && core_u_ready) begin
                        if (core_u_path_start) begin
                            local_valid[core_u_path] <= 1'b1;
                            local_pm[core_u_path]    <=
                                core_u_path_pm;
                        end

                        if (core_u_nonfrozen) begin
                            stage_bits[
                                capture_stage*LIST_SIZE +
                                core_u_path
                            ][local_kcount[core_u_path]]
                                <= core_u_bit;

                            local_kcount[core_u_path] <=
                                local_kcount[core_u_path] + 1'b1;
                        end
                    end

                    if (core_candidate_set_done)
                        core_candidate_seen <= 1'b1;

                    if (core_block_done)
                        core_done_seen <= 1'b1;

                    if (core_block_error ||
                        core_config_error) begin
                        error <= 1'b1;
                        state <= ST_ERROR;
                    end
                    else if (
                        (core_candidate_seen ||
                         core_candidate_set_done) &&
                        (core_done_seen ||
                         core_block_done)
                    ) begin
                        if ((core_llr_sent != (11'd1 << desc_nlog)) ||
                            !local_capture_complete) begin
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end
                        else begin
                            polar_subblock_count <=
                                polar_subblock_count + 1'b1;

                            if (desc_crc_on) begin
                                if (desc_cb_start)
                                    state <= ST_GLOBAL_INIT;
                                else
                                    state <= ST_COMBO_PREP;
                            end
                            else begin
                                state <= ST_LOCAL_OUT_INIT;
                            end
                        end
                    end
                end

                // =============================================================
                // No-CRC subblock output
                // =============================================================

                ST_LOCAL_OUT_INIT: begin
                    local_selected_path <= core_best_path;
                    local_out_pos       <= 11'd0;
                    m_valid_q           <= 1'b0;
                    m_last_q            <= 1'b0;
                    state               <= ST_LOCAL_OUT;
                end

                ST_LOCAL_OUT: begin
                    if (m_valid_q) begin
                        if (m_ready) begin
                            m_valid_q <= 1'b0;
                            m_last_q  <= 1'b0;

                            local_out_pos <=
                                local_out_pos + 1'b1;
                            msg_out_count <=
                                msg_out_count + 1'b1;
                        end
                    end
                    else if (local_out_pos >= desc_k) begin
                        state <= ST_ROUTE;
                    end
                    else if (!local_out_is_message) begin
                        local_out_pos <= local_out_pos + 1'b1;
                    end
                    else begin
                        m_valid_q <= 1'b1;
                        m_bit_q   <= local_out_bit_value;
                        m_index_q <= msg_out_count;
                        m_last_q  <=
                            (msg_out_count == B_l - 1'b1);
                    end
                end

                // =============================================================
                // Initialize one CRC logical block
                // =============================================================

                ST_GLOBAL_INIT: begin
                    for (ri = 0;
                         ri < LIST_SIZE;
                         ri = ri + 1) begin
                        global_pm[ri]    <= {PM_W{1'b0}};
                        global_crc[ri]   <= 24'd0;
                        global_valid[ri] <= 1'b0;
                    end

                    global_pm[0]    <= {PM_W{1'b0}};
                    global_crc[0]   <= crc_seed_l;
                    global_valid[0] <= 1'b1;

                    logical_cb_count <=
                        logical_cb_count + 1'b1;

                    state <= ST_COMBO_PREP;
                end

                // =============================================================
                // Cross-product generation, serial CRC update
                // =============================================================

                ST_COMBO_PREP: begin
                    pair_old      <= 0;
                    pair_local    <= 0;
                    combo_count   <= 0;
                    combo_bit_idx <= 0;

                    for (ri = 0;
                         ri < COMBO_MAX;
                         ri = ri + 1) begin
                        combo_valid[ri] <= 1'b0;
                        combo_used[ri]  <= 1'b0;
                    end

                    state <= ST_COMBO_FIND;
                end

                ST_COMBO_FIND: begin
                    if (pair_old >= LIST_SIZE) begin
                        state <= ST_SEL_PREP;
                    end
                    else if (pair_local >= LIST_SIZE) begin
                        pair_old   <= pair_old + 1'b1;
                        pair_local <= 0;
                    end
                    else if (
                        global_valid[pair_old[PATH_W-1:0]] &&
                        local_valid[pair_local[PATH_W-1:0]]
                    ) begin
                        combo_parent_work <=
                            pair_old[PATH_W-1:0];
                        combo_local_work  <=
                            pair_local[PATH_W-1:0];

                        combo_pm_work <= pm_sat_add(
                            global_pm[pair_old[PATH_W-1:0]],
                            local_pm[pair_local[PATH_W-1:0]]
                        );

                        combo_crc_work <=
                            global_crc[pair_old[PATH_W-1:0]];

                        combo_bit_idx <= 11'd0;
                        state <= ST_COMBO_BITS;
                    end
                    else begin
                        pair_local <= pair_local + 1'b1;
                    end
                end

                ST_COMBO_BITS: begin
                    combo_crc_work <= combo_crc_after_bit;

                    if (combo_bit_idx == desc_k - 1'b1) begin
                        combo_pm[combo_count[COMBO_W-1:0]]
                            <= combo_pm_work;
                        combo_crc[combo_count[COMBO_W-1:0]]
                            <= combo_crc_after_bit;
                        combo_parent[combo_count[COMBO_W-1:0]]
                            <= combo_parent_work;
                        combo_local[combo_count[COMBO_W-1:0]]
                            <= combo_local_work;
                        combo_valid[combo_count[COMBO_W-1:0]]
                            <= 1'b1;

                        combo_count <= combo_count + 1'b1;
                        pair_local  <= pair_local + 1'b1;
                        state       <= ST_COMBO_FIND;
                    end
                    else begin
                        combo_bit_idx <= combo_bit_idx + 1'b1;
                    end
                end

                // =============================================================
                // Serial top-L selection
                // =============================================================

                ST_SEL_PREP: begin
                    select_rank        <= 0;
                    select_scan        <= 0;
                    select_best_found  <= 1'b0;
                    select_best_index  <= {COMBO_W{1'b0}};
                    select_best_pm     <= {PM_W{1'b1}};
                    select_best_parent <= {PATH_W{1'b1}};
                    select_best_local  <= {PATH_W{1'b1}};

                    for (ri = 0;
                         ri < LIST_SIZE;
                         ri = ri + 1) begin
                        next_global_pm[ri] <=
                            {PM_W{1'b0}};
                        next_global_crc[ri] <= 24'd0;
                        next_global_valid[ri] <= 1'b0;
                    end

                    state <= ST_SEL_SCAN;
                end

                ST_SEL_SCAN: begin
                    if (select_scan < combo_count) begin
                        if (scan_candidate_better) begin
                            select_best_found <= 1'b1;
                            select_best_index <=
                                select_scan_index_safe;
                            select_best_pm <=
                                combo_pm[select_scan_index_safe];
                            select_best_parent <=
                                combo_parent[select_scan_index_safe];
                            select_best_local <=
                                combo_local[select_scan_index_safe];
                        end

                        select_scan <= select_scan + 1'b1;
                    end
                    else begin
                        state <= ST_SEL_PICK;
                    end
                end

                ST_SEL_PICK: begin
                    if (select_best_found &&
                        (select_rank < LIST_SIZE)) begin

                        next_global_pm[
                            select_rank[PATH_W-1:0]
                        ] <= select_best_pm;

                        next_global_crc[
                            select_rank[PATH_W-1:0]
                        ] <= combo_crc[select_best_index];

                        next_global_valid[
                            select_rank[PATH_W-1:0]
                        ] <= 1'b1;

                        hist_parent[
                            crc_stage_idx*LIST_SIZE +
                            select_rank[PATH_W-1:0]
                        ] <= select_best_parent;

                        hist_local[
                            crc_stage_idx*LIST_SIZE +
                            select_rank[PATH_W-1:0]
                        ] <= select_best_local;

                        combo_used[select_best_index] <= 1'b1;

                        if ((select_rank + 1'b1 < LIST_SIZE) &&
                            (select_rank + 1'b1 < combo_count)) begin
                            select_rank <= select_rank + 1'b1;
                            select_scan <= 0;

                            select_best_found <= 1'b0;
                            select_best_index <=
                                {COMBO_W{1'b0}};
                            select_best_pm <= {PM_W{1'b1}};
                            select_best_parent <=
                                {PATH_W{1'b1}};
                            select_best_local <=
                                {PATH_W{1'b1}};

                            state <= ST_SEL_SCAN;
                        end
                        else begin
                            state <= ST_SEL_COMMIT;
                        end
                    end
                    else begin
                        state <= ST_SEL_COMMIT;
                    end
                end

                ST_SEL_COMMIT: begin
                    for (ri = 0;
                         ri < LIST_SIZE;
                         ri = ri + 1) begin
                        global_pm[ri] <= next_global_pm[ri];
                        global_crc[ri] <= next_global_crc[ri];
                        global_valid[ri] <=
                            next_global_valid[ri];
                    end

                    state <= ST_SEL_POST;
                end

                ST_SEL_POST: begin
                    if (desc_cb_end) begin
                        state <= ST_FINAL_SELECT;
                    end
                    else begin
                        crc_stage_idx <= crc_stage_idx + 1'b1;
                        state <= ST_ROUTE;
                    end
                end

                // =============================================================
                // CRC-assisted final choice and survivor-history traceback
                // =============================================================

                ST_FINAL_SELECT: begin
                    cb_crc_valid <= 1'b1;
                    cb_crc_pass  <= final_pass_found;

                    if (final_pass_found) begin
                        final_selected_global <= final_pass_index;
                        trace_global          <= final_pass_index;
                        final_last_stage      <= crc_stage_idx;
                        trace_stage           <= crc_stage_idx;
                        state                 <= ST_TRACEBACK;
                    end
                    else if (final_any_found && CRC_FAIL_FALLBACK) begin
                        final_selected_global <= final_any_index;
                        trace_global          <= final_any_index;
                        final_last_stage      <= crc_stage_idx;
                        trace_stage           <= crc_stage_idx;
                        crc_fail              <= 1'b1;
                        state                 <= ST_TRACEBACK;
                    end
                    else begin
                        crc_fail <= 1'b1;
                        error    <= 1'b1;
                        state    <= ST_ERROR;
                    end
                end

                ST_TRACEBACK: begin
                    selected_local[trace_stage] <=
                        hist_local[
                            trace_stage*LIST_SIZE +
                            trace_global
                        ];

                    trace_global <=
                        hist_parent[
                            trace_stage*LIST_SIZE +
                            trace_global
                        ];

                    if (trace_stage == 0) begin
                        state <= ST_CRC_OUT_INIT;
                    end
                    else begin
                        trace_stage <= trace_stage - 1'b1;
                    end
                end

                ST_CRC_OUT_INIT: begin
                    crc_out_stage <= 0;
                    crc_out_pos   <= 0;
                    m_valid_q     <= 1'b0;
                    m_last_q      <= 1'b0;
                    state         <= ST_CRC_OUT;
                end

                ST_CRC_OUT: begin
                    if (m_valid_q) begin
                        if (m_ready) begin
                            m_valid_q <= 1'b0;
                            m_last_q  <= 1'b0;

                            crc_out_pos <= crc_out_pos + 1'b1;
                            msg_out_count <=
                                msg_out_count + 1'b1;
                        end
                    end
                    else if (
                        crc_out_pos >= stage_k[crc_out_stage]
                    ) begin
                        if (crc_out_stage == final_last_stage) begin
                            state <= ST_ROUTE;
                        end
                        else begin
                            crc_out_stage <=
                                crc_out_stage + 1'b1;
                            crc_out_pos <= 11'd0;
                        end
                    end
                    else if (!crc_out_is_message) begin
                        crc_out_pos <= crc_out_pos + 1'b1;
                    end
                    else begin
                        m_valid_q <= 1'b1;
                        m_bit_q   <= crc_out_bit_value;
                        m_index_q <= msg_out_count;
                        m_last_q  <=
                            (msg_out_count == B_l - 1'b1);
                    end
                end

                // =============================================================
                // Return to segmentation after one decoded subblock/logical CB
                // =============================================================

                ST_ROUTE: begin
                    case (route_kind)
                        ROUTE_B_FULL: begin
                            remaining <= remaining - {5'b0, KmL};
                            state <= ST_B_FULL_INIT;
                        end

                        ROUTE_B_SUB: begin
                            logical_vpos <= logical_vpos + desc_k;

                            if (!desc_cb_end) begin
                                state <= ST_B_SUBNEXT;
                            end
                            else begin
                                state <= ST_FRAME_DONE;
                            end
                        end

                        default: begin
                            if (msg_remaining >
                                {5'b0, desc_msg_count}) begin
                                msg_remaining <=
                                    msg_remaining -
                                    {5'b0, desc_msg_count};
                            end
                            else begin
                                msg_remaining <= 16'd0;
                            end

                            if (desc_frame_last)
                                state <= ST_FRAME_DONE;
                            else
                                state <= ST_A_BLKNEXT;
                        end
                    endcase
                end

                ST_FRAME_DONE: begin
                    if (!m_valid_q) begin
                        if (msg_out_count == B_l) begin
                            done <= 1'b1;
                            busy <= 1'b0;
                            state <= ST_IDLE;
                        end
                        else begin
                            error <= 1'b1;
                            state <= ST_ERROR;
                        end
                    end
                end

                ST_ERROR: begin
                    busy      <= 1'b0;
                    m_valid_q <= 1'b0;
                    m_last_q  <= 1'b0;

                    // Remain here until a new valid cfg_start, allowing a
                    // deterministic recovery without requiring reset.
                    if (cfg_start && cfg_values_valid) begin
                        frame_type_l <= frame_type;
                        B_l          <= B;
                        mcs_l        <= mcs;
                        crc_seed_l   <= crc_seed;
                        r16          <= tab22_r16(mcs);

                        busy         <= 1'b1;
                        error        <= 1'b0;
                        crc_fail     <= 1'b0;

                        polar_subblock_count <= 8'd0;
                        logical_cb_count     <= 8'd0;
                        llr_count            <= 32'd0;
                        msg_out_count        <= 16'd0;

                        use_crc       <= 1'b0;
                        remaining     <= B;
                        msg_remaining <= B;

                        if (frame_type == 3'd2)
                            state <= ST_A_INIT;
                        else
                            state <= ST_B_FULL_INIT;
                    end
                end

                default: begin
                    error <= 1'b1;
                    state <= ST_ERROR;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        if ((LIST_SIZE < 1) ||
            ((LIST_SIZE & (LIST_SIZE - 1)) != 0)) begin
            $display("ERROR(ca_scl_decoder_top): LIST_SIZE must be a power of two.");
            $finish;
        end

        if (NMAX != 1024) begin
            $display("WARNING(ca_scl_decoder_top): uploaded segmentation and reliability rules target NMAX=1024.");
        end

        if (MAX_CB_SUBBLOCKS < 4) begin
            $display("ERROR(ca_scl_decoder_top): MAX_CB_SUBBLOCKS must be at least 4.");
            $finish;
        end

        if ((CRC_FAIL_FALLBACK != 0) &&
            (CRC_FAIL_FALLBACK != 1)) begin
            $display("ERROR(ca_scl_decoder_top): CRC_FAIL_FALLBACK must be 0 or 1.");
            $finish;
        end
    end
`endif

endmodule
