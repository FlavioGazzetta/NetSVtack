module netsvtack_zcu106 (

  input logic clk_125_p, // board oscillator
  input logic clk_125_n,
  input logic cpu_reset, // push button, high when pressed

  input logic sfp_refclk_p, // 156.25 MHz from the SI570
  input logic sfp_refclk_n,
  input logic sfp0_rx_p,
  input logic sfp0_rx_n,
  output logic sfp0_tx_p,
  output logic sfp0_tx_n,
  output logic sfp0_tx_disable_b, // high -> the module's laser is on

  output logic [7:0] led

);

  logic clk_125_in;
  logic clk_125;
  (* ASYNC_REG = "TRUE" *) logic [3:0] rst_q; // the button onto clk_125
  logic refclk;

  logic tx_clk;
  logic tx_rst_n;
  logic rx_clk;
  logic rx_rst_n;
  logic [63:0] xgmii_txd;
  logic [7:0] xgmii_txc;
  logic [63:0] xgmii_rxd;
  logic [7:0] xgmii_rxc;
  logic block_lock;

  logic tcp_connected;
  logic stat_rx_good;
  logic stat_rx_bad;
  logic [22:0] good_q; // keeps the LED on for 50 ms after a frame
  logic [22:0] bad_q;

  assign sfp0_tx_disable_b = 1'b1;
  assign led = {3'b000, bad_q != '0, good_q != '0, tcp_connected, block_lock, tx_rst_n};

  IBUFDS u_clk_125_ibuf (.I(clk_125_p), .IB(clk_125_n), .O(clk_125_in));
  BUFG u_clk_125_bufg (.I(clk_125_in), .O(clk_125));
  IBUFDS_GTE4 u_refclk_ibuf (.I(sfp_refclk_p), .IB(sfp_refclk_n), .CEB(1'b0), .O(refclk), .ODIV2());

  always_ff @(posedge clk_125) begin
    rst_q <= {rst_q[2:0], cpu_reset};
  end

  always_ff @(posedge tx_clk) begin
    if (!tx_rst_n) begin
      good_q <= '0;
      bad_q <= '0;
    end else begin
      if (stat_rx_good) begin
        good_q <= '1;
      end else if (good_q != '0) begin
        good_q <= good_q - 1'b1;
      end
      if (stat_rx_bad) begin
        bad_q <= '1;
      end else if (bad_q != '0) begin
        bad_q <= bad_q - 1'b1;
      end
    end
  end

  phy_10g u_phy (
    .clk_free(clk_125),
    .rst_free(rst_q[3]),
    .refclk(refclk),
    .rx_p(sfp0_rx_p),
    .rx_n(sfp0_rx_n),
    .tx_p(sfp0_tx_p),
    .tx_n(sfp0_tx_n),
    .tx_clk(tx_clk),
    .tx_rst_n(tx_rst_n),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc),
    .rx_clk(rx_clk),
    .rx_rst_n(rx_rst_n),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .block_lock(block_lock)
  );

  netsvtack_echo u_echo (
    .clk(tx_clk),
    .rst_n(tx_rst_n),
    .rx_clk(rx_clk),
    .rx_rst_n(rx_rst_n),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc),
    .tcp_connected(tcp_connected),
    .stat_rx_good(stat_rx_good),
    .stat_rx_bad(stat_rx_bad)
  );

endmodule
