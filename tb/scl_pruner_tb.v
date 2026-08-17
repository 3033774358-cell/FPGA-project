`timescale 1ns/1ps

// =============================================================================
// tb_scl_pruner.v
// =============================================================================
// Self-checking testbench for scl_pruner.v
// Default DUT configuration: LIST_SIZE=4, 8 candidates -> best 4.
//
// Covered cases:
//   1. Basic PM ascending order.
//   2. valid candidates always beat invalid candidates.
//   3. Tie breaking: parent, bit, original candidate index.
//   4. Recommended candidate packing: candidate[2*p], candidate[2*p+1].
//   5. 200 deterministic pseudo-random test vectors, checked against an
//      independent bubble-sort reference model in this testbench.
// =============================================================================

module tb_scl_pruner;

    localparam integer LIST_SIZE = 4;
    localparam integer CAND_NUM  = 2 * LIST_SIZE;
    localparam integer PM_W      = 12;
    localparam integer PATH_W    = 2;
    localparam integer CAND_W    = 3;

    reg clk;
    reg rst_n;
    reg in_valid;
    wire in_ready;

    reg  [CAND_NUM*PM_W-1:0]   cand_pm_bus;
    reg  [CAND_NUM*PATH_W-1:0] cand_parent_bus;
    reg  [CAND_NUM-1:0]        cand_bit_bus;
    reg  [CAND_NUM-1:0]        cand_valid_bus;

    wire                              out_valid;
    wire [LIST_SIZE*PM_W-1:0]         sel_pm_bus;
    wire [LIST_SIZE*PATH_W-1:0]       sel_parent_bus;
    wire [LIST_SIZE-1:0]              sel_bit_bus;
    wire [LIST_SIZE-1:0]              sel_valid_bus;
    wire [LIST_SIZE*CAND_W-1:0]       sel_index_bus;

    integer errors;
    integer tests;
    integer i;
    integer t;
    integer random_value;

    // Independent reference-model arrays.
    reg [PM_W-1:0]   ref_pm     [0:CAND_NUM-1];
    reg [PATH_W-1:0] ref_parent [0:CAND_NUM-1];
    reg              ref_bit    [0:CAND_NUM-1];
    reg              ref_valid  [0:CAND_NUM-1];
    reg [CAND_W-1:0] ref_index  [0:CAND_NUM-1];

    reg [PM_W-1:0]   tmp_pm;
    reg [PATH_W-1:0] tmp_parent;
    reg              tmp_bit;
    reg              tmp_valid;
    reg [CAND_W-1:0] tmp_index;

    reg [LIST_SIZE*PM_W-1:0]       expected_pm_bus;
    reg [LIST_SIZE*PATH_W-1:0]     expected_parent_bus;
    reg [LIST_SIZE-1:0]            expected_bit_bus;
    reg [LIST_SIZE-1:0]            expected_valid_bus;
    reg [LIST_SIZE*CAND_W-1:0]     expected_index_bus;

    scl_pruner #(
        .LIST_SIZE       (LIST_SIZE),
        .PM_W            (PM_W),
        .PATH_W          (PATH_W),
        .CAND_W          (CAND_W),
        .REGISTER_OUTPUT (1)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .in_valid        (in_valid),
        .in_ready        (in_ready),
        .cand_pm_bus     (cand_pm_bus),
        .cand_parent_bus (cand_parent_bus),
        .cand_bit_bus    (cand_bit_bus),
        .cand_valid_bus  (cand_valid_bus),
        .out_valid       (out_valid),
        .sel_pm_bus      (sel_pm_bus),
        .sel_parent_bus  (sel_parent_bus),
        .sel_bit_bus     (sel_bit_bus),
        .sel_valid_bus   (sel_valid_bus),
        .sel_index_bus   (sel_index_bus)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

`ifdef DUMP_WAVE
    initial begin
        $dumpfile("tb_scl_pruner.vcd");
        $dumpvars(0, tb_scl_pruner);
    end
