# read after the transceiver's own constraints, which make the two 156.25 MHz clocks

set tx_clk [get_clocks -of_objects [get_nets tx_clk]]
set rx_clk [get_clocks -of_objects [get_nets rx_clk]]

# frame_cdc: gray pointers and the word they point at, less than a clock of skew between bits
set_max_delay -datapath_only -from $rx_clk -to $tx_clk 6.400
set_max_delay -datapath_only -from $tx_clk -to $rx_clk 6.400

set_clock_groups -asynchronous -group [get_clocks clk_125] -group [list $tx_clk $rx_clk]

# the reset synchronisers in phy_10g
set_false_path -to [get_pins -hier -filter {NAME =~ u_phy/tx_rst_q_reg[*]/CLR}]
set_false_path -to [get_pins -hier -filter {NAME =~ u_phy/rx_rst_q_reg[*]/CLR}]
