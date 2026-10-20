# Out-of-context synthesis of one block for the ZCU106, timing and utilisation.
# usage (from the repo root):
#   vivado -mode batch -source synth/ooc_synth.tcl -tclargs <top> <period_ns> <file.sv> [file.sv ...]
# reports land in synth/out/<top>/

set_param general.maxThreads 8

set top [lindex $argv 0]
set period [lindex $argv 1]
set files [lrange $argv 2 end]
set out synth/out/$top
file mkdir $out

set xdc [open $out/clk.xdc w]
puts $xdc "create_clock -period $period -name clk \[get_ports clk\]"
close $xdc

read_verilog -sv $files
read_xdc -mode out_of_context $out/clk.xdc
synth_design -mode out_of_context -top $top -part xczu7ev-ffvc1156-2-e

report_timing_summary -max_paths 5 -file $out/timing.txt
report_utilization -file $out/util.txt
report_timing -max_paths 5 -nworst 1 -file $out/worst_paths.txt
puts "WNS [get_property SLACK [get_timing_paths -max_paths 1]] ns at $period ns"
