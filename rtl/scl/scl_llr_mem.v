`timescale 1ns/1ps

// =============================================================================
// scl_llr_mem.v
// =============================================================================
// Timing/area-balanced LLR memory for the current scl_datapath interface.
//
// Key points
// -----------------------------------------------------------------------------
// * Root channel LLRs are stored once and shared by all active paths.
// * Intermediate LLRs use LIST_SIZE physical banks and a per-depth
//   logical-path -> physical-bank mapping.
// * Pruning changes only the mapping table; complete LLR vectors are not copied.
// * A target depth is written into identity banks.  The mapping is committed
//   automatically when the final address of the current active-N layer is
//   written.  wr_depth and the N loaded by load_start determine that final
//   address, so N=64/128/256/512/1024 are all handled correctly.
// * write_conflict flags an illegal write sequence, including a transaction
//   that starts at a nonzero layer offset, an unexpected address/depth, or a
//   write outside the selected depth workspace.  Conflicting writes are blocked.
// * Same-address read/write behavior is read-first.
// * REGISTER_READ_OUTPUT=0 gives one-cycle synchronous read latency.
//   REGISTER_READ_OUTPUT=1 adds one output register for two-cycle latency.
// =============================================================================

module scl_llr_mem #(
    parameter integer NMAX          = 1024,
    parameter integer LLR_W         = 8,
    parameter integer INT_W         = 10,
    parameter integer MAX_LOG       = 10,
    parameter integer LIST_SIZE     = 4,

    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),
    parameter integer DEPTH_W =
        ((MAX_LOG + 1) <= 2) ? 1 : $clog2(MAX_LOG + 1),

    parameter integer MEM_DEPTH     = 2 * NMAX - 1,
    parameter integer ADDR_W        = $clog2(MEM_DEPTH),
    parameter integer N_W           = $clog2(NMAX) + 1,

    // Retained for exact compatibility with the current scl_datapath.
    // The present balanced architecture explicitly infers block RAM.
    parameter integer BRAM_MIN_DEPTH = 64,

    // 0: one-cycle read response; 1: two-cycle read response.
    parameter integer REGISTER_READ_OUTPUT = 1,

    // 0: root data is returned only for request-aligned active paths.
    // 1: root data is broadcast to every PE lane.
    parameter integer BROADCAST_ROOT_TO_ALL_PATHS = 0,

    // 0: intermediate reads always use the committed per-depth mapping.
    // 1: while a complete layer overwrite is in progress, reads of that same
    //    depth use identity banks, without committing the mapping early.
    parameter integer INFLIGHT_IDENTITY_READ = 0
)(
    input  wire                                 clk,
    input  wire                                 rst_n,

    // Root-channel LLR serial loading.
    input  wire                                 load_start,
    input  wire [3:0]                           n_log,
    input  wire signed [LLR_W-1:0]              llr_in,
    input  wire                                 llr_in_valid,
    output wire                                 llr_in_ready,
    output reg                                  load_busy,
    output reg                                  load_done,

    // Path state and pruning remap.
    input  wire                                 path_init,
    input  wire [LIST_SIZE-1:0]                 path_active_bus,
    input  wire                                 path_remap_en,
    input  wire [LIST_SIZE*PATH_W-1:0]          remap_parent_bus,
    input  wire [LIST_SIZE-1:0]                 remap_valid_bus,

    // Two common-address synchronous read ports.
    input  wire                                 rd_req,
    input  wire [DEPTH_W-1:0]                   rd_depth,
    input  wire [ADDR_W-1:0]                    rd_addr_a,
    input  wire [ADDR_W-1:0]                    rd_addr_b,
    output reg                                  rd_valid,
    output reg  [LIST_SIZE*INT_W-1:0]           rd_data_a_bus,
    output reg  [LIST_SIZE*INT_W-1:0]           rd_data_b_bus,

    // Common-address, per-path identity-bank write interface.
    input  wire [DEPTH_W-1:0]                   wr_depth,
    input  wire [ADDR_W-1:0]                    wr_addr,
    input  wire [LIST_SIZE-1:0]                 wr_en_bus,
    input  wire [LIST_SIZE*INT_W-1:0]           wr_data_bus,
    output wire                                 write_conflict
);

    localparam integer DEPTH_COUNT = MAX_LOG + 1;
    localparam integer MID_DEPTH   = NMAX - 1;

`ifndef SYNTHESIS
    initial begin
        if (NMAX < 2) begin
            $display("ERROR(scl_llr_mem): NMAX must be >= 2.");
            $finish;
        end
        if ((NMAX & (NMAX - 1)) != 0) begin
            $display("ERROR(scl_llr_mem): NMAX must be a power of two.");
            $finish;
        end
        if ((LIST_SIZE < 1) ||
            ((LIST_SIZE & (LIST_SIZE - 1)) != 0)) begin
            $display("ERROR(scl_llr_mem): LIST_SIZE must be a power of two.");
            $finish;
        end
        if (INT_W < LLR_W) begin
            $display("ERROR(scl_llr_mem): INT_W must be >= LLR_W.");
            $finish;
        end
        if (MEM_DEPTH != (2 * NMAX - 1)) begin
            $display("ERROR(scl_llr_mem): MEM_DEPTH must equal 2*NMAX-1.");
            $finish;
        end
        if ((REGISTER_READ_OUTPUT != 0) &&
            (REGISTER_READ_OUTPUT != 1)) begin
            $display("ERROR(scl_llr_mem): REGISTER_READ_OUTPUT must be 0 or 1.");
            $finish;
        end
        if ((BROADCAST_ROOT_TO_ALL_PATHS != 0) &&
            (BROADCAST_ROOT_TO_ALL_PATHS != 1)) begin
            $display("ERROR(scl_llr_mem): BROADCAST_ROOT_TO_ALL_PATHS must be 0 or 1.");
            $finish;
        end
        if ((INFLIGHT_IDENTITY_READ != 0) &&
            (INFLIGHT_IDENTITY_READ != 1)) begin
            $display("ERROR(scl_llr_mem): INFLIGHT_IDENTITY_READ must be 0 or 1.");
            $finish;
        end
    end
