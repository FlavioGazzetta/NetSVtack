# Full build for the ZCU106: transceiver IP, synthesis, place and route, bitstream.
# usage (from the repo root):
#   vivado -mode batch -source fpga/zcu106/build.tcl
# everything lands in fpga/zcu106/out/

set_param general.maxThreads 8

set dir fpga/zcu106
set out $dir/out
file mkdir $out

create_project -in_memory -part xczu7ev-ffvc1156-2-e

# one GTH channel for 10GBASE-R. common is CORE for the one that holds the quad's PLL
proc gth {name channel common ports} {
  global out
  create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name $name -dir $out
  set ip [get_ips $name]
  set_property CONFIG.preset {GTH-10GBASE-R} $ip
  set_property -dict [list \
    CONFIG.CHANNEL_ENABLE $channel \
    CONFIG.TX_MASTER_CHANNEL $channel \
    CONFIG.RX_MASTER_CHANNEL $channel \
    CONFIG.TX_LINE_RATE {10.3125} \
    CONFIG.TX_REFCLK_FREQUENCY {156.25} \
    CONFIG.TX_USER_DATA_WIDTH {64} \
    CONFIG.TX_INT_DATA_WIDTH {32} \
    CONFIG.RX_LINE_RATE {10.3125} \
    CONFIG.RX_REFCLK_FREQUENCY {156.25} \
    CONFIG.RX_USER_DATA_WIDTH {64} \
    CONFIG.RX_INT_DATA_WIDTH {32} \
    CONFIG.TX_REFCLK_SOURCE "$channel clk1+1" \
    CONFIG.RX_REFCLK_SOURCE "$channel clk1+1" \
    CONFIG.LOCATE_COMMON $common \
    CONFIG.LOCATE_RESET_CONTROLLER {CORE} \
    CONFIG.LOCATE_TX_USER_CLOCKING {CORE} \
    CONFIG.LOCATE_RX_USER_CLOCKING {CORE} \
    CONFIG.LOCATE_USER_DATA_WIDTH_SIZING {CORE} \
    CONFIG.FREERUN_FREQUENCY {125} \
    CONFIG.ENABLE_OPTIONAL_PORTS $ports \
  ] $ip
  generate_target all $ip
  synth_ip $ip
}

gth gth_10g X0Y10 CORE {qpll0lock_out}
gth gth_10g_ch X0Y11 EXAMPLE_DESIGN {loopback_in}

read_verilog -sv [lsort [glob rtl/*/*.sv]] [lsort [glob $dir/rtl/*.sv]]
read_xdc $dir/zcu106.xdc
read_xdc $dir/clocks.xdc
set_property PROCESSING_ORDER LATE [get_files $dir/clocks.xdc]

synth_design -top netsvtack_zcu106 -part xczu7ev-ffvc1156-2-e
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -max_paths 5 -file $out/timing.txt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/util.txt
report_cdc -file $out/cdc.txt
report_clocks -file $out/clocks.txt
write_checkpoint -force $out/netsvtack_zcu106.dcp
puts "WNS [get_property SLACK [get_timing_paths -max_paths 1]] ns, WHS [get_property SLACK [get_timing_paths -hold -max_paths 1]] ns"
write_bitstream -force $out/netsvtack_zcu106.bit
