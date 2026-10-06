module hdr_link #(
  parameter int BYTES = 14
)(
  input logic clk,
  input logic rst_n,

  output logic [7:0] bytes,
  input logic bypass, // the strip is fed from r_* instead of the insert

  input logic [31:0][7:0] hdr_in,
  input logic [63:0] s_tdata,
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser,

  output logic [63:0] w_tdata, // header and payload together
  output logic [7:0] w_tkeep,
  output logic w_tvalid,
  input logic w_tready,
  output logic w_tlast,
  output logic w_tuser,

  input logic [63:0] r_tdata,
  input logic [7:0] r_tkeep,
  input logic r_tvalid,
  input logic r_tlast,
  input logic r_tuser,

  output logic [31:0][7:0] hdr_out,
  output logic hdr_valid,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser
);

  logic [BYTES-1:0][7:0] hdr;

  assign bytes = 8'(BYTES);
  assign hdr_out = 256'(hdr);

  hdr_insert #(.BYTES(BYTES)) u_insert (
    .clk(clk),
    .rst_n(rst_n),
    .hdr(hdr_in[BYTES-1:0]),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tready(s_tready),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
    .m_tdata(w_tdata),
    .m_tkeep(w_tkeep),
    .m_tvalid(w_tvalid),
    .m_tready(w_tready),
    .m_tlast(w_tlast),
    .m_tuser(w_tuser)
  );

  hdr_strip #(.BYTES(BYTES)) u_strip (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(bypass ? r_tdata : w_tdata),
    .s_tkeep(bypass ? r_tkeep : w_tkeep),
    .s_tvalid(bypass ? r_tvalid : (w_tvalid && w_tready)),
    .s_tlast(bypass ? r_tlast : w_tlast),
    .s_tuser(bypass ? r_tuser : w_tuser),
    .hdr(hdr),
    .hdr_valid(hdr_valid),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(m_tvalid),
    .m_tlast(m_tlast),
    .m_tuser(m_tuser)
  );

endmodule
