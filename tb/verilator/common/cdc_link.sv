module cdc_link (
  input logic clk,
  input logic rst_n,
  input logic s_clk,
  input logic s_rst_n,

  input logic [63:0] s_tdata,
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser
);

  frame_cdc u_cdc (
    .s_clk(s_clk),
    .s_rst_n(s_rst_n),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
    .m_clk(clk),
    .m_rst_n(rst_n),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(m_tvalid),
    .m_tlast(m_tlast),
    .m_tuser(m_tuser)
  );

endmodule
