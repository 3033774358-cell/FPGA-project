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
// depth0:
//     0 ~ NMAX-1
//
// depth1:
//     NMAX ~ NMAX+NMAX/2-1
//
// ...
//
// depth10:
//     2046
//
// 总空间:
//
//     MEM_DEPTH = 2*NMAX-1
//
//
// NMAX=1024:
//
//     MEM_DEPTH=2047
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



////////////////////////////////////////////////////////////
// beta存储阵列
////////////////////////////////////////////////////////////


reg beta_mem [0:MEM_DEPTH-1];

integer wi;
integer ri;



////////////////////////////////////////////////////////////
// 同步读（注册输出）
////////////////////////////////////////////////////////////
//
// 2026-08-12：由组合读改为同步读。beta 为 1bit 小阵列，同步读
// 避免在 2047 深度寄存器阵列上展开大 mux；对 FPGA 更友好。
// 时序：地址周期 T 生效，数据上升沿 T+1 锁存输出。
//


reg rd_data_a_r;
reg rd_data_b_r;


always @(posedge clk)
begin
    rd_data_a_r <= beta_mem[rd_addr_a];
    rd_data_b_r <= beta_mem[rd_addr_b];
end


assign rd_data_a = rd_data_a_r;


assign rd_data_b = rd_data_b_r;



////////////////////////////////////////////////////////////
// 同步写
////////////////////////////////////////////////////////////
//
// 复位把 beta_mem 全部清零，保证未写地址读出为 0
// （sc_datapath_tb 依赖 reset 后未写 beta 地址读回 0）。
//
// 代价：MEM_DEPTH 个寄存器增加复位逻辑（本设计为 2047 x 1bit）。
//
////////////////////////////////////////////////////////////


always @(posedge clk or negedge rst_n)
begin

    if(!rst_n)
    begin
        for (ri = 0; ri < MEM_DEPTH; ri = ri + 1)
        begin
            beta_mem[ri] <= 1'b0;
        end
    end

    else
    begin

        if(wr_en)
        begin

            beta_mem[wr_addr] <= wr_data;

        end

        // Fast-SSC 宽写：逐位使能，写入连续 P 个地址
        if (|wr_vec_en)
        begin
            for (wi = 0; wi < FAST_P; wi = wi + 1)
            begin
                if (wr_vec_en[wi])
                begin
                    beta_mem[wr_vec_addr + wi] <= wr_vec_data[wi];
                end
            end
        end

    end

end



endmodule
