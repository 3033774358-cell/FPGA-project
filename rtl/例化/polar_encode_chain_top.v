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
        S_CATW      = 5'd16, S_ROUTE     = 5'd17, S_DONE      = 5'd18,
        S_BYPASS    = 5'd19;               // R=1 直通: 不蝶形, 直接级联输出
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
    reg  [10:0] K_real;                    // 实际K: 类型2末块=剩余比特, 其余=Kblk
    reg  [3:0]  nlog_blk;
    reg         blk_is_last;

    wire [15:0] avail = B_l - mp;                    // 类型2: 剩余可取消息位
    wire        r1_bypass = (r16 == 5'd16);   // R=1: 直通 (类型2/3/4)

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
        .n_log(nlog_blk), .K(K_real), .busy(fg_busy), .done(fg_done), .frozen(fg_frozen));

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
        .s_load(cat_load),
        .s_blk(r1_bypass ? u_sh : bf_d),
        .s_elen(r1_bypass ? {1'b0, K_real} : elen),
        .s_last(cat_last),
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
            Kblk<=0; K_real<=0; nlog_blk<=4'd6; blk_is_last<=0;
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
                        Kblk<=K1024; K_real<=K1024;
                        nlog_blk<=4'd10; blk_is_last<=0;
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
                    if (r16 == 5'd16) begin          // R=1: 不细分, 直通
                        padv<=0; Kblk<=Kr; K_real<=Kr;
                        nlog_blk<=4'd10; blk_is_last<=1;
                        fz_sh<=0; acnt<=0;            // 冻结掩码清0, 直接装配
                        state<=S_ASM;                 // 装配结束后在 S_ASM 内转 S_BYPASS
                    end else if (Kr > U16) begin     // Kr>16U: 补0至1024R, 码长1024 @ 码率R
                        //   K = K1024 = 1024R = 表23 "码长1024" 列 (与满块同值)
                        padv<=K1024-Kr; Kblk<=K1024; K_real<=K1024;
                        nlog_blk<=4'd10; blk_is_last<=1;
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
                            Kblk<=U16; K_real<=U16;
                            nlog_blk<=4'd10; blk_is_last<=1;
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
                        K_real<={1'b0,tab23(r16,2'd0)};
                        subsel[3]<=0; blk_is_last<=(subsel[2:0]==3'b0);
                    end else if (subsel[2]) begin    // 码长256: K = tab23[R,256]
                        nlog_blk<=4'd8; Kblk<={1'b0,tab23(r16,2'd1)};
                        K_real<={1'b0,tab23(r16,2'd1)};
                        subsel[2]<=0; blk_is_last<=(subsel[1:0]==2'b0);
                    end else if (subsel[1]) begin    // 码长128: K = tab23[R,128]
                        nlog_blk<=4'd7; Kblk<={1'b0,tab23(r16,2'd2)};
                        K_real<={1'b0,tab23(r16,2'd2)};
                        subsel[1]<=0; blk_is_last<=(subsel[0]==1'b0);
                    end else begin                   // 码长64:  K = tab23[R,64]
                        nlog_blk<=4'd6; Kblk<={1'b0,tab23(r16,2'd3)};
                        K_real<={1'b0,tab23(r16,2'd3)};
                        subsel[0]<=0; blk_is_last<=1;
                    end
                    fg_start<=1; state<=S_FZ;
                end

                // ============ 类型2: 计数 (6.9.1.2 查表) ============
                SA_INIT: begin
                    c1024<=0; km<=B_l;
                    if (r16 == 5'd16) begin          // 类型2 R=1: 直通
                        padv<=0; Kblk<=B_l[10:0]; K_real<=B_l[10:0];
                        Kmsg_cur<=B_l[10:0];
                        nlog_blk<=4'd10; blk_is_last<=1;
                        fz_sh<=0; acnt<=0;
                        state<=S_ASM;                 // 装配结束后在 S_ASM 内转 S_BYPASS
                    end else if (B_l > thr1920) begin // N1024 = ⌊(B-904R)/1024R⌋
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
                        nlog_blk<=4'd10; Kblk<=K1024; K_real<=K1024; c1024<=c1024-1'b1;
                        blk_is_last<=((c1024==4'd1)&&(c512==0)&&(c256==0)&&(c128==0)&&(c64==0));
                    end else if (c512 != 0) begin
                        nlog_blk<=4'd9; Kblk<={1'b0,tab24(r16,2'd0)};
                        K_real<={1'b0,tab24(r16,2'd0)}; c512<=c512-1'b1;
                        blk_is_last<=((c512==2'd1)&&(c256==0)&&(c128==0)&&(c64==0));
                    end else if (c256 != 0) begin
                        nlog_blk<=4'd8; Kblk<={1'b0,tab24(r16,2'd1)};
                        K_real<={1'b0,tab24(r16,2'd1)}; c256<=c256-1'b1;
                        blk_is_last<=((c256==2'd1)&&(c128==0)&&(c64==0));
                    end else if (c128 != 0) begin
                        nlog_blk<=4'd7; Kblk<={1'b0,tab24(r16,2'd2)};
                        K_real<={1'b0,tab24(r16,2'd2)}; c128<=c128-1'b1;
                        blk_is_last<=((c128==2'd1)&&(c64==0));
                    end else begin
                        nlog_blk<=4'd6; Kblk<={1'b0,tab24(r16,2'd3)};
                        K_real<={1'b0,tab24(r16,2'd3)}; c64<=c64-1'b1;
                        blk_is_last<=(c64==6'd1);
                    end
                    state<=SA_PAD;
                end
                SA_PAD: begin                        // 类型2: 最后一码块 K=剩余比特, 不补零
                    if (blk_is_last && (avail < {5'b0,Kblk})) begin
                        padv     <= 11'd0;
                        Kmsg_cur <= avail[10:0];
                        K_real   <= avail[10:0];     // 让冻结生成器使用真实K
                    end else begin
                        padv     <= 11'd0;
                        Kmsg_cur <= Kblk;
                        K_real   <= Kblk;
                    end
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
                        if (r1_bypass) begin
                            // R=1: 本拍边沿完成最后一次移位, u_sh 随后保持完整;
                            // S_BYPASS 装载时直接取 u_sh, 避免边沿前采样少一位
                            state<=S_BYPASS;
                        end else begin
                            bf_start<=1;             // 启动蝶形 (u_bottom 已就绪)
                            state<=S_ENC;
                        end
                    end else
                        acnt<=acnt+11'd1;
                end
                S_ENC: begin                         // 蝶形编码 (log2(N)+1 拍)
                    if (bf_done)
                        state<=S_CATW;
                end
                S_BYPASS: begin                      // R=1 直通: 不蝶形
                    if (cat_ready) begin
                        cat_load<=1; cat_last<=blk_is_last;
                        cb_count<=cb_count+1'b1;
                        state<=S_ROUTE;
                    end
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
