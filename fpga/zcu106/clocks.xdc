# read after the transceivers' own constraints, which make the four 156.25 MHz clocks

set e_tx_clk [get_clocks -of_objects [get_nets e_tx_clk]]
set e_rx_clk [get_clocks -of_objects [get_nets e_rx_clk]]
set m_tx_clk [get_clocks -of_objects [get_nets m_tx_clk]]
set m_rx_clk [get_clocks -of_objects [get_nets m_rx_clk]]

# frame_cdc: gray pointers and the word they point at, less than a clock of skew between bits.
# the meter's start of frame flag crosses the same way
set_max_delay -datapath_only -from $e_rx_clk -to $e_tx_clk 6.400
set_max_delay -datapath_only -from $e_tx_clk -to $e_rx_clk 6.400
set_max_delay -datapath_only -from $m_rx_clk -to $m_tx_clk 6.400
set_max_delay -datapath_only -from $m_tx_clk -to $m_rx_clk 6.400

# the two sides only meet on the cable
set_clock_groups -asynchronous -group [get_clocks clk_125] -group [list $e_tx_clk $e_rx_clk] -group [list $m_tx_clk $m_rx_clk]

# the reset synchronisers in phy_10g
set_false_path -to [get_pins -hier -filter {NAME =~ */tx_rst_q_reg[*]/CLR}]
set_false_path -to [get_pins -hier -filter {NAME =~ */rx_rst_q_reg[*]/CLR}]
