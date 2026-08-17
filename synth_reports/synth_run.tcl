# =============================================================================
# sc_fast_ssc_small BRAM-optimized synthesis (unified strategy)
# Usage: vivado -mode batch -source synth_run.tcl -tclargs <out_dir> <rtl_dir>
# Part: xc7a200tfbg676-2 (license-available trend device; ZU47DR has no local
#        license). Strategy: Flow_RuntimeOptimized + NO_CROSS_BOUNDARY_OPT.
# =============================================================================
set out_dir [lindex $argv 0]
set rtl_dir [lindex $argv 1]
if {$out_dir eq "" || $rtl_dir eq ""} {
    puts "ERROR: usage: synth_run.tcl <out_dir> <rtl_dir>"
    exit 1
}
set part xc7a200tfbg676-2
file mkdir $out_dir
set proj_dir [file join $out_dir proj]
puts "== Creating project: $proj_dir (part=$part) =="
create_project sc_fast_ssc_bram $proj_dir -part $part -force
set rtl_files [list \
    [file join $rtl_dir sc_pe.v] \
    [file join $rtl_dir sc_llr_mem.v] \
    [file join $rtl_dir sc_beta_mem.v] \
    [file join $rtl_dir sc_uhat_mem.v] \
    [file join $rtl_dir frozen_gen.v] \
    [file join $rtl_dir polar_reliability_rom.v] \
    [file join $rtl_dir sc_fast_node_rom.v] \
    [file join $rtl_dir sc_datapath.v] \
    [file join $rtl_dir controller.v] \
    [file join $rtl_dir sc_decoder_core.v] \
]
add_files -norecurse $rtl_files
set_property top sc_decoder_core [current_fileset]
set_property strategy Flow_RuntimeOptimized [get_runs synth_1]
# Vivado 2024.2: no NO_CROSS_BOUNDARY_OPT property; equivalent is
# FLATTEN_HIERARCHY=none (keeps per-module hierarchy statistics clean).
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
reset_run synth_1
puts "== Launching synth_1 =="
launch_runs synth_1 -jobs 2
wait_on_run synth_1
set run_status [get_property STATUS [get_runs synth_1]]
puts "== Run status: $run_status =="
if {[string first "synth_design Complete" $run_status] != 0} {
    puts "ERROR: SYNTHESIS FAILED"
    exit 1
}
open_run synth_1
report_utilization -file [file join $out_dir utilization_top.rpt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
puts "== SYNTHESIS OK =="
puts "== Reports written to: $out_dir =="
exit 0
