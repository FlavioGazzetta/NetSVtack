module pcs_link (
  input logic clk,
  input logic rst_n,

  input logic [63:0] xgmii_txd,
  input logic [7:0] xgmii_txc,
  output logic [1:0] tx_header,
  output logic [63:0] tx_data,

  input logic [1:0] rx_header,
  input logic [63:0] rx_data,
  input logic rx_valid,
  output logic rx_slip,
  output logic [63:0] xgmii_rxd,
  output logic [7:0] xgmii_rxc,
  output logic block_lock
);

  pcs_tx u_tx (
    .clk(clk),
    .rst_n(rst_n),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc),
    .tx_header(tx_header),
    .tx_data(tx_data)
  );

  pcs_rx u_rx (
    .clk(clk),
    .rst_n(rst_n),
    .rx_header(rx_header),
    .rx_data(rx_data),
    .rx_valid(rx_valid),
    .rx_slip(rx_slip),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .block_lock(block_lock)
  );

endmodule
