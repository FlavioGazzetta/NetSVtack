module eth_tx (

  input logic clk,
  input logic rst_n,

  input logic [47:0] cfg_mac,

  input logic [47:0] s_dst_mac, // held until the first word is taken
  input logic [15:0] s_ethertype,
  input logic [63:0] s_tdata, // the payload, mac_tx does the padding
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser,

  output logic [63:0] m_tdata, // to mac_tx
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  logic [13:0][7:0] hdr;

  assign hdr = {s_dst_mac, cfg_mac, s_ethertype};

  hdr_insert #(.BYTES(14)) u_insert (
    .clk(clk),
    .rst_n(rst_n),
    .hdr(hdr),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tready(s_tready),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(m_tvalid),
    .m_tready(m_tready),
    .m_tlast(m_tlast),
    .m_tuser(m_tuser)
  );

endmodule
