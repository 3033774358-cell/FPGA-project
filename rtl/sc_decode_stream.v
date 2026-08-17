// =============================================================================
// sc_decode_stream.v -- 流式 I/O 封装顶层 (推荐 Vivado 综合顶层, 无需 OOC)
// -----------------------------------------------------------------------------
// 动机: 链核 sc_decode_chain 的 llr_stream(≈16384位输入)/ msg_bits(2048位输出)
//   是仿真导向的并行总线, 作引脚映射顶层需 ~1.8万引脚 -> 必须 Out-of-Context。
//   本封装把两侧宽总线**挪进模块内部**(串行装载缓冲 + 串行输出移位), 顶层引脚
//   降到几十个 -> 普通综合流程即可, 也可上板。与编码器 polar_encode_stream 对称。
//
// 接口时序:
//   1) cfg_start 拍采样 (B, mcs, ftype2, crc_seed); 仅空闲接受;
//   2) s_ready=1 期间逐拍送 LLR (s_valid&s_llr, 块顺序; 最后一个拍 s_last=1),
//      共送 ΣN 个 (上游解调器/前级知道总数, 用 s_last 标末尾, 类 AXIS TLAST);
//   3) 自动启动链核译码;
//   4) mo_valid 期间逐拍串行输出还原消息 (mo_bit, bit0 先; 第 B 位 mo_last=1);
//   5) done 单拍 = 整帧完毕, all_crc_ok 与之同时有效, 回空闲可配置下一帧。
//
// 链核 sc_decode_chain 原封实例化 (已由端到端 TB 验证); llr_buf / sh_out 为内部
//   寄存器(非端口)-> 消除引脚爆炸。注: llr_buf 较大(MAXLLR*LLR_W 位), 上板可换
//   BRAM 进一步省 FF; 本版用寄存器优先保证接口正确与可综合。
// =============================================================================
module sc_decode_stream #(
    parameter integer NMAX   = 1024,
    parameter integer LLR_W  = 8,
    parameter integer INT_W  = 10,
    parameter integer MAXB   = 2048,
    parameter integer MAXLLR = 2048
)(
    input  wire                 clk,
    input  wire                 rst_n,
    // 帧配置 (cfg_start 拍采样; 仅空闲接受)
    input  wire                 cfg_start,
    input  wire [15:0]          B,          // 信息比特总长
    input  wire [3:0]           mcs,        // 表22 MCS 索引 0..12
    input  wire                 ftype2,     // 1=无线帧类型2; 0=类型3/4
    input  wire [23:0]          crc_seed,   // 码块CRC24B种子
    // LLR 串行输入 (s_ready=1 期间有效; 块顺序; s_last 标最后一个)
    input  wire signed [LLR_W-1:0] s_llr,
    input  wire                 s_valid,
    input  wire                 s_last,
    output wire                 s_ready,
    // 状态 + 消息串行输出 (mo_valid 期间有效; bit0 先)
    output wire                 busy,
    output reg                  done,       // 单拍
    output wire                 mo_valid,
    output wire                 mo_bit,
    output wire                 mo_last,
    output reg                  all_crc_ok
);
    localparam integer LCW = $clog2(MAXLLR) + 1;   // LLR 计数位宽
    localparam integer BCW = $clog2(MAXB)   + 1;   // 输出计数位宽

    localparam [2:0] S_IDLE=3'd0, S_LOAD=3'd1, S_RUN=3'd2, S_WAIT=3'd3,
                     S_OUT=3'd4, S_FIN=3'd5;
    reg [2:0]  st;

    (* ram_style = "block" *)                       // 显式请求 Vivado 用块 RAM(BRAM)
    reg  signed [LLR_W-1:0] llr_mem [0:MAXLLR-1];   // 内部 LLR 缓冲 (BRAM: 计数器写/同步读)
    reg  signed [LLR_W-1:0] llr_rd_data_r;          // 同步读寄存器 (BRAM 输出)
    wire [12:0]             c_rd_addr;               // 链核给出的读地址
    reg  [MAXB-1:0]         sh_out;     // 内部输出移位寄存器 (非端口)
    reg  [LCW-1:0]          wcnt;       // 已装载 LLR 数
    reg  [BCW-1:0]          ocnt;       // 已输出比特数
    reg  [15:0]             B_l;
    reg  [3:0]              mcs_l;
    reg                     ft2_l;
    reg  [23:0]             seed_l;
    reg                     core_start;

    // ---- 链核 (宽总线全在内部) ----
    wire         chain_busy, chain_done, chain_crc;
    wire [MAXB-1:0] chain_msg;
    sc_decode_chain #(
        .NMAX(NMAX), .LLR_W(LLR_W), .INT_W(INT_W), .MAXB(MAXB), .MAXLLR(MAXLLR)
    ) u_core (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .B(B_l), .mcs(mcs_l), .ftype2(ft2_l), .crc_seed(seed_l),
        .llr_rd_addr(c_rd_addr), .llr_rd_data(llr_rd_data_r),
        .busy(chain_busy), .done(chain_done),
        .msg_bits(chain_msg), .all_crc_ok(chain_crc));

    // LLR BRAM (1写1读, 均在无复位时钟块 -> Vivado/yosys 稳妥推断成块 RAM)
    wire llr_we = (st == S_LOAD) && s_valid;    // 装载期计数器地址写
    always @(posedge clk) if (llr_we) llr_mem[wcnt] <= s_llr;   // 写口
    always @(posedge clk) llr_rd_data_r <= llr_mem[c_rd_addr];  // 同步读口

    // 写地址 wcnt: 独立**无异步复位**块 (Vivado REQP-1840: BRAM 地址不应由带异步
    // 复位的寄存器驱动 —— 复位瞬间地址异步突变可能污染存储内容, 且该路径默认不做
    // 时序分析)。此处异步复位本就冗余: 每次装载前 cfg_start 已显式清零, 且本设计
    // "先写满再读", 复位后必然重新装载。 语义与原 FSM 内递增完全一致。
    always @(posedge clk) begin
        if ((st == S_IDLE) && cfg_start) wcnt <= {LCW{1'b0}};   // 装载前清零
        else if (llr_we)                 wcnt <= wcnt + 1'b1;   // = 原 S_LOAD && s_valid
    end

    assign s_ready  = (st == S_LOAD);
    assign busy     = (st != S_IDLE);
    assign mo_valid = (st == S_OUT);
    assign mo_bit   = sh_out[0];
    assign mo_last  = (st == S_OUT) && (ocnt == B_l - 16'd1);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st<=S_IDLE; done<=0; all_crc_ok<=0; core_start<=0;
            sh_out<=0; ocnt<=0;   // llr_mem 是 BRAM 不复位; wcnt 在独立无复位块(见上)
            B_l<=0; mcs_l<=0; ft2_l<=0; seed_l<=0;
        end else begin
            done<=0; core_start<=0;
            case (st)
                S_IDLE: if (cfg_start) begin
                    B_l<=B; mcs_l<=mcs; ft2_l<=ftype2; seed_l<=crc_seed;
                    st<=S_LOAD;                 // wcnt 清零在独立无复位块
                end
                S_LOAD: if (s_valid) begin
                    if (s_last) st<=S_RUN;      // wcnt 递增在独立无复位块(llr_we)
                end
                S_RUN: begin core_start<=1'b1; st<=S_WAIT; end
                S_WAIT: if (chain_done) begin
                    sh_out     <= chain_msg;    // 并行装载 -> 逐位移出
                    all_crc_ok <= chain_crc;
                    ocnt       <= {BCW{1'b0}};
                    st<=S_OUT;
                end
                S_OUT: begin
                    sh_out <= {1'b0, sh_out[MAXB-1:1]};   // 右移, bit0 先出
                    if (ocnt == B_l - 16'd1) st<=S_FIN;
                    else ocnt<=ocnt+1'b1;
                end
                S_FIN: begin done<=1'b1; st<=S_IDLE; end
                default: st<=S_IDLE;
            endcase
        end
    end
endmodule
