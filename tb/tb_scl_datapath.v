`timescale 1ns/1ps

module tb_scl_datapath_balanced;

    localparam integer NMAX       = 16;
    localparam integer LLR_W      = 8;
    localparam integer INT_W      = 10;
    localparam integer MAX_LOG    = 4;
    localparam integer LIST_SIZE  = 4;
    localparam integer PM_W       = 12;
    localparam integer PATH_W     = 2;
    localparam integer DEPTH_W    = 3;
    localparam integer MEM_DEPTH  = 31;
    localparam integer ADDR_W     = 5;
    localparam integer INDEX_W    = 5;

    localparam [1:0] BETA_SRC_DIRECT = 2'b00;
    localparam [1:0] BETA_SRC_XOR    = 2'b01;

    reg clk;
    reg rst_n;

    reg load_start;
    reg [3:0] n_log;
    reg signed [LLR_W-1:0] llr_in;
    reg llr_in_valid;
    wire llr_in_ready;
    wire load_busy;
    wire load_done;

    reg path_init;

    reg llr_rd_req;
    reg [DEPTH_W-1:0] llr_rd_depth;
    reg [ADDR_W-1:0] llr_rd_addr_a;
    reg [ADDR_W-1:0] llr_rd_addr_b;
    wire llr_rd_valid;
    wire signed [LIST_SIZE*INT_W-1:0] llr_rd_data_a_bus;
    wire signed [LIST_SIZE*INT_W-1:0] llr_rd_data_b_bus;

    reg beta_rd_req;
    reg [ADDR_W-1:0] beta_rd_addr_a;
    reg [ADDR_W-1:0] beta_rd_addr_b;
    wire beta_rd_valid;
    wire [LIST_SIZE-1:0] beta_rd_data_a_bus;
    wire [LIST_SIZE-1:0] beta_rd_data_b_bus;

    reg pe_mode_g;
    wire pe_result_valid;
    wire signed [LIST_SIZE*INT_W-1:0] pe_result_bus;

    reg llr_wr_en;
    reg [DEPTH_W-1:0] llr_wr_depth;
    reg [ADDR_W-1:0] llr_wr_addr;
    wire llr_write_conflict;

    reg beta_wr_en;
    reg [ADDR_W-1:0] beta_wr_addr;
    reg [LIST_SIZE-1:0] beta_wr_direct_bus;
    reg [1:0] beta_wr_mode;
    reg beta_wr_commit;
    wire [LIST_SIZE-1:0] beta_selected_data_bus;
    wire beta_write_accepted;

    reg [INDEX_W-1:0] leaf_index;
    reg [ADDR_W-1:0] leaf_beta_addr;
    wire leaf_eval_valid;
    reg fixed_leaf_commit_en;

    wire [2*LIST_SIZE*PM_W-1:0] cand_pm_bus;
    wire [2*LIST_SIZE*PATH_W-1:0] cand_parent_bus;
    wire [2*LIST_SIZE-1:0] cand_bit_bus;
    wire [2*LIST_SIZE-1:0] cand_valid_bus;
    wire [LIST_SIZE-1:0] leaf_hard_bit_bus;
    wire [LIST_SIZE*INT_W-1:0] leaf_abs_llr_bus;

    reg prune_commit_en;
    reg [LIST_SIZE*PM_W-1:0] sel_pm_bus;
    reg [LIST_SIZE*PATH_W-1:0] sel_parent_bus;
    reg [LIST_SIZE-1:0] sel_bit_bus;
    reg [LIST_SIZE-1:0] sel_valid_bus;

    wire [LIST_SIZE-1:0] path_active_bus;
    wire [LIST_SIZE*PM_W-1:0] path_pm_bus;
    wire best_valid;
    wire [PATH_W-1:0] best_path;
    wire [PM_W-1:0] best_pm;

    reg output_start;
    reg [PATH_W-1:0] output_path;
    wire output_busy;
    wire output_done;
    wire u_valid;
    reg u_ready;
    wire u_bit;
    wire [INDEX_W-1:0] u_index;
    wire u_last;

    integer errors;
    integer i;
    integer p;
    integer timeout_count;
    integer output_count;
    reg [3:0] output_bits;
    reg signed [LLR_W-1:0] root_llr [0:3];

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
        .BRAM_MIN_DEPTH          (4),
        .REGISTER_LLR_READ_OUTPUT(1)
    ) dut (
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

        .llr_rd_req           (llr_rd_req),
        .llr_rd_depth         (llr_rd_depth),
        .llr_rd_addr_a        (llr_rd_addr_a),
        .llr_rd_addr_b        (llr_rd_addr_b),
        .llr_rd_valid         (llr_rd_valid),
        .llr_rd_data_a_bus    (llr_rd_data_a_bus),
        .llr_rd_data_b_bus    (llr_rd_data_b_bus),

        .beta_rd_req          (beta_rd_req),
        .beta_rd_addr_a       (beta_rd_addr_a),
        .beta_rd_addr_b       (beta_rd_addr_b),
        .beta_rd_valid        (beta_rd_valid),
        .beta_rd_data_a_bus   (beta_rd_data_a_bus),
        .beta_rd_data_b_bus   (beta_rd_data_b_bus),

        .pe_mode_g            (pe_mode_g),
        .pe_result_valid      (pe_result_valid),
        .pe_result_bus        (pe_result_bus),

        .llr_wr_en            (llr_wr_en),
        .llr_wr_depth         (llr_wr_depth),
        .llr_wr_addr          (llr_wr_addr),
        .llr_write_conflict   (llr_write_conflict),

        .beta_wr_en           (beta_wr_en),
        .beta_wr_addr         (beta_wr_addr),
        .beta_wr_direct_bus   (beta_wr_direct_bus),
        .beta_wr_mode         (beta_wr_mode),
        .beta_wr_commit       (beta_wr_commit),
        .beta_selected_data_bus(beta_selected_data_bus),
        .beta_write_accepted  (beta_write_accepted),

        .leaf_index           (leaf_index),
        .leaf_beta_addr       (leaf_beta_addr),
        .leaf_eval_valid      (leaf_eval_valid),
        .fixed_leaf_commit_en (fixed_leaf_commit_en),

        .cand_pm_bus          (cand_pm_bus),
        .cand_parent_bus      (cand_parent_bus),
        .cand_bit_bus         (cand_bit_bus),
        .cand_valid_bus       (cand_valid_bus),
        .leaf_hard_bit_bus    (leaf_hard_bit_bus),
        .leaf_abs_llr_bus     (leaf_abs_llr_bus),

        .prune_commit_en      (prune_commit_en),
        .sel_pm_bus           (sel_pm_bus),
        .sel_parent_bus       (sel_parent_bus),
        .sel_bit_bus          (sel_bit_bus),
        .sel_valid_bus        (sel_valid_bus),

        .path_active_bus      (path_active_bus),
        .path_pm_bus          (path_pm_bus),
        .best_valid           (best_valid),
        .best_path            (best_path),
        .best_pm              (best_pm),

        .output_start         (output_start),
        .output_path          (output_path),
        .output_busy          (output_busy),
        .output_done          (output_done),
        .u_valid              (u_valid),
        .u_ready              (u_ready),
        .u_bit                (u_bit),
        .u_index              (u_index),
        .u_last               (u_last)
    );

    always #5 clk = ~clk;

    function integer depth_base;
        input integer depth;
        begin
            if (depth == 0)
                depth_base = 0;
            else
                depth_base = 2*NMAX - (NMAX >> (depth-1));
        end
    endfunction

    task check;
        input condition;
        input [8*120-1:0] text;
        begin
            if (!condition) begin
                $display("FAIL: %0s time=%0t", text, $time);
                errors = errors + 1;
            end
            else begin
                $display("PASS: %0s", text);
            end
        end
    endtask

    task pulse_path_init;
        begin
            @(negedge clk);
            path_init = 1'b1;
            @(negedge clk);
            path_init = 1'b0;
            #1;
        end
    endtask

    task load_four_llrs;
        begin
            @(negedge clk);
            load_start = 1'b1;
            @(negedge clk);
            load_start = 1'b0;

            timeout_count = 0;
            while (!load_busy && timeout_count < 20) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(load_busy, "root loader entered busy state");

            for (i = 0; i < 4; i = i + 1) begin
                @(negedge clk);
                llr_in = root_llr[i];
                llr_in_valid = 1'b1;
            end

            @(negedge clk);
            llr_in_valid = 1'b0;

            timeout_count = 0;
            while (!load_done && timeout_count < 20) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(load_done, "root loader asserted load_done");
        end
    endtask

    task issue_llr_operation;
        input [DEPTH_W-1:0] depth;
        input [ADDR_W-1:0] addr_a;
        input [ADDR_W-1:0] addr_b;
        input mode_g;
        input use_beta;
        input [ADDR_W-1:0] beta_addr_a;
        input [ADDR_W-1:0] beta_addr_b;
        begin
            @(negedge clk);
            llr_rd_depth  = depth;
            llr_rd_addr_a = addr_a;
            llr_rd_addr_b = addr_b;
            pe_mode_g     = mode_g;
            llr_rd_req    = 1'b1;

            beta_rd_addr_a = beta_addr_a;
            beta_rd_addr_b = beta_addr_b;
            beta_rd_req    = use_beta;

            @(negedge clk);
            llr_rd_req  = 1'b0;
            beta_rd_req = 1'b0;

            timeout_count = 0;
            while (!pe_result_valid && timeout_count < 30) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(pe_result_valid, "parallel PE result became valid");
            #1;
        end
    endtask

    task write_current_pe_result;
        input [DEPTH_W-1:0] depth;
        input [ADDR_W-1:0] address;
        begin
            llr_wr_depth = depth;
            llr_wr_addr  = address;
            llr_wr_en    = 1'b1;
            #1;
            check(!llr_write_conflict, "LLR write has no physical-bank conflict");
            @(negedge clk);
            llr_wr_en = 1'b0;
        end
    endtask

    task issue_leaf_read;
        input [ADDR_W-1:0] address;
        begin
            issue_llr_operation(
                {DEPTH_W{1'b0}}, address, address,
                1'b0, 1'b0,
                {ADDR_W{1'b0}}, {ADDR_W{1'b0}}
            );
            check(leaf_eval_valid, "leaf candidate evaluation valid");
        end
    endtask

    task commit_fixed_leaf;
        input [INDEX_W-1:0] index_value;
        begin
            leaf_index = index_value;
            leaf_beta_addr = depth_base(n_log);
            fixed_leaf_commit_en = 1'b1;
            @(negedge clk);
            fixed_leaf_commit_en = 1'b0;
            #1;
        end
    endtask

    task commit_pruned_leaf;
        input [INDEX_W-1:0] index_value;
        begin
            leaf_index = index_value;
            leaf_beta_addr = depth_base(n_log);
            prune_commit_en = 1'b1;
            @(negedge clk);
            prune_commit_en = 1'b0;
            #1;
        end
    endtask

    task beta_direct_write;
        input [ADDR_W-1:0] address;
        input [LIST_SIZE-1:0] data_value;
        input commit_value;
        begin
            @(negedge clk);
            beta_wr_addr       = address;
            beta_wr_direct_bus = data_value;
            beta_wr_mode       = BETA_SRC_DIRECT;
            beta_wr_commit     = commit_value;
            beta_wr_en         = 1'b1;
            #1;
            check(beta_write_accepted, "direct beta write accepted");
            @(negedge clk);
            beta_wr_en     = 1'b0;
            beta_wr_commit = 1'b0;
        end
    endtask

    task issue_beta_read;
        input [ADDR_W-1:0] address_a;
        input [ADDR_W-1:0] address_b;
        begin
            @(negedge clk);
            beta_rd_addr_a = address_a;
            beta_rd_addr_b = address_b;
            beta_rd_req = 1'b1;
            @(negedge clk);
            beta_rd_req = 1'b0;

            timeout_count = 0;
            while (!beta_rd_valid && timeout_count < 10) begin
                @(negedge clk);
                timeout_count = timeout_count + 1;
            end
            check(beta_rd_valid, "beta read response valid");
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        load_start = 1'b0;
        n_log = 4'd2;
        llr_in = {LLR_W{1'b0}};
        llr_in_valid = 1'b0;
        path_init = 1'b0;

        llr_rd_req = 1'b0;
        llr_rd_depth = {DEPTH_W{1'b0}};
        llr_rd_addr_a = {ADDR_W{1'b0}};
        llr_rd_addr_b = {ADDR_W{1'b0}};

        beta_rd_req = 1'b0;
        beta_rd_addr_a = {ADDR_W{1'b0}};
        beta_rd_addr_b = {ADDR_W{1'b0}};

        pe_mode_g = 1'b0;
        llr_wr_en = 1'b0;
        llr_wr_depth = {DEPTH_W{1'b0}};
        llr_wr_addr = {ADDR_W{1'b0}};

        beta_wr_en = 1'b0;
        beta_wr_addr = {ADDR_W{1'b0}};
        beta_wr_direct_bus = {LIST_SIZE{1'b0}};
        beta_wr_mode = BETA_SRC_DIRECT;
        beta_wr_commit = 1'b0;

        leaf_index = {INDEX_W{1'b0}};
        leaf_beta_addr = depth_base(2);
        fixed_leaf_commit_en = 1'b0;

        prune_commit_en = 1'b0;
        sel_pm_bus = {LIST_SIZE*PM_W{1'b0}};
        sel_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
        sel_bit_bus = {LIST_SIZE{1'b0}};
        sel_valid_bus = {LIST_SIZE{1'b0}};

        output_start = 1'b0;
        output_path = {PATH_W{1'b0}};
        u_ready = 1'b0;

        errors = 0;
        output_count = 0;
        output_bits = 4'b0000;

        root_llr[0] =  8'sd20;
        root_llr[1] = -8'sd12;
        root_llr[2] = -8'sd7;
        root_llr[3] =  8'sd5;

        repeat (5) @(negedge clk);
        rst_n = 1'b1;

        pulse_path_init();
        check(path_active_bus === 4'b0001,
              "path_init activates only logical path0");
        check(path_pm_bus[0*PM_W +: PM_W] === 0,
              "path0 PM initializes to zero");

        load_four_llrs();

        // ---------------------------------------------------------------------
        // Parallel f operation and depth1 LLR writeback.
        // ---------------------------------------------------------------------
        issue_llr_operation(0, 0, 1, 1'b0, 1'b0, 0, 0);

        for (p = 0; p < LIST_SIZE; p = p + 1) begin
            check($signed(llr_rd_data_a_bus[p*INT_W +: INT_W]) === 20,
                  "root operand A is shared by all logical paths");
            check($signed(llr_rd_data_b_bus[p*INT_W +: INT_W]) === -12,
                  "root operand B is shared by all logical paths");
            check($signed(pe_result_bus[p*INT_W +: INT_W]) === -12,
                  "parallel min-sum f result is correct");
        end

        write_current_pe_result(1, depth_base(1));

        issue_llr_operation(1, depth_base(1), depth_base(1),
                            1'b0, 1'b0, 0, 0);
        check($signed(llr_rd_data_a_bus[0*INT_W +: INT_W]) === -12,
              "depth1 LLR writeback is readable");

        // ---------------------------------------------------------------------
        // Leaf0 fixed zero. LLR=-7, so PM0 adds 7.
        // ---------------------------------------------------------------------
        issue_leaf_read(2);
        check(cand_pm_bus[0*PM_W +: PM_W] === 12'd7,
              "fixed-zero candidate PM adds absolute negative LLR");
        check(cand_pm_bus[1*PM_W +: PM_W] === 12'd0,
              "opposite hard decision has zero penalty");

        commit_fixed_leaf(0);
        check(path_pm_bus[0*PM_W +: PM_W] === 12'd7,
              "fixed-zero leaf commits PM0");

        // ---------------------------------------------------------------------
        // Leaf1 split path0 into decisions 0 and 1.
        // ---------------------------------------------------------------------
        issue_leaf_read(3);
        check(cand_pm_bus[0*PM_W +: PM_W] === 12'd7,
              "positive leaf bit0 candidate keeps old PM");
        check(cand_pm_bus[1*PM_W +: PM_W] === 12'd12,
              "positive leaf bit1 candidate adds magnitude");

        sel_pm_bus = {LIST_SIZE*PM_W{1'b0}};
        sel_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
        sel_bit_bus = 4'b0010;
        sel_valid_bus = 4'b0011;
        sel_pm_bus[0*PM_W +: PM_W] = 12'd7;
        sel_pm_bus[1*PM_W +: PM_W] = 12'd12;
        sel_parent_bus[0*PATH_W +: PATH_W] = 0;
        sel_parent_bus[1*PATH_W +: PATH_W] = 0;

        commit_pruned_leaf(1);

        check(path_active_bus === 4'b0011,
              "first pruning creates two active logical paths");
        check(path_pm_bus[0*PM_W +: PM_W] === 12'd7,
              "survivor0 PM is correct");
        check(path_pm_bus[1*PM_W +: PM_W] === 12'd12,
              "survivor1 PM is correct");

        // Newly activated path1 must inherit all non-leaf LLR mappings.
        issue_llr_operation(1, depth_base(1), depth_base(1),
                            1'b0, 1'b0, 0, 0);
        check($signed(llr_rd_data_a_bus[0*INT_W +: INT_W]) === -12,
              "survivor0 inherited depth1 LLR bank");
        check($signed(llr_rd_data_a_bus[1*INT_W +: INT_W]) === -12,
              "new survivor1 inherited parent depth1 LLR bank");

        // ---------------------------------------------------------------------
        // Same-cycle LLR+beta issue. Datapath aligns beta to two-cycle LLR read.
        // Leaf beta bits are path0=0, path1=1.
        // g(a=20,b=-12,beta0)=8; g(...,beta1)=-32.
        // ---------------------------------------------------------------------
        issue_llr_operation(0, 0, 1, 1'b1, 1'b1,
                            depth_base(2), depth_base(2));

        check($signed(pe_result_bus[0*INT_W +: INT_W]) === 10'sd8,
              "aligned path0 g result uses beta=0");
        check($signed(pe_result_bus[1*INT_W +: INT_W]) === -10'sd32,
              "aligned path1 g result uses beta=1");

        write_current_pe_result(1, depth_base(1));

        issue_llr_operation(1, depth_base(1), depth_base(1),
                            1'b0, 1'b0, 0, 0);
        check($signed(llr_rd_data_a_bus[0*INT_W +: INT_W]) === 10'sd8,
              "path0 LLR bank separates on first depth write");
        check($signed(llr_rd_data_a_bus[1*INT_W +: INT_W]) === -10'sd32,
              "path1 LLR bank separates on first depth write");

        // ---------------------------------------------------------------------
        // beta transaction: two direct writes and final atomic map commit.
        // ---------------------------------------------------------------------
        beta_direct_write(depth_base(1),   4'b0011, 1'b0);
        beta_direct_write(depth_base(1)+1, 4'b0010, 1'b1);

        issue_beta_read(depth_base(1), depth_base(1)+1);
        check(beta_rd_data_a_bus === 4'b0011,
              "beta read A returns two active private bits");
        check(beta_rd_data_b_bus === 4'b0010,
              "beta read B returns two active private bits");

        beta_wr_mode = BETA_SRC_XOR;
        #1;
        check(beta_selected_data_bus === 4'b0001,
              "beta XOR source selection is correct");

        // ---------------------------------------------------------------------
        // Leaf2 fixed zero for both active paths. Positive LLR keeps PMs.
        // ---------------------------------------------------------------------
        issue_leaf_read(0);
        commit_fixed_leaf(2);
        check(path_pm_bus[0*PM_W +: PM_W] === 12'd7,
              "leaf2 fixed zero keeps path0 PM");
        check(path_pm_bus[1*PM_W +: PM_W] === 12'd12,
              "leaf2 fixed zero keeps path1 PM");

        // ---------------------------------------------------------------------
        // Leaf3 negative LLR=-12. Select all four candidates in sorted order:
        //   dst0 <- parent0 bit1 PM7
        //   dst1 <- parent1 bit1 PM12
        //   dst2 <- parent0 bit0 PM19
        //   dst3 <- parent1 bit0 PM24
        // ---------------------------------------------------------------------
        issue_leaf_read(1);

        sel_pm_bus = {LIST_SIZE*PM_W{1'b0}};
        sel_parent_bus = {LIST_SIZE*PATH_W{1'b0}};
        sel_bit_bus = 4'b0011;
        sel_valid_bus = 4'b1111;

        sel_pm_bus[0*PM_W +: PM_W] = 12'd7;
        sel_pm_bus[1*PM_W +: PM_W] = 12'd12;
        sel_pm_bus[2*PM_W +: PM_W] = 12'd19;
        sel_pm_bus[3*PM_W +: PM_W] = 12'd24;

        sel_parent_bus[0*PATH_W +: PATH_W] = 0;
        sel_parent_bus[1*PATH_W +: PATH_W] = 1;
        sel_parent_bus[2*PATH_W +: PATH_W] = 0;
        sel_parent_bus[3*PATH_W +: PATH_W] = 1;

        commit_pruned_leaf(3);

        check(path_active_bus === 4'b1111,
              "second pruning fills all four logical paths");
        check(best_valid && (best_path === 0) && (best_pm === 12'd7),
              "best-path selector chooses minimum PM with deterministic tie rule");

        // ---------------------------------------------------------------------
        // Natural-order traceback output for final path0 must be 0,0,0,1.
        // ---------------------------------------------------------------------
        @(negedge clk);
        output_path = 0;
        output_start = 1'b1;
        u_ready = 1'b1;
        @(negedge clk);
        output_start = 1'b0;

        timeout_count = 0;
        while (!output_busy && timeout_count < 20) begin
            @(negedge clk);
            timeout_count = timeout_count + 1;
        end
        check(output_busy, "u_hat traceback/output sequence started");

        output_count = 0;
        output_bits = 4'b0000;
        timeout_count = 0;

        while (!output_done && timeout_count < 100) begin
            if (u_valid && u_ready) begin
                if (u_index < 4) begin
                    output_bits[u_index] = u_bit;
                    output_count = output_count + 1;
                end
            end
            @(negedge clk);
            timeout_count = timeout_count + 1;
        end

        check(output_done, "u_hat output_done asserted");
        check(output_count == 4, "exactly four active-code bits streamed");
        check(output_bits === 4'b1000,
              "path0 natural-order u_hat sequence is [0,0,0,1]");

        u_ready = 1'b0;

        if (errors == 0)
            $display("PASS: scl_datapath balanced integration test completed.");
        else
            $display("FAIL: scl_datapath balanced integration errors=%0d", errors);

        $finish;
    end

endmodule
