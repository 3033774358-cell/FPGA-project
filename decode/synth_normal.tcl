# =============================================================================
# synth_normal.tcl -- 译码器普通综合 (顶层 sc_decode_stream, 免 OOC, 可上板)
# 用法: vivado -mode batch -source synth_normal.tcl
# 器件: 按实验室板卡改 PART。 xc7a35t(20800 LUT) 太小会爆, 已实测 xc7a100t 通过(49%)。
# =============================================================================
set PART xc7a100tcsg324-1

read_verilog [list \
  rtl_shared/polar_reliability_rom.v rtl_shared/frozen_gen.v rtl_shared/crc_gen.v \
  rtl_core/sc_pe.v rtl_core/sc_llr_mem.v rtl_core/sc_beta_mem.v rtl_core/sc_uhat_mem.v \
  rtl_core/sc_datapath.v rtl_core/controller.v rtl_core/sc_decoder_core.v \
  rtl_ours/seg_schedule.v rtl_ours/sc_decode_block.v rtl_ours/sc_decode_chain.v \
  rtl_ours/sc_decode_stream.v ]

# ★时序约束 (缺这一步会报 1000 条 TIMING-17, 且时序报告无参考价值)
read_xdc constraints/sc_decode_stream.xdc

synth_design -top sc_decode_stream -part $PART
report_utilization -file util_sc_decode_stream.rpt
report_timing_summary -file timing_sc_decode_stream.rpt
report_methodology  -file methodology_sc_decode_stream.rpt
puts "== 综合完成: 见 util_sc_decode_stream.rpt =="
puts "== 请确认 Block RAM Tile > 0 (核内存应推断成 BRAM); 若为 0 说明 mem 未进 BRAM =="
puts "== 时序应显示 'All user specified timing constraints are met'; TIMING-17 应清零 =="
