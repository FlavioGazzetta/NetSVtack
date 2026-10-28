module phy_10g #(
  parameter bit COMMON = 1'b1 // 1 -> has the quad's PLL in it, 0 -> takes it from the one that has
)(

  input logic clk_free, // 125 MHz, runs the transceiver's reset sequence
  input logic rst_free,
  input logic refclk, // 156.25 MHz, COMMON only
  input logic loopback, // the transmitter straight into the receiver inside the transceiver, not with COMMON

  output logic qpll_lock, // COMMON only
  output logic qpll_clk,
  output logic qpll_refclk,
  input logic qpll_lock_in, // not with COMMON
  input logic qpll_clk_in,
  input logic qpll_refclk_in,

  input logic rx_p,
  input logic rx_n,
  output logic tx_p,
  output logic tx_n,

  output logic tx_clk, // 156.25 MHz
  output logic tx_rst_n,
  input logic [63:0] xgmii_txd,
  input logic [7:0] xgmii_txc,

  output logic rx_clk, // 156.25 MHz, recovered from the link
  output logic rx_rst_n,
  output logic [63:0] xgmii_rxd,
  output logic [7:0] xgmii_rxc,
  output logic block_lock

);

  logic tx_done;
  logic rx_done;
  logic [3:0] tx_rst_q;
  logic [3:0] rx_rst_q;

  logic [1:0] tx_header; // pcs_tx -> transceiver
  logic [63:0] tx_data;
  logic [5:0] gt_txheader;
  logic [63:0] gt_txdata;

  logic [1:0] rx_header; // transceiver -> pcs_rx
  logic [63:0] rx_data;
  logic rx_valid;
  logic rx_slip;
  logic [5:0] gt_rxheader;
  logic [63:0] gt_rxdata;
  logic [1:0] gt_rxheadervalid;
  logic [1:0] gt_rxdatavalid;

  assign tx_rst_n = tx_rst_q[3];
  assign rx_rst_n = rx_rst_q[3];

  assign gt_txheader = {4'b0000, tx_header[0], tx_header[1]}; // the gearbox sends the top bit first
  assign gt_txdata = {<<{tx_data}};
  assign rx_header = {gt_rxheader[0], gt_rxheader[1]};
  assign rx_data = {<<{gt_rxdata}};
  assign rx_valid = gt_rxheadervalid[0] && gt_rxdatavalid[0];

  always_ff @(posedge tx_clk or negedge tx_done) begin
    if (!tx_done) begin
      tx_rst_q <= '0;
    end else begin
      tx_rst_q <= {tx_rst_q[2:0], 1'b1};
    end
  end

  always_ff @(posedge rx_clk or negedge rx_done) begin
    if (!rx_done) begin
      rx_rst_q <= '0;
    end else begin
      rx_rst_q <= {rx_rst_q[2:0], 1'b1};
    end
  end

  pcs_tx u_pcs_tx (
    .clk(tx_clk),
    .rst_n(tx_rst_n),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc),
    .tx_header(tx_header),
    .tx_data(tx_data)
  );

  pcs_rx u_pcs_rx (
    .clk(rx_clk),
    .rst_n(rx_rst_n),
    .rx_header(rx_header),
    .rx_data(rx_data),
    .rx_valid(rx_valid),
    .rx_slip(rx_slip),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .block_lock(block_lock)
  );

  if (COMMON) begin : g_gth

    gth_10g u_gth ( // gtwizard_ultrascale, made by build.tcl
      .gtwiz_userclk_tx_reset_in(1'b0),
      .gtwiz_userclk_tx_srcclk_out(),
      .gtwiz_userclk_tx_usrclk_out(),
      .gtwiz_userclk_tx_usrclk2_out(tx_clk),
      .gtwiz_userclk_tx_active_out(),
      .gtwiz_userclk_rx_reset_in(1'b0),
      .gtwiz_userclk_rx_srcclk_out(),
      .gtwiz_userclk_rx_usrclk_out(),
      .gtwiz_userclk_rx_usrclk2_out(rx_clk),
      .gtwiz_userclk_rx_active_out(),
      .gtwiz_reset_clk_freerun_in(clk_free),
      .gtwiz_reset_all_in(rst_free),
      .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_tx_datapath_in(1'b0),
      .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_rx_datapath_in(1'b0),
      .gtwiz_reset_rx_cdr_stable_out(),
      .gtwiz_reset_tx_done_out(tx_done),
      .gtwiz_reset_rx_done_out(rx_done),
      .gtwiz_userdata_tx_in(gt_txdata),
      .gtwiz_userdata_rx_out(gt_rxdata),
      .gtrefclk00_in(refclk),
      .qpll0lock_out(qpll_lock),
      .qpll0outclk_out(qpll_clk),
      .qpll0outrefclk_out(qpll_refclk),
      .gthrxn_in(rx_n),
      .gthrxp_in(rx_p),
      .rxgearboxslip_in(rx_slip),
      .txheader_in(gt_txheader),
      .txsequence_in(7'd0),
      .gthtxn_out(tx_n),
      .gthtxp_out(tx_p),
      .gtpowergood_out(),
      .rxdatavalid_out(gt_rxdatavalid),
      .rxheader_out(gt_rxheader),
      .rxheadervalid_out(gt_rxheadervalid),
      .rxpmaresetdone_out(),
      .rxprgdivresetdone_out(),
      .rxstartofseq_out(),
      .txpmaresetdone_out(),
      .txprgdivresetdone_out()
    );

  end else begin : g_gth

    gth_10g_ch u_gth (
      .gtwiz_userclk_tx_reset_in(1'b0),
      .gtwiz_userclk_tx_srcclk_out(),
      .gtwiz_userclk_tx_usrclk_out(),
      .gtwiz_userclk_tx_usrclk2_out(tx_clk),
      .gtwiz_userclk_tx_active_out(),
      .gtwiz_userclk_rx_reset_in(1'b0),
      .gtwiz_userclk_rx_srcclk_out(),
      .gtwiz_userclk_rx_usrclk_out(),
      .gtwiz_userclk_rx_usrclk2_out(rx_clk),
      .gtwiz_userclk_rx_active_out(),
      .gtwiz_reset_clk_freerun_in(clk_free),
      .gtwiz_reset_all_in(rst_free),
      .gtwiz_reset_tx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_tx_datapath_in(1'b0),
      .gtwiz_reset_rx_pll_and_datapath_in(1'b0),
      .gtwiz_reset_rx_datapath_in(1'b0),
      .gtwiz_reset_rx_cdr_stable_out(),
      .gtwiz_reset_tx_done_out(tx_done),
      .gtwiz_reset_rx_done_out(rx_done),
      .gtwiz_userdata_tx_in(gt_txdata),
      .gtwiz_userdata_rx_out(gt_rxdata),
      .gtwiz_reset_qpll0lock_in(qpll_lock_in),
      .gtwiz_reset_qpll0reset_out(),
      .loopback_in(loopback ? 3'b010 : 3'b000),
      .qpll0clk_in(qpll_clk_in),
      .qpll0refclk_in(qpll_refclk_in),
      .qpll1clk_in(1'b0),
      .qpll1refclk_in(1'b0),
      .gthrxn_in(rx_n),
      .gthrxp_in(rx_p),
      .rxgearboxslip_in(rx_slip),
      .txheader_in(gt_txheader),
      .txsequence_in(7'd0),
      .gthtxn_out(tx_n),
      .gthtxp_out(tx_p),
      .gtpowergood_out(),
      .rxdatavalid_out(gt_rxdatavalid),
      .rxheader_out(gt_rxheader),
      .rxheadervalid_out(gt_rxheadervalid),
      .rxpmaresetdone_out(),
      .rxprgdivresetdone_out(),
      .rxstartofseq_out(),
      .txpmaresetdone_out(),
      .txprgdivresetdone_out()
    );

    assign qpll_lock = 1'b0;
    assign qpll_clk = 1'b0;
    assign qpll_refclk = 1'b0;

  end

endmodule
