// =============================================================================
// polar_butterfly.v -- 纯蝶形编码 (档案 3.4 polar_encode_simple, 可综合)
// -----------------------------------------------------------------------------
// 只做 d = u * G_N (GF(2)) 的迭代蝶形, 不含 build_u_vector 的信息位散布网络
// (散布在顶层 polar_encode_full 里以移位寄存器串行完成 —— 正是档案把
//  build_u_vector 与 polar_encode_simple 分成两个函数的原因)。
//
// ★ 为什么单独抽出来: 导师确认版 polar_encoder.v 把"散布 + 蝶形"合在一个模块,
//   当 N=1024 时其内部散布网络在 Vivado 分层综合下无法塌缩, 占 ~175k LUT。
//   蝶形本身只是 XOR, 便宜; 把散布拿到外面串行做, 编码器就只剩蝶形 (~数千 LUT)。
//   本模块蝶形逻辑与确认版逐字相同, 仅去掉 u_packed 那段; 确认版原封不动保留。
//
// 运行时可变 N: 固定 log2(NMAX) 级蝶形网络, 编码 N=2^n_log 的码块时只施加前
//   n_log 级 (stage 0..n_log-1); u 的有效块须"低位对齐"在 u[0..N-1], 高位为 0,
//   则前 n_log 级不会把高位混入低 N 位, 低 N 位即为码字 (与 polar_encoder_nvar
//   验证过的可变 N 蝶形同理)。
//
// 时延 = n_log + 1 拍; 握手: start 在 busy=0 被接受; done 单拍脉冲。
// =============================================================================
module polar_butterfly #(
    parameter integer NMAX = 1024
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire [3:0]       n_log,      // log2(N)
    input  wire [NMAX-1:0]  u,          // 预装配 u (低 N 位有效, u[k]=第 k 个输入, 高位0)
    output reg              busy,
    output reg              done,
    output reg [NMAX-1:0]   d           // 码字 (低 N 位有效)
);
    localparam integer SMAX = $clog2(NMAX);
    localparam integer CW   = (SMAX <= 1) ? 1 : $clog2(SMAX+1);

    reg  [NMAX-1:0] x;
    reg  [CW-1:0]   stage;
    wire [NMAX-1:0] stage_net [0:SMAX-1];

    genvar gs, gi, gj;
    generate
        for (gs = 0; gs < SMAX; gs = gs + 1) begin : g_stage
            localparam integer M = (1 << gs);
            for (gi = 0; gi < NMAX; gi = gi + 2*M) begin : g_grp
                for (gj = 0; gj < M; gj = gj + 1) begin : g_pair
                    assign stage_net[gs][gi+gj]   = x[gi+gj] ^ x[gi+gj+M];
                    assign stage_net[gs][gi+gj+M] = x[gi+gj+M];
                end
            end
        end
    endgenerate

    wire [NMAX-1:0] x_next  = stage_net[stage];
    wire [CW-1:0]   last_st = n_log - 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy  <= 1'b0;
            done  <= 1'b0;
            stage <= {CW{1'b0}};
            x     <= {NMAX{1'b0}};
            d     <= {NMAX{1'b0}};
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                x     <= u;
                stage <= {CW{1'b0}};
                busy  <= 1'b1;
            end else if (busy) begin
                x <= x_next;
                if (stage == last_st) begin
                    d    <= x_next;
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    stage <= stage + 1'b1;
                end
            end
        end
    end
endmodule
