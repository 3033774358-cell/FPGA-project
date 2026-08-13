# =============================================================================
# polar_encode_stream.xdc -- 基础时序约束 (顶层 polar_encode_stream)
# -----------------------------------------------------------------------------
# 之前的 Vivado 报告 WNS/WHS = inf、Failing Endpoints = 0, 并非"时序全部通过",
# 而是报告末尾写的 "There are no user specified timing constraints" ——
# 没有约束文件, Vivado 不知道电路要跑多快, 所以没有做任何时序检查。
#
# 下面先给一个 100MHz(10ns 周期) 的起始约束, 这是多数 Xilinx 开发板(如
# Basys3/Nexys)板载晶振的常见频率, 供先验证设计能否在这个速度下收敛。
# 若你们的目标板子时钟不是 100MHz(比如 Zybo 是 125MHz), 把 -period 改成
# 实际周期(单位 ns) = 1000 / 目标频率(MHz) 即可, 其余不用改。
# =============================================================================
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]

# rst_n 是异步复位, 只在上电/复位瞬间变化, 不参与时钟域内的建立/保持时间检查
set_false_path -from [get_ports rst_n]

# =============================================================================
# 控制/状态类端口 (对应 DRC 报告里的 no_input_delay(49) / no_output_delay(45))
# -----------------------------------------------------------------------------
# 这些端口目前没有接任何已知的外部同步器件 (板子型号还没定, 也没有确定的下游
# 时序接口), Vivado 因此报"没有 input/output delay 约束", 但不代表设计有问题,
# 只是缺一个"这段时间预算按什么算"的说明。
#
# 现阶段先按下面两类处理:
#   - cfg_start/B/mcs/ftype2/crc_seed: 一次性配置, 在 cfg_start 之前保持稳定,
#     不是逐拍同步信号, 用 false_path 是准确的, 以后也不需要改。
#   - s_valid/s_bit/s_ready (输入侧握手) 与 busy/done/m_valid/m_bit/k_count/
#     cb_count (输出侧状态与串行流): 目前也当作板级监视/慢速接口处理, 先用
#     false_path 换掉这条 DRC 警告。
#     !! 如果以后这些端口真的接了同一板子上另一个同步时钟域的电路 (比如
#     m_valid/m_bit 直接喂给调制器或另一个 IP 核), 要把对应端口的 false_path
#     换成真实的 set_input_delay / set_output_delay, 不能再用 false_path 掩盖。
# =============================================================================
set_false_path -from [get_ports {cfg_start B[*] mcs[*] ftype2 crc_seed[*] \
                                  s_valid s_bit}]
set_false_path -to   [get_ports {s_ready busy done m_valid m_bit \
                                  k_count[*] cb_count[*]}]
