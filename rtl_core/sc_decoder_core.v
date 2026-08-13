`timescale 1ns/1ps

// =============================================================================
// sc_decoder_core.v
// -----------------------------------------------------------------------------
// 运行时支持五种极化码码长：N=64/128/256/512/1024。
//
// 每个码块的使用顺序：
//   1) config_ready=1 时，脉冲 config_start，并给出 n_log_cfg、k_cfg；
//   2) 等待 config_done，内部 frozen_gen 已生成冻结掩码；
//   3) block_ready=1 时，脉冲 block_start；
//   4) 按自然顺序输入 N=2^n_log 个 LLR；
//   5) 接收 N 个 u_hat，最后等待 block_done；
//   6) block_done 后可复用当前配置，或重新配置下一种 N/K。
//
// 本模块只做封装，不修改已经验证的 frozen_gen、sc_controller、sc_datapath。
// controller 与 datapath 之间的大量微操作端口均隐藏为内部连线。
// =============================================================================
module sc_decoder_core #(
    parameter integer NMAX      = 1024,
    parameter integer LLR_W     = 8,
    parameter integer INT_W     = 10,
    parameter integer MAX_LOG   = 10,
    parameter integer MEM_DEPTH = 2 * NMAX - 1,
    parameter integer ADDR_W    = 11,
    parameter integer INDEX_W   = 11
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // -------------------------------------------------------------------------
    // 码块配置接口
    // -------------------------------------------------------------------------
    input  wire                         config_start,
    input  wire [3:0]                   n_log_cfg,
    input  wire [10:0]                  k_cfg,
    output wire                         config_ready,
    output reg                          config_busy,
    output reg                          config_done,
    output reg                          config_error,

    // -------------------------------------------------------------------------
    // 当前配置下的码块启动接口
    // -------------------------------------------------------------------------
    input  wire                         block_start,
    output wire                         block_ready,
    output wire                         block_busy,
    output wire                         block_done,

    // -------------------------------------------------------------------------
    // 信道LLR串行输入
    // -------------------------------------------------------------------------
    input  wire signed [LLR_W-1:0]      llr_in,
    input  wire                         llr_in_valid,
    output wire                         llr_in_ready,

    // -------------------------------------------------------------------------
    // 译码结果串行输出
    // -------------------------------------------------------------------------
    output wire                         u_valid,
    input  wire                         u_ready,
    output wire                         u_bit,
    output wire [INDEX_W-1:0]           u_index,
    output wire                         u_last
);

    // =========================================================================
    // 配置控制状态机
    // =========================================================================

    localparam [2:0] ST_NO_CONFIG = 3'd0;
    localparam [2:0] ST_CFG_START = 3'd1;
    localparam [2:0] ST_CFG_WAIT  = 3'd2;
    localparam [2:0] ST_READY     = 3'd3;
    localparam [2:0] ST_ACTIVE    = 3'd4;

    localparam [3:0] MAX_LOG_CODE = MAX_LOG;

    reg [2:0] state;

    reg [3:0]  n_log_active;
    reg [10:0] k_active;

    reg  frozen_start;
    wire frozen_busy;
    wire frozen_done;

    // 明确保留该名称，便于testbench层次化检查。
    wire [NMAX-1:0] frozen_mask;

    reg datapath_load_start;

    wire [11:0] cfg_n_value;
    wire        cfg_n_valid;
    wire        cfg_k_valid;
    wire        cfg_valid;

    assign cfg_n_value = (12'd1 << n_log_cfg);

    assign cfg_n_valid =
        (n_log_cfg >= 4'd6) &&
        (n_log_cfg <= MAX_LOG_CODE);

    assign cfg_k_valid =
        ({1'b0, k_cfg} <= cfg_n_value);

    assign cfg_valid =
        cfg_n_valid && cfg_k_valid;

    assign config_ready =
        ((state == ST_NO_CONFIG) ||
         (state == ST_READY)) &&
        !config_busy;

    assign block_ready =
        (state == ST_READY);

    // =========================================================================
    // frozen_gen
    // =========================================================================

    frozen_gen #(
        .NMAX(NMAX)
    )
    u_frozen_gen (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (frozen_start),
        .n_log   (n_log_active),
        .K       (k_active),
        .busy    (frozen_busy),
        .done    (frozen_done),
        .frozen  (frozen_mask)
    );

    // =========================================================================
    // controller与datapath内部连线
    // =========================================================================

    wire load_busy;
    wire load_done;

    wire decode_busy;
    wire decode_done;

    wire output_busy;
    wire output_done;

    wire [ADDR_W-1:0] llr_rd_addr_a;
    wire [ADDR_W-1:0] llr_rd_addr_b;

    wire signed [INT_W-1:0] llr_rd_data_a;
    wire signed [INT_W-1:0] llr_rd_data_b;

    wire pe_mode_g;
    wire llr_wr_en;
    wire [ADDR_W-1:0] llr_wr_addr;
    wire signed [INT_W-1:0] pe_result;

    wire [ADDR_W-1:0] beta_rd_addr_a;
    wire [ADDR_W-1:0] beta_rd_addr_b;
    wire beta_rd_data_a;
    wire beta_rd_data_b;

    wire beta_wr_en;
    wire [ADDR_W-1:0] beta_wr_addr;
    wire beta_wr_data;
    wire [1:0] beta_wr_mode;
    wire beta_selected_data;

    wire leaf_decision_en;
    wire leaf_frozen;
    wire [INDEX_W-1:0] leaf_index;
    wire [ADDR_W-1:0] leaf_beta_wr_addr;
    wire leaf_decision;

    wire output_start;

    assign block_done = decode_done;

    assign block_busy =
        config_busy ||
        (state == ST_ACTIVE) ||
        load_busy ||
        decode_busy ||
        output_busy;

    // =========================================================================
    // sc_datapath
    // =========================================================================

    sc_datapath #(
        .NMAX      (NMAX),
        .LLR_W     (LLR_W),
        .INT_W     (INT_W),
        .MAX_LOG   (MAX_LOG),
        .MEM_DEPTH (MEM_DEPTH),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    )
    u_datapath (
        .clk                 (clk),
        .rst_n               (rst_n),

        .load_start          (datapath_load_start),
        .n_log               (n_log_active),
        .llr_in              (llr_in),
        .llr_in_valid        (llr_in_valid),
        .llr_in_ready        (llr_in_ready),
        .load_busy           (load_busy),
        .load_done           (load_done),

        .llr_rd_addr_a       (llr_rd_addr_a),
        .llr_rd_addr_b       (llr_rd_addr_b),
        .llr_rd_data_a       (llr_rd_data_a),
        .llr_rd_data_b       (llr_rd_data_b),

        .pe_mode_g           (pe_mode_g),
        .llr_wr_en           (llr_wr_en),
        .llr_wr_addr         (llr_wr_addr),
        .pe_result           (pe_result),

        .beta_rd_addr_a      (beta_rd_addr_a),
        .beta_rd_data_a      (beta_rd_data_a),

        .beta_rd_addr_b      (beta_rd_addr_b),
        .beta_rd_data_b      (beta_rd_data_b),

        .beta_wr_en          (beta_wr_en),
        .beta_wr_addr        (beta_wr_addr),
        .beta_wr_data        (beta_wr_data),
        .beta_wr_mode        (beta_wr_mode),
        .beta_selected_data  (beta_selected_data),

        .leaf_decision_en    (leaf_decision_en),
        .leaf_frozen         (leaf_frozen),
        .leaf_index          (leaf_index),
        .leaf_beta_wr_addr   (leaf_beta_wr_addr),
        .leaf_decision       (leaf_decision),

        .output_start        (output_start),
        .output_busy         (output_busy),
        .output_done         (output_done),

        .u_valid             (u_valid),
        .u_ready             (u_ready),
        .u_bit               (u_bit),
        .u_index             (u_index),
        .u_last              (u_last)
    );

    // =========================================================================
    // sc_controller
    // =========================================================================

    sc_controller #(
        .NMAX      (NMAX),
        .MAX_LOG   (MAX_LOG),
        .ADDR_W    (ADDR_W),
        .INDEX_W   (INDEX_W)
    )
    u_controller (
        .clk                  (clk),
        .rst_n                (rst_n),

        .decode_start         (load_done),
        .n_log                (n_log_active),
        .frozen_bits          (frozen_mask),

        .decode_busy          (decode_busy),
        .decode_done          (decode_done),

        .llr_rd_addr_a        (llr_rd_addr_a),
        .llr_rd_addr_b        (llr_rd_addr_b),
        .pe_mode_g            (pe_mode_g),
        .llr_wr_en            (llr_wr_en),
        .llr_wr_addr          (llr_wr_addr),

        .beta_rd_addr_a       (beta_rd_addr_a),
        .beta_rd_addr_b       (beta_rd_addr_b),
        .beta_wr_en           (beta_wr_en),
        .beta_wr_addr         (beta_wr_addr),
        .beta_wr_data         (beta_wr_data),
        .beta_wr_mode         (beta_wr_mode),

        .leaf_decision_en     (leaf_decision_en),
        .leaf_frozen          (leaf_frozen),
        .leaf_index           (leaf_index),
        .leaf_beta_wr_addr    (leaf_beta_wr_addr),

        .output_start         (output_start),
        .output_done          (output_done)
    );

    // =========================================================================
    // 配置/码块状态控制
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state               <= ST_NO_CONFIG;
            n_log_active        <= 4'd6;
            k_active            <= 11'd0;

            frozen_start        <= 1'b0;
            datapath_load_start <= 1'b0;

            config_busy         <= 1'b0;
            config_done         <= 1'b0;
            config_error        <= 1'b0;
        end
        else begin
            // 默认脉冲信号拉低
            frozen_start        <= 1'b0;
            datapath_load_start <= 1'b0;
            config_done         <= 1'b0;
            config_error        <= 1'b0;

            case (state)

                // -------------------------------------------------------------
                // 尚无有效配置
                // -------------------------------------------------------------
                ST_NO_CONFIG: begin
                    config_busy <= 1'b0;

                    if (config_start) begin
                        if (cfg_valid) begin
                            n_log_active <= n_log_cfg;
                            k_active     <= k_cfg;

                            config_busy  <= 1'b1;
                            state        <= ST_CFG_START;
                        end
                        else begin
                            config_error <= 1'b1;
                        end
                    end
                end

                // -------------------------------------------------------------
                // 在锁存配置后的下一拍启动frozen_gen
                // -------------------------------------------------------------
                ST_CFG_START: begin
                    config_busy  <= 1'b1;
                    frozen_start <= 1'b1;
                    state        <= ST_CFG_WAIT;
                end

                // -------------------------------------------------------------
                // 等待冻结掩码完成
                // -------------------------------------------------------------
                ST_CFG_WAIT: begin
                    config_busy <= 1'b1;

                    if (frozen_done) begin
                        config_busy <= 1'b0;
                        config_done <= 1'b1;
                        state       <= ST_READY;
                    end
                end

                // -------------------------------------------------------------
                // 已有配置，可以启动码块或重新配置
                // -------------------------------------------------------------
                ST_READY: begin
                    config_busy <= 1'b0;

                    if (config_start) begin
                        if (cfg_valid) begin
                            n_log_active <= n_log_cfg;
                            k_active     <= k_cfg;

                            config_busy  <= 1'b1;
                            state        <= ST_CFG_START;
                        end
                        else begin
                            config_error <= 1'b1;
                        end
                    end
                    else if (block_start) begin
                        datapath_load_start <= 1'b1;
                        state               <= ST_ACTIVE;
                    end
                end

                // -------------------------------------------------------------
                // 当前码块正在装载、译码或输出
                // -------------------------------------------------------------
                ST_ACTIVE: begin
                    config_busy <= 1'b0;

                    if (decode_done) begin
                        state <= ST_READY;
                    end
                end

                default: begin
                    state        <= ST_NO_CONFIG;
                    config_busy  <= 1'b0;
                    config_error <= 1'b1;
                end

            endcase
        end
    end

endmodule