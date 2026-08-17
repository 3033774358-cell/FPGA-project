`timescale 1ns/1ps

// =============================================================================
// scl_path_mem_balanced_complete_v2.v
// =============================================================================
// Timing/area balanced path-state memory for parameterized Polar SCL decoding.
//
// beta strategy
// -----------------------------------------------------------------------------
// * The DFS beta workspace keeps the original flat address layout.
// * Physical beta banks are packed into the RAM word width:
//       beta_ram[address][physical_bank]
// * Two mirrored memories provide two independent read addresses.
// * Each tree depth owns only a logical-path -> physical-bank mapping.
// * Pruning copies mappings only.
// * A beta update transaction writes each logical path directly into physical
//   bank p while reads continue to use the old mapping.  The last write asserts
//   beta_wr_commit and atomically changes that depth mapping to identity.
// * Read-first RAM behavior preserves the old source bit when the current read
//   and write address are equal.  Thus PH_C can read shared left-beta data and
//   write private merged beta data in the same cycle, without copying a layer.
//
// u_hat strategy
// -----------------------------------------------------------------------------
// * No per-path complete u_hat vector and no segmented COW network.
// * At every leaf, one survivor-history word is written:
//       for each destination path: {parent_path, decision_bit}
// * The first output_start after decoding traces all final logical paths in
//   parallel through the history RAM into an NMAX x LIST_SIZE bit cache.
// * Later output_start requests can stream another candidate immediately without
//   repeating traceback, which is useful for block-level CA-SCL CRC checking.
//
// Cost for NMAX=1024, LIST_SIZE=4:
// * beta RAM: two mirrored 2047 x 4 memories (normally 2 RAM blocks)
// * history RAM: 1024 x 12 bits (normally 1 RAM block)
// * beta mapping: 11 x 4 x 2 = 88 bits
// * trace cache: 1024 x 4 = 4096 bits
//
// Timing contract
// -----------------------------------------------------------------------------
// * beta read latency is exactly one clock cycle.
// * Inactive logical paths are masked to zero using a request-aligned mask.
// * beta writes are synchronous.
// * output_busy includes both traceback and streaming.
// * u_valid is asserted only during natural-order streaming.
// =============================================================================

module scl_path_mem #(
    parameter integer NMAX       = 1024,
    parameter integer MAX_LOG    = 10,
    parameter integer LIST_SIZE  = 4,

    parameter integer PATH_W =
        (LIST_SIZE <= 1) ? 1 : $clog2(LIST_SIZE),

    parameter integer MEM_DEPTH  = 2 * NMAX - 1,
    parameter integer ADDR_W     = $clog2(MEM_DEPTH),
    parameter integer INDEX_W    = $clog2(NMAX) + 1
)(
    input  wire                                 clk,
    input  wire                                 rst_n,

    input  wire                                 path_init,
    output reg  [LIST_SIZE-1:0]                 path_active_bus,

    input  wire                                 clone_commit_en,
    input  wire [LIST_SIZE*PATH_W-1:0]          clone_parent_bus,
    input  wire [LIST_SIZE-1:0]                 clone_bit_bus,
    input  wire [LIST_SIZE-1:0]                 clone_valid_bus,
    input  wire [INDEX_W-1:0]                   clone_leaf_index,
    input  wire [ADDR_W-1:0]                    clone_leaf_beta_addr,

    input  wire                                 leaf_write_en,
    input  wire [LIST_SIZE-1:0]                 leaf_bit_bus,
    input  wire [INDEX_W-1:0]                   leaf_index,
    input  wire [ADDR_W-1:0]                    leaf_beta_addr,

    input  wire [ADDR_W-1:0]                    beta_rd_addr_a,
    input  wire [ADDR_W-1:0]                    beta_rd_addr_b,
    output reg  [LIST_SIZE-1:0]                 beta_rd_data_a_bus,
    output reg  [LIST_SIZE-1:0]                 beta_rd_data_b_bus,

    input  wire                                 beta_wr_en,
    input  wire [ADDR_W-1:0]                    beta_wr_addr,
    input  wire [LIST_SIZE-1:0]                 beta_wr_data_bus,

    // Assert together with the final write of one depth-workspace update.
    // After that edge, reads at this depth use physical bank p for path p.
    input  wire                                 beta_wr_commit,

    input  wire                                 output_start,
    input  wire [3:0]                           n_log,
    input  wire [PATH_W-1:0]                    output_path,

    output reg                                  output_busy,
    output reg                                  output_done,

    output wire                                 u_valid,
    input  wire                                 u_ready,
    output wire                                 u_bit,
    output wire [INDEX_W-1:0]                   u_index,
    output wire                                 u_last
);

    localparam integer DEPTH_COUNT = MAX_LOG + 1;
    localparam integer RECORD_W    = PATH_W + 1;
    localparam integer HISTORY_W   = LIST_SIZE * RECORD_W;

    localparam [LIST_SIZE-1:0] PATH0_ACTIVE =
        {{(LIST_SIZE-1){1'b0}}, 1'b1};

    localparam [1:0] OUT_IDLE   = 2'b00;
    localparam [1:0] OUT_TRACE  = 2'b01;
    localparam [1:0] OUT_STREAM = 2'b10;

`ifndef SYNTHESIS
    initial begin
        if (NMAX < 2) begin
            $display("ERROR(scl_path_mem): NMAX must be >= 2.");
            $finish;
        end

        if ((NMAX & (NMAX - 1)) != 0) begin
            $display("ERROR(scl_path_mem): NMAX must be a power of two.");
            $finish;
        end

        if ((LIST_SIZE < 1) ||
            ((LIST_SIZE & (LIST_SIZE - 1)) != 0)) begin
            $display("ERROR(scl_path_mem): LIST_SIZE must be a power of two.");
            $finish;
        end

        if (MEM_DEPTH != (2 * NMAX - 1)) begin
            $display("ERROR(scl_path_mem): MEM_DEPTH must equal 2*NMAX-1.");
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

    function integer addr_to_depth;
        input [ADDR_W-1:0] address_value;
        integer d;
        begin
            addr_to_depth = 0;
            for (d = 1; d <= MAX_LOG; d = d + 1) begin
                if (address_value >= depth_base(d))
                    addr_to_depth = d;
            end
        end
    endfunction

    // =========================================================================
    // beta memory
    // =========================================================================
    // Physical bank id is the bit position in each RAM word.  Two mirrored
    // memories implement two read addresses plus one common write address.

    (* ram_style = "block" *)
    reg [LIST_SIZE-1:0] beta_ram_a [0:MEM_DEPTH-1];

    (* ram_style = "block" *)
    reg [LIST_SIZE-1:0] beta_ram_b [0:MEM_DEPTH-1];

    // beta_map[depth][logical_path] -> physical bank.
    reg [PATH_W-1:0] beta_map [0:DEPTH_COUNT*LIST_SIZE-1];

    reg [LIST_SIZE-1:0] beta_rd_word_a_q;
    reg [LIST_SIZE-1:0] beta_rd_word_b_q;

    reg [PATH_W-1:0] beta_rd_bank_a_q [0:LIST_SIZE-1];
    reg [PATH_W-1:0] beta_rd_bank_b_q [0:LIST_SIZE-1];

    // The active mask belongs to the same request cycle as the captured
    // address and path-to-bank mapping.  Pipeline it together with the RAM
    // request so inactive logical paths always read as zero.
    reg [LIST_SIZE-1:0] beta_rd_active_a_q;
    reg [LIST_SIZE-1:0] beta_rd_active_b_q;

    integer beta_rd_depth_a_int;
    integer beta_rd_depth_b_int;
    integer beta_wr_depth_int;
    integer leaf_depth_int;

    always @* begin
        beta_rd_depth_a_int = addr_to_depth(beta_rd_addr_a);
        beta_rd_depth_b_int = addr_to_depth(beta_rd_addr_b);
        beta_wr_depth_int   = addr_to_depth(beta_wr_addr);
        leaf_depth_int      = n_log;
    end

    // -------------------------------------------------------------------------
    // Route one logical write vector into physical-bank bit positions.
    // Priority matches the state update priority below.
    // -------------------------------------------------------------------------

    reg                  beta_mem_wr_en;
    reg [ADDR_W-1:0]     beta_mem_wr_addr;
    reg [LIST_SIZE-1:0]  beta_mem_wr_word;

    integer route_p;

    always @* begin
        beta_mem_wr_en    = 1'b0;
        beta_mem_wr_addr  = {ADDR_W{1'b0}};
        beta_mem_wr_word  = {LIST_SIZE{1'b0}};

        if (clone_commit_en) begin
            // A leaf workspace is completely overwritten at offset zero.
            // Destination path id is therefore also the new physical bank id.
            beta_mem_wr_en   = 1'b1;
            beta_mem_wr_addr = clone_leaf_beta_addr;

            for (route_p = 0; route_p < LIST_SIZE;
                 route_p = route_p + 1) begin
                if (clone_valid_bus[route_p])
                    beta_mem_wr_word[route_p] = clone_bit_bus[route_p];
            end
        end
        else if (leaf_write_en) begin
            // Fixed/frozen leaves also overwrite the leaf workspace entirely.
            beta_mem_wr_en   = 1'b1;
            beta_mem_wr_addr = leaf_beta_addr;

            for (route_p = 0; route_p < LIST_SIZE;
                 route_p = route_p + 1) begin
                if (path_active_bus[route_p])
                    beta_mem_wr_word[route_p] = leaf_bit_bus[route_p];
            end
        end
        else if (beta_wr_en) begin
            // Streaming private write: destination bank equals logical path id.
            // The active mapping is intentionally not changed until commit.
            beta_mem_wr_en   = 1'b1;
            beta_mem_wr_addr = beta_wr_addr;

            for (route_p = 0; route_p < LIST_SIZE;
                 route_p = route_p + 1) begin
                if (path_active_bus[route_p])
                    beta_mem_wr_word[route_p] =
                        beta_wr_data_bus[route_p];
            end
        end
    end

    // -------------------------------------------------------------------------
    // Synchronous read-first RAM behavior.  Output buses correspond to the
    // read addresses presented in the previous clock cycle.
    // -------------------------------------------------------------------------

    integer rd_sel_p;

    always @(posedge clk) begin
        beta_rd_word_a_q   <= beta_ram_a[beta_rd_addr_a];
        beta_rd_word_b_q   <= beta_ram_b[beta_rd_addr_b];
        beta_rd_active_a_q <= path_active_bus;
        beta_rd_active_b_q <= path_active_bus;

        for (rd_sel_p = 0; rd_sel_p < LIST_SIZE;
             rd_sel_p = rd_sel_p + 1) begin
            beta_rd_bank_a_q[rd_sel_p] <= beta_map[
                beta_rd_depth_a_int*LIST_SIZE + rd_sel_p
            ];

            beta_rd_bank_b_q[rd_sel_p] <= beta_map[
                beta_rd_depth_b_int*LIST_SIZE + rd_sel_p
            ];
        end

        if (beta_mem_wr_en) begin
            beta_ram_a[beta_mem_wr_addr] <= beta_mem_wr_word;
            beta_ram_b[beta_mem_wr_addr] <= beta_mem_wr_word;
        end
    end

    integer beta_out_p;
    integer beta_out_bank_a;
    integer beta_out_bank_b;

    always @* begin
        beta_rd_data_a_bus = {LIST_SIZE{1'b0}};
        beta_rd_data_b_bus = {LIST_SIZE{1'b0}};

        for (beta_out_p = 0; beta_out_p < LIST_SIZE;
             beta_out_p = beta_out_p + 1) begin
            beta_out_bank_a = beta_rd_bank_a_q[beta_out_p];
            beta_out_bank_b = beta_rd_bank_b_q[beta_out_p];

            if (beta_rd_active_a_q[beta_out_p] &&
                (beta_out_bank_a >= 0) &&
                (beta_out_bank_a < LIST_SIZE)) begin
                beta_rd_data_a_bus[beta_out_p] =
                    beta_rd_word_a_q[beta_out_bank_a];
            end

            if (beta_rd_active_b_q[beta_out_p] &&
                (beta_out_bank_b >= 0) &&
                (beta_out_bank_b < LIST_SIZE)) begin
                beta_rd_data_b_bus[beta_out_p] =
                    beta_rd_word_b_q[beta_out_bank_b];
            end
        end
    end

    // =========================================================================
    // Survivor history for u_hat reconstruction
    // =========================================================================

    (* ram_style = "block" *)
    reg [HISTORY_W-1:0] history_mem [0:NMAX-1];

    reg                  history_wr_en;
    reg [INDEX_W-1:0]    history_wr_addr;
    reg [HISTORY_W-1:0]  history_wr_word;

    integer hist_p;
    reg [PATH_W-1:0] hist_parent;

    always @* begin
        history_wr_en   = 1'b0;
        history_wr_addr = {INDEX_W{1'b0}};
        history_wr_word = {HISTORY_W{1'b0}};
        hist_parent     = {PATH_W{1'b0}};

        if (clone_commit_en) begin
            history_wr_en   = 1'b1;
            history_wr_addr = clone_leaf_index;

            for (hist_p = 0; hist_p < LIST_SIZE;
                 hist_p = hist_p + 1) begin
                hist_parent = clone_parent_bus[
                    hist_p*PATH_W +: PATH_W
                ];

                if (clone_valid_bus[hist_p]) begin
                    history_wr_word[
                        hist_p*RECORD_W +: RECORD_W
                    ] = {hist_parent, clone_bit_bus[hist_p]};
                end
            end
        end
        else if (leaf_write_en) begin
            history_wr_en   = 1'b1;
            history_wr_addr = leaf_index;

            for (hist_p = 0; hist_p < LIST_SIZE;
                 hist_p = hist_p + 1) begin
                if (path_active_bus[hist_p]) begin
                    history_wr_word[
                        hist_p*RECORD_W +: RECORD_W
                    ] = {hist_p[PATH_W-1:0], leaf_bit_bus[hist_p]};
                end
            end
        end
    end

    // All final candidates are reconstructed together.  Packing all paths into
    // one RAM word allows one write per traceback cycle.
    (* ram_style = "distributed" *)
    reg [LIST_SIZE-1:0] trace_buffer [0:NMAX-1];

    reg [HISTORY_W-1:0] history_rd_data_q;
    reg [INDEX_W-1:0]   history_rd_index_q;
    reg                 history_rd_valid_q;

    reg [1:0]           output_state;
    reg [INDEX_W-1:0]   active_n_q;
    reg [INDEX_W-1:0]   trace_issue_index_q;
    reg                 trace_issue_valid_q;
    reg [PATH_W-1:0]    trace_path_q [0:LIST_SIZE-1];
    reg [PATH_W-1:0]    output_path_q;
    reg [PATH_W-1:0]    pending_output_path_q;
    reg [INDEX_W-1:0]   output_index_q;
    reg                 trace_cache_valid_q;

    reg [LIST_SIZE-1:0]        trace_capture_bits;
    reg [LIST_SIZE*PATH_W-1:0] trace_capture_parent_bus;
    reg [RECORD_W-1:0]         trace_record_temp;
    integer                     trace_capture_p;

    always @* begin
        trace_capture_bits       = {LIST_SIZE{1'b0}};
        trace_capture_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
        trace_record_temp        = {RECORD_W{1'b0}};

        for (trace_capture_p = 0; trace_capture_p < LIST_SIZE;
             trace_capture_p = trace_capture_p + 1) begin
            trace_record_temp = history_rd_data_q >>
                (trace_path_q[trace_capture_p] * RECORD_W);

            trace_capture_bits[trace_capture_p] =
                trace_record_temp[0];

            trace_capture_parent_bus[
                trace_capture_p*PATH_W +: PATH_W
            ] = trace_record_temp[RECORD_W-1:1];
        end
    end

    // History write port and synchronous traceback read port.
    always @(posedge clk) begin
        if (history_wr_en)
            history_mem[history_wr_addr] <= history_wr_word;

        if ((output_state == OUT_TRACE) && trace_issue_valid_q) begin
            history_rd_data_q  <= history_mem[trace_issue_index_q];
            history_rd_index_q <= trace_issue_index_q;
        end
    end

    assign u_valid = (output_state == OUT_STREAM);
    assign u_index = output_index_q;
    assign u_bit   = trace_buffer[output_index_q][output_path_q];
    assign u_last  = (output_state == OUT_STREAM) &&
                     (output_index_q == (active_n_q - 1'b1));

    // =========================================================================
    // Path mappings, path activity, and output traceback/stream control
    // =========================================================================

    integer map_d;
    integer map_p;
    integer parent_i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            path_active_bus    <= PATH0_ACTIVE;

            output_state       <= OUT_IDLE;
            output_busy        <= 1'b0;
            output_done        <= 1'b0;

            active_n_q         <= {INDEX_W{1'b0}};
            trace_issue_index_q <= {INDEX_W{1'b0}};
            trace_issue_valid_q <= 1'b0;
            output_path_q       <= {PATH_W{1'b0}};
            pending_output_path_q <= {PATH_W{1'b0}};
            output_index_q      <= {INDEX_W{1'b0}};
            trace_cache_valid_q <= 1'b0;

            history_rd_valid_q  <= 1'b0;

            for (map_p = 0; map_p < LIST_SIZE;
                 map_p = map_p + 1) begin
                trace_path_q[map_p] <= map_p[PATH_W-1:0];
            end

            for (map_d = 0; map_d < DEPTH_COUNT;
                 map_d = map_d + 1) begin
                for (map_p = 0; map_p < LIST_SIZE;
                     map_p = map_p + 1) begin
                    beta_map[map_d*LIST_SIZE + map_p] <=
                        {PATH_W{1'b0}};
                end
            end

        end
        else begin
            output_done <= 1'b0;

            // -----------------------------------------------------------------
            // Decoder path-state updates
            // -----------------------------------------------------------------
            if (path_init) begin
                path_active_bus    <= PATH0_ACTIVE;
                trace_cache_valid_q <= 1'b0;

                for (map_d = 0; map_d < DEPTH_COUNT;
                     map_d = map_d + 1) begin
                    for (map_p = 0; map_p < LIST_SIZE;
                         map_p = map_p + 1) begin
                        beta_map[map_d*LIST_SIZE + map_p] <=
                            {PATH_W{1'b0}};
                    end
                end
            end
            else if (clone_commit_en) begin
                path_active_bus     <= clone_valid_bus;
                trace_cache_valid_q <= 1'b0;

                for (map_d = 0; map_d < DEPTH_COUNT;
                     map_d = map_d + 1) begin
                    for (map_p = 0; map_p < LIST_SIZE;
                         map_p = map_p + 1) begin
                        parent_i = clone_parent_bus[
                            map_p*PATH_W +: PATH_W
                        ];

                        if (clone_valid_bus[map_p] &&
                            (parent_i < LIST_SIZE)) begin
                            if (map_d == leaf_depth_int) begin
                                // Leaf data is written in this same cycle.
                                beta_map[map_d*LIST_SIZE + map_p] <=
                                    map_p[PATH_W-1:0];
                            end
                            else begin
                                beta_map[map_d*LIST_SIZE + map_p] <=
                                    beta_map[
                                        map_d*LIST_SIZE + parent_i
                                    ];
                            end
                        end
                        else begin
                            beta_map[map_d*LIST_SIZE + map_p] <=
                                {PATH_W{1'b0}};
                        end
                    end
                end
            end
            else if (leaf_write_en) begin
                trace_cache_valid_q <= 1'b0;
                // Leaf workspace starts at offset zero and is overwritten.
                for (map_p = 0; map_p < LIST_SIZE;
                     map_p = map_p + 1) begin
                    if (path_active_bus[map_p]) begin
                        beta_map[
                            leaf_depth_int*LIST_SIZE + map_p
                        ] <= map_p[PATH_W-1:0];
                    end
                end
            end
            else if (beta_wr_en && beta_wr_commit) begin
                // The full update transaction for this depth is complete.
                // All data required by future reads now resides in bank p.
                for (map_p = 0; map_p < LIST_SIZE;
                     map_p = map_p + 1) begin
                    if (path_active_bus[map_p]) begin
                        beta_map[
                            beta_wr_depth_int*LIST_SIZE + map_p
                        ] <= map_p[PATH_W-1:0];
                    end
                end
            end

            // -----------------------------------------------------------------
            // Selected-path traceback and natural-order stream
            // -----------------------------------------------------------------
            case (output_state)
                OUT_IDLE: begin
                    output_busy         <= 1'b0;
                    history_rd_valid_q  <= 1'b0;
                    trace_issue_valid_q <= 1'b0;

                    if (output_start) begin
                        output_busy  <= 1'b1;
                        active_n_q   <=
                            ({{(INDEX_W-1){1'b0}}, 1'b1} << n_log);
                        output_index_q <= {INDEX_W{1'b0}};
                        output_path_q  <= output_path;

                        if (trace_cache_valid_q) begin
                            output_state <= OUT_STREAM;
                        end
                        else begin
                            trace_issue_index_q <=
                                ({{(INDEX_W-1){1'b0}}, 1'b1} << n_log) - 1'b1;
                            trace_issue_valid_q <= 1'b1;
                            pending_output_path_q <= output_path;
                            history_rd_valid_q  <= 1'b0;

                            for (map_p = 0; map_p < LIST_SIZE;
                                 map_p = map_p + 1) begin
                                trace_path_q[map_p] <=
                                    map_p[PATH_W-1:0];
                            end

                            output_state <= OUT_TRACE;
                        end
                    end
                end

                OUT_TRACE: begin
                    output_busy <= 1'b1;

                    // The RAM response from the previous issued address is now
                    // valid.  Store its decision and follow its parent pointer.
                    if (history_rd_valid_q) begin
                        trace_buffer[history_rd_index_q] <=
                            trace_capture_bits;

                        for (map_p = 0; map_p < LIST_SIZE;
                             map_p = map_p + 1) begin
                            trace_path_q[map_p] <=
                                trace_capture_parent_bus[
                                    map_p*PATH_W +: PATH_W
                                ];
                        end

                        if (history_rd_index_q == 0) begin
                            output_index_q       <= {INDEX_W{1'b0}};
                            output_path_q        <= pending_output_path_q;
                            trace_issue_valid_q  <= 1'b0;
                            history_rd_valid_q   <= 1'b0;
                            trace_cache_valid_q  <= 1'b1;
                            output_state         <= OUT_STREAM;
                        end
                    end

                    // Pipeline one history address per clock.
                    history_rd_valid_q <= trace_issue_valid_q;

                    if (trace_issue_valid_q) begin
                        if (trace_issue_index_q == 0)
                            trace_issue_valid_q <= 1'b0;
                        else
                            trace_issue_index_q <=
                                trace_issue_index_q - 1'b1;
                    end
                end

                OUT_STREAM: begin
                    output_busy <= 1'b1;

                    if (u_ready) begin
                        if (output_index_q == (active_n_q - 1'b1)) begin
                            output_index_q <= {INDEX_W{1'b0}};
                            output_busy    <= 1'b0;
                            output_done    <= 1'b1;
                            output_state   <= OUT_IDLE;
                        end
                        else begin
                            output_index_q <= output_index_q + 1'b1;
                        end
                    end
                end

                default: begin
                    output_state <= OUT_IDLE;
                    output_busy  <= 1'b0;
                end
            endcase
        end
    end

endmodule
