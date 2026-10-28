module netsvtack_zcu106 (

  input logic clk_125_p, // board oscillator
  input logic clk_125_n,
  input logic cpu_reset, // push button, high when pressed
  input logic sw_loopback, // DIP switch 0, on -> SFP1 hears itself and not the cable

  input logic sfp_refclk_p, // 156.25 MHz from the SI570
  input logic sfp_refclk_n,

  input logic sfp0_rx_p, // the stack, echoing
  input logic sfp0_rx_n,
  output logic sfp0_tx_p,
  output logic sfp0_tx_n,
  output logic sfp0_tx_disable_b, // high -> the module's laser is on

  input logic sfp1_rx_p, // the meter, cabled to SFP0
  input logic sfp1_rx_n,
  output logic sfp1_tx_p,
  output logic sfp1_tx_n,
  output logic sfp1_tx_disable_b,

  output logic uart_txd, // the meter's reports, 115200 baud
  output logic [7:0] led

);

  logic clk_125_in;
  logic clk_125;
  (* ASYNC_REG = "TRUE" *) logic [3:0] rst_q; // the button onto clk_125
  logic refclk;
  logic qpll_lock;
  logic qpll_clk;
  logic qpll_refclk;

  logic e_tx_clk; // the echo side, SFP0
  logic e_tx_rst_n;
  logic e_rx_clk;
  logic e_rx_rst_n;
  logic [63:0] e_xgmii_txd;
  logic [7:0] e_xgmii_txc;
  logic [63:0] e_xgmii_rxd;
  logic [7:0] e_xgmii_rxc;
  logic e_block_lock;
  logic tcp_connected;
  logic stat_rx_good;
  logic stat_rx_bad;
  logic [22:0] good_q; // keeps the LED on for 50 ms after a frame
  logic [22:0] bad_q;

  logic m_tx_clk; // the meter side, SFP1
  logic m_tx_rst_n;
  logic m_rx_clk;
  logic m_rx_rst_n;
  logic [63:0] m_xgmii_txd;
  logic [7:0] m_xgmii_txc;
  logic [63:0] m_xgmii_rxd;
  logic [7:0] m_xgmii_rxc;
  logic m_block_lock;
  (* ASYNC_REG = "TRUE" *) logic [1:0] raw_q; // the switch onto m_tx_clk
  logic rep_valid;
  logic [15:0] rep_lost;
  logic rep_tgl; // flips with every report
  logic rep_loss; // the last report had probes without an echo

  assign sfp0_tx_disable_b = 1'b1;
  assign sfp1_tx_disable_b = 1'b1;
  assign led = {rep_loss, rep_tgl, m_block_lock, bad_q != '0, good_q != '0, tcp_connected, e_block_lock, e_tx_rst_n};

  IBUFDS u_clk_125_ibuf (.I(clk_125_p), .IB(clk_125_n), .O(clk_125_in));
  BUFG u_clk_125_bufg (.I(clk_125_in), .O(clk_125));
  IBUFDS_GTE4 u_refclk_ibuf (.I(sfp_refclk_p), .IB(sfp_refclk_n), .CEB(1'b0), .O(refclk), .ODIV2());

  always_ff @(posedge clk_125) begin
    rst_q <= {rst_q[2:0], cpu_reset};
  end

  always_ff @(posedge e_tx_clk) begin
    if (!e_tx_rst_n) begin
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

  always_ff @(posedge m_tx_clk) begin
    raw_q <= {raw_q[0], sw_loopback};
  end

  always_ff @(posedge m_tx_clk) begin
    if (!m_tx_rst_n) begin
      rep_tgl <= 1'b0;
      rep_loss <= 1'b0;
    end else begin
      if (rep_valid) begin
        rep_tgl <= !rep_tgl;
        rep_loss <= rep_lost != '0;
      end
    end
  end

  phy_10g #(.COMMON(1'b1)) u_phy_echo (
    .clk_free(clk_125),
    .rst_free(rst_q[3]),
    .refclk(refclk),
    .loopback(1'b0),
    .qpll_lock(qpll_lock),
    .qpll_clk(qpll_clk),
    .qpll_refclk(qpll_refclk),
    .qpll_lock_in(1'b0),
    .qpll_clk_in(1'b0),
    .qpll_refclk_in(1'b0),
    .rx_p(sfp0_rx_p),
    .rx_n(sfp0_rx_n),
    .tx_p(sfp0_tx_p),
    .tx_n(sfp0_tx_n),
    .tx_clk(e_tx_clk),
    .tx_rst_n(e_tx_rst_n),
    .xgmii_txd(e_xgmii_txd),
    .xgmii_txc(e_xgmii_txc),
    .rx_clk(e_rx_clk),
    .rx_rst_n(e_rx_rst_n),
    .xgmii_rxd(e_xgmii_rxd),
    .xgmii_rxc(e_xgmii_rxc),
    .block_lock(e_block_lock)
  );

  netsvtack_echo u_echo (
    .clk(e_tx_clk),
    .rst_n(e_tx_rst_n),
    .rx_clk(e_rx_clk),
    .rx_rst_n(e_rx_rst_n),
    .xgmii_rxd(e_xgmii_rxd),
    .xgmii_rxc(e_xgmii_rxc),
    .xgmii_txd(e_xgmii_txd),
    .xgmii_txc(e_xgmii_txc),
    .tcp_connected(tcp_connected),
    .stat_rx_good(stat_rx_good),
    .stat_rx_bad(stat_rx_bad)
  );

  phy_10g #(.COMMON(1'b0)) u_phy_meter (
    .clk_free(clk_125),
    .rst_free(rst_q[3]),
    .refclk(1'b0),
    .loopback(sw_loopback),
    .qpll_lock(),
    .qpll_clk(),
    .qpll_refclk(),
    .qpll_lock_in(qpll_lock),
    .qpll_clk_in(qpll_clk),
    .qpll_refclk_in(qpll_refclk),
    .rx_p(sfp1_rx_p),
    .rx_n(sfp1_rx_n),
    .tx_p(sfp1_tx_p),
    .tx_n(sfp1_tx_n),
    .tx_clk(m_tx_clk),
    .tx_rst_n(m_tx_rst_n),
    .xgmii_txd(m_xgmii_txd),
    .xgmii_txc(m_xgmii_txc),
    .rx_clk(m_rx_clk),
    .rx_rst_n(m_rx_rst_n),
    .xgmii_rxd(m_xgmii_rxd),
    .xgmii_rxc(m_xgmii_rxc),
    .block_lock(m_block_lock)
  );

  echo_meter u_meter (
    .clk(m_tx_clk),
    .rst_n(m_tx_rst_n),
    .rx_clk(m_rx_clk),
    .rx_rst_n(m_rx_rst_n),
    .raw(raw_q[1]),
    .xgmii_rxd(m_xgmii_rxd),
    .xgmii_rxc(m_xgmii_rxc),
    .xgmii_txd(m_xgmii_txd),
    .xgmii_txc(m_xgmii_txc),
    .rep_valid(rep_valid),
    .rep_min(),
    .rep_max(),
    .rep_avg(),
    .rep_lost(rep_lost),
    .uart_txd(uart_txd)
  );

endmodule
