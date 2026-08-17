# Polar 编码蝶形结构

*导出时间: 2026/8/12 16:42:44*

---

### User

【学习上下文衔接指令】

我们正在学习 5G NR Polar 编码（TS 38.212 6.9.1.3），目标是从理论理解进入工程代码实现阶段。请基于以下已有学习背景继续教学，不要重新从基础讲起。

一、已经掌握的内容

1. 已理解 CRC 在 Polar 编码流程中的位置：

码块数据 B
→ CRC24B 计算
→ 附加 CRC 校验比特
→ Polar 编码
→ 速率匹配
→ 调制发送

已经理解：
- CRC 实际工程中通常由硬件 CRC 寄存器/IP 核完成；
- 不需要手算 CRC24B，但需要理解 CRC 在编码链路中的作用；
- 接收端译码后重新计算 CRC，用于判断译码结果是否正确。

2. 已学习 Polar 编码参数：

需要继续使用以下符号：

B：
输入比特长度（包含CRC前的数据长度）

L：
CRC长度或者译码相关参数，根据场景解释

C：
码块数量（code block segmentation 后的块数）

K：
Polar 编码输入信息长度（information bits，包括CRC）

N：
Polar 母码长度（mother code length）

E：
速率匹配后的输出长度

已经理解：
- K 是进入 Polar encoder 的比特数；
- N 是经过极化变换后的码长；
- E 是最终发送比特数；
- N 与 E 不一定相等，因此需要 rate matching。

3. 已学习矩阵形式：

G2：

[1 0
 1 1]

以及：

G4 = G2 ⊗ G2

理解：

x = uGN

其中：
u 是编码前比特；
G 是 Polar 生成矩阵；
x 是编码后码字。

希望后续继续扩展到：
- Kronecker积如何生成GN；
- bit-reversal；
- frozen bit 插入；
- encoder代码实现。

4. 已讨论码块分段和CRC：

流程：

Transport Block
↓
TB CRC24A
↓
Code Block Segmentation
↓
CB CRC24B
↓
Polar Encoder

已明确：
- TB CRC 和 CB CRC 不是一个东西；
- CB CRC 在分段后每个码块单独添加。

5. 已开始学习 Polar 编码：

下一步重点： 
我已经有写好的代码，你详细讲解代码思路，带我看代码，以及可能出现问题的点和可以优化的点，我下个对话会给出具体代码。这是一个FPGA的项目，使用的语言是verilog，软件是vivado
 二、这是目前的顶层模块
