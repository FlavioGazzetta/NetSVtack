module tcp_tx (

  input logic clk,
  input logic rst_n,

  input logic [15:0] cfg_port,

  input logic tx_valid, // a segment to send, from tcp_ctrl
  output logic tx_ready,
  input logic [31:0] tx_dst_ip,
  input logic [15:0] tx_dst_port,
  input logic [31:0] tx_seq,
  input logic [31:0] tx_ack,
  input logic [7:0] tx_flags,
  input logic [15:0] tx_window,
  input logic [15:0] tx_len,

  input logic [63:0] s_tdata, // tx_len bytes from the send buffer
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  output logic s_tready,
  input logic s_tlast,

  output logic [31:0] m_dst_ip, // to ipv4_tx
  output logic [15:0] m_len,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  // to do: hdr_insert of 20 bytes, the checksum has to be known before the first word goes out

  assign tx_ready = 1'b0;
  assign s_tready = 1'b0;
  assign m_dst_ip = '0;
  assign m_len = '0;
  assign m_tdata = '0;
  assign m_tkeep = '0;
  assign m_tvalid = 1'b0;
  assign m_tlast = 1'b0;
  assign m_tuser = 1'b0;

endmodule
