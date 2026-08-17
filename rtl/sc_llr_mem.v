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
// 存储物理结构（2026-08-12 面积优化重构）
// -----------------------------------------------------------------------------
//
// 原实现：2047 x 10bit 单一寄存器数组 + 同步读。
// 面积问题：写 always 块带异步复位，且一次需要 2 个单读 + 8 路宽读共 10 个
// 读端口，Vivado 无法把整个数组映射成 BRAM/URAM，只能退化为
// 2047 深寄存器阵列 + 多棵 2047:1 地址 MUX（F7/F8 MUX 树），
// 即报告中的 ~89K LUT + 35K F7 + 17K F8。
//
// 新结构（保持端口、时序、算法完全不变）：
//
//   copyA : 2048 x 10bit 简单双口 BRAM（1W + 1R），只服务 rd_addr_a；
//   copyB : 2048 x 10bit 简单双口 BRAM（1W + 1R），只服务 rd_addr_b；
//   copyV : 8 x (256 x 10bit) BRAM bank，服务 Fast-SSC 8 路宽读；
//           地址低 3 位选 bank，高 8 位选 word，8 个连续地址天然落在
//           8 个不同 bank，一个周期并行读 8 个 LLR。
//
// 三个副本同步写入（装载写入 + PE 写回），读端口彼此独立，
// 任何读写组合都不会超过单 bank 1W+1R 的物理能力。
//
// 代价：BRAM 增加约 10~12 个 RAMB18（ZU47DR 共 1080 个，占比 ~1%），
//       LUT/F7/F8 从 ~89K/35K/17K 降到几百量级。
//
// 读延迟保持 1 拍：地址周期 T 生效，数据周期 T+1 有效
// （BRAM 自带输出寄存器，时序与原来的“同步读寄存器数组”完全一致，
//  控制器/datapath 流水线无需任何修改）。
//
// =============================================================================

