module tcp_rx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] s_src_ip, // from ipv4_rx
  input logic [15:0] s_len,
  input logic [63:0] s_tdata, // TCP packets
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic seg_valid, // one clock, a segment with a good checksum has ended
  output logic [31:0] seg_src_ip,
  output logic [15:0] seg_src_port,
  output logic [15:0] seg_dst_port,
  output logic [31:0] seg_seq,
  output logic [31:0] seg_ack,
  output logic [7:0] seg_flags, // CWR ECE URG ACK PSH RST SYN FIN
  output logic [15:0] seg_window,
  output logic [15:0] seg_len, // bytes of data

  output logic [63:0] m_tdata, // the data, to the receive buffer
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser // with tlast -> drop the segment

);

  // to do: hdr_strip of 20 bytes, skip the options, checksum over the pseudo header and the segment

  assign seg_valid = 1'b0;
  assign seg_src_ip = '0;
  assign seg_src_port = '0;
  assign seg_dst_port = '0;
  assign seg_seq = '0;
  assign seg_ack = '0;
  assign seg_flags = '0;
  assign seg_window = '0;
  assign seg_len = '0;
  assign m_tdata = '0;
  assign m_tkeep = '0;
  assign m_tvalid = 1'b0;
  assign m_tlast = 1'b0;
  assign m_tuser = 1'b0;

endmodule
