# =============================================================================
# synth_normal.tcl -- 编码器普通综合 (顶层 polar_encode_stream, 无需 OOC, 可上板)
# 用法: vivado -mode batch -source synth_normal.tcl
# 器件: 按实验室板卡改 PART。参考实测: ~1300 LCs, F7 ~4000, 普通模式可上板。
# =============================================================================
set PART xc7a100tcsg324-1

read_verilog [list \
  rtl/polar_reliability_rom.v rtl/frozen_gen.v rtl/crc_gen.v \
  rtl/polar_butterfly.v rtl/code_block_concat.v rtl/polar_encode_chain.v \
  rtl/polar_encode_stream.v ]

# 时序约束 (缺这一步会报 TIMING-17, 且时序报告无参考价值)
read_xdc constraints/polar_encode_stream.xdc

synth_design -top polar_encode_stream -part $PART
report_utilization -file util_polar_encode_stream.rpt
report_timing_summary -file timing_polar_encode_stream.rpt
report_methodology  -file methodology_polar_encode_stream.rpt
puts "== 综合完成: 见 util_polar_encode_stream.rpt =="
puts "== 时序应显示 'All user specified timing constraints are met' =="