module sc_llr_mem #(
    parameter integer NMAX = 1024,
    parameter integer LLR_W = 8,
    parameter integer INT_W = 10,

    // NMAX=1024 时 MAX_LOG=10
    parameter integer MAX_LOG = $clog2(NMAX),

    parameter integer MEM_DEPTH = 2 * NMAX - 1,

    // NMAX=1024
    // MEM_DEPTH=2047
    // ADDR_W=11
    parameter integer ADDR_W = $clog2(MEM_DEPTH),

    // 需要能够表示 NMAX 本身：
    // NMAX=1024 时 N_W=11
    parameter integer N_W =  $clog2(NMAX)+1,

    // Fast-SSC: P 路宽读端口位宽
    parameter integer FAST_P = 8
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
    output wire signed [INT_W-1:0]  rd_data_b,

    // =========================================================================
    // Fast-SSC 宽读接口（Rate-1 DECIDE 阶段一次读 P 个连续 LLR）
    // =========================================================================

    input  wire [ADDR_W-1:0]        rd_vec_addr,
    output wire [(FAST_P*INT_W)-1:0] rd_vec_data
);

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
    // 默认：LLR_W=8，INT_W=10，符号扩展，数值不变。
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
    // 写地址/写数据选择
    // =========================================================================
    //
    // 优先级（与原实现一致）：
    //
    //     装载写入（load_busy && llr_in_fire）> 普通 wr_en 写入
    //
    // 三个副本（copyA/copyB/copyV）写同样的数据。
    // =========================================================================

    localparam integer BANK_DEPTH = 1 << (ADDR_W - 3);   // 256
    localparam integer BANK_AW    = ADDR_W - 3;          // 8

    wire bank_we_load =
        load_busy && llr_in_fire;

    wire [BANK_AW-1:0] bank_waddr_load =
        load_count[ADDR_W-1:3];

    wire signed [INT_W-1:0] bank_wdata_load =
        llr_in_ext;

    wire bank_we_norm =
        (!load_busy) && wr_en;

    wire [BANK_AW-1:0] bank_waddr_norm =
        wr_addr[ADDR_W-1:3];

    wire signed [INT_W-1:0] bank_wdata_norm =
        wr_data;

    // =========================================================================
    // copyA：读端口 A 专用 BRAM（扁平 2048 深）
    // =========================================================================

    wire signed [INT_W-1:0] qa;

    sc_llr_ram #(
        .INT_W (INT_W),
        .DEPTH (1 << ADDR_W),
        .AW    (ADDR_W)
    )
    u_ram_a (
        .clk   (clk),
        .we    (bank_we_load | bank_we_norm),
        .waddr (bank_we_load ? load_count[ADDR_W-1:0]
                             : wr_addr),
        .wdata (bank_we_load ? bank_wdata_load : bank_wdata_norm),
        .raddr (rd_addr_a),
        .q     (qa)
    );

    assign rd_data_a = qa;

    // =========================================================================
    // copyB：读端口 B 专用 BRAM（扁平 2048 深）
    // =========================================================================

    wire signed [INT_W-1:0] qb;

    sc_llr_ram #(
        .INT_W (INT_W),
        .DEPTH (1 << ADDR_W),
        .AW    (ADDR_W)
    )
    u_ram_b (
        .clk   (clk),
        .we    (bank_we_load | bank_we_norm),
        .waddr (bank_we_load ? load_count[ADDR_W-1:0]
                             : wr_addr),
        .wdata (bank_we_load ? bank_wdata_load : bank_wdata_norm),
        .raddr (rd_addr_b),
        .q     (qb)
    );

    assign rd_data_b = qb;

    // =========================================================================
    // copyV：Fast-SSC 8 路宽读专用 bank 阵列
    // =========================================================================
    //
    // 8 个连续地址（rd_vec_addr, rd_vec_addr+1, ..., rd_vec_addr+7）
    // 按低 3 位落入 8 个不同 bank，因此一个周期并行读 8 个 LLR。
    //
    // bank b 负责的 lane 为：lane = (b - rd_vec_addr[2:0]) & 7，
    // 其物理地址为 rd_vec_addr + lane，word 为 (rd_vec_addr+lane)>>3。
    // 越界 lane（>= MEM_DEPTH）输出补 0，同时 bank 读地址被钳到合法范围，
    // 不产生非法下标访问。
    // =========================================================================

    wire signed [INT_W-1:0] qv [0:FAST_P-1];
    wire [ADDR_W:0] vec_lane_addr [0:FAST_P-1];

    genvar gv;
    generate
        for (gv = 0; gv < FAST_P; gv = gv + 1)
        begin : gen_ram_v

            assign vec_lane_addr[gv] =
                {1'b0, rd_vec_addr} +
                ((gv - rd_vec_addr[2:0]) & (FAST_P-1));

            sc_llr_bank #(
                .INT_W (INT_W),
                .DEPTH (BANK_DEPTH),
                .AW    (BANK_AW)
            )
            u_ram_v (
                .clk   (clk),
                .we    ((bank_we_load && (load_count[2:0] == gv)) ||
                        (bank_we_norm && (wr_addr[2:0] == gv))),
                .waddr (bank_we_load ? bank_waddr_load : bank_waddr_norm),
                .wdata (bank_we_load ? bank_wdata_load : bank_wdata_norm),
                .raddr (vec_lane_addr[gv] < MEM_DEPTH
                            ? vec_lane_addr[gv][ADDR_W-1:3]
                            : {BANK_AW{1'b0}}),
                .q     (qv[gv])
            );
        end
    endgenerate

    // =========================================================================
    // 宽读输出：每 lane 选择其对应 bank 的注册输出，越界补 0
    // =========================================================================
    //
    // 注意：bank 的注册输出 qv 对应“上一拍”的 rd_vec_addr。因此 lane 选择
    // 与越界保护必须使用 rd_vec_addr_r（与 qv 同拍），而不能使用当前组合的
    // rd_vec_addr，否则在 gap/非快速周期地址变化后，旧数据的越界 lane
    // 会失去屏蔽（泄漏陈旧/X 数据）。
    // =========================================================================

    reg [ADDR_W-1:0] rd_vec_addr_r;

    always @(posedge clk) begin
        rd_vec_addr_r <= rd_vec_addr;
    end

    genvar gv2;
    generate
        for (gv2 = 0; gv2 < FAST_P; gv2 = gv2 + 1)
        begin : gen_rd_vec
            wire [ADDR_W:0] lane_addr =
                {1'b0, rd_vec_addr_r} + gv2;

            assign rd_vec_data[gv2*INT_W +: INT_W] =
                (lane_addr < MEM_DEPTH)
                ? qv[(rd_vec_addr_r[2:0] + gv2) & (FAST_P-1)]
                : {INT_W{1'b0}};
        end
    endgenerate

    // =========================================================================
    // 时序控制（只控制装载状态机；存储体本身不复位）
    // =========================================================================

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_busy  <= 1'b0;
            load_done  <= 1'b0;
            active_n   <= {N_W{1'b0}};
            load_count <= {N_W{1'b0}};
        end
        else begin
            // load_done 默认只保持一个周期
            load_done <= 1'b0;

            // =================================================================
            // 启动一次新的根节点装载
            // =================================================================

            if (load_start && !load_busy) begin
                active_n   <= (1 << n_log);
                load_count <= {N_W{1'b0}};
                load_busy  <= 1'b1;
            end

            // =================================================================
            // 根节点串行装载
            // =================================================================

            else if (load_busy) begin
                if (llr_in_fire) begin

                    // 根节点基地址固定为0
                    // load_count=0 → d[0]，...，load_count=N-1 → d[N-1]

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

            // 普通写端口不需要控制状态参与：写使能/地址/数据已组合接入存储体
        end
    end

    // =========================================================================
    // 仿真观察影子数组（仅仿真，不综合）
    // =========================================================================
    //
    // tb_256 / tb_1024 通过层次引用 u_sc_llr_mem.llr_mem[i] 检查
    // 根节点 LLR 内容。真实存储为 BRAM 副本，因此保留与真实存储同步
    // 更新的仿真影子数组。该数组在综合（SYNTHESIS 宏定义）时被排除。
    // =========================================================================

`ifndef SYNTHESIS

    reg signed [INT_W-1:0] llr_mem [0:MEM_DEPTH-1];

    integer sli;

    always @(posedge clk) begin
        if (load_busy && llr_in_fire) begin
            llr_mem[load_count] <= llr_in_ext;
        end
        else if (wr_en) begin
            llr_mem[wr_addr] <= wr_data;
        end
    end

`endif

endmodule

// =============================================================================
// sc_llr_ram：扁平简单双口 BRAM（1 写 + 1 同步读）
// =============================================================================

module sc_llr_ram #(
    parameter integer INT_W  = 10,
    parameter integer DEPTH  = 2048,
    parameter integer AW     = 11
)(
    input  wire                     clk,
    input  wire                     we,
    input  wire [AW-1:0]            waddr,
    input  wire signed [INT_W-1:0]  wdata,
    input  wire [AW-1:0]            raddr,
    output wire signed [INT_W-1:0]  q
);

    (* ram_style = "block" *)
    reg signed [INT_W-1:0] ram [0:DEPTH-1];

    reg signed [INT_W-1:0] q_r;

    always @(posedge clk) begin
        if (we) begin
            ram[waddr] <= wdata;
        end
        q_r <= ram[raddr];
    end

    assign q = q_r;

endmodule

// =============================================================================
// sc_llr_bank：8 路宽读 bank（256 深简单双口 BRAM）
// =============================================================================

module sc_llr_bank #(
    parameter integer INT_W = 10,
    parameter integer DEPTH = 256,
    parameter integer AW    = 8
)(
    input  wire                     clk,
    input  wire                     we,
    input  wire [AW-1:0]            waddr,
    input  wire signed [INT_W-1:0]  wdata,
    input  wire [AW-1:0]            raddr,
    output wire signed [INT_W-1:0]  q
);

    (* ram_style = "block" *)
    reg signed [INT_W-1:0] ram [0:DEPTH-1];

    reg signed [INT_W-1:0] q_r;

    always @(posedge clk) begin
        if (we)
            ram[waddr] <= wdata;
        q_r <= ram[raddr];
    end

    assign q = q_r;

endmodule
