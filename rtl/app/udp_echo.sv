module udp_echo (

  input logic clk,
  input logic rst_n,

  input logic [31:0] rx_src_ip, // from the stack's udp_rx_*
  input logic [15:0] rx_src_port,
  input logic [15:0] rx_dst_port,
  input logic [15:0] rx_len,
  input logic [63:0] rx_tdata,
  input logic [7:0] rx_tkeep,
  input logic rx_tvalid,
  input logic rx_tlast,
  input logic rx_tuser,

  output logic [31:0] tx_dst_ip, // to the stack's udp_tx_*, the same data back to where it came from
  output logic [15:0] tx_src_port,
  output logic [15:0] tx_dst_port,
  output logic [15:0] tx_len,
  output logic [63:0] tx_tdata,
  output logic [7:0] tx_tkeep,
  output logic tx_tvalid,
  input logic tx_tready,
  output logic tx_tlast,
  output logic tx_tuser

);

  assign tx_tuser = 1'b0;

  frame_fifo #(.DEPTH(512), .META(80)) u_fifo ( // a datagram is only known to be good at its end
    .clk(clk),
    .rst_n(rst_n),
    .s_meta({rx_src_ip, rx_src_port, rx_dst_port, rx_len}),
    .s_tdata(rx_tdata),
    .s_tkeep(rx_tkeep),
    .s_tvalid(rx_tvalid),
    .s_tlast(rx_tlast),
    .s_tuser(rx_tuser),
    .m_meta({tx_dst_ip, tx_dst_port, tx_src_port, tx_len}),
    .m_tdata(tx_tdata),
    .m_tkeep(tx_tkeep),
    .m_tvalid(tx_tvalid),
    .m_tready(tx_tready),
    .m_tlast(tx_tlast)
  );

endmodule