`endif

    // =========================================================================
    // Address helpers
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

    // Number of valid entries in one active-N workspace at a given depth.
    function [N_W-1:0] active_layer_size;
        input [DEPTH_W-1:0] depth_value;
        input [N_W-1:0]     active_n_value;
        integer depth_i;
        reg [N_W-1:0] size_value;
        begin
            depth_i = depth_value;
            if (depth_i > MAX_LOG)
                size_value = {N_W{1'b0}};
            else
                size_value = active_n_value >> depth_i;
            active_layer_size = size_value;
        end
    endfunction

    // =========================================================================
    // Root loading and sign extension
    // =========================================================================

    reg [N_W-1:0] active_n_q;
    reg [N_W-1:0] load_count_q;

    wire signed [INT_W-1:0] llr_in_ext;

    generate
        if (INT_W > LLR_W) begin : g_llr_extend
            assign llr_in_ext = {
                {(INT_W-LLR_W){llr_in[LLR_W-1]}}, llr_in
            };
        end
        else begin : g_llr_same_width
            assign llr_in_ext = llr_in;
        end
    endgenerate

    assign llr_in_ready = load_busy;

    wire llr_in_fire;
    assign llr_in_fire = llr_in_valid && llr_in_ready;

    (* ram_style = "block" *)
    reg signed [INT_W-1:0] root_ram [0:NMAX-1];

    reg signed [INT_W-1:0] root_rd_data_a_q;
    reg signed [INT_W-1:0] root_rd_data_b_q;

    always @(posedge clk) begin
        if (load_busy && llr_in_fire) begin
            root_ram[load_count_q] <= llr_in_ext;
        end
        else if (rd_req && (rd_depth == {DEPTH_W{1'b0}}) &&
                 (rd_addr_a < active_n_q)) begin
            root_rd_data_a_q <= root_ram[rd_addr_a];
        end
    end

    always @(posedge clk) begin
        if (rd_req && (rd_depth == {DEPTH_W{1'b0}}) &&
            (rd_addr_b < active_n_q)) begin
            root_rd_data_b_q <= root_ram[rd_addr_b];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_busy   <= 1'b0;
            load_done   <= 1'b0;
            active_n_q  <= {N_W{1'b0}};
            load_count_q <= {N_W{1'b0}};
        end
        else begin
            load_done <= 1'b0;

            if (load_start && !load_busy) begin
                active_n_q   <= ({{(N_W-1){1'b0}}, 1'b1} << n_log);
                load_count_q <= {N_W{1'b0}};
                load_busy    <= 1'b1;
            end
            else if (load_busy && llr_in_fire) begin
                if (load_count_q == (active_n_q - 1'b1)) begin
                    load_count_q <= {N_W{1'b0}};
                    load_busy    <= 1'b0;
                    load_done    <= 1'b1;
                end
                else begin
                    load_count_q <= load_count_q + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // Write transaction checking and automatic layer commit
    // =========================================================================

    wire                 wr_any;
    wire [N_W-1:0]       wr_layer_size;
    wire [ADDR_W-1:0]    wr_layer_base;
    wire [ADDR_W-1:0]    wr_layer_last;
    wire                 wr_depth_valid;
    wire                 wr_addr_in_layer;

    reg                  wr_txn_active_q;
    reg [DEPTH_W-1:0]    wr_txn_depth_q;
    reg [ADDR_W-1:0]     wr_expected_addr_q;

    assign wr_any = |wr_en_bus;
    assign wr_layer_size = active_layer_size(wr_depth, active_n_q);
    assign wr_layer_base = depth_base(wr_depth);
    assign wr_layer_last = wr_layer_base + wr_layer_size - 1'b1;

    assign wr_depth_valid =
        (wr_depth != {DEPTH_W{1'b0}}) &&
        (wr_depth <= MAX_LOG) &&
        (wr_depth <= n_log) &&
        (wr_layer_size != {N_W{1'b0}});

    assign wr_addr_in_layer =
        wr_depth_valid &&
        (wr_addr >= wr_layer_base) &&
        (wr_addr <= wr_layer_last) &&
        (wr_addr >= NMAX) &&
        (wr_addr < MEM_DEPTH);

    wire wr_sequence_ok;
    assign wr_sequence_ok =
        wr_addr_in_layer &&
        ((!wr_txn_active_q && (wr_addr == wr_layer_base)) ||
         ( wr_txn_active_q &&
           (wr_depth == wr_txn_depth_q) &&
           (wr_addr  == wr_expected_addr_q)));

    assign write_conflict = wr_any &&
                            (load_busy || load_start || !wr_sequence_ok);

    wire wr_accept;
    wire wr_auto_commit;

    assign wr_accept = wr_any && !load_busy && !load_start && wr_sequence_ok;
    assign wr_auto_commit = wr_accept && (wr_addr == wr_layer_last);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_txn_active_q    <= 1'b0;
            wr_txn_depth_q     <= {DEPTH_W{1'b0}};
            wr_expected_addr_q <= {ADDR_W{1'b0}};
        end
        else if (path_init || path_remap_en || load_start) begin
            wr_txn_active_q    <= 1'b0;
            wr_txn_depth_q     <= {DEPTH_W{1'b0}};
            wr_expected_addr_q <= {ADDR_W{1'b0}};
        end
        else if (wr_accept) begin
            if (wr_auto_commit) begin
                wr_txn_active_q    <= 1'b0;
                wr_txn_depth_q     <= {DEPTH_W{1'b0}};
                wr_expected_addr_q <= {ADDR_W{1'b0}};
            end
            else begin
                wr_txn_active_q    <= 1'b1;
                wr_txn_depth_q     <= wr_depth;
                wr_expected_addr_q <= wr_addr + 1'b1;
            end
        end
    end

    // =========================================================================
    // Intermediate physical banks: two mirrors for two synchronous read addresses
    // =========================================================================

    wire [LIST_SIZE*INT_W-1:0] mid_rd_all_a;
    wire [LIST_SIZE*INT_W-1:0] mid_rd_all_b;

    genvar bank_g;
    generate
        for (bank_g = 0; bank_g < LIST_SIZE; bank_g = bank_g + 1) begin : g_llr_bank
            (* ram_style = "block" *)
            reg signed [INT_W-1:0] mid_ram_a [0:MID_DEPTH-1];

            (* ram_style = "block" *)
            reg signed [INT_W-1:0] mid_ram_b [0:MID_DEPTH-1];

            reg signed [INT_W-1:0] mid_rd_a_q;
            reg signed [INT_W-1:0] mid_rd_b_q;

            wire signed [INT_W-1:0] bank_wr_data;
            assign bank_wr_data =
                wr_data_bus[bank_g*INT_W +: INT_W];

            assign mid_rd_all_a[bank_g*INT_W +: INT_W] = mid_rd_a_q;
            assign mid_rd_all_b[bank_g*INT_W +: INT_W] = mid_rd_b_q;

            // Nonblocking read and write in the same process yield read-first
            // simulation semantics for a same-address collision.
            always @(posedge clk) begin
                if (rd_req &&
                    (rd_depth != {DEPTH_W{1'b0}}) &&
                    (rd_addr_a >= NMAX) &&
                    (rd_addr_a < MEM_DEPTH)) begin
                    mid_rd_a_q <= mid_ram_a[rd_addr_a - NMAX];
                end

                if (wr_accept && wr_en_bus[bank_g]) begin
                    mid_ram_a[wr_addr - NMAX] <= bank_wr_data;
                end
            end

            always @(posedge clk) begin
                if (rd_req &&
                    (rd_depth != {DEPTH_W{1'b0}}) &&
                    (rd_addr_b >= NMAX) &&
                    (rd_addr_b < MEM_DEPTH)) begin
                    mid_rd_b_q <= mid_ram_b[rd_addr_b - NMAX];
                end

                if (wr_accept && wr_en_bus[bank_g]) begin
                    mid_ram_b[wr_addr - NMAX] <= bank_wr_data;
                end
            end
        end
    endgenerate

    // =========================================================================
    // Per-depth logical-path -> physical-bank mapping
    // =========================================================================

    reg [PATH_W-1:0] llr_map [0:DEPTH_COUNT*LIST_SIZE-1];

    integer map_d;
    integer map_p;
    integer remap_parent_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (map_d = 0; map_d < DEPTH_COUNT; map_d = map_d + 1) begin
                for (map_p = 0; map_p < LIST_SIZE; map_p = map_p + 1) begin
                    llr_map[map_d*LIST_SIZE + map_p] <= {PATH_W{1'b0}};
                end
            end
        end
        else if (path_init) begin
            for (map_d = 0; map_d < DEPTH_COUNT; map_d = map_d + 1) begin
                for (map_p = 0; map_p < LIST_SIZE; map_p = map_p + 1) begin
                    llr_map[map_d*LIST_SIZE + map_p] <= {PATH_W{1'b0}};
                end
            end
        end
        else if (path_remap_en) begin
            for (map_d = 0; map_d < DEPTH_COUNT; map_d = map_d + 1) begin
                for (map_p = 0; map_p < LIST_SIZE; map_p = map_p + 1) begin
                    remap_parent_i = remap_parent_bus[
                        map_p*PATH_W +: PATH_W
                    ];

                    if (remap_valid_bus[map_p] &&
                        (remap_parent_i < LIST_SIZE)) begin
                        llr_map[map_d*LIST_SIZE + map_p] <=
                            llr_map[map_d*LIST_SIZE + remap_parent_i];
                    end
                    else begin
                        llr_map[map_d*LIST_SIZE + map_p] <=
                            {PATH_W{1'b0}};
                    end
                end
            end
        end
        else if (wr_auto_commit) begin
            for (map_p = 0; map_p < LIST_SIZE; map_p = map_p + 1) begin
                if (path_active_bus[map_p]) begin
                    llr_map[wr_depth*LIST_SIZE + map_p] <=
                        map_p[PATH_W-1:0];
                end
                else begin
                    llr_map[wr_depth*LIST_SIZE + map_p] <=
                        {PATH_W{1'b0}};
                end
            end
        end
    end

    // =========================================================================
    // Request-aligned read metadata
    // =========================================================================

    reg                                  rd_valid_s1_q;
    reg                                  rd_is_root_q;
    reg [LIST_SIZE-1:0]                  rd_active_s1_q;
    reg [PATH_W-1:0]                     rd_bank_q [0:LIST_SIZE-1];

    integer rd_capture_p;
    integer rd_depth_i;

    wire rd_use_inflight_identity;
    assign rd_use_inflight_identity =
        (INFLIGHT_IDENTITY_READ != 0) &&
        wr_txn_active_q &&
        (rd_depth == wr_txn_depth_q);

    always @* begin
        rd_depth_i = rd_depth;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid_s1_q <= 1'b0;
            rd_is_root_q  <= 1'b0;
            rd_active_s1_q <= {LIST_SIZE{1'b0}};

            for (rd_capture_p = 0; rd_capture_p < LIST_SIZE;
                 rd_capture_p = rd_capture_p + 1) begin
                rd_bank_q[rd_capture_p] <= {PATH_W{1'b0}};
            end
        end
        else begin
            rd_valid_s1_q <= rd_req;

            if (rd_req) begin
                rd_is_root_q   <= (rd_depth == {DEPTH_W{1'b0}});
                rd_active_s1_q <= path_active_bus;

                for (rd_capture_p = 0; rd_capture_p < LIST_SIZE;
                     rd_capture_p = rd_capture_p + 1) begin
                    if ((rd_depth == {DEPTH_W{1'b0}}) ||
                        (rd_depth_i > MAX_LOG)) begin
                        rd_bank_q[rd_capture_p] <= {PATH_W{1'b0}};
                    end
                    else if (rd_use_inflight_identity) begin
                        rd_bank_q[rd_capture_p] <=
                            rd_capture_p[PATH_W-1:0];
                    end
                    else begin
                        rd_bank_q[rd_capture_p] <=
                            llr_map[rd_depth_i*LIST_SIZE + rd_capture_p];
                    end
                end
            end
        end
    end

    // =========================================================================
    // Logical-path routing and inactive-path masking
    // =========================================================================

    reg [LIST_SIZE*INT_W-1:0] rd_data_a_s1;
    reg [LIST_SIZE*INT_W-1:0] rd_data_b_s1;

    integer mux_p;
    integer bank_sel_i;

    always @* begin
        rd_data_a_s1 = {LIST_SIZE*INT_W{1'b0}};
        rd_data_b_s1 = {LIST_SIZE*INT_W{1'b0}};

        for (mux_p = 0; mux_p < LIST_SIZE; mux_p = mux_p + 1) begin
            if (rd_is_root_q) begin
                if ((BROADCAST_ROOT_TO_ALL_PATHS != 0) ||
                    rd_active_s1_q[mux_p]) begin
                    rd_data_a_s1[mux_p*INT_W +: INT_W] = root_rd_data_a_q;
                    rd_data_b_s1[mux_p*INT_W +: INT_W] = root_rd_data_b_q;
                end
            end
            else if (rd_active_s1_q[mux_p]) begin
                bank_sel_i = rd_bank_q[mux_p];
                rd_data_a_s1[mux_p*INT_W +: INT_W] =
                    mid_rd_all_a[bank_sel_i*INT_W +: INT_W];
                rd_data_b_s1[mux_p*INT_W +: INT_W] =
                    mid_rd_all_b[bank_sel_i*INT_W +: INT_W];
            end
        end
    end

    // =========================================================================
    // Optional read-output register
    // =========================================================================

    generate
        if (REGISTER_READ_OUTPUT == 0) begin : g_one_cycle_read
            always @* begin
                rd_valid      = rd_valid_s1_q;
                rd_data_a_bus = rd_data_a_s1;
                rd_data_b_bus = rd_data_b_s1;
            end
        end
        else begin : g_two_cycle_read
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    rd_valid      <= 1'b0;
                    rd_data_a_bus <= {LIST_SIZE*INT_W{1'b0}};
                    rd_data_b_bus <= {LIST_SIZE*INT_W{1'b0}};
                end
                else begin
                    rd_valid      <= rd_valid_s1_q;
                    rd_data_a_bus <= rd_data_a_s1;
                    rd_data_b_bus <= rd_data_b_s1;
                end
            end
        end
    endgenerate

endmodule
