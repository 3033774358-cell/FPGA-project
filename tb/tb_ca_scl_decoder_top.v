`timescale 1ns/1ps

// =============================================================================
// tb_ca_scl_decoder_top.v
// =============================================================================
// Full-frame self-checking integration test.
//
// The uploaded polar_encode_chain is used as the golden transmitter. Its
// concatenated code bits are captured, mapped to noiseless signed LLRs, and
// then supplied to ca_scl_decoder_top. The decoder output is compared with the
// original a0-first message stream.
//
// Cases:
//   1. frame type 2, B=500, MCS=5
//      table20/table24 multi-subblock segmentation, final front padding.
//      Expected Polar subblocks: 6; logical blocks: 6; no CRC.
//
//   2. frame type 3, B=100, MCS=0
//      one no-CRC logical block split as N=512 + N=64.
//      Expected Polar subblocks: 2; logical blocks: 1; no CRC.
//
//   3. frame type 4, B=270, MCS=0
//      two CRC logical blocks. The last logical block is split as N=256+N=128;
//      its message and CRC fields cross the Polar-subblock boundary.
//      Expected Polar subblocks: 3; logical blocks: 2; CRC-pass pulses: 2.
//
// All source conventions are preserved:
//   msg[0] / a0 first
//   d[0] first
//   code bit 0 -> +64 LLR, code bit 1 -> -64 LLR
//   CRC24B polynomial 24'hB2B117, seed 24'h555555
// =============================================================================

module tb_ca_scl_decoder_top;

    localparam integer NMAX      = 1024;
    localparam integer MSG_MAX   = 2048;
    localparam integer CODE_MAX  = 16384;
    localparam integer LLR_W     = 8;
    localparam integer INT_W     = 10;
    localparam integer MAX_LOG   = 10;
    localparam integer LIST_SIZE = 4;
    localparam integer PM_W      = 24;

    reg clk;
    reg rst_n;

    // Encoder controls.
    reg                     enc_start;
    reg [MSG_MAX-1:0]       enc_msg;
    reg [15:0]              enc_B;
    reg [3:0]               enc_mcs;
    reg                     enc_ftype2;
    reg [23:0]              enc_crc_seed;
    wire                    enc_busy;
    wire                    enc_done;
    wire                    enc_m_valid;
    wire                    enc_m_bit;
    wire [31:0]             enc_k_count;
    wire [7:0]              enc_cb_count;

    // Decoder controls.
    reg                     dec_cfg_start;
    reg [2:0]               dec_frame_type;
    reg [15:0]              dec_B;
    reg [3:0]               dec_mcs;
    reg [23:0]              dec_crc_seed;
    wire                    dec_cfg_ready;
    wire                    dec_busy;
    wire                    dec_done;
    wire                    dec_error;
    wire                    dec_crc_fail;
    wire                    dec_cb_crc_valid;
    wire                    dec_cb_crc_pass;

    reg signed [LLR_W-1:0]  dec_s_llr;
    reg                     dec_s_llr_valid;
    wire                    dec_s_llr_ready;

    wire                    dec_m_valid;
    reg                     dec_m_ready;
    wire                    dec_m_bit;
    wire [15:0]             dec_m_index;
    wire                    dec_m_last;

    wire [7:0]              dec_polar_subblock_count;
    wire [7:0]              dec_logical_cb_count;
    wire [31:0]             dec_llr_count;

    reg code_mem [0:CODE_MAX-1];
    reg msg_ref  [0:MSG_MAX-1];

    integer errors;
    integer checks;

    integer enc_capture_enable;
    integer enc_count;

    integer score_enable;
    integer out_count;
    integer out_mismatch_count;
    integer out_last_count;
    integer crc_valid_count;
    integer crc_pass_count;
    integer ready_cycle;
    integer use_backpressure;

    integer case_number;
    integer i;

    // =========================================================================
    // Actual uploaded encoder
    // =========================================================================

    polar_encode_chain #(
        .NMAX   (NMAX),
        .MSG_MAX(MSG_MAX)
    ) u_encoder (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (enc_start),
        .msg      (enc_msg),
        .B        (enc_B),
        .mcs      (enc_mcs),
        .ftype2   (enc_ftype2),
        .crc_seed (enc_crc_seed),
        .busy     (enc_busy),
        .done     (enc_done),
        .m_valid  (enc_m_valid),
        .m_bit    (enc_m_bit),
        .k_count  (enc_k_count),
        .cb_count (enc_cb_count)
    );

    // =========================================================================
    // Complete frame-type 2/3/4 decoder
    // =========================================================================

    ca_scl_decoder_top #(
        .NMAX              (NMAX),
        .MSG_MAX           (MSG_MAX),
        .LLR_W             (LLR_W),
        .INT_W             (INT_W),
        .MAX_LOG           (MAX_LOG),
        .LIST_SIZE         (LIST_SIZE),
        .PM_W              (PM_W),
        .MAX_CB_SUBBLOCKS  (4),
        .CRC_FAIL_FALLBACK (1)
    ) u_decoder (
        .clk                    (clk),
        .rst_n                  (rst_n),

        .cfg_start              (dec_cfg_start),
        .frame_type             (dec_frame_type),
        .B                      (dec_B),
        .mcs                    (dec_mcs),
        .crc_seed               (dec_crc_seed),

        .cfg_ready              (dec_cfg_ready),
        .busy                   (dec_busy),
        .done                   (dec_done),
        .error                  (dec_error),
        .crc_fail               (dec_crc_fail),
        .cb_crc_valid           (dec_cb_crc_valid),
        .cb_crc_pass            (dec_cb_crc_pass),

        .s_llr                  (dec_s_llr),
        .s_llr_valid            (dec_s_llr_valid),
        .s_llr_ready            (dec_s_llr_ready),

        .m_valid                (dec_m_valid),
        .m_ready                (dec_m_ready),
        .m_bit                  (dec_m_bit),
        .m_index                (dec_m_index),
        .m_last                 (dec_m_last),

        .polar_subblock_count   (dec_polar_subblock_count),
        .logical_cb_count       (dec_logical_cb_count),
        .llr_count              (dec_llr_count)
    );

    always #5 clk = ~clk;

    // =========================================================================
    // Generic checker
    // =========================================================================

    task check_true;
        input condition;
        input [8*180-1:0] message;
        begin
            checks = checks + 1;

            if (condition) begin
                $display("PASS: %0s", message);
            end
            else begin
                errors = errors + 1;
                $display("FAIL: %0s time=%0t", message, $time);
            end
        end
    endtask

    // =========================================================================
    // Message preparation
    // =========================================================================

    task prepare_message;
        input [15:0] bit_length;
        input integer pattern_id;
        integer idx;
        reg [15:0] lfsr;
        reg bit_value;
        begin
            enc_msg = {MSG_MAX{1'b0}};
            lfsr    = 16'h9E37 ^ pattern_id;

            for (idx = 0; idx < MSG_MAX; idx = idx + 1)
                msg_ref[idx] = 1'b0;

            for (idx = 0; idx < bit_length; idx = idx + 1) begin
                case (pattern_id)
                    0: bit_value = 1'b0;
                    1: bit_value = 1'b1;
                    2: bit_value = idx[0];
                    default: begin
                        bit_value = lfsr[0];
                        lfsr = {
                            lfsr[0] ^ lfsr[2] ^ lfsr[3] ^ lfsr[5],
                            lfsr[15:1]
                        };
                    end
                endcase

                enc_msg[idx] = bit_value;
                msg_ref[idx] = bit_value;
            end
        end
    endtask

    // =========================================================================
    // Encode one frame and capture g[0]...g[E-1]
    // =========================================================================

    task encode_frame;
        input [15:0] bit_length;
        input [3:0]  mcs_value;
        input        is_type2;
        integer guard;
        begin
            while (enc_busy)
                @(posedge clk);

            enc_count          = 0;
            enc_capture_enable = 1;

            @(negedge clk);
            enc_B        = bit_length;
            enc_mcs      = mcs_value;
            enc_ftype2   = is_type2;
            enc_crc_seed = 24'h555555;
            enc_start    = 1'b1;

            @(negedge clk);
            enc_start = 1'b0;

            guard = 0;
            while (!enc_done && (guard < 3000000)) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end

            check_true(guard < 3000000, "encoder done observed before timeout");
            check_true(enc_done, "encoder done asserted");
            check_true(enc_count > 0, "encoder produced concatenated code bits");
            check_true(enc_count < CODE_MAX, "captured code stream fits CODE_MAX");

            enc_capture_enable = 0;
        end
    endtask

    always @(posedge clk) begin
        if (rst_n && (enc_capture_enable != 0) && enc_m_valid) begin
            if (enc_count < CODE_MAX) begin
                code_mem[enc_count] = enc_m_bit;
                enc_count = enc_count + 1;
            end
            else begin
                errors = errors + 1;
                $display("FAIL: encoder code stream overflow time=%0t", $time);
            end
        end
    end

    // =========================================================================
    // Decoder output scoreboard and backpressure
    // =========================================================================

    always @(negedge clk) begin
        if (!rst_n) begin
            dec_m_ready <= 1'b1;
            ready_cycle <= 0;
        end
        else if (score_enable != 0) begin
            ready_cycle <= ready_cycle + 1;

            if (use_backpressure != 0)
                dec_m_ready <= ((ready_cycle % 7) != 2) &&
                               ((ready_cycle % 7) != 3);
            else
                dec_m_ready <= 1'b1;
        end
        else begin
            dec_m_ready <= 1'b1;
            ready_cycle <= 0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            out_count          = 0;
            out_mismatch_count = 0;
            out_last_count     = 0;
            crc_valid_count    = 0;
            crc_pass_count     = 0;
        end
        else if (score_enable != 0) begin
            if (dec_cb_crc_valid) begin
                crc_valid_count = crc_valid_count + 1;

                if (dec_cb_crc_pass)
                    crc_pass_count = crc_pass_count + 1;
            end

            if (dec_m_valid && dec_m_ready) begin
                checks = checks + 1;

                if (dec_m_index !== out_count[15:0]) begin
                    errors = errors + 1;
                    out_mismatch_count = out_mismatch_count + 1;
                    $display(
                        "FAIL: case%0d m_index got=%0d expected=%0d time=%0t",
                        case_number, dec_m_index, out_count, $time
                    );
                end
                else if (dec_m_bit !== msg_ref[out_count]) begin
                    errors = errors + 1;
                    out_mismatch_count = out_mismatch_count + 1;
                    $display(
                        "FAIL: case%0d message[%0d] got=%0b expected=%0b time=%0t",
                        case_number, out_count, dec_m_bit,
                        msg_ref[out_count], $time
                    );
                end

                if (dec_m_last) begin
                    out_last_count = out_last_count + 1;

                    if (out_count != dec_B - 1'b1) begin
                        errors = errors + 1;
                        $display(
                            "FAIL: case%0d m_last at index=%0d expected=%0d time=%0t",
                            case_number, out_count, dec_B - 1'b1, $time
                        );
                    end
                end

                out_count = out_count + 1;
            end
        end
    end

    // =========================================================================
    // Decode one captured frame
    // =========================================================================

    task decode_frame;
        input [2:0]  frame_type_value;
        input [15:0] bit_length;
        input [3:0]  mcs_value;
        input integer expected_subblocks;
        input integer expected_logical_blocks;
        input integer expected_crc_blocks;
        input integer apply_backpressure;

        integer feed_index;
        integer send_armed;
        integer guard;
        begin
            while (!dec_cfg_ready)
                @(posedge clk);

            out_count          = 0;
            out_mismatch_count = 0;
            out_last_count     = 0;
            crc_valid_count    = 0;
            crc_pass_count     = 0;
            ready_cycle        = 0;
            use_backpressure   = apply_backpressure;
            score_enable       = 1;

            @(negedge clk);
            dec_frame_type = frame_type_value;
            dec_B          = bit_length;
            dec_mcs        = mcs_value;
            dec_crc_seed   = 24'h555555;
            dec_cfg_start  = 1'b1;

            @(negedge clk);
            dec_cfg_start = 1'b0;

            feed_index = 0;
            send_armed = 0;
            guard      = 0;

            while ((feed_index < enc_count) &&
                   !dec_error &&
                   (guard < 5000000)) begin
                @(negedge clk);

                if (dec_s_llr_ready) begin
                    dec_s_llr =
                        code_mem[feed_index] ? -8'sd64 : 8'sd64;
                    dec_s_llr_valid = 1'b1;
                    send_armed = 1;
                end
                else begin
                    dec_s_llr       = {LLR_W{1'b0}};
                    dec_s_llr_valid = 1'b0;
                    send_armed      = 0;
                end

                @(posedge clk);
                #1;

                if (send_armed != 0)
                    feed_index = feed_index + 1;

                guard = guard + 1;
            end

            @(negedge clk);
            dec_s_llr_valid = 1'b0;
            dec_s_llr       = {LLR_W{1'b0}};

            check_true(!dec_error, "decoder has no error while accepting LLRs");
            check_true(feed_index == enc_count, "decoder accepts complete encoded LLR stream");

            guard = 0;
            while (!dec_done && !dec_error && (guard < 5000000)) begin
                @(posedge clk);
                #1;
                guard = guard + 1;
            end

            check_true(guard < 5000000, "decoder done observed before timeout");
            check_true(!dec_error, "decoder completes without error");
            check_true(dec_done, "decoder done asserted");
            check_true(!dec_crc_fail, "noiseless frame has no CRC failure");
            check_true(out_count == bit_length, "decoder outputs exactly B message bits");
            check_true(out_mismatch_count == 0, "decoded message equals encoder input");
            check_true(out_last_count == 1, "m_last asserts exactly once");
            check_true(dec_llr_count == enc_count, "decoder LLR count equals encoder code length");
            check_true(dec_polar_subblock_count == expected_subblocks, "Polar subblock count matches encoder segmentation");
            check_true(dec_polar_subblock_count == enc_cb_count, "decoder Polar subblock count equals encoder cb_count");
            check_true(dec_logical_cb_count == expected_logical_blocks, "logical code-block count is correct");
            check_true(crc_valid_count == expected_crc_blocks, "CRC-result pulse count is correct");
            check_true(crc_pass_count == expected_crc_blocks, "all noiseless CRC blocks pass");

            @(posedge clk);
            #1;
            check_true(dec_cfg_ready, "decoder returns to cfg_ready");

            score_enable     = 0;
            use_backpressure = 0;
        end
    endtask

    // =========================================================================
    // Main sequence
    // =========================================================================

    initial begin
        clk                = 1'b0;
        rst_n              = 1'b0;

        enc_start          = 1'b0;
        enc_msg            = {MSG_MAX{1'b0}};
        enc_B              = 16'd0;
        enc_mcs            = 4'd0;
        enc_ftype2         = 1'b0;
        enc_crc_seed       = 24'h555555;

        dec_cfg_start      = 1'b0;
        dec_frame_type     = 3'd2;
        dec_B              = 16'd0;
        dec_mcs            = 4'd0;
        dec_crc_seed       = 24'h555555;
        dec_s_llr          = {LLR_W{1'b0}};
        dec_s_llr_valid    = 1'b0;
        dec_m_ready        = 1'b1;

        errors             = 0;
        checks             = 0;
        enc_capture_enable = 0;
        enc_count          = 0;
        score_enable       = 0;
        out_count          = 0;
        out_mismatch_count = 0;
        out_last_count     = 0;
        crc_valid_count    = 0;
        crc_pass_count     = 0;
        ready_cycle        = 0;
        use_backpressure   = 0;
        case_number        = 0;

        for (i = 0; i < CODE_MAX; i = i + 1)
            code_mem[i] = 1'b0;

        for (i = 0; i < MSG_MAX; i = i + 1)
            msg_ref[i] = 1'b0;

        repeat (10) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        repeat (4) @(posedge clk);
        check_true(dec_cfg_ready, "decoder cfg_ready after reset");

        // ---------------------------------------------------------------------
        // Case 1: frame type 2
        // ---------------------------------------------------------------------
        case_number = 1;
        $display("---- CASE 1: frame type2 B=500 MCS=5 ----");
        prepare_message(16'd500, 3);
        encode_frame(16'd500, 4'd5, 1'b1);
        decode_frame(3'd2, 16'd500, 4'd5, 6, 6, 0, 1);

        // ---------------------------------------------------------------------
        // Case 2: frame type 3, no CRC, split final logical block
        // ---------------------------------------------------------------------
        case_number = 2;
        $display("---- CASE 2: frame type3 B=100 MCS=0 no CRC ----");
        prepare_message(16'd100, 2);
        encode_frame(16'd100, 4'd0, 1'b0);
        decode_frame(3'd3, 16'd100, 4'd0, 2, 1, 0, 1);

        // ---------------------------------------------------------------------
        // Case 3: frame type 4, CRC logical blocks and cross-subblock CRC
        // ---------------------------------------------------------------------
        case_number = 3;
        $display("---- CASE 3: frame type4 B=270 MCS=0 CRC24B ----");
        prepare_message(16'd270, 3);
        encode_frame(16'd270, 4'd0, 1'b0);
        decode_frame(3'd4, 16'd270, 4'd0, 3, 2, 2, 1);

        if (errors == 0)
            $display("PASS: tb_ca_scl_decoder_top completed %0d checks.", checks);
        else
            $display("FAIL: tb_ca_scl_decoder_top errors=%0d checks=%0d.", errors, checks);

        $finish;
    end

    initial begin
        #200000000;
        $display(
            "FAIL: tb_ca_scl_decoder_top global timeout case=%0d decoder_state=%0d core_state=%0d controller_state=%0d time=%0t",
            case_number,
            u_decoder.state,
            u_decoder.u_scl_core.state,
            u_decoder.u_scl_core.u_controller.state,
            $time
        );
        $finish;
    end

endmodule
