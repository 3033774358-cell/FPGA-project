// =============================================================================
// frozen_gen.v  --  由 (N, K) 生成极化码冻结掩码 (依据 spec 附录C 可靠度序列)
// -----------------------------------------------------------------------------
// spec 6.9.1.4: 码长 N、信息位数 K 时, 在可靠度排序序列 Q_0^{N-1} 中取"后 K 个"
// (可靠性最高) 索引作为非冻结(信息)集, 前 N-K 个作为冻结集. 且长为 N 的序列是
// 全序列 Q_0^{Nmax-1} 中"比特索引 < N"的子序列 (嵌套性).
//
// 实现: 从最高可靠度秩 (rank=NMAX-1) 向下扫描可靠度 ROM, 对每个 rank 取比特索引
// q=ROM[rank]; 若 q<N 且信息配额未满, 则将 q 标为信息位 (frozen[q]=0), 直到标满 K 个.
//   —— 自顶向下天然给出"可靠性最高的 K 个 (且索引<N) 位置", 即非冻结集.
// 位 >= N 的 frozen 恒为 1 (置0), 便于后续 u 装配对任意 N 统一处理.
//
// 时延: 可变, 最多 ~NMAX 拍 (一次配置). 混合码长流中同一 (N,K) 只需配置一次,
//       顶层可缓存复用 (见 polar_encode_top).
//
// 端口: start 在 busy=0 时被接受; done 为单拍脉冲, 与 frozen 有效同拍.
// =============================================================================
module frozen_gen #(
    parameter integer NMAX = 1024
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             start,
    input  wire [3:0]       n_log,     // log2(N); spec 取 6..10, 也支持更小便于测试
    input  wire [10:0]      K,         // 信息位数 (0..N)
    output reg              busy,
    output reg              done,
    output reg [NMAX-1:0]   frozen     // 1=冻结(u=0), 0=信息位; 位>=N 恒为1
);
    localparam integer RW = $clog2(NMAX);   // 秩位宽 (=10)
    localparam [RW-1:0] RANK_MAX = {RW{1'b1}};   // = NMAX-1 (NMAX 为 2 的幂)

    reg  [RW-1:0] rank;
    wire [9:0]    q;                        // 当前秩对应的比特索引
    reg  [11:0]   need;                     // 尚需标记的信息位数
    wire [11:0]   N = (12'd1 << n_log);     // 码长 N

    polar_reliability_rom u_rom (.rank(rank), .q(q));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy   <= 1'b0;
            done   <= 1'b0;
            frozen <= {NMAX{1'b1}};
            rank   <= {RW{1'b0}};
            need   <= 12'd0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                frozen <= {NMAX{1'b1}};      // 全部先置冻结
                need   <= {1'b0, K};
                rank   <= RANK_MAX;          // 从最高可靠度秩开始
                busy   <= (K != 0);          // K=0 则无需处理
                done   <= (K == 0);          // K=0 立即完成 (全冻结)
            end else if (busy) begin
                if (({2'b00, q} < N) && (need != 0)) begin
                    frozen[q] <= 1'b0;        // 标为信息位
                    if (need == 12'd1) begin  // 刚标满 K 个 -> 完成
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        need <= need - 1'b1;
                        rank <= rank - 1'b1;
                    end
                end else begin
                    if (rank == 0) begin      // 扫到底 (K>N 的异常保护) -> 结束
                        busy <= 1'b0;
                        done <= 1'b1;
                    end else begin
                        rank <= rank - 1'b1;
                    end
                end
            end
        end
    end
endmodule
