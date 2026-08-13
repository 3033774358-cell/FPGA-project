// =============================================================================
// polar_encode_stream.v -- 流式输入封装顶层 (推荐 Vivado 综合顶层, 无需 OOC)
// -----------------------------------------------------------------------------
// 动机: 链核 polar_encode_chain 的 msg 是 2048 位并行输入 (≈2100 引脚), 任何芯片
//   都装不下物理引脚, 直接综合必须设 Out-of-Context。本封装把消息改为**逐位串行
//   装载** (s_valid/s_bit), 顶层引脚降到几十个 —— 普通流程即可综合, 也可上板。
//
// 装载机制 (零变址网络, 与链核同一面积原则):
//   - buf_sh 移位寄存器: 每 s_valid 拍从高位插入一位 (a0 先送);
//   - 送满 B 位后进入对齐段: 继续补零移位至总移位数 = MSG_MAX,
//     此时 a0 恰好落在 bit0 (链核要求 msg[0]=首比特), 无需桶形移位器;
//   - 对齐最多 MSG_MAX 拍, 相对编码时延可忽略。
//
// 时序: cfg_start(采样 B/mcs/ftype2/crc_seed) → s_ready=1 期间送 B 位
//   (可有气泡, s_valid 置位才计数) → 自动启动链核 → m_valid/m_bit 串行输出
//   → done 单拍 = 整帧完毕, 回到空闲可配置下一帧。
//
// 链核 polar_encode_chain 原封不动实例化 (已由整链 TB 黄金模型验证);
// 本封装另有 tb_polar_encode_stream 与链核并行输入版逐位等价性比对。
// =============================================================================
module polar_encode_stream #(
    parameter integer NMAX    = 1024,
    parameter integer MSG_MAX = 2048
)(
    input  wire        clk,
    input  wire        rst_n,
    // 帧配置 (cfg_start 拍采样; 仅空闲时接受)
    input  wire        cfg_start,
    input  wire [15:0] B,         // 信息比特总长
    input  wire [3:0]  mcs,       // 表22 调制编码方式索引 0..12
    input  wire        ftype2,    // 1=无线帧类型2; 0=类型3/4
    input  wire [23:0] crc_seed,  // 码块CRC24B种子 (广播类: 0x555555)
    // 消息串行装载 (s_ready=1 期间有效, a0 先送)
    input  wire        s_valid,
    input  wire        s_bit,
    output wire        s_ready,
    // 状态与编码输出 (m_* 直通链核)
    output wire        busy,      // 整帧处理中 (含装载/对齐)
    output wire        done,      // 整帧输出完毕 (单拍)
    output wire        m_valid,
    output wire        m_bit,
    output wire [31:0] k_count,
    output wire [7:0]  cb_count
);
    localparam integer CW = $clog2(MSG_MAX) + 1;      // 计数到 MSG_MAX (含) 的位宽
    localparam [CW-1:0] SHMAX = MSG_MAX[CW-1:0];

    localparam [1:0] W_IDLE=2'd0, W_LOAD=2'd1, W_ALIGN=2'd2, W_RUN=2'd3;
    reg [1:0]         wst;
    reg [MSG_MAX-1:0] buf_sh;
    reg [CW-1:0]      shcnt;      // 已移位次数 (装载+对齐)
    reg [15:0]        bitcnt;     // 已装载消息位数
    reg [15:0]        B_l;
    reg [3:0]         mcs_l;
    reg               ft2_l;
    reg [23:0]        seed_l;
    reg               core_start;

    assign s_ready = (wst == W_LOAD);
    assign busy    = (wst != W_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wst<=W_IDLE; buf_sh<=0; shcnt<=0; bitcnt<=0;
            B_l<=0; mcs_l<=0; ft2_l<=0; seed_l<=0; core_start<=0;
        end else begin
            core_start<=0;
            case (wst)
                W_IDLE: if (cfg_start) begin
                    B_l<=B; mcs_l<=mcs; ft2_l<=ftype2; seed_l<=crc_seed;
                    shcnt<={CW{1'b0}}; bitcnt<=16'd0;
                    wst<=W_LOAD;
                end
                W_LOAD: begin
                    if (B_l == 16'd0)                 // 异常保护: 空帧直接对齐
                        wst<=W_ALIGN;
                    else if (s_valid) begin
                        buf_sh<={s_bit, buf_sh[MSG_MAX-1:1]};
                        shcnt<=shcnt+1'b1;
                        bitcnt<=bitcnt+1'b1;
                        if (bitcnt+16'd1 == B_l) wst<=W_ALIGN;
                    end
                end
                W_ALIGN: begin                        // 补零至 a0 落到 bit0
                    if (shcnt == SHMAX) begin
                        core_start<=1;
                        wst<=W_RUN;
                    end else begin
                        buf_sh<={1'b0, buf_sh[MSG_MAX-1:1]};
                        shcnt<=shcnt+1'b1;
                    end
                end
                W_RUN: if (done) wst<=W_IDLE;
                default: wst<=W_IDLE;
            endcase
        end
    end

    /* verilator lint_off PINCONNECTEMPTY */          // 链核 busy 由本封装 busy 覆盖
    polar_encode_chain #(.NMAX(NMAX), .MSG_MAX(MSG_MAX)) u_core (
        .clk(clk), .rst_n(rst_n), .start(core_start),
        .msg(buf_sh), .B(B_l), .mcs(mcs_l), .ftype2(ft2_l), .crc_seed(seed_l),
        .busy(), .done(done), .m_valid(m_valid), .m_bit(m_bit),
        .k_count(k_count), .cb_count(cb_count));
    /* verilator lint_on PINCONNECTEMPTY */
endmodule
