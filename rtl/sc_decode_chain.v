// =============================================================================
// sc_decode_chain.v -- 完整 SC 译码链 (编码链 polar_encode_chain 的镜像)
// -----------------------------------------------------------------------------
// 接收 LLR 流 -> 分段调度 -> 逐块解级联+SC译码+信息提取 -> 组级(剥pad+CRC校验)
//   -> 解分段拼回 B 比特。与编码端共享 seg_schedule(同一份分段, 假设 X1~X5 落点)。
//
// 结构:
//   seg_schedule           : (B,mcs,ftype2) -> 块描述符流 (nlog,K,padv,Kmsg,crc,grp_last)
//   sc_decode_block(裸模式) : 每块 SC 译码 + 提取 K 个原始信息位 (padv=0/Kmsg=K/crc=0)
//   组级缓冲 grpV          : 同一码块组的各块信息位按序拼成 V=0^padv‖msg‖CRC
//   组级 CRC24B            : 组末剥 padv, 对 msg 重算 CRC 与 V 尾部比对
//   解分段                : 各组 msg 顺序拼进 msg_bits
// 说明: LLR 流用并行总线 + 逐字装载(behavioral, 仿真导向); 上板可换串行前端。
// =============================================================================
module sc_decode_chain #(
    parameter integer NMAX   = 1024,
    parameter integer LLR_W  = 8,
    parameter integer INT_W  = 10,
    parameter integer MAXB   = 2048,       // 最大信息比特
    parameter integer MAXLLR = 4096        // 最大码字总长(ΣN)
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,
    input  wire [15:0]              B,
    input  wire [3:0]               mcs,
    input  wire                     ftype2,
    input  wire [23:0]              crc_seed,
    // LLR 来源: 寻址读接口(接 BRAM); 1拍寄存读延迟 (addr 组合 -> data 下拍有效)
    output wire [12:0]              llr_rd_addr,  // 读地址(块顺序, off+块内序号)
    input  wire signed [LLR_W-1:0]  llr_rd_data,  // 上拍地址对应的 LLR
    output reg                      busy,
    output reg                      done,
    output reg  [MAXB-1:0]          msg_bits,     // 还原信息比特(低B位)
    output reg                      all_crc_ok    // 所有带CRC组校验通过
);
    // ---- 分段调度 ----
    reg          seg_start, blk_next;
    wire         seg_busy, seg_done, blk_valid, blk_crc, blk_last, blk_grp_last;
    wire [3:0]   blk_nlog; wire [10:0] blk_K, blk_padv, blk_Kmsg;
    wire [7:0]   seg_cb;
    seg_schedule u_seg (
        .clk(clk), .rst_n(rst_n), .start(seg_start), .B(B), .mcs(mcs), .ftype2(ftype2),
        .busy(seg_busy), .done(seg_done), .blk_valid(blk_valid), .blk_next(blk_next),
        .blk_nlog(blk_nlog), .blk_K(blk_K), .blk_padv(blk_padv), .blk_Kmsg(blk_Kmsg),
        .blk_crc(blk_crc), .blk_last(blk_last), .blk_grp_last(blk_grp_last), .cb_count(seg_cb));

    // ---- 块解码 (裸模式: 只出 K 个原始信息位) ----
    reg          dec_start;
    reg  [3:0]   cur_nlog;
    reg  [10:0]  cur_K;
    reg  [NMAX*LLR_W-1:0] llr_blk;
    wire         dec_busy, dec_done;
    wire [NMAX-1:0] dec_msg;
    wire [10:0]  dec_len;
    sc_decode_block #(.NMAX(NMAX), .LLR_W(LLR_W), .INT_W(INT_W)) u_blk (
        .clk(clk), .rst_n(rst_n), .start(dec_start), .n_log(cur_nlog), .K(cur_K),
        .padv(11'd0), .Kmsg(cur_K), .crc_on(1'b0), .crc_seed(24'd0),
        .llr_blk(llr_blk), .busy(dec_busy), .done(dec_done),
        .msg_out(dec_msg), .msg_len(dec_len), .crc_ok());

    // ---- 组级 CRC24B (组合驱动, 与 sc_decode_block 同款时序) ----
    wire         gcrc_load, gcrc_en, gcrc_din;
    wire [23:0]  gcrc_val;
    crc_gen #(.WIDTH(24), .POLY(24'hB2B117)) u_gcrc (
        .clk(clk), .rst_n(rst_n), .load(gcrc_load), .seed(crc_seed),
        .en(gcrc_en), .din(gcrc_din), .crc(gcrc_val));
    wire [23:0]  gcrc_rev;
    genvar gc;
    generate for (gc=0; gc<24; gc=gc+1) begin: g_rev
        assign gcrc_rev[gc] = gcrc_val[23-gc];
    end endgenerate

    // ---- 组级/链级寄存器 ----
    reg  [NMAX-1:0] grpV;                  // 当前组的 V 序列
    reg  [10:0]  grpVlen;                  // grpV 已填长度
    reg  [10:0]  cur_padv, cur_Kmsg;
    reg          cur_crc, cur_grplast, cur_framelast;
    reg  [12:0]  off;                      // LLR 流偏移(LLR 单位)
    reg  [11:0]  Boff;                     // 输出比特偏移
    reg  [11:0]  cur_N;
    reg  [11:0]  j;                        // 输出计数
    reg  [12:0]  jrd;                      // LLR 读地址计数(块内, 领先写1拍)
    reg  [11:0]  jwr;                      // LLR 写 llr_blk 计数(块内)
    reg  [10:0]  jg;                       // CRC 喂入计数

    // R=1(码率1, MCS8/12) 旁路: 码块无信道编码, 信息位 = 收到的 K 个 LLR 硬判决(不做 SC 译码)
    // 与编码器 polar_encode_chain.v 的 R=1 直传对称; R<1 时 cur_rate1=0 走原 SC 路径。
    wire            rate1_now = (mcs==4'd8) || (mcs==4'd12);   // 表22: MCS8/12 -> R=1
    reg             cur_rate1;
    reg  [NMAX-1:0] pass_msg;

    localparam [3:0] S_IDLE=0, S_GET=1, S_PRE=11, S_LOAD=2, S_DEC=3, S_DECW=4,
                     S_ACC=5, S_GCLD=6, S_GCF=7, S_GCMP=8, S_WR=9, S_FIN=10, S_PMRG=12;
    reg [3:0] st;

    // LLR 寻址读: 组合地址 = 本块基址 off + 块内序号 jrd; 数据下拍有效(BRAM同步读)
    assign llr_rd_addr = off + jrd;

    // -------------------------------------------------------------------------
    // llr_blk / pass_msg 写口: **独立无复位块**
    //   llr_blk(8192位) 原在带异步复位的 always 块内、但复位分支未给它赋值, Vivado
    //   报 [Synth 8-7137] "Set 与 reset 同优先级, 可能导致仿真与综合不一致"
    //   —— 是真实风险而非风格告警。 pass_msg 的清零也必须一并移入(同一信号不能
    //   被两个 always 块驱动), 顺带省掉 1024 个触发器的复位布线。
    //   语义完全不变: 清零条件 (st==S_GET && blk_valid), 写入条件 (st==S_LOAD)。
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if ((st == S_GET) && blk_valid) begin
            pass_msg <= {NMAX{1'b0}};                 // R=1 旁路准备
        end else if (st == S_LOAD) begin
            // R<1: LLR 存入 llr_blk 供 SC; R=1: 直接对 LLR 硬判决(符号位=负=1)
            if (cur_rate1) pass_msg[jwr] <= llr_rd_data[LLR_W-1];
            else           llr_blk[jwr*LLR_W +: LLR_W] <= llr_rd_data;
        end
    end

    // 组合驱动 CRC: 装种子/喂消息位 (避免寄存器一拍延迟造成的漏位/早比)
    assign gcrc_load = (st==S_GCLD);
    assign gcrc_en   = (st==S_GCF);
    assign gcrc_din  = grpV[cur_padv + jg];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0; msg_bits<=0; all_crc_ok<=1;
            seg_start<=0; blk_next<=0; dec_start<=0;
            grpV<=0; grpVlen<=0; off<=0; Boff<=0; cur_N<=0; j<=0; jrd<=0; jwr<=0; jg<=0;
            cur_nlog<=0; cur_K<=0; cur_padv<=0; cur_Kmsg<=0; cur_crc<=0; cur_grplast<=0; cur_framelast<=0;
            cur_rate1<=0;      // pass_msg / llr_blk 在独立无复位块驱动(见上)
        end else begin
            done<=0; seg_start<=0; blk_next<=0; dec_start<=0;
            case (st)
                S_IDLE: begin
                    busy<=0;
                    if (start) begin
                        busy<=1; msg_bits<={MAXB{1'b0}}; all_crc_ok<=1'b1;
                        off<=0; Boff<=0; grpVlen<=0; grpV<={NMAX{1'b0}};
                        seg_start<=1; st<=S_GET;
                    end
                end
                S_GET: begin
                    if (seg_done && !blk_valid) st<=S_FIN;
                    else if (blk_valid) begin
                        cur_nlog<=blk_nlog; cur_K<=blk_K;
                        cur_padv<=blk_padv; cur_Kmsg<=blk_Kmsg;
                        cur_crc<=blk_crc; cur_grplast<=blk_grp_last;
                        cur_framelast<=blk_last;     // 帧末标志(锁存, 不依赖 seg_done 脉冲)
                        cur_N<=(12'd1<<blk_nlog);
                        cur_rate1<=rate1_now;        // pass_msg 清零在独立块
                        jrd<=0; jwr<=0;
                        blk_next<=1;                 // 让 seg 准备下一块
                        st<=S_PRE;
                    end
                end
                S_PRE: begin                         // 预读拍: 本拍地址=off+0, 数据下拍到
                    jrd<=13'd1; st<=S_LOAD;
                end
                S_LOAD: begin                        // 从 BRAM 逐字读入 (jrd领先jwr一拍)
                    // llr_blk / pass_msg 的写在独立无复位块 (见上), 此处只推进计数
                    jrd<=jrd+13'd1;
                    if (jwr == (cur_rate1 ? {1'b0,cur_K} : cur_N) - 12'd1) begin
                        jwr<=0; st <= cur_rate1 ? S_PMRG : S_DEC;
                    end else jwr<=jwr+12'd1;
                end
                S_PMRG: begin                        // R=1 旁路: 硬判决位直接拼进组 V, off 前进 K(非 N)
                    grpV    <= grpV | (pass_msg << grpVlen);
                    grpVlen <= grpVlen + cur_K;
                    off     <= off + {2'b0, cur_K};
                    st <= S_ACC;
                end
                S_DEC:  begin dec_start<=1; st<=S_DECW; end
                S_DECW: if (dec_done) begin
                            grpV    <= grpV | (dec_msg << grpVlen);   // 拼进组 V
                            grpVlen <= grpVlen + cur_K;
                            off     <= off + cur_N;
                            st <= S_ACC;
                        end
                S_ACC: begin                          // 组是否结束
                    j<=0;                             // 复位输出计数(S_LOAD 现用 jwr, 不再复位 j)
                    if (cur_grplast) st <= cur_crc ? S_GCLD : S_WR;
                    else             st <= S_GET;      // 组内还有块
                end
                S_GCLD: begin jg<=0; st<=S_GCF; end     // gcrc_load 组合置位, 本拍装种子
                S_GCF:  begin                          // 对 msg 位重算 CRC (组合喂位)
                    if (jg == cur_Kmsg-1) st<=S_GCMP;
                    else jg<=jg+11'd1;
                end
                S_GCMP: begin                          // 比对 V 尾部 24 位
                    if (grpV[cur_padv + cur_Kmsg +: 24] != gcrc_rev) all_crc_ok<=1'b0;
                    j<=0; st<=S_WR;
                end
                S_WR: begin                            // 解分段: msg 逐位拼进输出
                    msg_bits[Boff + j] <= grpV[cur_padv + j];
                    if (j == cur_Kmsg-1) begin
                        Boff<=Boff+{1'b0,cur_Kmsg};
                        grpV<={NMAX{1'b0}}; grpVlen<=0;
                        st <= cur_framelast ? S_FIN : S_GET;   // 帧末->收尾, 否则下一块
                    end else j<=j+12'd1;
                end
                S_FIN: begin done<=1'b1; busy<=0; st<=S_IDLE; end
                default: st<=S_IDLE;
            endcase
        end
    end
endmodule
