`timescale 1ns/1ps

// =============================================================================
// tb_scl_llr_mem.v
// =============================================================================
// Independent self-checking testbench for scl_llr_mem.v.
//
// Default fast regression parameters:
//   NMAX=16, MAX_LOG=4, LIST_SIZE=4, LLR_W=8, INT_W=10
//
// Coverage includes:
//   * reset and path_init
//   * root serial loading and natural d[0]..d[N-1] order
//   * shared root reads and inactive-path masking
//   * two simultaneous logical read addresses and one-cycle rd_valid
//   * first 1->2 pruning remap using remap_valid_bus
//   * shared parent bank, complete identity-bank overwrite and atomic commit
//   * independent path data after commit
//   * second 2->4 pruning remap
//   * four-path inheritance and independent writes
//   * read-first same-address read/write behavior
//   * request-aligned activity-mask behavior
//   * randomized remap/read/write checking against a reference model
// =============================================================================

module tb_scl_llr_mem;

    localparam integer NMAX         = 16;
    localparam integer MAX_LOG      = 4;
    localparam integer LIST_SIZE    = 4;
    localparam integer LLR_W        = 8;
    localparam integer INT_W        = 10;
    localparam integer PATH_W       = 2;
    localparam integer MEM_DEPTH    = 2 * NMAX - 1;
    localparam integer ADDR_W       = 5;
    localparam integer N_W          = 5;
    localparam integer MID_DEPTH    = NMAX - 1;
    localparam integer DEPTH_COUNT  = MAX_LOG + 1;

    reg                                  clk;
    reg                                  rst_n;

    reg                                  path_init;
    reg  [LIST_SIZE-1:0]                 path_active_bus;

    reg                                  load_start;
    reg  [3:0]                           n_log;
    reg  signed [LLR_W-1:0]              llr_in;
    reg                                  llr_in_valid;
    wire                                 llr_in_ready;
    wire                                 load_busy;
    wire                                 load_done;

    reg                                  remap_en;
    reg  [LIST_SIZE*PATH_W-1:0]          remap_parent_bus;
    reg  [LIST_SIZE-1:0]                 remap_valid_bus;

    reg                                  rd_en;
    reg  [ADDR_W-1:0]                    rd_addr_a;
    reg  [ADDR_W-1:0]                    rd_addr_b;
    wire                                 rd_valid;
    wire [LIST_SIZE*INT_W-1:0]           rd_data_a_bus;
    wire [LIST_SIZE*INT_W-1:0]           rd_data_b_bus;

    reg  [LIST_SIZE-1:0]                 wr_en_bus;
    reg  [ADDR_W-1:0]                    wr_addr;
    reg  [LIST_SIZE*INT_W-1:0]           wr_data_bus;
    reg                                  wr_commit;

    integer error_count;
    integer check_count;
    integer seed;
    integer i;
    integer p;
    integer d;
    integer iter;
    integer rand_value;
    integer rand_depth;
    integer rand_offset_a;
    integer rand_offset_b;
    integer rand_tag;

    // Reference model: root, physical intermediate banks and depth mappings.
    integer ref_root [0:NMAX-1];
    integer ref_mid  [0:LIST_SIZE*MID_DEPTH-1];
    integer ref_map  [0:DEPTH_COUNT*LIST_SIZE-1];
    integer ref_map_temp [0:DEPTH_COUNT*LIST_SIZE-1];
    reg [LIST_SIZE-1:0] model_active;

    reg [LIST_SIZE*INT_W-1:0] expected_a;
    reg [LIST_SIZE*INT_W-1:0] expected_b;
    reg [LIST_SIZE*INT_W-1:0] old_data_a;
    reg [LIST_SIZE*INT_W-1:0] old_data_b;

    scl_llr_mem #(
        .NMAX         (NMAX),
        .MAX_LOG      (MAX_LOG),
        .LIST_SIZE    (LIST_SIZE),
        .LLR_W        (LLR_W),
        .INT_W        (INT_W),
        .PATH_W       (PATH_W),
        .MEM_DEPTH    (MEM_DEPTH),
        .ADDR_W       (ADDR_W),
        .N_W          (N_W),
        .EXTRA_RD_REG (0)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),

        .path_init          (path_init),
        .path_active_bus    (path_active_bus),

        .load_start         (load_start),
        .n_log              (n_log),
        .llr_in             (llr_in),
        .llr_in_valid       (llr_in_valid),
        .llr_in_ready       (llr_in_ready),
        .load_busy          (load_busy),
        .load_done          (load_done),

        .remap_en           (remap_en),
        .remap_parent_bus   (remap_parent_bus),
        .remap_valid_bus    (remap_valid_bus),

        .rd_en              (rd_en),
        .rd_addr_a          (rd_addr_a),
        .rd_addr_b          (rd_addr_b),
        .rd_valid           (rd_valid),
        .rd_data_a_bus      (rd_data_a_bus),
        .rd_data_b_bus      (rd_data_b_bus),

        .wr_en_bus          (wr_en_bus),
        .wr_addr            (wr_addr),
        .wr_data_bus        (wr_data_bus),
        .wr_commit          (wr_commit)
    );

    always #5 clk = ~clk;

    // =========================================================================
    // Reference-model helpers
    // =========================================================================

    function integer depth_base_int;
        input integer depth_value;
        begin
            if (depth_value <= 0)
                depth_base_int = 0;
            else
                depth_base_int =
                    (2 * NMAX) - (NMAX >> (depth_value - 1));
        end
    endfunction

    function integer addr_to_depth_int;
        input integer address_value;
        integer fd;
        begin
            addr_to_depth_int = 0;
            for (fd = 1; fd <= MAX_LOG; fd = fd + 1) begin
                if (address_value >= depth_base_int(fd))
                    addr_to_depth_int = fd;
            end
        end
    endfunction

    function [LIST_SIZE*INT_W-1:0] model_read_bus;
        input integer address_value;
        input [LIST_SIZE-1:0] active_mask;
        integer fp;
        integer fdepth;
        integer fbank;
        integer fvalue;
        begin
            model_read_bus = {LIST_SIZE*INT_W{1'b0}};
            fdepth = addr_to_depth_int(address_value);

            for (fp = 0; fp < LIST_SIZE; fp = fp + 1) begin
                if (active_mask[fp]) begin
                    if (address_value < NMAX) begin
                        fvalue = ref_root[address_value];
                    end
                    else begin
                        fbank = ref_map[fdepth*LIST_SIZE + fp];
                        fvalue = ref_mid[
                            fbank*MID_DEPTH + (address_value - NMAX)
                        ];
                    end

                    model_read_bus[fp*INT_W +: INT_W] = fvalue;
                end
            end
        end
    endfunction

    function [LIST_SIZE*INT_W-1:0] make_data_bus;
        input integer v0;
        input integer v1;
        input integer v2;
        input integer v3;
        begin
            make_data_bus = {LIST_SIZE*INT_W{1'b0}};
            make_data_bus[0*INT_W +: INT_W] = v0;
            make_data_bus[1*INT_W +: INT_W] = v1;
            make_data_bus[2*INT_W +: INT_W] = v2;
            make_data_bus[3*INT_W +: INT_W] = v3;
        end
    endfunction

    task print_bus_mismatch;
        input integer test_id;
        input [LIST_SIZE*INT_W-1:0] got_bus;
        input [LIST_SIZE*INT_W-1:0] exp_bus;
        integer tp;
        begin
            $display("FAIL[%0d] t=%0t got_bus=0x%0h expected_bus=0x%0h",
                     test_id, $time, got_bus, exp_bus);
            for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                if (got_bus[tp*INT_W +: INT_W] !==
                    exp_bus[tp*INT_W +: INT_W]) begin
                    $display("  path%0d got=%0d expected=%0d",
                        tp,
                        $signed(got_bus[tp*INT_W +: INT_W]),
                        $signed(exp_bus[tp*INT_W +: INT_W]));
                end
            end
        end
    endtask

    task check_scalar;
        input integer test_id;
        input integer got_value;
        input integer expected_value;
        begin
            check_count = check_count + 1;
            if (got_value !== expected_value) begin
                error_count = error_count + 1;
                $display("FAIL[%0d] t=%0t got=%0d expected=%0d",
                         test_id, $time, got_value, expected_value);
            end
        end
    endtask

    task check_read_once;
        input integer test_id;
        input integer address_a;
        input integer address_b;
        input [LIST_SIZE-1:0] active_mask;
        input [LIST_SIZE*INT_W-1:0] exp_a;
        input [LIST_SIZE*INT_W-1:0] exp_b;
        begin
            @(negedge clk);
            path_active_bus = active_mask;
            rd_addr_a = address_a[ADDR_W-1:0];
            rd_addr_b = address_b[ADDR_W-1:0];
            rd_en = 1'b1;

            @(posedge clk);
            #1;

            check_count = check_count + 1;
            if (rd_valid !== 1'b1) begin
                error_count = error_count + 1;
                $display("FAIL[%0d] t=%0t rd_valid got=%b expected=1",
                         test_id, $time, rd_valid);
            end

            check_count = check_count + 1;
            if (rd_data_a_bus !== exp_a) begin
                error_count = error_count + 1;
                print_bus_mismatch(test_id, rd_data_a_bus, exp_a);
            end

            check_count = check_count + 1;
            if (rd_data_b_bus !== exp_b) begin
                error_count = error_count + 1;
                print_bus_mismatch(test_id, rd_data_b_bus, exp_b);
            end

            @(negedge clk);
            rd_en = 1'b0;

            @(posedge clk);
            #1;
            check_count = check_count + 1;
            if (rd_valid !== 1'b0) begin
                error_count = error_count + 1;
                $display("FAIL[%0d] t=%0t rd_valid did not clear",
                         test_id, $time);
            end
        end
    endtask

    task apply_path_init;
        input [LIST_SIZE-1:0] new_active;
        integer td;
        integer tp;
        begin
            @(negedge clk);
            path_active_bus = new_active;
            path_init = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);
            path_init = 1'b0;

            for (td = 0; td < DEPTH_COUNT; td = td + 1) begin
                for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                    ref_map[td*LIST_SIZE + tp] = 0;
                end
            end
            model_active = new_active;
        end
    endtask

    task apply_remap;
        input [LIST_SIZE-1:0] new_valid;
        integer td;
        integer tp;
        integer parent_value;
        begin
            // Build the reference mapping from the OLD mapping first.
            for (td = 0; td < DEPTH_COUNT; td = td + 1) begin
                for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                    parent_value = remap_parent_bus[
                        tp*PATH_W +: PATH_W
                    ];

                    if (new_valid[tp] && (parent_value < LIST_SIZE))
                        ref_map_temp[td*LIST_SIZE + tp] =
                            ref_map[td*LIST_SIZE + parent_value];
                    else
                        ref_map_temp[td*LIST_SIZE + tp] = 0;
                end
            end

            @(negedge clk);
            remap_valid_bus = new_valid;
            remap_en = 1'b1;

            @(posedge clk);
            #1;

            @(negedge clk);
            remap_en = 1'b0;
            path_active_bus = new_valid;

            for (td = 0; td < DEPTH_COUNT; td = td + 1) begin
                for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                    ref_map[td*LIST_SIZE + tp] =
                        ref_map_temp[td*LIST_SIZE + tp];
                end
            end
            model_active = new_valid;
        end
    endtask

    task write_one_word;
        input integer address_value;
        input [LIST_SIZE-1:0] enable_mask;
        input [LIST_SIZE*INT_W-1:0] data_value;
        input integer commit_value;
        integer tp;
        begin
            @(negedge clk);
            wr_addr = address_value[ADDR_W-1:0];
            wr_en_bus = enable_mask;
            wr_data_bus = data_value;
            wr_commit = commit_value[0];

            @(posedge clk);
            #1;

            // Update the physical-bank reference memory after the edge.
            if (address_value >= NMAX) begin
                for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                    if (enable_mask[tp]) begin
                        ref_mid[
                            tp*MID_DEPTH + (address_value - NMAX)
                        ] = $signed(data_value[tp*INT_W +: INT_W]);
                    end
                end
            end

            @(negedge clk);
            wr_en_bus = {LIST_SIZE{1'b0}};
            wr_commit = 1'b0;
        end
    endtask

    task complete_layer_write;
        input integer depth_value;
        input integer tag_value;
        integer base_value;
        integer length_value;
        integer toffset;
        integer tp;
        integer lane_value;
        reg [LIST_SIZE*INT_W-1:0] layer_bus;
        begin
            base_value = depth_base_int(depth_value);
            length_value = NMAX >> depth_value;

            for (toffset = 0; toffset < length_value;
                 toffset = toffset + 1) begin
                layer_bus = {LIST_SIZE*INT_W{1'b0}};

                for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                    lane_value = tag_value + tp*80 + toffset;
                    layer_bus[tp*INT_W +: INT_W] = lane_value;
                end

                write_one_word(
                    base_value + toffset,
                    model_active,
                    layer_bus,
                    (toffset == (length_value - 1))
                );
            end

            // The final commit changes only this depth to identity banks.
            for (tp = 0; tp < LIST_SIZE; tp = tp + 1) begin
                if (model_active[tp])
                    ref_map[depth_value*LIST_SIZE + tp] = tp;
                else
                    ref_map[depth_value*LIST_SIZE + tp] = 0;
            end
        end
    endtask

    task set_parent_bus_0000;
        begin
            remap_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
        end
    endtask

    task set_parent_bus_0011_pattern;
        begin
            // destination [0,1,2,3] <- parent [0,0,1,1]
            remap_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
            remap_parent_bus[0*PATH_W +: PATH_W] = 0;
            remap_parent_bus[1*PATH_W +: PATH_W] = 0;
            remap_parent_bus[2*PATH_W +: PATH_W] = 1;
            remap_parent_bus[3*PATH_W +: PATH_W] = 1;
        end
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        path_init = 1'b0;
        path_active_bus = 4'b0001;

        load_start = 1'b0;
        n_log = 4;
        llr_in = {LLR_W{1'b0}};
        llr_in_valid = 1'b0;

        remap_en = 1'b0;
        remap_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
        remap_valid_bus = {LIST_SIZE{1'b0}};

        rd_en = 1'b0;
        rd_addr_a = {ADDR_W{1'b0}};
        rd_addr_b = {ADDR_W{1'b0}};

        wr_en_bus = {LIST_SIZE{1'b0}};
        wr_addr = {ADDR_W{1'b0}};
        wr_data_bus = {LIST_SIZE*INT_W{1'b0}};
        wr_commit = 1'b0;

        error_count = 0;
        check_count = 0;
        seed = 32'h13579bdf;
        model_active = 4'b0001;

        for (d = 0; d < DEPTH_COUNT; d = d + 1) begin
            for (p = 0; p < LIST_SIZE; p = p + 1) begin
                ref_map[d*LIST_SIZE + p] = 0;
                ref_map_temp[d*LIST_SIZE + p] = 0;
            end
        end

        for (i = 0; i < NMAX; i = i + 1)
            ref_root[i] = 0;

        for (i = 0; i < LIST_SIZE*MID_DEPTH; i = i + 1)
            ref_mid[i] = 0;

        // ---------------------------------------------------------------------
        // 1. reset and path_init
        // ---------------------------------------------------------------------
        repeat (3) @(posedge clk);
        #1;
        rst_n = 1'b1;

        repeat (2) @(posedge clk);
        #1;
        check_scalar(1, load_busy, 0);
        check_scalar(2, load_done, 0);
        check_scalar(3, rd_valid, 0);

        apply_path_init(4'b0001);

        // ---------------------------------------------------------------------
        // 2. root LLR serial loading in d[0]..d[15] order
        // ---------------------------------------------------------------------
        @(negedge clk);
        load_start = 1'b1;
        @(posedge clk);
        #1;
        check_scalar(10, load_busy, 1);
        @(negedge clk);
        load_start = 1'b0;

        for (i = 0; i < NMAX; i = i + 1) begin
            @(negedge clk);
            llr_in = i - 8;
            llr_in_valid = 1'b1;
            ref_root[i] = i - 8;

            @(posedge clk);
            #1;
            check_scalar(20+i, llr_in_ready, (i == NMAX-1) ? 0 : 1);

            if (i == NMAX-1) begin
                check_scalar(40, load_busy, 0);
                check_scalar(41, load_done, 1);
            end
        end

        @(negedge clk);
        llr_in_valid = 1'b0;
        llr_in = 0;
        @(posedge clk);
        #1;
        check_scalar(42, load_done, 0);

        // Natural root order, one active path.
        expected_a = model_read_bus(0, 4'b0001);
        expected_b = model_read_bus(1, 4'b0001);
        check_read_once(50, 0, 1, 4'b0001, expected_a, expected_b);

        // Root is shared by every active path; inactive path2 is zero.
        expected_a = model_read_bus(5, 4'b1011);
        expected_b = model_read_bus(9, 4'b1011);
        check_read_once(51, 5, 9, 4'b1011, expected_a, expected_b);

        // Explicitly check the final two loaded root locations as well.
        expected_a = model_read_bus(14, 4'b1111);
        expected_b = model_read_bus(15, 4'b1111);
        check_read_once(511, 14, 15, 4'b1111, expected_a, expected_b);

        // Request-aligned active-mask test.  Change the current mask after the
        // request edge; returned data must still use 0011.
        expected_a = model_read_bus(2, 4'b0011);
        expected_b = model_read_bus(3, 4'b0011);
        @(negedge clk);
        path_active_bus = 4'b0011;
        rd_addr_a = 2;
        rd_addr_b = 3;
        rd_en = 1'b1;
        @(posedge clk);
        #1;
        path_active_bus = 4'b1111;
        check_count = check_count + 1;
        if ((rd_valid !== 1'b1) ||
            (rd_data_a_bus !== expected_a) ||
            (rd_data_b_bus !== expected_b)) begin
            error_count = error_count + 1;
            $display("FAIL[52] t=%0t request-aligned active mask", $time);
            if (rd_data_a_bus !== expected_a)
                print_bus_mismatch(52, rd_data_a_bus, expected_a);
            if (rd_data_b_bus !== expected_b)
                print_bus_mismatch(52, rd_data_b_bus, expected_b);
        end
        @(negedge clk);
        rd_en = 1'b0;
        path_active_bus = 4'b0001;
        @(posedge clk);
        #1;

        // ---------------------------------------------------------------------
        // 3. path0 intermediate-layer write/read
        // ---------------------------------------------------------------------
        model_active = 4'b0001;
        path_active_bus = 4'b0001;
        complete_layer_write(1, 10);

        expected_a = model_read_bus(18, 4'b0001);
        expected_b = model_read_bus(21, 4'b0001);
        check_read_once(60, 18, 21, 4'b0001, expected_a, expected_b);

        // ---------------------------------------------------------------------
        // 4-8. first 1->2 pruning remap and inherited shared bank
        // ---------------------------------------------------------------------
        set_parent_bus_0000();
        apply_remap(4'b0011);

        expected_a = model_read_bus(19, 4'b0011);
        expected_b = model_read_bus(22, 4'b0011);
        check_read_once(70, 19, 22, 4'b0011, expected_a, expected_b);

        // Both paths must read exactly the same inherited bank0 value.
        check_count = check_count + 1;
        if (expected_a[0*INT_W +: INT_W] !==
            expected_a[1*INT_W +: INT_W]) begin
            error_count = error_count + 1;
            $display("FAIL[71] reference setup did not create a shared bank");
        end

        // ---------------------------------------------------------------------
        // 9-11. complete layer overwrite, atomic commit and independent banks
        // ---------------------------------------------------------------------
        complete_layer_write(1, 100);

        expected_a = model_read_bus(17, 4'b0011);
        expected_b = model_read_bus(23, 4'b0011);
        check_read_once(80, 17, 23, 4'b0011, expected_a, expected_b);

        check_count = check_count + 1;
        if (expected_a[0*INT_W +: INT_W] ===
            expected_a[1*INT_W +: INT_W]) begin
            error_count = error_count + 1;
            $display("FAIL[81] independent path data unexpectedly equal");
        end

        // ---------------------------------------------------------------------
        // 14. same-address read/write must be read-first
        // ---------------------------------------------------------------------
        old_data_a = model_read_bus(16, 4'b0011);
        old_data_b = model_read_bus(16, 4'b0011);

        @(negedge clk);
        path_active_bus = 4'b0011;
        rd_addr_a = 16;
        rd_addr_b = 16;
        rd_en = 1'b1;
        wr_addr = 16;
        wr_en_bus = 4'b0011;
        wr_data_bus = make_data_bus(301, 401, 0, 0);
        wr_commit = 1'b0;

        @(posedge clk);
        #1;
        check_count = check_count + 1;
        if ((rd_valid !== 1'b1) ||
            (rd_data_a_bus !== old_data_a) ||
            (rd_data_b_bus !== old_data_b)) begin
            error_count = error_count + 1;
            $display("FAIL[90] t=%0t same-address access was not read-first",
                     $time);
            if (rd_data_a_bus !== old_data_a)
                print_bus_mismatch(90, rd_data_a_bus, old_data_a);
            if (rd_data_b_bus !== old_data_b)
                print_bus_mismatch(90, rd_data_b_bus, old_data_b);
        end

        // Update reference physical banks after the collision edge.
        ref_mid[0*MID_DEPTH + 0] = 301;
        ref_mid[1*MID_DEPTH + 0] = 401;

        @(negedge clk);
        rd_en = 1'b0;
        wr_en_bus = 4'b0000;
        @(posedge clk);
        #1;

        expected_a = model_read_bus(16, 4'b0011);
        expected_b = model_read_bus(16, 4'b0011);
        check_read_once(91, 16, 16, 4'b0011, expected_a, expected_b);

        // ---------------------------------------------------------------------
        // 12-13. second pruning expansion to four paths
        // ---------------------------------------------------------------------
        set_parent_bus_0011_pattern();
        apply_remap(4'b1111);

        expected_a = model_read_bus(17, 4'b1111);
        expected_b = model_read_bus(18, 4'b1111);
        check_read_once(100, 17, 18, 4'b1111, expected_a, expected_b);

        // Expected inheritance: p0/p1 share parent0; p2/p3 share parent1.
        check_count = check_count + 1;
        if ((expected_a[0*INT_W +: INT_W] !==
             expected_a[1*INT_W +: INT_W]) ||
            (expected_a[2*INT_W +: INT_W] !==
             expected_a[3*INT_W +: INT_W]) ||
            (expected_a[0*INT_W +: INT_W] ===
             expected_a[2*INT_W +: INT_W])) begin
            error_count = error_count + 1;
            $display("FAIL[101] four-path inherited-bank relation is wrong");
        end

        complete_layer_write(1, 20);

        expected_a = model_read_bus(20, 4'b1111);
        expected_b = model_read_bus(23, 4'b1111);
        check_read_once(110, 20, 23, 4'b1111, expected_a, expected_b);

        // Explicit inactive-path masking on intermediate data.
        expected_a = model_read_bus(20, 4'b0101);
        expected_b = model_read_bus(23, 4'b0101);
        check_read_once(111, 20, 23, 4'b0101, expected_a, expected_b);
        path_active_bus = 4'b1111;
        model_active = 4'b1111;

        // ---------------------------------------------------------------------
        // path_init must restore mappings to bank0 without clearing RAM.
        // ---------------------------------------------------------------------
        apply_path_init(4'b0001);
        expected_a = model_read_bus(16, 4'b0001);
        expected_b = model_read_bus(17, 4'b0001);
        check_read_once(120, 16, 17, 4'b0001, expected_a, expected_b);

        // Re-expand to four paths using remap_valid_bus and initialize every
        // intermediate depth before randomized checking.
        set_parent_bus_0000();
        apply_remap(4'b1111);

        for (d = 1; d <= MAX_LOG; d = d + 1)
            complete_layer_write(d, -40 + d*10);

        // ---------------------------------------------------------------------
        // 17. randomized reference-model regression
        // ---------------------------------------------------------------------
        for (iter = 0; iter < 30; iter = iter + 1) begin
            // Random all-valid parent remap.  Every parent is currently active.
            for (p = 0; p < LIST_SIZE; p = p + 1) begin
                rand_value = $random(seed) & 32'h7fffffff;
                remap_parent_bus[p*PATH_W +: PATH_W] =
                    rand_value % LIST_SIZE;
            end
            apply_remap(4'b1111);

            rand_value = $random(seed) & 32'h7fffffff;
            rand_depth = 1 + (rand_value % MAX_LOG);

            rand_value = $random(seed) & 32'h7fffffff;
            rand_offset_a = rand_value % (NMAX >> rand_depth);

            rand_value = $random(seed) & 32'h7fffffff;
            rand_offset_b = rand_value % (NMAX >> rand_depth);

            expected_a = model_read_bus(
                depth_base_int(rand_depth) + rand_offset_a,
                4'b1111
            );
            expected_b = model_read_bus(
                depth_base_int(rand_depth) + rand_offset_b,
                4'b1111
            );
            check_read_once(
                200 + iter*2,
                depth_base_int(rand_depth) + rand_offset_a,
                depth_base_int(rand_depth) + rand_offset_b,
                4'b1111,
                expected_a,
                expected_b
            );

            rand_value = $random(seed) & 32'h7fffffff;
            rand_tag = (rand_value % 200) - 100;
            complete_layer_write(rand_depth, rand_tag);

            rand_value = $random(seed) & 32'h7fffffff;
            rand_offset_a = rand_value % (NMAX >> rand_depth);
            rand_value = $random(seed) & 32'h7fffffff;
            rand_offset_b = rand_value % (NMAX >> rand_depth);

            expected_a = model_read_bus(
                depth_base_int(rand_depth) + rand_offset_a,
                4'b1111
            );
            expected_b = model_read_bus(
                depth_base_int(rand_depth) + rand_offset_b,
                4'b1111
            );
            check_read_once(
                201 + iter*2,
                depth_base_int(rand_depth) + rand_offset_a,
                depth_base_int(rand_depth) + rand_offset_b,
                4'b1111,
                expected_a,
                expected_b
            );
        end

        // ---------------------------------------------------------------------
        // Unified result
        // ---------------------------------------------------------------------
        repeat (3) @(posedge clk);
        #1;

        if (error_count == 0) begin
            $display("============================================================");
            $display("PASS: tb_scl_llr_mem completed %0d checks.", check_count);
            $display("============================================================");
        end
        else begin
            $display("============================================================");
            $display("FAIL: tb_scl_llr_mem found %0d errors in %0d checks.",
                     error_count, check_count);
            $display("============================================================");
        end

        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: tb_scl_llr_mem timeout at t=%0t", $time);
        $finish;
    end

endmodule
