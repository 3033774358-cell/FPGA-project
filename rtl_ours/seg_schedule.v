// =============================================================================
// seg_schedule.v -- 码块分段调度器 (T/XS 10002-2025 6.9.1.2/6.9.1.3)
// -----------------------------------------------------------------------------
// 编解码"共享单一来源": 分段/查表逻辑与编码器 polar_encode_chain.v 逐字相同,
// 仅去掉编码数据通路(CRC引擎/冻结集/蝶形/级联/u装配), 改为按序"吐出块描述符":
//   每块 (nlog, K, padv, Kmsg, crc_on, is_last), 用 valid/next 握手交给消费者。
// 编码器与译码器用同一份 -> 对完老师数据只改这一处, 两侧同步 (假设 X1~X5 落点)。
//
// 输入 (B, mcs, ftype2); 输出块描述符流。cb_count 给出总块数。
// 所有除法/取整用迭代减法 (无变量除法, 综合友好)。
// =============================================================================
module seg_schedule (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,       // busy=0 时脉冲启动
    input  wire [15:0]  B,           // 信息比特总长
    input  wire [3:0]   mcs,         // 表22 MCS 索引 0..12
    input  wire         ftype2,      // 1=无线帧类型2; 0=类型3/4
    output reg          busy,
    output reg          done,        // 全部块吐完 (单拍)
    // 块描述符输出 (blk_valid 时有效; 消费者置 blk_next 一拍取走)
    output wire         blk_valid,
    input  wire         blk_next,
    output wire [3:0]   blk_nlog,
    output wire [10:0]  blk_K,
    output wire [10:0]  blk_padv,
    output wire [10:0]  blk_Kmsg,
    output wire         blk_crc,
    output wire         blk_last,     // 帧内最后一块
    output wire         blk_grp_last, // 码块组末块 (细分组只在最后子块=1; 独立块恒1)
    output reg  [7:0]   cb_count
);
    // ---------------- 协议表 (与编码器逐字一致) ----------------
    function [4:0] tab22_r16;
        input [3:0] m;
        case (m)
            4'd0, 4'd2:  tab22_r16 = 5'd4;    4'd1, 4'd3:  tab22_r16 = 5'd6;
            4'd4:        tab22_r16 = 5'd8;    4'd5, 4'd9:  tab22_r16 = 5'd10;
            4'd6, 4'd10: tab22_r16 = 5'd12;   4'd7, 4'd11: tab22_r16 = 5'd14;
            4'd8, 4'd12: tab22_r16 = 5'd16;   default:     tab22_r16 = 5'd8;
        endcase
    endfunction
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
            default: tab20 = {2'd2,2'd2,2'd2};
        endcase
    endfunction
    function [9:0] tab23;
        input [4:0] r16v; input [1:0] nsel;
        case ({r16v, nsel})
            {5'd4, 2'd0}: tab23=10'd96;  {5'd4, 2'd1}: tab23=10'd48;
            {5'd4, 2'd2}: tab23=10'd24;  {5'd4, 2'd3}: tab23=10'd12;
            {5'd6, 2'd0}: tab23=10'd160; {5'd6, 2'd1}: tab23=10'd80;
            {5'd6, 2'd2}: tab23=10'd40;  {5'd6, 2'd3}: tab23=10'd20;
            {5'd8, 2'd0}: tab23=10'd224; {5'd8, 2'd1}: tab23=10'd112;
            {5'd8, 2'd2}: tab23=10'd56;  {5'd8, 2'd3}: tab23=10'd28;
            {5'd10,2'd0}: tab23=10'd288; {5'd10,2'd1}: tab23=10'd144;
            {5'd10,2'd2}: tab23=10'd72;  {5'd10,2'd3}: tab23=10'd36;
            {5'd12,2'd0}: tab23=10'd352; {5'd12,2'd1}: tab23=10'd176;
            {5'd12,2'd2}: tab23=10'd88;  {5'd12,2'd3}: tab23=10'd44;
            {5'd14,2'd0}: tab23=10'd416; {5'd14,2'd1}: tab23=10'd208;
            {5'd14,2'd2}: tab23=10'd104; {5'd14,2'd3}: tab23=10'd52;
            default:      tab23=10'd0;
        endcase
    endfunction
    function [9:0] tab24;
        input [4:0] r16v; input [1:0] nsel;
        case ({r16v, nsel})
            {5'd10,2'd0}: tab24=10'd316; {5'd10,2'd1}: tab24=10'd156;
            {5'd10,2'd2}: tab24=10'd74;  {5'd10,2'd3}: tab24=10'd36;
            {5'd12,2'd0}: tab24=10'd382; {5'd12,2'd1}: tab24=10'd189;
            {5'd12,2'd2}: tab24=10'd90;  {5'd12,2'd3}: tab24=10'd45;
            {5'd14,2'd0}: tab24=10'd446; {5'd14,2'd1}: tab24=10'd221;
            {5'd14,2'd2}: tab24=10'd106; {5'd14,2'd3}: tab24=10'd53;
            default:      tab24=10'd0;
        endcase
    endfunction
    function [10:0] mul012;
        input [1:0] c; input [9:0] K;
        case (c)
            2'd0:    mul012 = 11'd0;
            2'd1:    mul012 = {1'b0, K};
            default: mul012 = {K, 1'b0};
        endcase
    endfunction

    // ---------------- 状态 ----------------
    localparam [4:0]
        S_IDLE=5'd0, SB_FULL_INIT=5'd1, SB_LAST_INIT=5'd2, SB_QINIT=5'd3,
        SB_QLOOP=5'd4, SB_SUBNEXT=5'd5, SA_INIT=5'd6, SA_N1024=5'd7, SA_IDX=5'd8,
        SA_REM=5'd9, SA_N64=5'd10, SA_BLKNEXT=5'd11, SA_PAD=5'd12,
        S_EMIT=5'd13, S_ROUTE=5'd14, S_DONE=5'd15;
    reg [4:0] state;
    localparam [1:0] PH_BFULL=2'd0, PH_BSUB=2'd1, PH_A=2'd2;
    reg [1:0] phase;

    reg  [15:0] B_l, mp;
    reg  [4:0]  r16;
    reg         use_crc;

    wire [10:0] K1024 = {r16, 6'b0};
    wire [10:0] KmL   = K1024 - 11'd24;
    wire [6:0]  Uu    = {(r16-5'd1), 2'b0};
    wire [10:0] U16   = {(r16-5'd1), 6'b0};
    wire [15:0] r16w    = {11'b0, r16};
    wire [15:0] thr1920 = (r16w << 7) - (r16w << 3);
    wire [15:0] r904    = (r16w << 5) + (r16w << 4) + (r16w << 3) + (r16w >> 1);
    wire [15:0] r128w   = (r16w << 3);

    reg  [15:0] remaining, tmpx;
    reg  [10:0] Kr;
    reg  [4:0]  qv;
    reg  [3:0]  subsel;
    reg  [3:0]  c1024;
    reg  [1:0]  c512, c256, c128;
    reg  [5:0]  c64;
    reg  [15:0] km;
    reg  [3:0]  idxA;
    reg  signed [15:0] remA;
    reg  [10:0] Kblk;
    reg  [3:0]  nlog_blk;
    reg         blk_is_last;
    reg  [10:0] padv, Kmsg_cur;
    reg         crc_on;
    reg         in_sub;                    // 当前块属于细分组(共享 V)
    wire [15:0] avail = B_l - mp;

    // 描述符输出
    assign blk_valid = (state == S_EMIT);
    assign blk_nlog  = nlog_blk;
    assign blk_K     = Kblk;
    assign blk_padv  = padv;
    assign blk_Kmsg  = Kmsg_cur;
    assign blk_crc   = crc_on;
    assign blk_last  = blk_is_last;
    // 组末: 细分组只在最后子块(=帧末), 其余独立块恒 1
    assign blk_grp_last = in_sub ? blk_is_last : 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; phase<=PH_BFULL; busy<=0; done<=0; cb_count<=0;
            B_l<=0; mp<=0; r16<=5'd8; use_crc<=0;
            remaining<=0; tmpx<=0; Kr<=0; qv<=0; subsel<=0;
            c1024<=0; c512<=0; c256<=0; c128<=0; c64<=0;
            km<=0; idxA<=0; remA<=0;
            Kblk<=0; nlog_blk<=4'd6; blk_is_last<=0; padv<=0; Kmsg_cur<=0; crc_on<=0; in_sub<=0;
        end else begin
            done<=0;
            case (state)
                S_IDLE: begin
                    busy<=0;
                    if (start && !busy) begin
                        B_l<=B; mp<=0; cb_count<=0; busy<=1; use_crc<=0;
                        r16<=tab22_r16(mcs);
                        if (ftype2) begin phase<=PH_A; state<=SA_INIT; end
                        else begin remaining<=B; state<=SB_FULL_INIT; end
                    end
                end
                // ===== 类型3/4 (6.9.1.3) =====
                SB_FULL_INIT: begin
                    if (( use_crc && (remaining > {5'b0, KmL}))  ||
                        (!use_crc && (remaining > {5'b0, K1024}))) begin
                        use_crc<=1;
                        Kblk<=K1024; nlog_blk<=4'd10; blk_is_last<=0;
                        padv<=0; Kmsg_cur<=KmL; crc_on<=1; in_sub<=0;
                        phase<=PH_BFULL; state<=S_EMIT;
                    end else state<=SB_LAST_INIT;
                end
                SB_LAST_INIT: begin
                    Kmsg_cur<=remaining[10:0];
                    Kr<=remaining[10:0] + (use_crc ? 11'd24 : 11'd0);
                    crc_on<=use_crc;
                    state<=SB_QINIT;
                end
                SB_QINIT: begin
                    phase<=PH_BSUB; subsel<=0;
                    if (r16 == 5'd16) begin
                        padv<=0; Kblk<=Kr; nlog_blk<=4'd10; blk_is_last<=1; in_sub<=0;
                        state<=S_EMIT;
                    end else if (Kr > U16) begin
                        padv<=K1024-Kr; Kblk<=K1024; nlog_blk<=4'd10; blk_is_last<=1; in_sub<=0;
                        state<=S_EMIT;
                    end else begin
                        tmpx<={5'b0,Kr}; qv<=5'd1; state<=SB_QLOOP;
                    end
                end
                SB_QLOOP: begin
                    if (tmpx > {9'b0,Uu}) begin
                        tmpx<=tmpx-{9'b0,Uu}; qv<=qv+1'b1;
                    end else begin
                        padv<={4'b0,Uu}-tmpx[10:0];
                        if (qv == 5'd16) begin
                            Kblk<=U16; nlog_blk<=4'd10; blk_is_last<=1; in_sub<=0;
                            state<=S_EMIT;
                        end else begin
                            subsel<=qv[3:0]; state<=SB_SUBNEXT;
                        end
                    end
                end
                SB_SUBNEXT: begin
                    if (subsel[3]) begin
                        nlog_blk<=4'd9; Kblk<={1'b0,tab23(r16,2'd0)};
                        subsel[3]<=0; blk_is_last<=(subsel[2:0]==3'b0);
                    end else if (subsel[2]) begin
                        nlog_blk<=4'd8; Kblk<={1'b0,tab23(r16,2'd1)};
                        subsel[2]<=0; blk_is_last<=(subsel[1:0]==2'b0);
                    end else if (subsel[1]) begin
                        nlog_blk<=4'd7; Kblk<={1'b0,tab23(r16,2'd2)};
                        subsel[1]<=0; blk_is_last<=(subsel[0]==1'b0);
                    end else begin
                        nlog_blk<=4'd6; Kblk<={1'b0,tab23(r16,2'd3)};
                        subsel[0]<=0; blk_is_last<=1;
                    end
                    in_sub<=1;
                    state<=S_EMIT;
                end
                // ===== 类型2 (6.9.1.2) =====
                SA_INIT: begin
                    c1024<=0; km<=B_l;
                    // 类型2 + R=1: 整帧直通单块 (与编码器 polar_encode_chain.v SA_INIT 同步)
                    // 【表24】无 R=1 条目, 误入查表会得到 K=0 空块; 金标准为 "P:B"。
                    if (r16 == 5'd16) begin
                        padv<=0; Kblk<=B_l[10:0]; Kmsg_cur<=B_l[10:0];
                        crc_on<=0; nlog_blk<=4'd10; blk_is_last<=1; in_sub<=0;
                        c512<=0; c256<=0; c128<=0; c64<=0;
                        state<=S_EMIT;
                    end
                    else if (B_l > thr1920) begin tmpx<=B_l - r904; state<=SA_N1024; end
                    else begin tmpx<=B_l - 16'd1; idxA<=0; state<=SA_IDX; end
                end
                SA_N1024: begin
                    if (tmpx >= {5'b0,K1024}) begin
                        tmpx<=tmpx-{5'b0,K1024}; km<=km-{5'b0,K1024}; c1024<=c1024+1'b1;
                    end else begin tmpx<=km-16'd1; idxA<=0; state<=SA_IDX; end
                end
                SA_IDX: begin
                    if ((tmpx >= r128w) && (idxA < 4'd14)) begin
                        tmpx<=tmpx-r128w; idxA<=idxA+1'b1;
                    end else begin {c512,c256,c128}<=tab20(idxA); state<=SA_REM; end
                end
                SA_REM: begin
                    remA <= $signed({1'b0,km[14:0]})
                          - $signed({5'b0,mul012(c512,tab24(r16,2'd0))})
                          - $signed({5'b0,mul012(c256,tab24(r16,2'd1))})
                          - $signed({5'b0,mul012(c128,tab24(r16,2'd2))});
                    c64<=0; state<=SA_N64;
                end
                SA_N64: begin
                    if ((remA > 0) && (tab24(r16,2'd3) != 10'd0)) begin
                        remA<=remA - $signed({5'b0,{1'b0,tab24(r16,2'd3)}}); c64<=c64+1'b1;
                    end else state<=SA_BLKNEXT;
                end
                SA_BLKNEXT: begin
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
                SA_PAD: begin
                    // 附录H符合性(与编码器 polar_encode_chain.v 同步): 类型2末块消息不足时,
                    // 不补零到表24-K, 而是收缩 K=消息位数 (类型3/4仍前补0, 见 SB_QINIT)
                    if (avail < {5'b0,Kblk}) Kblk <= avail[10:0];
                    padv     <= 11'd0;
                    Kmsg_cur <= (avail < {5'b0,Kblk}) ? avail[10:0] : Kblk;
                    crc_on<=0; in_sub<=0;
                    state<=S_EMIT;
                end
                // ===== 吐块描述符 + 路由 =====
                S_EMIT: begin
                    if (blk_next) begin
                        cb_count <= cb_count + 1'b1;
                        mp <= mp + {5'b0, Kmsg_cur};   // 累计已消费消息(类型2 avail 用)
                        state <= S_ROUTE;
                    end
                end
                S_ROUTE: begin
                    case (phase)
                        PH_BFULL: begin remaining<=remaining-{5'b0,KmL}; state<=SB_FULL_INIT; end
                        PH_BSUB:  state<=(subsel!=4'b0) ? SB_SUBNEXT : S_DONE;
                        default:  state<=({c1024,c512,c256,c128,c64}!=0) ? SA_BLKNEXT : S_DONE;
                    endcase
                end
                S_DONE: begin done<=1'b1; busy<=0; state<=S_IDLE; end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
