`timescale 1ns/1ps


// =============================================================================
// sc_beta_mem.v
// =============================================================================
//
// SC译码器部分和(beta)存储模块
//
// 功能:
// -----------------------------------------------------------------------------
// 1. 保存SC译码过程中产生的部分和(partial sum)
//
// 2. 保存叶节点判决结果对应的beta:
//
//        beta(phi)=u_hat(phi)
//
// 3. 保存内部节点经过子节点合并后的partial sum
//
// 4. 提供两个组合读端口:
//        用于父节点beta更新时同时读取两个子beta
//
// 5. 提供一个同步写端口:
//        由C控制模块指定地址写入beta
//
// 不负责:
// -----------------------------------------------------------------------------
// × SC树遍历
// × beta递推算法
// × f/g计算
// × 叶节点判决
// × frozen判断
//
//
// 地址布局:
// -----------------------------------------------------------------------------
//
// 与sc_llr_mem保持一致
//
// 使用DFS工作区:
//
// depth0:     0 ~ NMAX-1
// depth1:     NMAX ~ NMAX+NMAX/2-1
// ...
// depth10:    2046
//
// 总空间:
//
//     MEM_DEPTH = 2*NMAX-1
//
// NMAX=1024: MEM_DEPTH=2047
//
// -----------------------------------------------------------------------------
// 存储物理结构（2026-08-12 面积优化重构）
// -----------------------------------------------------------------------------
//
// 原实现：2047 x 1bit 寄存器数组 + 同步读，复位时把整个数组清零。
// 面积问题：带“整数组复位”的 always 块使 Vivado 无法推断任何 RAM
//          （BRAM/LUTRAM 均不支持内容复位），2047 个 1bit 存储退化为
//          FF + 2 棵 2047:1 读 MUX + 宽写译码，即报告中的 ~34K LUT。
//
// 新结构（端口、时序、算法不变）：
//
//   copyA : 8 x (256 x 1bit) 分布式 RAM，只服务 beta_rd_addr_a；
//   copyB : 8 x (256 x 1bit) 分布式 RAM，只服务 beta_rd_addr_b；
//   两个副本同步写入（普通单写 + Fast-SSC 8 路宽写）。
//
//   地址低 3 位选 bank，高 8 位选 word；普通写与宽写互斥，
//   每个 bank 每周期最多 1 写 + 1 读，物理端口不冲突。
//
// 复位策略：真实存储体不再做内容清零（算法保证任何 beta 读地址
//          在读取前必然已写入；Rate-0 跳过时父节点合并显式写 0）。
//          仅保留“仿真观察影子数组 beta_mem”（ifndef SYNTHESIS），
//          供 tb_256/tb_1024 层次化检查，综合时不生成任何硬件。
//
// 读延迟保持 1 拍：bank 组合读出 → 顶层寄存器采样，与原同步读一致。
//
// =============================================================================


module sc_beta_mem #(

    parameter integer NMAX = 1024,

    parameter integer MEM_DEPTH = 2*NMAX-1,

    parameter integer ADDR_W = $clog2(MEM_DEPTH),

    // Fast-SSC: P 路宽写端口位宽
    parameter integer FAST_P = 8

)(

    input  wire                 clk,

    input  wire                 rst_n,


    // =========================================================================
    // 同步写接口
    // =========================================================================

    input  wire                 wr_en,

    input  wire [ADDR_W-1:0]    wr_addr,

    input  wire                 wr_data,


    // =========================================================================
    // 双组合读接口
    // =========================================================================

    input  wire [ADDR_W-1:0]    rd_addr_a,

    output wire                 rd_data_a,


    input  wire [ADDR_W-1:0]    rd_addr_b,

    output wire                 rd_data_b,


    // =========================================================================
    // Fast-SSC 宽写接口（Rate-1 DECIDE 阶段按 P 位写回原始硬判决）
    // =========================================================================

    input  wire [FAST_P-1:0]    wr_vec_en,

    input  wire [ADDR_W-1:0]    wr_vec_addr,

    input  wire [FAST_P-1:0]    wr_vec_data


);


    // =========================================================================
    // 组合几何量
    // =========================================================================

    localparam integer BANK_DEPTH = 1 << (ADDR_W - 3);   // 256
    localparam integer BANK_AW    = ADDR_W - 3;          // 8

    // =========================================================================
    // copyA / copyB 每 bank 的写控制
    // =========================================================================
    //
    // 优先级（与原实现一致）：宽写（wr_vec_en）覆盖普通单写。
    //
    // bank b 对应的宽写 lane = (b - wr_vec_addr[2:0]) & 7。
    // =========================================================================

    wire qa [0:FAST_P-1];
    wire qb [0:FAST_P-1];

    genvar gb;
    generate
        for (gb = 0; gb < FAST_P; gb = gb + 1)
        begin : gen_bank

            wire [ADDR_W:0] vec_lane_addr =
                {1'b0, wr_vec_addr} +
                ((gb - wr_vec_addr[2:0]) & (FAST_P-1));

            wire vec_we =
                wr_vec_en[(gb - wr_vec_addr[2:0]) & (FAST_P-1)];

            wire single_we =
                wr_en && (wr_addr[2:0] == gb);

            wire bank_we =
                single_we | vec_we;

            wire [BANK_AW-1:0] bank_waddr =
                vec_we
                ? vec_lane_addr[ADDR_W-1:3]
                : wr_addr[ADDR_W-1:3];

            wire bank_wdata =
                vec_we
                ? wr_vec_data[(gb - wr_vec_addr[2:0]) & (FAST_P-1)]
                : wr_data;

            sc_bit_bank #(
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_bank_a (
                .clk   (clk),
                .we    (bank_we),
                .waddr (bank_waddr),
                .wdata (bank_wdata),
                .raddr (rd_addr_a[ADDR_W-1:3]),
                .rdata (qa[gb])
            );

            sc_bit_bank #(
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_bank_b (
                .clk   (clk),
                .we    (bank_we),
                .waddr (bank_waddr),
                .wdata (bank_wdata),
                .raddr (rd_addr_b[ADDR_W-1:3]),
                .rdata (qb[gb])
            );

        end
    endgenerate

    // =========================================================================
    // 同步读（注册输出），1 拍延迟
    // =========================================================================

    reg rd_data_a_r;
    reg rd_data_b_r;

    always @(posedge clk) begin
        rd_data_a_r <= qa[rd_addr_a[2:0]];
        rd_data_b_r <= qb[rd_addr_b[2:0]];
    end

    assign rd_data_a = rd_data_a_r;

    assign rd_data_b = rd_data_b_r;


    // =========================================================================
    // 仿真观察影子数组（仅仿真，不综合）
    // =========================================================================
    //
    // tb_256 / tb_1024 通过层次引用 u_sc_beta_mem.beta_mem[i] 检查
    // 根节点 beta 内容。真实存储为 bank 阵列，无法直接以 beta_mem[i]
    // 形式访问，因此保留一个与真实存储同步更新的仿真影子数组。
    // 该数组在综合（SYNTHESIS 宏定义）时被完全排除，不产生任何硬件。
    // =========================================================================

`ifndef SYNTHESIS

    reg beta_mem [0:MEM_DEPTH-1];

    integer sri;
    integer swi;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (sri = 0; sri < MEM_DEPTH; sri = sri + 1) begin
                beta_mem[sri] <= 1'b0;
            end
        end
        else begin
            if (wr_en) begin
                beta_mem[wr_addr] <= wr_data;
            end

            if (|wr_vec_en) begin
                for (swi = 0; swi < FAST_P; swi = swi + 1) begin
                    if (wr_vec_en[swi]) begin
                        beta_mem[wr_vec_addr + swi] <= wr_vec_data[swi];
                    end
                end
            end
        end
    end

`endif

endmodule


// =============================================================================
// sc_bit_bank：1bit 分布式 RAM bank（1 写 + 1 组合读）
// =============================================================================

module sc_bit_bank #(
    parameter integer DEPTH = 256,
    parameter integer AW    = 8
)(
    input  wire             clk,
    input  wire             we,
    input  wire [AW-1:0]    waddr,
    input  wire             wdata,
    input  wire [AW-1:0]    raddr,
    output wire             rdata
);

    (* ram_style = "distributed" *)
    reg ram [0:DEPTH-1];

    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
        end
    end

    assign rdata = ram[raddr];

endmodule
