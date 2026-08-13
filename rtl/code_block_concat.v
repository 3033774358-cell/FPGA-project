// =============================================================================
// code_block_concat.v -- 码块级联 (T/XS 10002-2025  6.9.1.5)
// -----------------------------------------------------------------------------
// 将各码块编码后的比特序列 f_r(0..E_r-1) 按码块顺序串行拼接为输出 g_k:
//   k=0; for r=0..C-1 { for j=0..E_r-1 { g[k]=f_r(j); k++; } }
// 逐块装入(s_load, 并行码块 s_blk, 有效长 s_elen), 串行输出拼接流(m_valid/m_bit),
// k_count 给出输出比特序号 k. s_ready=1 时可装入下一块; done 在最后一块输出完脉冲.
// =============================================================================
module code_block_concat #(
    parameter integer NMAX = 1024
)(
    input  wire             clk,
    input  wire             rst_n,
    // 装入一个码块
    input  wire             s_load,       // s_ready=1 时的装入脉冲
    input  wire [NMAX-1:0]  s_blk,        // 码块比特 f_r, bit j = f_r(j)
    input  wire [10:0]      s_elen,       // 该块有效比特数 E_r
    input  wire             s_last,       // 是否最后一块
    output reg              s_ready,       // 可接收下一块
    // 串行拼接输出
    output reg              m_valid,
    output reg              m_bit,
    output reg [31:0]       k_count,
    output reg              done          // 最后一块输出完毕 (单拍)
);
    reg [NMAX-1:0] blk;
    reg [10:0]     elen, j;
    reg            last_r;
    localparam IDLE=1'b0, EMIT=1'b1;
    reg st;

    // -------------------------------------------------------------------------
    // 块数据寄存器 (blk/elen/last_r): **独立无复位块**
    //   这三个是纯数据保持寄存器, 原先待在带异步复位的 always 块内、但复位分支又
    //   没给它们赋值, Vivado 因此报 [Synth 8-7137] "Set 与 reset 同优先级, 可能
    //   导致仿真与综合不一致"(真实风险, 非风格告警)。
    //   移出后语义完全不变: 装载条件仍为 (st==IDLE && s_load), 且它们只在装载后
    //   被读取, 复位期的值不参与任何判断。
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if ((st == IDLE) && s_load) begin
            blk    <= s_blk;
            elen   <= s_elen;
            last_r <= s_last;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_ready<=1'b1; m_valid<=1'b0; m_bit<=1'b0; k_count<=32'd0;
            done<=1'b0; j<=11'd0; st<=IDLE;
        end else begin
            done<=1'b0; m_valid<=1'b0;
            case (st)
                IDLE: begin
                    s_ready <= 1'b1;
                    if (s_load) begin
                        // blk/elen/last_r 在下方独立无复位块装载 (见 Synth 8-7137 说明)
                        j<=11'd0; s_ready<=1'b0;
                        // 空块保护 (E_r=0): 若不拦截, EMIT 的判据 j==elen-1 会下溢成
                        // j==2047(11位), 导致误吐 2048 位。 空帧(附录H TV215, B=0)
                        // 与 R=1 直通零长块都会走到这里 —— 直接不输出任何比特。
                        if (s_elen == 11'd0) begin
                            if (s_last) done <= 1'b1;
                            st <= IDLE;
                        end else st<=EMIT;
                    end
                end
                EMIT: begin
                    m_valid <= 1'b1;
                    m_bit   <= blk[j[9:0]];        // g[k] = f_r(j)  (j<=1023, 取低10位索引)
                    k_count <= k_count + 1'b1;
                    if (j == elen-1) begin
                        if (last_r) done <= 1'b1;
                        st <= IDLE;                // 本块输出完, 回 IDLE 等下一块
                    end else begin
                        j <= j + 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