`endif

    function ref_item_greater;
        input                   valid_a;
        input [PM_W-1:0]        pm_a;
        input [PATH_W-1:0]      parent_a;
        input                   bit_a;
        input [CAND_W-1:0]      index_a;
        input                   valid_b;
        input [PM_W-1:0]        pm_b;
        input [PATH_W-1:0]      parent_b;
        input                   bit_b;
        input [CAND_W-1:0]      index_b;
        begin
            if (valid_a != valid_b)
                ref_item_greater = !valid_a;
            else if (!valid_a)
                ref_item_greater = (index_a > index_b);
            else if (pm_a != pm_b)
                ref_item_greater = (pm_a > pm_b);
            else if (parent_a != parent_b)
                ref_item_greater = (parent_a > parent_b);
            else if (bit_a != bit_b)
                ref_item_greater = (bit_a > bit_b);
            else
                ref_item_greater = (index_a > index_b);
        end
    endfunction

    task clear_candidates;
        begin
            cand_pm_bus     = {(CAND_NUM*PM_W){1'b0}};
            cand_parent_bus = {(CAND_NUM*PATH_W){1'b0}};
            cand_bit_bus    = {CAND_NUM{1'b0}};
            cand_valid_bus  = {CAND_NUM{1'b0}};
        end
    endtask

    task set_candidate;
        input integer index_value;
        input integer pm_value;
        input integer parent_value;
        input integer bit_value;
        input integer valid_value;
        begin
            cand_pm_bus[index_value*PM_W +: PM_W] = pm_value;
            cand_parent_bus[index_value*PATH_W +: PATH_W] = parent_value;
            cand_bit_bus[index_value] = bit_value[0];
            cand_valid_bus[index_value] = valid_value[0];
        end
    endtask

    task build_reference;
        integer a;
        integer b;
        begin
            for (a = 0; a < CAND_NUM; a = a + 1) begin
                ref_pm[a] = cand_pm_bus[a*PM_W +: PM_W];
                ref_parent[a] = cand_parent_bus[a*PATH_W +: PATH_W];
                ref_bit[a] = cand_bit_bus[a];
                ref_valid[a] = cand_valid_bus[a];
                ref_index[a] = a[CAND_W-1:0];
            end

            // Independent bubble sort in ascending priority order.
            for (a = 0; a < CAND_NUM-1; a = a + 1) begin
                for (b = 0; b < CAND_NUM-1-a; b = b + 1) begin
                    if (ref_item_greater(
                        ref_valid[b], ref_pm[b], ref_parent[b],
                        ref_bit[b], ref_index[b],
                        ref_valid[b+1], ref_pm[b+1], ref_parent[b+1],
                        ref_bit[b+1], ref_index[b+1]
                    )) begin
                        tmp_pm = ref_pm[b];
                        ref_pm[b] = ref_pm[b+1];
                        ref_pm[b+1] = tmp_pm;

                        tmp_parent = ref_parent[b];
                        ref_parent[b] = ref_parent[b+1];
                        ref_parent[b+1] = tmp_parent;

                        tmp_bit = ref_bit[b];
                        ref_bit[b] = ref_bit[b+1];
                        ref_bit[b+1] = tmp_bit;

                        tmp_valid = ref_valid[b];
                        ref_valid[b] = ref_valid[b+1];
                        ref_valid[b+1] = tmp_valid;

                        tmp_index = ref_index[b];
                        ref_index[b] = ref_index[b+1];
                        ref_index[b+1] = tmp_index;
                    end
                end
            end

            expected_pm_bus     = {(LIST_SIZE*PM_W){1'b0}};
            expected_parent_bus = {(LIST_SIZE*PATH_W){1'b0}};
            expected_bit_bus    = {LIST_SIZE{1'b0}};
            expected_valid_bus  = {LIST_SIZE{1'b0}};
            expected_index_bus  = {(LIST_SIZE*CAND_W){1'b0}};

            for (a = 0; a < LIST_SIZE; a = a + 1) begin
                expected_pm_bus[a*PM_W +: PM_W] = ref_pm[a];
                expected_parent_bus[a*PATH_W +: PATH_W] = ref_parent[a];
                expected_bit_bus[a] = ref_bit[a];
                expected_valid_bus[a] = ref_valid[a];
                expected_index_bus[a*CAND_W +: CAND_W] = ref_index[a];
            end
        end
    endtask

    task report_vector;
        integer k;
        begin
            $display("  Input candidates:");
            for (k = 0; k < CAND_NUM; k = k + 1) begin
                $display("    idx=%0d valid=%0d pm=%0d parent=%0d bit=%0d",
                    k,
                    cand_valid_bus[k],
                    cand_pm_bus[k*PM_W +: PM_W],
                    cand_parent_bus[k*PATH_W +: PATH_W],
                    cand_bit_bus[k]);
            end
            $display("  Expected selected indices = 0x%0h", expected_index_bus);
            $display("  Actual   selected indices = 0x%0h", sel_index_bus);
        end
    endtask

    task apply_and_check;
        begin
            build_reference;

            @(negedge clk);
            in_valid = 1'b1;

            @(posedge clk);
            #1;
            tests = tests + 1;

            if (in_ready !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL test %0d: in_ready is not 1", tests);
            end

            if (out_valid !== 1'b1) begin
                errors = errors + 1;
                $display("FAIL test %0d: out_valid is not asserted", tests);
                report_vector;
            end
            else if ((sel_pm_bus !== expected_pm_bus) ||
                     (sel_parent_bus !== expected_parent_bus) ||
                     (sel_bit_bus !== expected_bit_bus) ||
                     (sel_valid_bus !== expected_valid_bus) ||
                     (sel_index_bus !== expected_index_bus)) begin
                errors = errors + 1;
                $display("FAIL test %0d: selected result mismatch", tests);
                $display("  expected pm     = 0x%0h", expected_pm_bus);
                $display("  actual   pm     = 0x%0h", sel_pm_bus);
                $display("  expected parent = 0x%0h", expected_parent_bus);
                $display("  actual   parent = 0x%0h", sel_parent_bus);
                $display("  expected bit    = 0x%0h", expected_bit_bus);
                $display("  actual   bit    = 0x%0h", sel_bit_bus);
                $display("  expected valid  = 0x%0h", expected_valid_bus);
                $display("  actual   valid  = 0x%0h", sel_valid_bus);
                report_vector;
            end

            @(negedge clk);
            in_valid = 1'b0;
            @(posedge clk);
            #1;

            if (out_valid !== 1'b0) begin
                errors = errors + 1;
                $display("FAIL test %0d: out_valid did not return low", tests);
            end
        end
    endtask

    initial begin
        rst_n = 1'b0;
        in_valid = 1'b0;
        errors = 0;
        tests = 0;
        clear_candidates;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // ---------------------------------------------------------------------
        // Test 1: basic PM sorting.
        // ---------------------------------------------------------------------
        clear_candidates;
        set_candidate(0, 50, 0, 0, 1);
        set_candidate(1, 10, 0, 1, 1);
        set_candidate(2, 70, 1, 0, 1);
        set_candidate(3, 30, 1, 1, 1);
        set_candidate(4, 20, 2, 0, 1);
        set_candidate(5, 80, 2, 1, 1);
        set_candidate(6, 40, 3, 0, 1);
        set_candidate(7, 60, 3, 1, 1);
        apply_and_check;

        // ---------------------------------------------------------------------
        // Test 2: valid has priority over PM.
        // Invalid candidates deliberately use smaller PM values.
        // ---------------------------------------------------------------------
        clear_candidates;
        set_candidate(0,  0, 0, 0, 0);
        set_candidate(1,  1, 0, 1, 0);
        set_candidate(2, 90, 1, 0, 1);
        set_candidate(3, 30, 1, 1, 1);
        set_candidate(4,  2, 2, 0, 0);
        set_candidate(5, 20, 2, 1, 1);
        set_candidate(6, 10, 3, 0, 1);
        set_candidate(7,  3, 3, 1, 0);
        apply_and_check;

        // ---------------------------------------------------------------------
        // Test 3: all PM equal; check parent, then bit, then original index.
        // ---------------------------------------------------------------------
        clear_candidates;
        set_candidate(0, 100, 2, 1, 1);
        set_candidate(1, 100, 0, 1, 1);
        set_candidate(2, 100, 1, 1, 1);
        set_candidate(3, 100, 0, 0, 1);
        set_candidate(4, 100, 3, 0, 1);
        set_candidate(5, 100, 1, 0, 1);
        set_candidate(6, 100, 2, 0, 1);
        set_candidate(7, 100, 0, 0, 1);
        apply_and_check;

        // ---------------------------------------------------------------------
        // Test 4: recommended 2*p / 2*p+1 packing.
        // ---------------------------------------------------------------------
        clear_candidates;
        set_candidate(0, 12, 0, 0, 1);
        set_candidate(1,  7, 0, 1, 1);
        set_candidate(2,  4, 1, 0, 1);
        set_candidate(3, 14, 1, 1, 1);
        set_candidate(4,  8, 2, 0, 1);
        set_candidate(5,  8, 2, 1, 1);
        set_candidate(6,  6, 3, 0, 1);
        set_candidate(7,  9, 3, 1, 1);
        apply_and_check;

        // ---------------------------------------------------------------------
        // Test 5: deterministic pseudo-random regression.
        // ---------------------------------------------------------------------
        for (t = 0; t < 200; t = t + 1) begin
            clear_candidates;
            for (i = 0; i < CAND_NUM; i = i + 1) begin
                random_value = $random;
                cand_pm_bus[i*PM_W +: PM_W] = random_value[PM_W-1:0];

                random_value = $random;
                cand_parent_bus[i*PATH_W +: PATH_W] =
                    random_value[PATH_W-1:0];

                random_value = $random;
                cand_bit_bus[i] = random_value[0];

                random_value = $random;
                // About 75% valid, but always permit all-invalid vectors too.
                cand_valid_bus[i] = (random_value[1:0] != 2'b00);
            end
            apply_and_check;
        end

        if (errors == 0) begin
            $display("============================================================");
            $display("PASS: scl_pruner completed %0d self-checking tests.", tests);
            $display("============================================================");
        end
        else begin
            $display("============================================================");
            $display("FAIL: scl_pruner had %0d errors in %0d tests.",
                     errors, tests);
            $display("============================================================");
        end

        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: tb_scl_pruner timeout");
        $finish;
    end

endmodule
