# ZCU106, xczu7ev-ffvc1156-2-e, SFP0

set_property -dict {PACKAGE_PIN H9 IOSTANDARD LVDS} [get_ports clk_125_p]
set_property -dict {PACKAGE_PIN G9 IOSTANDARD LVDS} [get_ports clk_125_n]
create_clock -period 8.000 -name clk_125 [get_ports clk_125_p]

set_property -dict {PACKAGE_PIN G13 IOSTANDARD LVCMOS18} [get_ports cpu_reset]
set_false_path -from [get_ports cpu_reset]

# 156.25 MHz, MGTREFCLK1 of quad 226, the SI570 at its power-on frequency
set_property PACKAGE_PIN U10 [get_ports sfp_refclk_p]
set_property PACKAGE_PIN U9 [get_ports sfp_refclk_n]
create_clock -period 6.400 -name sfp_refclk [get_ports sfp_refclk_p]

# SFP0 is GTHE4_CHANNEL_X0Y10 in quad 225
set_property PACKAGE_PIN AA2 [get_ports sfp0_rx_p]
set_property PACKAGE_PIN AA1 [get_ports sfp0_rx_n]
set_property PACKAGE_PIN Y4 [get_ports sfp0_tx_p]
set_property PACKAGE_PIN Y3 [get_ports sfp0_tx_n]
set_property -dict {PACKAGE_PIN AE22 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports sfp0_tx_disable_b]
set_false_path -to [get_ports sfp0_tx_disable_b]

set_property -dict {PACKAGE_PIN AL11 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN AL13 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN AK13 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN AE15 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN AM8 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN AM9 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN AM10 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[6]}]
set_property -dict {PACKAGE_PIN AM11 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[7]}]
set_false_path -to [get_ports {led[*]}]

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
