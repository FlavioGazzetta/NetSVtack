module mac_link (
  input logic clk,
  input logic rst_n,

  input logic [63:0] s_tdata,
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser,

  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser,

  output logic stat_good,
  output logic stat_bad
);

  logic [63:0] xgmii_d;
  logic [7:0] xgmii_c;

  mac_tx u_tx (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tready(s_tready),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
    .xgmii_txd(xgmii_d),
    .xgmii_txc(xgmii_c)
  );

  mac_rx u_rx (
    .clk(clk),
    .rst_n(rst_n),
    .xgmii_rxd(xgmii_d),
    .xgmii_rxc(xgmii_c),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(m_tvalid),
    .m_tlast(m_tlast),
    .m_tuser(m_tuser),
    .stat_good(stat_good),
    .stat_bad(stat_bad)
  );

endmodule
