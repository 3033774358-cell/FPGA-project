`timescale 1ns/1ps

module tb_scl_path_mem_balanced;

    localparam integer NMAX      = 16;
    localparam integer MAX_LOG   = 4;
    localparam integer LIST_SIZE = 4;
    localparam integer PATH_W    = 2;
    localparam integer MEM_DEPTH = 2*NMAX-1;
    localparam integer ADDR_W    = 5;
    localparam integer INDEX_W   = 5;

    localparam [ADDR_W-1:0] DEPTH2_BASE = 5'd24;
    localparam [ADDR_W-1:0] LEAF_BASE   = 5'd30;

    reg clk;
    reg rst_n;

    reg path_init;
    wire [LIST_SIZE-1:0] path_active_bus;

    reg clone_commit_en;
    reg [LIST_SIZE*PATH_W-1:0] clone_parent_bus;
    reg [LIST_SIZE-1:0] clone_bit_bus;
    reg [LIST_SIZE-1:0] clone_valid_bus;
    reg [INDEX_W-1:0] clone_leaf_index;
    reg [ADDR_W-1:0] clone_leaf_beta_addr;

    reg leaf_write_en;
    reg [LIST_SIZE-1:0] leaf_bit_bus;
    reg [INDEX_W-1:0] leaf_index;
    reg [ADDR_W-1:0] leaf_beta_addr;

    reg [ADDR_W-1:0] beta_rd_addr_a;
    reg [ADDR_W-1:0] beta_rd_addr_b;
    wire [LIST_SIZE-1:0] beta_rd_data_a_bus;
    wire [LIST_SIZE-1:0] beta_rd_data_b_bus;

    reg beta_wr_en;
    reg [ADDR_W-1:0] beta_wr_addr;
    reg [LIST_SIZE-1:0] beta_wr_data_bus;
    reg beta_wr_commit;

    reg output_start;
    reg [3:0] n_log;
    reg [PATH_W-1:0] output_path;
    wire output_busy;
    wire output_done;
    wire u_valid;
    reg  u_ready;
    wire u_bit;
    wire [INDEX_W-1:0] u_index;
    wire u_last;

    integer errors;
    integer p;
    integer i;
    integer parent_i;
    integer recv_count;

    reg [NMAX-1:0] expected_uhat [0:LIST_SIZE-1];

    scl_path_mem #(
        .NMAX      (NMAX),
        .MAX_LOG   (MAX_LOG),
        .LIST_SIZE (LIST_SIZE),
        .PATH_W    (PATH_W),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    ) dut (
        .clk                      (clk),
        .rst_n                    (rst_n),

        .path_init                (path_init),
        .path_active_bus          (path_active_bus),

        .clone_commit_en          (clone_commit_en),
        .clone_parent_bus         (clone_parent_bus),
        .clone_bit_bus            (clone_bit_bus),
        .clone_valid_bus          (clone_valid_bus),
        .clone_leaf_index         (clone_leaf_index),
        .clone_leaf_beta_addr     (clone_leaf_beta_addr),

        .leaf_write_en            (leaf_write_en),
        .leaf_bit_bus             (leaf_bit_bus),
        .leaf_index               (leaf_index),
        .leaf_beta_addr           (leaf_beta_addr),

        .beta_rd_addr_a           (beta_rd_addr_a),
        .beta_rd_addr_b           (beta_rd_addr_b),
        .beta_rd_data_a_bus       (beta_rd_data_a_bus),
        .beta_rd_data_b_bus       (beta_rd_data_b_bus),

        .beta_wr_en               (beta_wr_en),
        .beta_wr_addr             (beta_wr_addr),
        .beta_wr_data_bus         (beta_wr_data_bus),
        .beta_wr_commit           (beta_wr_commit),

        .output_start             (output_start),
        .n_log                    (n_log),
        .output_path              (output_path),
        .output_busy              (output_busy),
        .output_done              (output_done),
        .u_valid                  (u_valid),
        .u_ready                  (u_ready),
        .u_bit                    (u_bit),
        .u_index                  (u_index),
        .u_last                   (u_last)
    );

    always #5 clk = ~clk;

    task check_bus;
        input [LIST_SIZE-1:0] got;
        input [LIST_SIZE-1:0] exp;
        input [8*96-1:0] label_text;
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got=%b expected=%b time=%0t",
                         label_text, got, exp, $time);
                errors = errors + 1;
            end
            else begin
                $display("PASS: %0s = %b", label_text, got);
            end
        end
    endtask

    task check_int;
        input integer got;
        input integer exp;
        input [8*96-1:0] label_text;
        begin
            if (got !== exp) begin
                $display("FAIL: %0s got=%0d expected=%0d time=%0t",
                         label_text, got, exp, $time);
                errors = errors + 1;
            end
            else begin
                $display("PASS: %0s = %0d", label_text, got);
            end
        end
    endtask

    task pulse_path_init;
        begin
            @(negedge clk);
            path_init = 1'b1;
            @(negedge clk);
            path_init = 1'b0;
        end
    endtask

    task fixed_leaf;
        input [INDEX_W-1:0] idx;
        input [LIST_SIZE-1:0] bits;
        integer q;
        begin
            @(negedge clk);
            leaf_index     = idx;
            leaf_beta_addr = LEAF_BASE;
            leaf_bit_bus   = bits;
            leaf_write_en  = 1'b1;

            @(negedge clk);
            leaf_write_en  = 1'b0;

            for (q = 0; q < LIST_SIZE; q = q + 1) begin
                if (path_active_bus[q])
                    expected_uhat[q][idx] = bits[q];
            end
        end
    endtask

    task clone_leaf;
        input [INDEX_W-1:0] idx;
        input [LIST_SIZE*PATH_W-1:0] parents;
        input [LIST_SIZE-1:0] bits;
        input [LIST_SIZE-1:0] valids;
        reg [NMAX-1:0] old_expected [0:LIST_SIZE-1];
        integer q;
        integer parent_q;
        begin
            for (q = 0; q < LIST_SIZE; q = q + 1)
                old_expected[q] = expected_uhat[q];

            @(negedge clk);
            clone_leaf_index     = idx;
            clone_leaf_beta_addr = LEAF_BASE;
            clone_parent_bus     = parents;
            clone_bit_bus        = bits;
            clone_valid_bus      = valids;
            clone_commit_en      = 1'b1;

            @(negedge clk);
            clone_commit_en      = 1'b0;

            for (q = 0; q < LIST_SIZE; q = q + 1) begin
                parent_q = parents[q*PATH_W +: PATH_W];
                if (valids[q]) begin
                    expected_uhat[q] = old_expected[parent_q];
                    expected_uhat[q][idx] = bits[q];
                end
            end
        end
    endtask

    task beta_write;
        input [ADDR_W-1:0] addr;
        input [LIST_SIZE-1:0] bits;
        input commit_now;
        begin
            @(negedge clk);
            beta_wr_addr     = addr;
            beta_wr_data_bus = bits;
            beta_wr_commit   = commit_now;
            beta_wr_en       = 1'b1;

            @(negedge clk);
            beta_wr_en       = 1'b0;
            beta_wr_commit   = 1'b0;
        end
    endtask

    // Read request is sampled at the next positive edge; data is checked after
    // that edge because beta read latency is exactly one cycle.
    task beta_read_check;
        input [ADDR_W-1:0] addr_a;
        input [ADDR_W-1:0] addr_b;
        input [LIST_SIZE-1:0] exp_a;
        input [LIST_SIZE-1:0] exp_b;
        input [8*96-1:0] label_text;
        begin
            @(negedge clk);
            beta_rd_addr_a = addr_a;
            beta_rd_addr_b = addr_b;
            @(posedge clk);
            #1;
            check_bus(beta_rd_data_a_bus, exp_a, label_text);
            check_bus(beta_rd_data_b_bus, exp_b, label_text);
        end
    endtask

    // Present read and write in the same cycle to verify read-first behavior.
    task beta_read_write_same_cycle;
        input [ADDR_W-1:0] addr;
        input [LIST_SIZE-1:0] write_bits;
        input commit_now;
        input [LIST_SIZE-1:0] expected_old_read;
        input [8*96-1:0] label_text;
        begin
            @(negedge clk);
            beta_rd_addr_a  = addr;
            beta_rd_addr_b  = addr;
            beta_wr_addr    = addr;
            beta_wr_data_bus= write_bits;
            beta_wr_commit  = commit_now;
            beta_wr_en      = 1'b1;

            @(posedge clk);
            #1;
            check_bus(beta_rd_data_a_bus, expected_old_read, label_text);
            check_bus(beta_rd_data_b_bus, expected_old_read, label_text);

            @(negedge clk);
            beta_wr_en      = 1'b0;
            beta_wr_commit  = 1'b0;
        end
    endtask

    task check_output_path;
        input [PATH_W-1:0] path_sel;
        integer local_count;
        reg stalled;
        begin
            local_count = 0;
            stalled = 1'b0;

            @(negedge clk);
            output_path  = path_sel;
            output_start = 1'b1;
            u_ready      = 1'b0;

            @(negedge clk);
            output_start = 1'b0;

            while (!u_valid)
                @(negedge clk);

            // We are now at a negative edge with u_valid asserted.  Check the
            // current item before the next positive-edge handshake.
            while (local_count < NMAX) begin
                if (!stalled && (local_count == 5)) begin
                    u_ready = 1'b0;
                    stalled = 1'b1;
                end
                else begin
                    u_ready = 1'b1;
                end

                #1;
                if (u_valid && u_ready) begin
                    if (u_index !== local_count[INDEX_W-1:0]) begin
                        $display("FAIL: output path%0d index got=%0d expected=%0d",
                                 path_sel, u_index, local_count);
                        errors = errors + 1;
                    end

                    if (u_bit !== expected_uhat[path_sel][local_count]) begin
                        $display("FAIL: output path%0d u[%0d]=%b expected=%b",
                                 path_sel, local_count, u_bit,
                                 expected_uhat[path_sel][local_count]);
                        errors = errors + 1;
                    end

                    if (u_last !== (local_count == NMAX-1)) begin
                        $display("FAIL: output path%0d u_last at index %0d",
                                 path_sel, local_count);
                        errors = errors + 1;
                    end

                    local_count = local_count + 1;
                end

                @(negedge clk);
            end

            wait(output_done === 1'b1);
            @(negedge clk);
            u_ready = 1'b0;

            $display("PASS: natural-order traceback output path %0d", path_sel);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        path_init = 1'b0;
        clone_commit_en = 1'b0;
        clone_parent_bus = 0;
        clone_bit_bus = 0;
        clone_valid_bus = 0;
        clone_leaf_index = 0;
        clone_leaf_beta_addr = LEAF_BASE;

        leaf_write_en = 1'b0;
        leaf_bit_bus = 0;
        leaf_index = 0;
        leaf_beta_addr = LEAF_BASE;

        beta_rd_addr_a = 0;
        beta_rd_addr_b = 0;
        beta_wr_en = 1'b0;
        beta_wr_addr = 0;
        beta_wr_data_bus = 0;
        beta_wr_commit = 1'b0;

        output_start = 1'b0;
        n_log = 4;
        output_path = 0;
        u_ready = 1'b0;

        errors = 0;

        for (p = 0; p < LIST_SIZE; p = p + 1)
            expected_uhat[p] = {NMAX{1'b0}};

        repeat (3) @(negedge clk);
        rst_n = 1'b1;

        pulse_path_init();
        check_bus(path_active_bus, 4'b0001, "path_init active mask");

        // Leaf 0: fixed bit 1 on the only active path.
        fixed_leaf(0, 4'b0001);
        beta_read_check(LEAF_BASE, LEAF_BASE,
                        4'b0001, 4'b0001,
                        "fixed leaf beta");

        // Build a depth-2 source workspace for path0 and commit its map.
        beta_write(DEPTH2_BASE + 0, 4'b0001, 1'b0);
        beta_write(DEPTH2_BASE + 1, 4'b0001, 1'b1);
        beta_read_check(DEPTH2_BASE + 0, DEPTH2_BASE + 1,
                        4'b0001, 4'b0001,
                        "depth2 source before split");

        // Leaf 1: path0 -> dst0(bit0), dst1(bit1).
        clone_leaf(1,
                   {2'd0, 2'd0, 2'd0, 2'd0},
                   4'b0010,
                   4'b0011);
        check_bus(path_active_bus, 4'b0011, "first split active mask");

        check_int(dut.beta_map[2*LIST_SIZE + 0], 0,
                  "depth2 dst0 inherited bank");
        check_int(dut.beta_map[2*LIST_SIZE + 1], 0,
                  "depth2 dst1 shares parent bank");

        beta_read_check(DEPTH2_BASE + 0, DEPTH2_BASE + 1,
                        4'b0011, 4'b0011,
                        "shared beta after first split");

        // Copy-while-compute PH_C-like transaction.  Reads must see the old
        // shared source while writes create private bank0/bank1 results.
        beta_read_write_same_cycle(DEPTH2_BASE + 0,
                                   4'b0010,
                                   1'b0,
                                   4'b0011,
                                   "read-first beta transaction word0");

        beta_read_write_same_cycle(DEPTH2_BASE + 1,
                                   4'b0001,
                                   1'b1,
                                   4'b0011,
                                   "read-first beta transaction word1");

        check_int(dut.beta_map[2*LIST_SIZE + 0], 0,
                  "depth2 dst0 private bank after commit");
        check_int(dut.beta_map[2*LIST_SIZE + 1], 1,
                  "depth2 dst1 private bank after commit");

        beta_read_check(DEPTH2_BASE + 0, DEPTH2_BASE + 1,
                        4'b0010, 4'b0001,
                        "private beta after two-path commit");

        // Leaf 2: dst0/dst1 from parent0, dst2/dst3 from parent1.
        clone_leaf(2,
                   {2'd1, 2'd1, 2'd0, 2'd0},
                   4'b1010,
                   4'b1111);
        check_bus(path_active_bus, 4'b1111, "second split active mask");

        check_int(dut.beta_map[2*LIST_SIZE + 0], 0,
                  "second split dst0 bank");
        check_int(dut.beta_map[2*LIST_SIZE + 1], 0,
                  "second split dst1 shares parent0");
        check_int(dut.beta_map[2*LIST_SIZE + 2], 1,
                  "second split dst2 bank");
        check_int(dut.beta_map[2*LIST_SIZE + 3], 1,
                  "second split dst3 shares parent1");

        beta_read_check(DEPTH2_BASE + 0, DEPTH2_BASE + 0,
                        4'b1100, 4'b1100,
                        "four-path inherited beta");

        // One-word private transaction for all four paths.
        beta_read_write_same_cycle(DEPTH2_BASE + 0,
                                   4'b1010,
                                   1'b1,
                                   4'b1100,
                                   "four-path read-first transaction");
        beta_read_check(DEPTH2_BASE + 0, DEPTH2_BASE + 0,
                        4'b1010, 4'b1010,
                        "four private banks after commit");

        // Leaf 3 and the remaining leaves are fixed/non-split decisions.
        fixed_leaf(3, 4'b0110);
        for (i = 4; i < NMAX; i = i + 1)
            fixed_leaf(i[INDEX_W-1:0], 4'b0000);

        // Verify natural-order reconstruction for every final path.
        for (p = 0; p < LIST_SIZE; p = p + 1)
            check_output_path(p[PATH_W-1:0]);

        if (errors == 0)
            $display("PASS: scl_path_mem balanced test completed.");
        else
            $display("FAIL: scl_path_mem balanced test errors=%0d", errors);

        #20;
        $finish;
    end

endmodule
