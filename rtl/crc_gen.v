// =============================================================================
// crc_gen.v  --  串行 LFSR 循环冗余校验 (T/XS 10002-2025  6.9.1.1 / 6.10.1)
// -----------------------------------------------------------------------------
// 6.9.1.3 带CRC的码块分段: 每个码块用生成多项式 g_CRC24B(D) 计算 24 比特 CRC.
// 采用系统码: 多项式 a0*D^(A+L-1)+...+a_{A-1}*D^L + p0*D^(L-1)+...+p_{L-1} 可被 g(D) 整除.
// 输入比特按 MSB(a0) 优先逐比特送入; 送完 A 个消息比特后 crc 即为 L 位校验.
//
// 生成多项式 (摘自 spec 6.10.1, 仅取低 L 位, 隐含最高次 D^L):
//   g_CRC24B(D)=D24+D23+D21+D20+D17+D15+D13+D12+D8+D4+D2+D+1  -> POLY=24'hB2B117
//   (亦支持 CRC24A=24'h00065B / CRC12=12'h80F / CRC32=32'h04C11DB7, 改参数即可)
// 生成种子 seed: 寄存器初值. 码块 CRC24B 的种子为 0x555555 (spec 6.10.1).
// =============================================================================
module crc_gen #(
    parameter integer WIDTH = 24,
    parameter [WIDTH-1:0] POLY = 24'hB2B117      // 默认 CRC24B
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             load,       // 置1: 用 seed 装载寄存器 (每块开始前)
    input  wire [WIDTH-1:0] seed,       // 生成种子 (CRC24B 码块: 0x555555)
    input  wire             en,         // 置1: 送入一个消息比特 din
    input  wire             din,        // 消息比特, MSB(a0) 优先
    output wire [WIDTH-1:0] crc         // 当前 CRC 余数
);
    reg  [WIDTH-1:0] r;
    wire fb = r[WIDTH-1] ^ din;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      r <= {WIDTH{1'b0}};
        else if (load)   r <= seed;
        else if (en)     r <= {r[WIDTH-2:0], 1'b0} ^ (fb ? POLY : {WIDTH{1'b0}});
    end

    assign crc = r;
endmodule
