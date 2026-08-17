# Generate utilization reports from an existing synthesized run.
# Usage: vivado -mode batch -source report_synth.tcl -tclargs <proj_dir> <out_dir>
set proj_dir [lindex $argv 0]
set out_dir  [lindex $argv 1]
open_project $proj_dir
open_run synth_1
report_utilization -file [file join $out_dir utilization_top.rpt]
report_utilization -hierarchical -file [file join $out_dir utilization_hier.rpt]
puts "== REPORTS OK =="
exit 0
