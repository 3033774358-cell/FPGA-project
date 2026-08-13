`timescale 1ns/1ps

// =============================================================================
// sc_llr_mem.v
// =============================================================================
// SC 译码器 LLR 存储模块
//
// 功能：
// 1. 串行装载根节点信道 LLR；
// 2. 保存 SC 译码过程中产生的中间层 LLR；
// 3. 提供两个组合读端口，供一个 PE 同时读取 a、b；
// 4. 提供一个时钟同步写端口，保存 PE 计算结果。
//
// -----------------------------------------------------------------------------
// 地址布局
// -----------------------------------------------------------------------------
//
// 存储器按照 SC 树的“深度 depth”进行分区。
//
// 每一个深度固定预留 NMAX 个地址：
//
//     depth_base = depth * NMAX
//
// 物理地址为：
//
//     address = depth * NMAX + layer_offset
//
// 对于当前码长 N = 2^n_log：
//
//     node_len    = N >> depth
//     layer_offset = node_id * node_len + element_index
//
// 因此：
//
//     address = depth * NMAX
//             + node_id * (N >> depth)
//             + element_index
//
// 其中：
//
//     depth         ：从根节点开始计数，根节点 depth=0
//     node_id        ：该深度下从左到右的节点编号
//     element_index  ：该节点内部的 LLR 编号
//
// -----------------------------------------------------------------------------
// N=4 地址示例，假设 NMAX=1024
// -----------------------------------------------------------------------------
//
// depth=0，根节点：
//
//     地址 0    ：根节点 d[0] 对应 LLR
//     地址 1    ：根节点 d[1] 对应 LLR
//     地址 2    ：根节点 d[2] 对应 LLR
//     地址 3    ：根节点 d[3] 对应 LLR
//
// depth=1，节点长度为2，基地址为1024：
//
//     地址 1024 ：左节点第0个 LLR
//     地址 1025 ：左节点第1个 LLR
//     地址 1026 ：右节点第0个 LLR
//     地址 1027 ：右节点第1个 LLR
//
// depth=2，叶节点层，基地址为2048：
//
//     地址 2048 ：u[0] 对应叶节点 LLR
//     地址 2049 ：u[1] 对应叶节点 LLR
//     地址 2050 ：u[2] 对应叶节点 LLR
//     地址 2051 ：u[3] 对应叶节点 LLR
//
// 对于 N=1024，共有 depth=0～10，共11层。
//
// -----------------------------------------------------------------------------
// 串行装载规则
// -----------------------------------------------------------------------------
//
// load_start 在空闲状态下拉高一个时钟周期，启动一次装载。
// 模块锁存：
//
//     N = 1 << n_log
//
// 当 llr_in_valid 与 llr_in_ready 同时为1时，接收一个 LLR：
//
//     第1个输入 → mem[0]，对应 d[0]
//     第2个输入 → mem[1]，对应 d[1]
//     ...
//     第N个输入 → mem[N-1]，对应 d[N-1]
//
// 不进行反序，也不进行 bit reversal。
//
// 接收第 N 个 LLR 后：
//
//     load_busy 拉低
//     load_done 拉高一个时钟周期
//
// -----------------------------------------------------------------------------
// 读写特性
// -----------------------------------------------------------------------------
//
// 读取：两个组合读端口
//
//     rd_data_a = mem[rd_addr_a]
//     rd_data_b = mem[rd_addr_b]
//
// 写入：时钟上升沿写入
//
//     wr_en=1 时：mem[wr_addr] <= wr_data
//
// 优先级：
//
//     根节点启动/装载 > 普通 wr_en 写入
//
// 当 load_busy=1 时，普通 wr_en 写入被忽略。
//
// -----------------------------------------------------------------------------
// 注意
// -----------------------------------------------------------------------------
//
// 1. 复位只清除控制状态，不清空整个 LLR 数组。
//    当前有效译码所需地址必须在使用前被写入。
//
// 2. 第一版使用组合双读寄存器数组。
//    后续替换同步 BRAM 时，读取会增加时钟延迟，C 控制模块需要相应调整。
//
// 3. 正常配置要求 INT_W >= LLR_W。
// =============================================================================

module sc_llr_mem #(
    parameter integer NMAX = 1024,
    parameter integer LLR_W = 8,
    parameter integer INT_W = 10,

    // NMAX=1024 时 MAX_LOG=10
    parameter integer MAX_LOG = $clog2(NMAX),

    // 每层预留 NMAX 个位置，共 MAX_LOG+1 层
    // NMAX=1024 时 MEM_DEPTH=11*1024=11264
    parameter integer MEM_DEPTH = 2 * NMAX - 1,

    // NMAX=1024
    // MEM_DEPTH=2047
    // ADDR_W=11
    parameter integer ADDR_W = $clog2(MEM_DEPTH),

    // 需要能够表示 NMAX 本身：
    // NMAX=1024 时 N_W=11
    parameter integer N_W =  $clog2(NMAX)+1
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // =========================================================================
    // 根节点串行装载接口
    // =========================================================================

    // 空闲状态下拉高一个周期，启动根节点 LLR 装载
    input  wire                     load_start,

    // 当前码长的 log2：
    // 6、7、8、9、10 分别对应 64～1024
    input  wire [3:0]               n_log,

    // 串行输入 LLR
    input  wire signed [LLR_W-1:0]  llr_in,

    // llr_in 当前周期有效
    input  wire                     llr_in_valid,

    // 模块能够接收 llr_in
    output wire                     llr_in_ready,

    // 正在装载根节点 LLR
    output reg                      load_busy,

    // 最后一个根节点 LLR 接收完成后，拉高一个周期
    output reg                      load_done,

    // =========================================================================
    // 普通同步写端口
    // =========================================================================

    // 普通写使能
    // 仅在 load_busy=0 时有效
    input  wire                     wr_en,

    // 写入物理地址
    input  wire [ADDR_W-1:0]        wr_addr,

    // 写入内部 LLR
    input  wire signed [INT_W-1:0]  wr_data,

    // =========================================================================
    // 双组合读端口
    // =========================================================================

    input  wire [ADDR_W-1:0]        rd_addr_a,
    output wire signed [INT_W-1:0]  rd_data_a,

    input  wire [ADDR_W-1:0]        rd_addr_b,
    output wire signed [INT_W-1:0]  rd_data_b
);

    // =========================================================================
    // LLR 存储数组
    // =========================================================================

    (* ram_style = "block" *)                       // 显式请求 Vivado 用块 RAM(BRAM)
    reg signed [INT_W-1:0] llr_mem [0:MEM_DEPTH-1];

    // =========================================================================
    // 根节点装载状态
    // =========================================================================

    // 当前需要装载的 LLR 总数 N
    // NMAX=1024，因此必须使用11位表示1024
    reg [N_W-1:0] active_n;

    // 当前即将写入的根节点索引
    // 范围为 0～N-1
    reg [N_W-1:0] load_count;

    // =========================================================================
    // 输入 LLR 位宽转换
    // =========================================================================
    //
    // 默认：
    //
    //     LLR_W = 8
    //     INT_W = 10
    //
    // 例如：
    //
    //     8'b1110_0000 = -32
    //
    // 符号扩展后：
    //
    //     10'b11_1110_0000 = -32
    //
    // 不改变数值。
    // =========================================================================

    wire signed [INT_W-1:0] llr_in_ext;

    generate
    if(INT_W > LLR_W)
    begin

    assign llr_in_ext =
    {
     {(INT_W-LLR_W){llr_in[LLR_W-1]}},
     llr_in
    };
    end
    else
    begin
    assign llr_in_ext = llr_in;
    end
    endgenerate

    // =========================================================================
    // valid/ready 握手
    // =========================================================================

    assign llr_in_ready = load_busy;

    wire llr_in_fire;

    assign llr_in_fire = llr_in_valid && llr_in_ready;

    // =========================================================================
    // 双端口组合读取
    // =========================================================================
    //
    // PE_NUM=1，但一次 f/g 需要两个操作数，所以提供两个组合读地址。
    //
    // 地址变化后，rd_data_a 和 rd_data_b 组合更新。
    // =========================================================================

    // 同步读(寄存一拍)-> 可推断成块 RAM(BRAM); 控制器已配 1 拍读延迟(rd_ph)
    reg signed [INT_W-1:0] rd_data_a_r, rd_data_b_r;
    always @(posedge clk) rd_data_a_r <= llr_mem[rd_addr_a];
    always @(posedge clk) rd_data_b_r <= llr_mem[rd_addr_b];
    assign rd_data_a = rd_data_a_r;
    assign rd_data_b = rd_data_b_r;

    // =========================================================================
    // 时序控制及写入
    // =========================================================================

    // ---- 控制 FSM (装载状态机; 不含存储器写, 使 llr_mem 能进 BRAM) ----
    // 复位方式: **同步复位** (原为异步 negedge rst_n)。 load_count/load_busy 参与
    //   合成 mem_wa(BRAM 写地址), 异步复位会触发 Vivado DRC REQP-1839(地址异步突变
    //   可能污染存储内容)。 改同步后地址仅在时钟沿变化。 见 controller.v 同样处理。
    always @(posedge clk) begin
        if (!rst_n) begin
            load_busy  <= 1'b0;
            load_done  <= 1'b0;
            active_n   <= {N_W{1'b0}};
            load_count <= {N_W{1'b0}};
        end
        else begin
            load_done <= 1'b0;                    // 默认单周期

            if (load_start && !load_busy) begin   // 启动装载(本拍不收数据)
                active_n   <= (1 << n_log);
                load_count <= {N_W{1'b0}};
                load_busy  <= 1'b1;
            end
            else if (load_busy) begin             // 根节点串行装载计数
                if (llr_in_fire) begin
                    if (load_count == (active_n - 1'b1)) begin
                        load_count <= {N_W{1'b0}};
                        load_busy  <= 1'b0;
                        load_done  <= 1'b1;
                    end
                    else begin
                        load_count <= load_count + 1'b1;
                    end
                end
            end
        end
    end

    // ---- 存储器写口 (无复位独立块 -> Vivado 推断块 RAM/BRAM) ----
    // 优先级同原设计: 装载期写 load_count/llr_in; 否则(非启动拍)wr_en 写 wr_addr/wr_data
    wire                    mem_we = load_busy ? llr_in_fire : (wr_en && !load_start);
    wire [ADDR_W-1:0]       mem_wa = load_busy ? load_count[ADDR_W-1:0] : wr_addr;
    wire signed [INT_W-1:0] mem_wd = load_busy ? llr_in_ext : wr_data;
    always @(posedge clk) if (mem_we) llr_mem[mem_wa] <= mem_wd;

endmodule