// =============================================================================
// polar_encode_chain.v -- 完整信道编码链 (T/XS 10002-2025  6.9, 查表全规则)
//                          串行瘦身版 (v2, 综合顶层)
// -----------------------------------------------------------------------------
// ★ 综合顶层 (Vivado top). 完整实现 spec 6.9 两条路径, 协议表格全部内置:
//
// [无线帧类型3/4] 6.9.1.3 带CRC的码块分段 + 6.9.1.1 码块CRC24B:
//   - B <= Kcb: 单块, 无码块CRC (L=0);  Kcb = 1024R (速率适配表 1024 列)
//   - B >  Kcb: C=⌈B/(Kcb-24)⌉ 块, 每块加CRC24B; 满块 K=Kcb 编 N=1024 码率R
//   - 末块 (r=C-1) 进一步细分 (R≠1), U=64(R-1/16):
//       Kr > 16U: 前补0至 1024R, 编 N=1024 码率R
//       否则 q=⌈Kr/U⌉, 前补0至 qU:
//         q=16: 编 N=1024, K=16U (码率 R-1/16)
//         q≤15: q 的二进制 b3..b0 对应是否用 512/256/128/64 码长,
//               各块 K=N(R-1/16) (即表23 对应列), 按 512→64 顺序切分
//     (以上规则已逐行对照 spec 附录A 表A.1: 分块组合与 Padding 完全一致)
//
// [无线帧类型2] 6.9.1.2 不带CRC的码块分段 (查表):
//   - B > 1920R: N1024=⌊(B-904R)/1024R⌋, Km=B-N1024·1024R; 否则 N1024=0, Km=B
//   - index=⌊(Km-1)/128R⌋ 查【表20】得 N512/N256/N128 (index>14 按14, 见假设③)
//   - N64=⌈(Km-ΣN·K_N)/K64⌉, K 值查【表24】; 块序 1024→512→256→128→64
//
// 内置协议表 (均为显式查表, 与协议逐格对照):
//   表22 (MCS→编码速率R), 表20 (类型2 分段表格),
//   表23 (类型3/4 末块细分 512/256/128/64 的 K 值, 码率R-1/16),
//   表24 (类型2 512/256/128/64 的 K 值)。 码长1024 的 K = 1024R 由 K1024 给出。
// 分段后: 6.9.1.4 极化编码 (附录C可靠度序列) → 6.9.1.5 码块级联 串行输出.
//
// ★ v2 瘦身 (与老师确认代码融合, 修 Vivado F7 Mux 爆炸):
//   旧版(存档 legacy_xingshan/)为全并行: msg_l[mp] 2048:1 变址读、info_reg[i] 变址写、
//   编码器内部信息位散布网络 —— 在 Vivado 实现阶段 F7 Mux 需 87339 > 器件 50700。
//   本版全串行数据通路, 上述三处全部消除:
//   - 消息读取: msg_sh 移位寄存器, 每拍只看 msg_sh[0] (零变址 mux);
//   - u 装配 (信息位散布): u_sh 移位寄存器逐位串行装配, 冻结位置0/信息位取流
//     (fz_sh 冻结掩码同拍同步移位), 零组合散布网络;
//   - 蝶形: 单个 polar_butterfly —— 蝶形逻辑与**老师已确认的 polar_encoder.v 逐字
//     相同**, 仅不含其内部散布网络 (该网络 N=1024 时在 Vivado 分层综合下爆 ~175k
//     LUT, 已实测); 确认版原封不动保留在库中单独测试, 不进综合数据通路;
//   - 末块 CRC 不再预扫描: V 序列按序消费, 消息位随取随喂 CRC, 到 CRC 区时值已就绪;
//   - 全链变址 mux 仅剩: u_bottom 对齐 (5选1) + 级联块内读 (单个 N:1) 两处。
//   分段/查表状态机与旧版逐字一致 (协议语义零改动), 由整链 TB 黄金模型交叉验证。
//
// 文档化假设: ①末块多码长按 512→256→128→64 顺序顺次取比特;
//   ②类型2 末尾不足位在末块块首补0; ③表20 index>14 钳位为14
// 补0均为"前补": 序列 = 0^pad ‖ 消息 ‖ CRC;  msg[0]=第一比特
// 全部除法/取整以迭代减法实现 (无变量除法, Vivado 综合友好)
// =============================================================================
module polar_encode_chain #(
    parameter integer NMAX    = 1024,
    parameter integer MSG_MAX = 2048       // 支持的最大输入信息比特数
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire [MSG_MAX-1:0]   msg,       // 输入信息比特, msg[0]=首比特
    input  wire [15:0]          B,         // 信息比特总长
    input  wire [3:0]           mcs,       // 表22 调制编码方式索引 0..12
    input  wire                 ftype2,    // 1=无线帧类型2(6.9.1.2); 0=类型3/4(6.9.1.3)
    input  wire [23:0]          crc_seed,  // 码块CRC24B生成种子 (广播类: 0x555555)
    output reg                  busy,
    output reg                  done,      // 整链输出完毕 (单拍)
    output wire                 m_valid,   // 级联后串行输出
    output wire                 m_bit,
    output wire [31:0]          k_count,
    output reg  [7:0]           cb_count   // 本次产生的码块总数 (观测/校验)
);
    // ---------------- 协议表格 ----------------
    // 表22: MCS -> r16 (= 编码速率R × 16; 调制方式与信道编码无关)
    function [4:0] tab22_r16;
        input [3:0] m;
        case (m)
            4'd0, 4'd2:  tab22_r16 = 5'd4;    // R=1/4  (BPSK/QPSK)
            4'd1, 4'd3:  tab22_r16 = 5'd6;    // R=3/8
            4'd4:        tab22_r16 = 5'd8;    // R=1/2
            4'd5, 4'd9:  tab22_r16 = 5'd10;   // R=5/8
            4'd6, 4'd10: tab22_r16 = 5'd12;   // R=3/4
            4'd7, 4'd11: tab22_r16 = 5'd14;   // R=7/8
            4'd8, 4'd12: tab22_r16 = 5'd16;   // R=1
            default:     tab22_r16 = 5'd8;    // 非法MCS按1/2 (spec 仅 0..12)
        endcase
    endfunction

    // 表20: index(0..14) -> {N512[1:0], N256[1:0], N128[1:0]}
    function [5:0] tab20;
        input [3:0] idx;
        case (idx)
            4'd0:  tab20 = {2'd0,2'd0,2'd0};   4'd1:  tab20 = {2'd0,2'd0,2'd1};
            4'd2:  tab20 = {2'd0,2'd0,2'd2};   4'd3:  tab20 = {2'd0,2'd1,2'd1};
            4'd4:  tab20 = {2'd0,2'd1,2'd2};   4'd5:  tab20 = {2'd0,2'd2,2'd1};
            4'd6:  tab20 = {2'd0,2'd2,2'd2};   4'd7:  tab20 = {2'd1,2'd1,2'd1};
            4'd8:  tab20 = {2'd1,2'd1,2'd2};   4'd9:  tab20 = {2'd1,2'd2,2'd1};
            4'd10: tab20 = {2'd1,2'd2,2'd2};   4'd11: tab20 = {2'd2,2'd1,2'd1};
            4'd12: tab20 = {2'd2,2'd1,2'd2};   4'd13: tab20 = {2'd2,2'd2,2'd1};
            default: tab20 = {2'd2,2'd2,2'd2}; // idx=14 (及钳位)
        endcase
    endfunction

    // 表23: 类型3/4 末块细分 速率适配 K 值 (码率 R-1/16); nsel: 0=码长512, 1=256, 2=128, 3=64
    //   数值直接照抄 spec 表23 (第一表格) 原格, 便于逐格对照; 等价于 N×(R-1/16)。
    //   (码长1024 列 = 1024R, 与满块相同, 由 K1024 给出, 不在本函数内。)
    function [9:0] tab23;
        input [4:0] r16v;
        input [1:0] nsel;
        case ({r16v, nsel})
            {5'd4, 2'd0}: tab23 = 10'd96;   {5'd4, 2'd1}: tab23 = 10'd48;   // R=1/4
            {5'd4, 2'd2}: tab23 = 10'd24;   {5'd4, 2'd3}: tab23 = 10'd12;
            {5'd6, 2'd0}: tab23 = 10'd160;  {5'd6, 2'd1}: tab23 = 10'd80;   // R=3/8
            {5'd6, 2'd2}: tab23 = 10'd40;   {5'd6, 2'd3}: tab23 = 10'd20;
            {5'd8, 2'd0}: tab23 = 10'd224;  {5'd8, 2'd1}: tab23 = 10'd112;  // R=1/2
            {5'd8, 2'd2}: tab23 = 10'd56;   {5'd8, 2'd3}: tab23 = 10'd28;
            {5'd10,2'd0}: tab23 = 10'd288;  {5'd10,2'd1}: tab23 = 10'd144;  // R=5/8
            {5'd10,2'd2}: tab23 = 10'd72;   {5'd10,2'd3}: tab23 = 10'd36;
            {5'd12,2'd0}: tab23 = 10'd352;  {5'd12,2'd1}: tab23 = 10'd176;  // R=3/4
            {5'd12,2'd2}: tab23 = 10'd88;   {5'd12,2'd3}: tab23 = 10'd44;
            {5'd14,2'd0}: tab23 = 10'd416;  {5'd14,2'd1}: tab23 = 10'd208;  // R=7/8
            {5'd14,2'd2}: tab23 = 10'd104;  {5'd14,2'd3}: tab23 = 10'd52;
            default:      tab23 = 10'd0;    // R=1 不细分, 不会取用
        endcase
    endfunction

    // 表24: 类型2 速率适配 K 值; nsel: 0=码长512, 1=256, 2=128, 3=64
    function [9:0] tab24;
        input [4:0] r16v;
        input [1:0] nsel;
        case ({r16v, nsel})
            {5'd10,2'd0}: tab24 = 10'd316;  {5'd10,2'd1}: tab24 = 10'd156;
            {5'd10,2'd2}: tab24 = 10'd74;   {5'd10,2'd3}: tab24 = 10'd36;
            {5'd12,2'd0}: tab24 = 10'd382;  {5'd12,2'd1}: tab24 = 10'd189;
            {5'd12,2'd2}: tab24 = 10'd90;   {5'd12,2'd3}: tab24 = 10'd45;
            {5'd14,2'd0}: tab24 = 10'd446;  {5'd14,2'd1}: tab24 = 10'd221;
            {5'd14,2'd2}: tab24 = 10'd106;  {5'd14,2'd3}: tab24 = 10'd53;
            default:      tab24 = 10'd0;    // 类型2 仅支持表24所列速率
        endcase
    endfunction

    // n∈{0,1,2} 与 K 的乘积 (类型2 rem 计算用)
    function [10:0] mul012;
        input [1:0] c;
        input [9:0] K;
        case (c)
            2'd0:    mul012 = 11'd0;
            2'd1:    mul012 = {1'b0, K};
            default: mul012 = {K, 1'b0};
        endcase
    endfunction

    // ---------------- 状态机 ----------------
    localparam [4:0]
        S_IDLE      = 5'd0,
        SB_FULL_INIT= 5'd1,  SB_LAST_INIT= 5'd2,  SB_QINIT    = 5'd3,
        SB_QLOOP    = 5'd4,  SB_SUBNEXT  = 5'd5,
        SA_INIT     = 5'd6,  SA_N1024    = 5'd7,  SA_IDX      = 5'd8,
        SA_REM      = 5'd9,  SA_N64      = 5'd10, SA_BLKNEXT  = 5'd11,
        SA_PAD      = 5'd12,
        S_FZ        = 5'd13, S_ASM       = 5'd14, S_ENC       = 5'd15,
        S_CATW      = 5'd16, S_ROUTE     = 5'd17, S_DONE      = 5'd18;
    reg [4:0] state;
    localparam [1:0] PH_BFULL=2'd0, PH_BSUB=2'd1, PH_A=2'd2;
    reg [1:0] phase;

    // ---------------- 锁存与派生量 ----------------
    reg  [MSG_MAX-1:0] msg_sh;             // 消息移位寄存器 (消费一位移一位, 零变址 mux)
    reg  [15:0] B_l;
    reg  [15:0] mp;                        // 已消费消息位数 (仅计数, 供类型2 avail)
    reg  [4:0]  r16;
    reg         use_crc;

    wire [10:0] K1024 = {r16, 6'b0};                 // 1024R = 64·r16
    wire [10:0] KmL   = K1024 - 11'd24;              // 满块消息容量 Kcb-24
    wire [6:0]  Uu    = {(r16-5'd1), 2'b0};          // U = 64(R-1/16) = 4(r16-1)
    wire [10:0] U16   = {(r16-5'd1), 6'b0};          // 16U = 64(r16-1)
    // 类型2 门限/常量 (r16 为偶数, 904R=56.5·r16 为整数)
    wire [15:0] r16w    = {11'b0, r16};
    wire [15:0] thr1920 = (r16w << 7) - (r16w << 3);                       // 1920R=120·r16
    wire [15:0] r904    = (r16w << 5) + (r16w << 4) + (r16w << 3) + (r16w >> 1); // 904R
    wire [15:0] r128w   = (r16w << 3);                                     // 128R=8·r16

    // 分段迭代
    reg  [15:0] remaining, tmpx;
    reg  [10:0] Kr;
    reg  [4:0]  qv;
    reg  [3:0]  subsel;                              // {512,256,128,64}
    // 类型2 计数
    reg  [3:0]  c1024;
    reg  [1:0]  c512, c256, c128;
    reg  [5:0]  c64;
    reg  [15:0] km;
    reg  [3:0]  idxA;
    reg  signed [15:0] remA;
    // 当前块
    reg  [10:0] Kblk;
    reg  [3:0]  nlog_blk;
    reg         blk_is_last;

    wire [15:0] avail = B_l - mp;                    // 类型2: 剩余可取消息位

    // ---------------- CRC24B (6.9.1.1 / 6.10.1) ----------------
    // 块虚拟序列 V = 0^padv ‖ 消息(Kmsg_cur位) ‖ CRC24(crc_on 时); 按 vpos 顺序消费。
    // 消息位随消费同步喂入 CRC (crc_en), 消费到 CRC 区时余数已就绪 —— 无需旧版的
    // 末块预扫描 (类型3/4 末块细分跨多个子块时 vpos/CRC 跨子块连续, 语义不变)。
    reg  [10:0] padv;                                // V 前补0 位数
    reg  [10:0] Kmsg_cur;                            // V 中消息位数
    reg         crc_on;                              // V 尾部是否有 24 位块 CRC
    reg  [10:0] vpos;                                // V 消费位置

    wire        crc_load = (state == SB_FULL_INIT) || (state == SB_LAST_INIT);
    wire        crc_en, crc_din;
    wire [23:0] crc_val;
    crc_gen #(.WIDTH(24), .POLY(24'hB2B117)) u_crc (
        .clk(clk), .rst_n(rst_n), .load(crc_load), .seed(crc_seed),
        .en(crc_en), .din(crc_din), .crc(crc_val));
    wire [23:0] crc_rev;                             // p_i = crc[23-i] (高位先)
    genvar gc;
    generate for (gc=0; gc<24; gc=gc+1) begin: g_rev
        assign crc_rev[gc] = crc_val[23-gc];
    end endgenerate

    wire [11:0] vend   = {1'b0, padv} + {1'b0, Kmsg_cur};   // 消息区末界 (V 坐标)
    wire        in_pad = (vpos <  padv);
    wire        in_msg = (vpos >= padv) && ({1'b0, vpos} < vend);
    /* verilator lint_off UNUSEDSIGNAL */            // vgap 仅用 [4:0] (CRC 偏移 0..23), 高位不参与
    wire [10:0] vgap   = vpos - vend[10:0];          // CRC 区内: 0..23
    /* verilator lint_on UNUSEDSIGNAL */
    wire        vbit   = in_pad ? 1'b0 : (in_msg ? msg_sh[0] : crc_rev[vgap[4:0]]);

    // ---------------- 冻结集 (6.9.1.4, 附录C 可靠度序列) ----------------
    reg         fg_start;
    /* verilator lint_off UNUSEDSIGNAL */            // fg_busy 观测用, FSM 以 done 驱动
    wire        fg_busy, fg_done;
    /* verilator lint_on UNUSEDSIGNAL */
    wire [NMAX-1:0] fg_frozen;
    frozen_gen #(.NMAX(NMAX)) u_fg (
        .clk(clk), .rst_n(rst_n), .start(fg_start),
        .n_log(nlog_blk), .K(Kblk), .busy(fg_busy), .done(fg_done), .frozen(fg_frozen));

    // ---------------- u 串行装配 (信息位散布, 零组合散布网络) ----------------
    reg [NMAX-1:0] fz_sh;                  // 冻结掩码移位寄存器 (每拍看 [0])
    reg [NMAX-1:0] u_sh;                   // u 移位装配: N 拍后块占据高 N 位
    reg [10:0]     acnt;
    wire [10:0] Nv_blk = 11'd1 << nlog_blk;

    wire        cur_fz = fz_sh[0];
    wire        ubit   = cur_fz ? 1'b0 : vbit;

    assign crc_en  = (state == S_ASM) && !cur_fz && in_msg && crc_on;
    assign crc_din = msg_sh[0];

    // ---------------- 极化编码 (6.9.1.4): 单个纯蝶形 ----------------
    // u_sh 装配后块占据"高 N 位" (u[0] 位于 1024-N); 蝶形要求"低位对齐",
    //   故用 5:1 mux 把高 N 位窗口搬到低 N 位 (nlog_blk 仅 5 种取值, 廉价 5 选 1)。
    wire [NMAX-1:0] u_bottom = (nlog_blk == 4'd9) ? {512'h0, u_sh[1023:512]} :
                               (nlog_blk == 4'd8) ? {768'h0, u_sh[1023:768]} :
                               (nlog_blk == 4'd7) ? {896'h0, u_sh[1023:896]} :
                               (nlog_blk == 4'd6) ? {960'h0, u_sh[1023:960]} :
                                                    u_sh;                   // N=1024
    reg             bf_start;
    wire            bf_done;
    wire [NMAX-1:0] bf_d;
    /* verilator lint_off PINCONNECTEMPTY */          // busy 观测口, FSM 以 done 驱动
    polar_butterfly #(.NMAX(NMAX)) u_bf (
        .clk(clk), .rst_n(rst_n), .start(bf_start),
        .n_log(nlog_blk), .u(u_bottom), .busy(), .done(bf_done), .d(bf_d));
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------- 码块级联 (6.9.1.5) ----------------
    reg             cat_load, cat_last;
    wire            cat_ready, cat_done;
    wire [10:0]     elen = (11'd1 << nlog_blk);      // E_r = N
    code_block_concat #(.NMAX(NMAX)) u_cat (
        .clk(clk), .rst_n(rst_n),
        .s_load(cat_load), .s_blk(bf_d), .s_elen(elen), .s_last(cat_last),
        .s_ready(cat_ready), .m_valid(m_valid), .m_bit(m_bit),
        .k_count(k_count), .done(cat_done));

    // ---------------- 主 FSM ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; phase<=PH_BFULL; busy<=0; done<=0; cb_count<=0;
            msg_sh<=0; B_l<=0; mp<=0; r16<=5'd8; use_crc<=0;
            remaining<=0; tmpx<=0; Kr<=0; qv<=0; subsel<=0;
            c1024<=0; c512<=0; c256<=0; c128<=0; c64<=0;
            km<=0; idxA<=0; remA<=0;
            Kblk<=0; nlog_blk<=4'd6; blk_is_last<=0;
            padv<=0; Kmsg_cur<=0; crc_on<=0; vpos<=0;
            fz_sh<=0; u_sh<=0; acnt<=0;
            fg_start<=0; bf_start<=0; cat_load<=0; cat_last<=0;
        end else begin
            done<=0; fg_start<=0; bf_start<=0; cat_load<=0;
            case (state)
                // ================= 入口 =================
                S_IDLE: begin
                    busy<=0;
                    if (start && !busy) begin
                        msg_sh<=msg; B_l<=B; mp<=0; cb_count<=0; busy<=1;
                        use_crc<=0;
                        r16<=tab22_r16(mcs);
                        if (ftype2) begin
                            phase<=PH_A;
                            state<=SA_INIT;
                        end else begin
                            remaining<=B;
                            state<=SB_FULL_INIT;
                        end
                    end
                end

                // ============ 类型3/4: 满块循环 (6.9.1.3) ============
                // 首次判据 B>Kcb (=K1024); 之后判据 remaining>Kcb-24 (满块循环)
                SB_FULL_INIT: begin                  // 本拍同时装载 CRC 种子
                    if (( use_crc && (remaining > {5'b0, KmL}))  ||
                        (!use_crc && (remaining > {5'b0, K1024}))) begin
                        use_crc<=1;
                        Kblk<=K1024; nlog_blk<=4'd10; blk_is_last<=0;
                        padv<=0; Kmsg_cur<=KmL; crc_on<=1; vpos<=0;
                        phase<=PH_BFULL;
                        fg_start<=1; state<=S_FZ;
                    end else begin
                        state<=SB_LAST_INIT;
                    end
                end

                // ============ 类型3/4: 末块 + 细分 ============
                SB_LAST_INIT: begin                  // 本拍装载 CRC 种子 (随消费喂入, 无预扫)
                    Kmsg_cur<=remaining[10:0];
                    Kr<=remaining[10:0] + (use_crc ? 11'd24 : 11'd0);
                    crc_on<=use_crc; vpos<=0;
                    state<=SB_QINIT;
                end
                SB_QINIT: begin                      // 细分决策 (spec 6.9.1.3)
                    phase<=PH_BSUB; subsel<=0;
                    if (r16 == 5'd16) begin          // R=1: 不细分
                        padv<=0; Kblk<=Kr; nlog_blk<=4'd10; blk_is_last<=1;
                        fg_start<=1; state<=S_FZ;
                    end else if (Kr > U16) begin     // Kr>16U: 补0至1024R, 码长1024 @ 码率R
                        //   K = K1024 = 1024R = 表23 "码长1024" 列 (与满块同值)
                        padv<=K1024-Kr; Kblk<=K1024; nlog_blk<=4'd10; blk_is_last<=1;
                        fg_start<=1; state<=S_FZ;
                    end else begin                   // 迭代求 q=⌈Kr/U⌉
                        tmpx<={5'b0,Kr}; qv<=5'd1;
                        state<=SB_QLOOP;
                    end
                end
                SB_QLOOP: begin
                    if (tmpx > {9'b0,Uu}) begin
                        tmpx<=tmpx-{9'b0,Uu}; qv<=qv+1'b1;
                    end else begin                   // 终止: 余量∈(0,U], pad=U-余量
                        padv<={4'b0,Uu}-tmpx[10:0];
                        if (qv == 5'd16) begin       // q=16: 码长1024 @ 码率R-1/16
                            //   K = 1024(R-1/16) = 16U (按码率定义, 非表23格值)
                            Kblk<=U16; nlog_blk<=4'd10; blk_is_last<=1;
                            fg_start<=1; state<=S_FZ;
                        end else begin               // q≤15: 二进制选码长
                            subsel<=qv[3:0];
                            state<=SB_SUBNEXT;
                        end
                    end
                end
                SB_SUBNEXT: begin                    // 512→256→128→64 顺序; K 值查【表23】(码率R-1/16)
                    if (subsel[3]) begin             // 码长512: K = tab23[R,512]
                        nlog_blk<=4'd9; Kblk<={1'b0,tab23(r16,2'd0)};
                        subsel[3]<=0; blk_is_last<=(subsel[2:0]==3'b0);
                    end else if (subsel[2]) begin    // 码长256: K = tab23[R,256]
                        nlog_blk<=4'd8; Kblk<={1'b0,tab23(r16,2'd1)};
                        subsel[2]<=0; blk_is_last<=(subsel[1:0]==2'b0);
                    end else if (subsel[1]) begin    // 码长128: K = tab23[R,128]
                        nlog_blk<=4'd7; Kblk<={1'b0,tab23(r16,2'd2)};
                        subsel[1]<=0; blk_is_last<=(subsel[0]==1'b0);
                    end else begin                   // 码长64:  K = tab23[R,64]
                        nlog_blk<=4'd6; Kblk<={1'b0,tab23(r16,2'd3)};
                        subsel[0]<=0; blk_is_last<=1;
                    end
                    fg_start<=1; state<=S_FZ;
                end

                // ============ 类型2: 计数 (6.9.1.2 查表) ============
                SA_INIT: begin
                    c1024<=0; km<=B_l;
                    if (B_l > thr1920) begin         // N1024 = ⌊(B-904R)/1024R⌋
                        tmpx<=B_l - r904;
                        state<=SA_N1024;
                    end else begin
                        tmpx<=B_l - 16'd1;           // (Km-1)
                        idxA<=0;
                        state<=SA_IDX;
                    end
                end
                SA_N1024: begin
                    // 循环: tmpx=(B-904R)-n·1024R 与 km=B-n·1024R 同步递减;
                    // 终止时 n=⌊(B-904R)/1024R⌋=N1024, km 即剩余待编码比特 Km
                    if (tmpx >= {5'b0,K1024}) begin
                        tmpx<=tmpx-{5'b0,K1024};
                        km<=km-{5'b0,K1024};
                        c1024<=c1024+1'b1;
                    end else begin
                        tmpx<=km-16'd1;              // 转 (Km-1) 供 index 迭代
                        idxA<=0;
                        state<=SA_IDX;
                    end
                end
                SA_IDX: begin                        // index=⌊(Km-1)/128R⌋, 钳位14
                    if ((tmpx >= r128w) && (idxA < 4'd14)) begin
                        tmpx<=tmpx-r128w; idxA<=idxA+1'b1;
                    end else begin
                        {c512,c256,c128}<=tab20(idxA);
                        state<=SA_REM;
                    end
                end
                SA_REM: begin                        // rem = Km - Σ N·K_N (表24)
                    remA <= $signed({1'b0,km[14:0]})
                          - $signed({5'b0,mul012(c512,tab24(r16,2'd0))})
                          - $signed({5'b0,mul012(c256,tab24(r16,2'd1))})
                          - $signed({5'b0,mul012(c128,tab24(r16,2'd2))});
                    c64<=0;
                    state<=SA_N64;
                end
                SA_N64: begin                        // N64=⌈rem/K64⌉ (迭代)
                    if ((remA > 0) && (tab24(r16,2'd3) != 10'd0)) begin
                        remA<=remA - $signed({5'b0,{1'b0,tab24(r16,2'd3)}});
                        c64<=c64+1'b1;
                    end else
                        state<=SA_BLKNEXT;
                end
                SA_BLKNEXT: begin                    // 块序 1024→512→256→128→64
                    if (c1024 != 0) begin
                        nlog_blk<=4'd10; Kblk<=K1024; c1024<=c1024-1'b1;
                        blk_is_last<=((c1024==4'd1)&&(c512==0)&&(c256==0)&&(c128==0)&&(c64==0));
                    end else if (c512 != 0) begin
                        nlog_blk<=4'd9; Kblk<={1'b0,tab24(r16,2'd0)}; c512<=c512-1'b1;
                        blk_is_last<=((c512==2'd1)&&(c256==0)&&(c128==0)&&(c64==0));
                    end else if (c256 != 0) begin
                        nlog_blk<=4'd8; Kblk<={1'b0,tab24(r16,2'd1)}; c256<=c256-1'b1;
                        blk_is_last<=((c256==2'd1)&&(c128==0)&&(c64==0));
                    end else if (c128 != 0) begin
                        nlog_blk<=4'd7; Kblk<={1'b0,tab24(r16,2'd2)}; c128<=c128-1'b1;
                        blk_is_last<=((c128==2'd1)&&(c64==0));
                    end else begin
                        nlog_blk<=4'd6; Kblk<={1'b0,tab24(r16,2'd3)}; c64<=c64-1'b1;
                        blk_is_last<=(c64==6'd1);
                    end
                    state<=SA_PAD;
                end
                SA_PAD: begin                        // 末块不足位: 块首补0
                    padv     <= (avail < {5'b0,Kblk}) ? (Kblk - avail[10:0]) : 11'd0;
                    Kmsg_cur <= (avail < {5'b0,Kblk}) ? avail[10:0] : Kblk;
                    crc_on<=0; vpos<=0;
                    fg_start<=1; state<=S_FZ;
                end

                // ============ 公共: 冻结集 → 装配 → 编码 → 级联 → 调度 ============
                S_FZ: begin                          // 冻结集生成 → 装入移位寄存器
                    if (fg_done) begin
                        fz_sh<=fg_frozen; acnt<=0;
                        state<=S_ASM;
                    end
                end
                S_ASM: begin                         // u 串行装配 (N 拍); 消息位同步喂 CRC
                    u_sh<={ubit, u_sh[NMAX-1:1]};
                    fz_sh<={1'b0, fz_sh[NMAX-1:1]};
                    if (!cur_fz) begin
                        vpos<=vpos+11'd1;
                        if (in_msg) begin
                            msg_sh<={1'b0, msg_sh[MSG_MAX-1:1]};
                            mp<=mp+16'd1;
                        end
                    end
                    if (acnt == Nv_blk - 11'd1) begin
                        bf_start<=1;                 // 启动蝶形 (u_bottom 已就绪)
                        state<=S_ENC;
                    end else
                        acnt<=acnt+11'd1;
                end
                S_ENC: begin                         // 蝶形编码 (log2(N)+1 拍)
                    if (bf_done)
                        state<=S_CATW;
                end
                S_CATW: begin
                    if (cat_ready) begin
                        cat_load<=1; cat_last<=blk_is_last;
                        cb_count<=cb_count+1'b1;
                        state<=S_ROUTE;
                    end
                end
                S_ROUTE: begin
                    case (phase)
                        PH_BFULL: begin
                            remaining<=remaining-{5'b0,KmL};
                            state<=SB_FULL_INIT;
                        end
                        PH_BSUB:  state<=(subsel!=4'b0) ? SB_SUBNEXT : S_DONE;
                        default:  state<=({c1024,c512,c256,c128,c64}!=0)
                                          ? SA_BLKNEXT : S_DONE;
                    endcase
                end
                S_DONE: begin
                    if (cat_done) begin
                        done<=1; busy<=0; state<=S_IDLE;
                    end
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule

---

### ChatGPT

收到。我会基于你已经掌握的 Polar 编码理论继续，不重新讲 CRC、K/N/E 基础。
你下一步给代码后，我会按照FPGA工程审查方式带你看，而不是只解释 Verilog 语法。针对这个 polar_encode_chain.v 顶层，我后续会重点从以下几个层次分析：

1. 先看整个模块的数据流架构
我会先帮你建立这份代码在 FPGA 中真实运行时的“硬件结构图”：
代码输入 msg   |   | start   ↓+----------------+| 参数解析 FSM   || MCS→R          || 类型判断       |+----------------+        |        |        +----------------+        |                |        ↓                ↓  Type3/4路径       Type2路径  6.9.1.3           6.9.1.2        |                |        ↓                ↓   CB分段计算        查表分段        |        ↓+----------------+| 当前block参数  || Kblk           || N              || pad             || CRC enable     |+----------------+        |        ↓+----------------+| frozen_gen     || 生成冻结集合   |+----------------+        |        ↓+----------------+| S_ASM           || 构造u向量       || frozen=0       || info=message   |+----------------+        |        ↓+----------------+| polar_butterfly|| uGN            |+----------------+        |        ↓+----------------+| concat          || 码块级联        |+----------------+        |        ↓输出m_valid/m_bit
我会重点解释：


为什么 FSM 这么设计；


为什么不用 RAM；


为什么采用 shift register；


为什么这个版本比 legacy 版本 LUT 少。



2. FSM逐状态分析
这个模块最大的核心不是 Polar 数学，而是状态机。
我会逐个解释：
例如：
S_IDLE
verilogif(start && !busy)begin    msg_sh<=msg;    B_l<=B;    r16<=tab22_r16(mcs);end
这里实际上完成：
协议输入参数锁存。
需要注意：
潜在问题：
r16<=tab22_r16(mcs);
是非阻塞赋值。
所以：
这一拍以后 r16 才更新。
如果后面状态马上使用 r16：
可能产生：
代码旧r16
问题。
不过你的代码这里：
代码S_IDLE ↓SB_FULL_INIT
隔了一拍。
所以目前安全。
但是以后改 FSM 要注意。

3. 我会重点分析 Polar encoder部分
因为这是 FPGA 实现核心。
你这里：
verilogu_sh<={ubit, u_sh[NMAX-1:1]};
这个设计非常关键。
传统 Polar：
数学：
$u=(u_0,u_1,...u_{N-1})$
但是硬件：
不能：
verilogu[i]=bit;
因为：
代码i
是动态地址。
Vivado 会生成：
巨大MUX。
所以你改成：
代码bit stream    |    |shift register    |    |u_sh
这个思想我会详细讲。
包括：
为什么：
verilogu_sh[1023:0]
最后需要：
verilogu_bottom
这个5选1：
verilogwire [NMAX-1:0] u_bottom =
是什么意思。

4. 冻结比特插入分析
这里：
verilogwire cur_fz = fz_sh[0];wire ubit =       cur_fz ? 1'b0 : vbit;
这是 Polar 最重要的地方。
对应：
$u_i=
\begin{cases}
0,&i\in F\\
a_i,&i\in A
\end{cases}$
也就是：
冻结集合：
代码F
决定哪些位置强制0。
信息集合：
代码A
填：
代码message + CRC
我会帮你检查：


frozen_gen 输出顺序是否和 u 装配一致；


Appendix C reliability sequence 是否需要 bit reverse；


N=64/128/256/512 时有没有错位。



5. CRC24B硬件实现分析
重点看：
verilogassign crc_en =(state == S_ASM)&& !cur_fz&& in_msg&& crc_on;
这个设计思想很好：
以前：
代码先扫描message计算CRC再编码
需要：
RAM + 二次读取。
现在：
代码message流过 | |CRC同时更新
即：
single pass。
我会重点检查：
CRC输出方向
你的：
verilogcrc_rev[gc]=crc_val[23-gc];
涉及：
38.212中：
CRC bit ordering。
这是非常容易错的地方。
需要和：
golden model
逐bit比较。

6. Butterfly编码模块
你这里：
verilogpolar_butterfly
是独立模块。
后续你需要给我：


polar_butterfly.v


frozen_gen.v


crc_gen.v


code_block_concat.v


否则只能分析顶层。
重点：
我会检查：
Polar变换：
$x=uG_N$
是否实现：
代码stage0:a^bstage1:...
以及：
有没有：
bit reversal。
因为：
很多 FPGA Polar encoder错误：
不是蝶形错，
而是：
代码u位置↓bit reverse↓蝶形↓输出顺序
错一位。

7. Vivado综合风险分析
你的注释里已经提到了：
旧版本：
代码msg_l[mp]
导致：
2048:1 mux。
我会继续帮你检查：
现在版本还有哪些可能爆 LUT：
例如：
(1)
verilogwire [NMAX-1:0] u_bottom
这里：
虽然只有5选1，
但是：
1024 bit宽。
综合可能生成：
大量MUX。
需要看综合报告：
代码Report UtilizationReport Timing
判断。

(2)
函数查表：
例如：
verilogtab23()
综合会生成：
ROM/LUT。
需要看：
Vivado是否推成：
distributed ROM。

(3)
大量wire计算：
例如：
verilogwire [15:0] r904
里面：
代码shift + add
可能进入关键路径。

8. 我会重点帮你找协议错误
因为这类代码最大风险不是Verilog，而是：
“代码能跑，但是标准错”。
我会逐项检查：
TS 38.212 6.9.1.3
包括：


Kcb判断


C计算


CRC24B添加


最后一块处理


q计算


shortening/padding


N选择


6.9.1.4
检查：


reliability sequence


frozen bit


interleaving


6.9.1.5
检查：


block concatenation顺序



9. 我建议你下一步按这个顺序发代码
不要一次发全部，否则分析会很乱。
推荐：
第一份：
代码polar_butterfly.v
先确认核心编码。
第二份：
代码frozen_gen.v
确认：
A/F集合。
第三份：
代码crc_gen.v
第四份：
代码code_block_concat.v
第五份：
testbench
尤其需要：


输入msg


B


mcs


ftype2


期望输出



然后我们按照 FPGA 调试流程：
代码数学模型 ↓Python黄金模型 ↓Verilog仿真 ↓Vivado综合 ↓资源报告 ↓时序优化
一步一步对齐。
你这个顶层目前看，设计思想已经明显是面向综合优化的 Polar encoder 架构，不是简单教材实现。下一步我会重点帮你验证三个最容易出错的地方：


u装配顺序是否和Polar冻结集合一致


蝶形输出是否需要bit reversal


CRC24B bit ordering是否符合38.212


你下一条直接发 polar_butterfly.v 即可。

---

### User

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
讲解清楚蝶形的原理
另外我想问下，是不是状态机状态太多也会造成mux的爆炸，如果换成流水线valid是不是可以大量减小

---

### User

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
讲解清楚蝶形的原理
另外我想问下，是不是状态机状态太多也会造成mux的爆炸，如果换成流水线valid是不是可以大量减小


1.这篇论文最重要的价值不是发明了 SCL，而是明确提出并验证：

Polar码
+
列表/栈搜索
+
CRC候选筛选
Polar码+列表/栈搜索+CRC候选筛选
	​


这一组合。
这是CA-SCL的译码逻辑，我们是不是可以用这个进行译码
2.下面是butterfly
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

---

### ChatGPT

你的几个问题其实都指向 Polar 编解码器硬件架构的核心问题：算法结构 → 硬件映射 → 面积/时序优化。我分几个层次解释。

一、Polar 蝶形编码到底是什么？
Polar 编码：
$x=uG_N$
其中：


$u$：冻结位 + 信息位组成的输入向量


$G_N$：生成矩阵


生成矩阵：
$G_N=F^{\otimes n}$
其中：
$F=
\begin{bmatrix}
1&0\\
1&1
\end{bmatrix}$
例如：
N=2
输入：
$u=[u_0,u_1]$
经过：
代码u0 -------- XOR ------- x0             \u1 ---------- -------- x1
得到：
$x_0=u_0\oplus u_1$
$x_1=u_1$
对应矩阵：
$[u_0,u_1]
\begin{bmatrix}
1&0\\
1&1
\end{bmatrix}$

N=4
Polar蝶形：
代码stage0:u0 ----⊕------ a0       |u1 ----------- a1u2 ----⊕------ a2       |u3 ----------- a3stage1:a0 ----⊕------ x0       |a2 ----------- x2a1 ----⊕------ x1       |a3 ----------- x3
对应代码：
你的：
verilogassign stage_net[gs][gi+gj] =       x[gi+gj] ^ x[gi+gj+M];assign stage_net[gs][gi+gj+M] =       x[gi+gj+M];
实际上就是：
代码上支路 = 左输入 XOR 右输入下支路 = 保留右输入
也就是：
代码        XORa --------------+                |                +------ a^bb --------------------- b
这就是 Polar 的基本核：
$\begin{bmatrix}
1&0\\
1&1
\end{bmatrix}$

二、你的代码为什么叫 butterfly？
因为它和 FFT 蝶形结构非常像。
FFT：
代码      +x0 ---|---- y0      |x1 ---|---- y1      -
Polar：
代码      XORu0 ----⊕---->       |u1 -------->
区别：
FFT:
$a+b$
Polar:
$a\oplus b$
所以硬件上：
FFT：


加法器


乘法器


Polar：


XOR


因此极其便宜。

三、为什么这个版本比原来的省175k LUT？
关键在这里：

不要把 bit mapping 和 butterfly 混在一起。

原设计：
代码输入bit      |      v+----------------+| build_u_vector || 信息位散布      |+----------------+      |+----------------+| butterfly      |+----------------+      |      vcodeword
问题：
N=1024：
信息位位置：
例如：
代码u[0]u[1]u[2]...
要映射：
代码u[0] → bit 3u[1] → bit 5u[2] → bit 17...
如果组合实现：
综合器看到：
代码大量条件选择if(index==...)muxmuxmuxmux...
最后：
代码175k LUT
你的优化：
变成：
代码串行shift register+ 固定xor网络
所以：
代码build_u_vector      |      | 1 bit/cycle      vu[0:N]      |butterfly
这是非常正确的硬件思想。

四、你的问题1：
状态机状态太多，会不会造成MUX爆炸？
答案：
会，但是不是状态数量本身导致，而是状态控制的数据路径导致。
例如：
错误设计：
代码FSMIDLECASE stateS0: x<=a;S1: x<=b;S2: x<=c;S3: x<=d;...
综合：
变成：
代码        state          |          v      +--------+a --->|        |b --->|  MUX   |---- xc --->|        |d --->|        |      +--------+
如果：
state=100个
输入数据宽度=1024 bit
那么：
巨大MUX。
特别是：
代码case(state)stage0:x=stage0_netstage1:x=stage1_netstage2:x=stage2_net...
这个非常容易爆。

你的代码：
verilogwire [NMAX-1:0] x_next =       stage_net[stage];
这里其实隐藏了一个：
代码stage选择MUX
例如：
N=1024
stage:
0~9
综合：
代码10路1024bit MUX
约：
10k LUT级别。
还能接受。
但是如果：
N=8192
stage=13
可能明显增加。

五、流水valid是不是更好？
你的理解方向正确。
FSM版本：
代码       state counter             |             v       MUX选择stage             |       butterfly
Pipeline版本：
展开：
代码stage0 |reg |stage1 |reg |stage2 |reg |... |stage9
数据流：
代码input |vXOR |vXOR |vXOR |output
控制：
只需要：
代码valid shift registervalid_in0010000000valid_out
没有：
代码state decoderstage mux
所以：
面积：
下降
时钟：
提高
但是：
代价：
面积增加。
因为：
FSM：
只有一个蝶形网络
复用10次
Pipeline：
10个蝶形网络
比较：
架构面积速度FSM复用小低pipeline大高半流水中中

六、你的CA-SCL问题
你理解论文价值基本正确。
Polar经典：
Arikan：
提出Polar码。
后续：
Tal-Vardy：
提出：
$CA-SCL$
核心：
不是简单SCL。
而是：
代码SCL搜索+CRC校验
流程：
代码                 channel LLR                     |                     v             SC tree traversal                     |          --------------------          |                  |       path0              path1          |                  |          ...                    L个候选路径                     |             CRC check                     |             最优合法路径
所以：
CA-SCL：
就是：
代码Polar decoder+list management+CRC

七、能不能用CA-SCL做你的译码？
答案：
可以，而且这是Polar硬件译码的主流方案。
但是注意：
编码：
简单：
代码XOR butterfly
译码：
复杂：
需要：
1. LLR计算
信道：
$y=x+n$
转换：
$LLR=\log\frac{P(y|0)}{P(y|1)}$

2. SC递归
两个核心函数：
f：
$f(a,b)=sign(a)sign(b)
min(|a|,|b|)$
g：
$g(a,b,u)=
b+(1-2u)a$
硬件：
大量：


加法


比较


符号处理



3. List管理
L=8：
意味着：
代码8条路径
每遇到信息bit：
分裂：
代码path0 | +--0 | +--1path1 | +--0 | +--1...
排序：
保留8条。
这里非常吃资源。

八、如果你的目标是FPGA实现，我建议：
不要直接上CA-SCL。
路线：
第一阶段：
实现：
SC decoder
代码N=1024latency:几千cycle
验证算法。

第二阶段：
SCL
L=4
硬件：
代码4 path memory+4 tree engine

第三阶段：
CA-SCL
L=8/16
增加：
CRC checker

九、结合你的蝶形代码，我建议架构：
不要FSM控制整个编码器。
推荐：
代码                input                  |                  v        bit mapper        (serial)                  |                  v        butterfly pipeline       stage0          |       stage1          |       ...          |       stage9                  |                  v              codeword
控制：
代码valid shift registervalid[0] |valid[1] |... |valid[10]
不要：
代码state=0state=1state=2...
这是现代高速Polar IP的典型设计。

总结：


蝶形就是GF(2)上的矩阵乘法，每一级实现一个 $F$ 核。你的代码结构正确。


状态机不会因为状态多自动爆炸，真正爆炸的是状态控制的大宽度MUX。


流水valid替代stage mux，可以显著降低MUX和提高频率，但面积换性能。


CA-SCL完全可以作为Polar译码方案，而且是工程主流，但硬件复杂度远高于编码。


你的编码器优化方向（散布串行化 + 蝶形独立）是正确的，175k LUT降到几千LUT符合实际。


如果后续做FPGA Polar IP，我建议下一步重点设计 SCL译码器的路径存储（Path Memory）和LLR共享架构，那才是真正决定面积的地方。

---

### User

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
                        blk<=s_blk; elen<=s_elen; last_r<=s_last;
                        j<=11'd0; s_ready<=1'b0; st<=EMIT;
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
讲解下这部分思路

---

### ChatGPT

这个 code_block_concat.v 模块其实是 Polar 编码链路里面最后一级“码块拼接（Code Block Concatenation）”，它本身不负责编码，只负责按照标准要求：
$g_k = \{f_0,f_1,...,f_{C-1}\}$
把多个已经编码好的码块串成一个连续比特流。
它的设计思想和你前面 polar_butterfly 很像：

不要一次性做复杂的大组合逻辑，而是把大操作拆成小模块，用串行时序完成。

下面详细解释。

1. 为什么需要码块拼接？
实际通信系统中，一个运输块（TB）可能太长。
例如：
输入：
代码Transport Block111010101011101010101010...
长度：
比如：
$A=10000bit$
但是 Polar 编码器最大：
$N=1024$
不能直接：
代码10000 bit      |      vN=1024 Polar encoder
所以需要分块：
代码TB | +---------+ |         | v         vCB0       CB1       CB21024      1024      1024
每个：
代码CB |polar encode |f_r
得到：
$f_r(0),f_r(1)...f_r(E_r-1)$
最后：
重新组合：
代码f0全部+f1全部+f2全部
就是：
$g_0,g_1,...g_{E-1}$

2. 数学对应关系
标准：
Plain textfor r=0:C-1    for j=0:E_r-1        g[k]=f_r(j)        k++
也就是：
假设：
三个码块：
代码f0:1011f1:0010f2:1110
输出：
代码g:1011 0010 1110

3. 你的模块结构
整体：
代码                s_blk                  |                  |             +----------+             |          |             |  buffer  |             |          |             +----------+                  |                  |              j counter                  |                  v             m_bit output
核心就是：
输入一个码块
verilogs_load
时：
把：
verilogs_blk
存进去：
verilogblk<=s_blk;
同时保存长度：
verilogelen<=s_elen;
例如：
代码blk:101101011elen:9

4. 为什么不用组合拼接？
最直观：
verilogassign g ={ f0, f1, f2};
但是问题：
如果：
C=10
每个：
1024bit
那么：
组合网络：
代码10240 bit mux
面积暴涨。
尤其：
码块数量可变：
代码if(C==...) if(C==...)
综合：
大量MUX。
所以你的设计：
采用：
串行输出
每周期：
输出1bit：
代码cycle0:f0[0]cycle1:f0[1]cycle2:f0[2]...cycle1023:f0[1023]
然后：
下一个block。

5. FSM非常简单
你的状态：
veriloglocalparam IDLE=1'b0,           EMIT=1'b1;
只有两个状态。

状态1：IDLE
意思：
等待码块。
Plain texts_ready=1可以接受数据
硬件：
代码        s_ready           |           v     +-----------+     |   idle    |     +-----------+
收到：
verilogif(s_load)
进入：
代码EMIT

状态2：EMIT
开始发送。
每拍：
verilogm_valid=1
输出：
verilogm_bit=blk[j]
例如：
j：
代码0123
输出：
代码blk[0]blk[1]blk[2]blk[3]

6. j计数器的作用
这个：
verilogreg [10:0] j;
就是：
当前输出位置。
比如：
代码blk:index:0 1 2 3 4 5j:0
第一次：
代码m_bit=blk[0]j++
下一拍：
代码m_bit=blk[1]
直到：
verilogj==elen-1
说明：
当前码块结束。

7. s_ready为什么拉低？
这里：
verilogs_ready<=1'b0;
原因：
模块只有：
一个缓存：
verilogreg [NMAX-1:0] blk;
只能存：
一个码块。
如果正在输出：
代码blk正在被读取
不能覆盖。
否则：
错误：
代码cycle0blk0输出突然load blk1blk被覆盖输出混乱
所以：
代码EMIT期间：s_ready=0

8. done逻辑
最后一个码块：
输入：
verilogs_last=1
保存：
veriloglast_r
当：
verilogj==elen-1
表示：
最后一个bit。
于是：
verilogdone<=1;
产生：
一个周期脉冲。
例如：
代码cycle:100010011010最后bit       ^       |      done=1

9. 这个设计的硬件优势
你的架构：
代码      多个码块          |          v +----------------+ | code_block     | | concat         | +----------------+          |          v      serial bits
优势：
(1) 面积极小
只有：


一个1024bit寄存器


一个计数器


一个MUX


核心：
verilogblk[j]
综合：
就是：
1024:1选择器。
但注意：
由于j是计数器：
综合器通常实现：
RAM/LUTRAM或者MUX树。

(2) 时序简单
没有：
大宽度组合拼接。

(3) 易流水
接口：
代码valid-ready
非常适合：
连接：
代码CRC |Polar encoder |rate matching |modulator

10. 和前面的 butterfly 对比
你整个Polar Encoder现在像这样：
代码                信息bits                    |                    v          bit allocation          (串行)                    |                    v          polar_butterfly          stage0             |          stage1             |          ...          stage9                    |                    v          code block f_r                    |                    v          code_block_concat                    |                    v              g_k输出
这是非常典型的硬件通信架构。

11. 一个小建议
你的：
verilogm_bit <= blk[j[9:0]];
这里：
verilogj[9:0]
固定认为：
最大1024。
如果以后：
NMAX改成2048：
会出问题。
建议：
veriloglocalparam IDXW=$clog2(NMAX);m_bit <= blk[j[IDXW-1:0]];
更通用。

总结一句话：
这个模块的核心思想：

把原本需要大规模组合拼接的码块连接操作，转换成“一个码块缓存 + 一个地址计数器 + 串行valid输出”的时序结构，用吞吐换面积。

和你前面优化 Polar butterfly 是同一个思想：


butterfly：复用 XOR 网络


concat：复用 bit 输出通道


都是 FPGA 上非常典型的 资源共享型架构设计。你现在这个方向其实已经接近通信IP设计思路了。

