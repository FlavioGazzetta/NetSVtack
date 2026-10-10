module tcp_ctrl (

  input logic clk,
  input logic rst_n,

  input logic [15:0] cfg_port, // the port it listens on

  input logic seg_valid, // from tcp_rx
  input logic [31:0] seg_src_ip,
  input logic [15:0] seg_src_port,
  input logic [15:0] seg_dst_port,
  input logic [31:0] seg_seq,
  input logic [31:0] seg_ack,
  input logic [7:0] seg_flags,
  input logic [15:0] seg_window,
  input logic [15:0] seg_len,

  output logic rx_accept, // the segment is the next one in order, its data is kept
  input logic [15:0] rx_space, // room left in the receive buffer

  output logic tx_valid, // a segment to send, to tcp_tx
  input logic tx_ready,
  output logic [31:0] tx_dst_ip,
  output logic [15:0] tx_dst_port,
  output logic [31:0] tx_seq,
  output logic [31:0] tx_ack,
  output logic [7:0] tx_flags,
  output logic [15:0] tx_window,
  output logic [15:0] tx_len, // bytes of data to take from the send buffer
  input logic [15:0] tx_avail, // bytes waiting in the send buffer
  output logic [31:0] tx_acked, // everything before this can leave the send buffer

  output logic connected

);

  typedef enum logic [2:0] {CLOSED, LISTEN, SYN_RCVD, ESTABLISHED, CLOSE_WAIT, LAST_ACK} state_t;

  state_t state;
  state_t next_state;

  // to do: one connection, passive open. snd_una, snd_nxt, rcv_nxt, the
  // retransmit timer and the choice of what to send next all live here

  assign rx_accept = 1'b0;
  assign tx_valid = 1'b0;
  assign tx_dst_ip = '0;
  assign tx_dst_port = '0;
  assign tx_seq = '0;
  assign tx_ack = '0;
  assign tx_flags = '0;
  assign tx_window = '0;
  assign tx_len = '0;
  assign tx_acked = '0;
  assign connected = state == ESTABLISHED;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= CLOSED;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      CLOSED: next_state = LISTEN;
      LISTEN: next_state = LISTEN;
      default: next_state = CLOSED;
    endcase
  end

endmodule
