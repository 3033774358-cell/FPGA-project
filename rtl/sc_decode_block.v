// =============================================================================
// sc_decode_block.v -- 单码块解码封装 (驱动组员 sc_decoder_core + 信息提取 + CRC校验)
// -----------------------------------------------------------------------------
// D 外层链路最内层单元: "喂一块 LLR -> 出该块消息比特 + CRC 校验结果"。
//   1) config: 给 (n_log, K), core 内部生成冻结集; 本模块并行起一份 frozen_gen
//      得到同一掩码(core 不暴露掩码), 用于挑非冻结位;
//   2) 逐个把 N 个 LLR 串行喂给 core (valid/ready);
//   3) core 串行吐 N 个 û(带 u_index); 非冻结位按序 = V 序列(K 位);
//   4) V = 0^padv ‖ 消息(Kmsg) ‖ CRC24(crc_on 时) —— 剥前补0, 取消息, 校验 CRC24B。
// CRC 约定与编码端逐字镜像(crc_gen 同款 LFSR, POLY=0xB2B117):
//   编码端 CRC 只对消息位算(不含padding), 附加时按 crc_rev[i]=crc[23-i](高位先);
//   本模块对提取的消息位重算 CRC, 与 V 尾部 24 位比对得 crc_ok。
//
// 端口: start 脉冲启动(busy=0 时); done 单拍, 与 msg_out/crc_ok 有效同拍。
//   msg_out[i]=第 i 个消息比特(i=0 为编码端 a0); msg_len=Kmsg; crc_ok(无CRC时恒1)。
// =============================================================================
module sc_decode_block #(
    parameter integer NMAX  = 1024,
    parameter integer LLR_W = 8,
    parameter integer INT_W = 10
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     start,        // 启动一块解码 (busy=0 时)
    input  wire [3:0]               n_log,        // log2(N)
    input  wire [10:0]              K,            // 信息位数(=padv+Kmsg+(crc?24:0))
    input  wire [10:0]              padv,          // 前补0 位数
    input  wire [10:0]              Kmsg,          // 消息位数
    input  wire                     crc_on,        // 该块是否带 CRC24B
    input  wire [23:0]              crc_seed,      // CRC 生成种子
    input  wire [NMAX*LLR_W-1:0]    llr_blk,      // 该块 N 个信道 LLR(低 N 个有效, 自然序)
    output reg                      busy,
    output reg                      done,         // 单拍
    output reg  [NMAX-1:0]          msg_out,      // 消息比特(低 Kmsg 位有效)
    output reg  [10:0]              msg_len,      // = Kmsg
    output reg                      crc_ok
);
    localparam integer INDEX_W = 11;

    // ---- FSM 状态 (前置声明) ----
    localparam [3:0] S_IDLE=4'd0, S_CFG=4'd1, S_CFGW=4'd2, S_BLK=4'd3, S_FEED=4'd4,
                     S_COLL=4'd5, S_CRCLD=4'd6, S_CRCFEED=4'd7, S_CMP=4'd8,
                     S_FIN=4'd9, S_DONE=4'd10;
    reg [3:0]  st;
    reg [11:0] fidx;                 // 已喂 LLR 数
    reg [10:0] cidx;                 // 已收信息位数 (0..K-1)
    reg [10:0] jc;                   // CRC 喂入计数
    reg [NMAX-1:0] vbuf;             // 收集的 V 序列 (K 位)
    wire [11:0] Nblk = 12'd1 << n_log;

    // ---- 组员 SC 核 ----
    wire              cfg_start, blk_start, llr_valid, u_ready;
    wire signed [LLR_W-1:0] llr_word;
    wire              cfg_ready, cfg_busy, cfg_done, cfg_err;
    wire              blk_ready, blk_busy, blk_done;
    wire              llr_ready, u_valid, u_bit, u_last;
    wire [INDEX_W-1:0] u_index;

    sc_decoder_core #(
        .NMAX(NMAX), .LLR_W(LLR_W), .INT_W(INT_W),
        .MAX_LOG(10), .MEM_DEPTH(2*NMAX-1), .ADDR_W(11), .INDEX_W(INDEX_W)
    ) u_core (
        .clk(clk), .rst_n(rst_n),
        .config_start(cfg_start), .n_log_cfg(n_log), .k_cfg(K),
        .config_ready(cfg_ready), .config_busy(cfg_busy),
        .config_done(cfg_done), .config_error(cfg_err),
        .block_start(blk_start), .block_ready(blk_ready),
        .block_busy(blk_busy), .block_done(blk_done),
        .llr_in(llr_word), .llr_in_valid(llr_valid), .llr_in_ready(llr_ready),
        .u_valid(u_valid), .u_ready(u_ready), .u_bit(u_bit),
        .u_index(u_index), .u_last(u_last)
    );

    // ---- 本地冻结掩码 (与 core 内部同源) ----
    wire         fg_start, fg_busy, fg_done;
    wire [NMAX-1:0] fg_frozen;
    frozen_gen #(.NMAX(NMAX)) u_fg (
        .clk(clk), .rst_n(rst_n), .start(fg_start),
        .n_log(n_log), .K(K), .busy(fg_busy), .done(fg_done), .frozen(fg_frozen));

    // ---- CRC24B 重算 (与编码端同款 LFSR) ----
    wire         crc_load, crc_en, crc_din;
    wire [23:0]  crc_val;
    crc_gen #(.WIDTH(24), .POLY(24'hB2B117)) u_crc (
        .clk(clk), .rst_n(rst_n), .load(crc_load), .seed(crc_seed),
        .en(crc_en), .din(crc_din), .crc(crc_val));
    wire [23:0]  crc_rev;                        // crc_rev[i]=crc_val[23-i] (高位先)
    genvar gc;
    generate for (gc=0; gc<24; gc=gc+1) begin: g_rev
        assign crc_rev[gc] = crc_val[23-gc];
    end endgenerate

    // ---- 组合控制 (状态门控) ----
    assign cfg_start = (st==S_CFG) && cfg_ready;
    assign fg_start  = (st==S_CFG) && cfg_ready;
    assign blk_start = (st==S_BLK) && blk_ready;
    assign llr_valid = (st==S_FEED);
    assign u_ready   = (st==S_COLL);
    assign llr_word  = $signed(llr_blk[fidx*LLR_W +: LLR_W]);
    assign crc_load  = (st==S_CRCLD);
    assign crc_en    = (st==S_CRCFEED);
    assign crc_din   = vbuf[padv + jc];          // 消息区第 jc 位

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; busy<=0; done<=0;
            fidx<=0; cidx<=0; jc<=0; vbuf<=0; msg_out<=0; msg_len<=0; crc_ok<=0;
        end else begin
            done<=0;
            case (st)
                S_IDLE: begin
                    busy<=0;
                    if (start) begin
                        busy<=1; msg_out<={NMAX{1'b0}}; msg_len<=Kmsg; crc_ok<=0;
                        vbuf<={NMAX{1'b0}}; fidx<=0; cidx<=0; jc<=0;
                        st<=S_CFG;
                    end
                end
                S_CFG:  if (cfg_ready) st<=S_CFGW;       // cfg_start/fg_start 本拍已脉冲
                S_CFGW: if (cfg_done)  st<=S_BLK;
                S_BLK:  if (blk_ready) st<=S_FEED;       // blk_start 本拍已脉冲
                S_FEED: if (llr_ready) begin             // valid 恒高, 成交推进 fidx
                            if (fidx == Nblk-1) st<=S_COLL;
                            else                fidx<=fidx+12'd1;
                        end
                S_COLL: if (u_valid) begin               // 收 û, 取非冻结位 = V
                            if (!fg_frozen[u_index]) begin
                                vbuf[cidx] <= u_bit;
                                cidx <= cidx + 11'd1;
                            end
                            if (u_last) st <= crc_on ? S_CRCLD : S_FIN;
                        end
                S_CRCLD:  begin jc<=0; st<=S_CRCFEED; end // 本拍 crc_load 脉冲装种子
                S_CRCFEED: begin                          // 逐位喂消息给 CRC
                            if (jc == Kmsg-1) st<=S_CMP;
                            else              jc<=jc+11'd1;
                        end
                S_CMP: begin                              // 比对 V 尾部 24 位 vs 重算
                            crc_ok  <= (vbuf[padv + Kmsg +: 24] == crc_rev);
                            msg_out <= vbuf >> padv;      // 剥前补0, 低 Kmsg 位=消息
                            st<=S_DONE;
                        end
                S_FIN: begin                              // 无 CRC: 直接输出
                            crc_ok  <= 1'b1;
                            msg_out <= vbuf >> padv;
                            st<=S_DONE;
                        end
                S_DONE: begin done<=1'b1; busy<=0; st<=S_IDLE; end
                default: st<=S_IDLE;
            endcase
        end
    end
endmodule
