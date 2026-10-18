module tcp_ctrl #(
  parameter int RTO = 31_250_000, // clocks before unanswered data is sent again, 200 ms
  parameter int RETRIES = 8 // times in a row before the connection is given up
)(

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

  output logic rx_commit, // to tcp_rx_buf, with seg_valid: the data is the next in order and is kept
  output logic rx_rollback,
  input logic rx_over, // the data did not fit
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

  output logic tx_init, // to tcp_tx_buf, a new connection
  output logic [31:0] tx_init_seq,
  input logic [31:0] tx_wr_seq, // end of the data the application has written
  output logic [31:0] tx_acked, // everything before this can leave the send buffer

  output logic connected

);

  localparam logic [31:0] MSS = 32'd1460;
  localparam logic [7:0] FLAG_FIN = 8'h01;
  localparam logic [7:0] FLAG_SYN = 8'h02;
  localparam logic [7:0] FLAG_PSH = 8'h08;
  localparam logic [7:0] FLAG_ACK = 8'h10;

  typedef enum logic [2:0] {LISTEN, SYN_RCVD, ESTABLISHED, CLOSE_WAIT, LAST_ACK} state_t;

  state_t state;
  state_t next_state;

  logic [31:0] peer_ip;
  logic [15:0] peer_port;
  logic [31:0] rcv_nxt; // next byte expected
  logic [31:0] snd_una; // oldest byte not acknowledged
  logic [31:0] snd_nxt; // next byte to send
  logic [31:0] snd_max; // end of what has ever been sent
  logic [15:0] snd_wnd; // window the peer gave
  logic [31:0] iss_q; // free running, the first sequence number of a connection
  logic [31:0] timer;
  logic [3:0] retries; // times the timer has run out with nothing acknowledged since
  logic ack_pend; // something arrived that has to be acknowledged
  logic wnd_small; // the last window sent was under a segment

  logic f_fin;
  logic f_syn;
  logic f_rst;
  logic f_ack;
  logic mine; // a segment for the port
  logic from_peer;
  logic syn_in; // a new connection
  logic ack_ok; // acknowledges something that was sent
  logic ack_all;
  logic in_order;
  logic data_ok;
  logic fin_ok; // the peer has closed, right after the data in this segment
  logic [31:0] rcv_step;

  logic rto; // nothing came back in time
  logic give_up; // the peer is gone
  logic decide; // free to pick the next segment
  logic fin_out; // the FIN has gone out
  logic [31:0] avail; // written and not sent
  logic [31:0] in_flight;
  logic [31:0] wnd_left;
  logic [31:0] len;
  logic syn_go;
  logic data_go;
  logic fin_go;
  logic ack_go;
  logic [31:0] snd_nxt_n;

  assign f_fin = seg_flags[0];
  assign f_syn = seg_flags[1];
  assign f_rst = seg_flags[2];
  assign f_ack = seg_flags[4];
  assign mine = seg_valid && seg_dst_port == cfg_port;
  assign from_peer = mine && state != LISTEN && seg_src_ip == peer_ip && seg_src_port == peer_port;
  assign syn_in = mine && (state == LISTEN || state == SYN_RCVD) && f_syn && !f_ack && !f_rst;
  assign ack_ok = f_ack && seg_ack - snd_una <= snd_max - snd_una;
  assign ack_all = ack_ok && seg_ack == snd_max && snd_una != snd_max;
  assign in_order = seg_seq == rcv_nxt;
  assign data_ok = state == ESTABLISHED && in_order && seg_len != '0 && !rx_over;
  assign fin_ok = state == ESTABLISHED && f_fin && in_order && (seg_len == '0 || data_ok);
  assign rcv_step = (data_ok ? 32'(seg_len) : 32'd0) + (fin_ok ? 32'd1 : 32'd0);
  assign rx_commit = from_peer && data_ok;
  assign rx_rollback = seg_valid && !rx_commit;

  assign rto = timer == '0 && snd_una != snd_max;
  assign give_up = rto && !seg_valid && retries == 4'(RETRIES);
  assign decide = state != LISTEN && !seg_valid && !rto && !tx_valid;
  assign fin_out = snd_nxt == tx_wr_seq + 32'd1;
  assign avail = tx_wr_seq - snd_nxt;
  assign in_flight = snd_nxt - snd_una;
  assign wnd_left = (in_flight < 32'(snd_wnd)) ? 32'(snd_wnd) - in_flight : 32'd0;
  assign syn_go = decide && state == SYN_RCVD && snd_nxt == snd_una;
  assign data_go = decide && state != SYN_RCVD && !fin_out && avail != '0 && wnd_left != '0;
  assign fin_go = decide && (state == CLOSE_WAIT || state == LAST_ACK) && avail == '0;
  assign ack_go = decide && ack_pend;
  assign tx_acked = snd_una;
  assign tx_init = syn_in;
  assign tx_init_seq = iss_q + 32'd1;
  assign connected = state == ESTABLISHED;

  always_comb begin
    len = (avail < wnd_left) ? avail : wnd_left;
    if (len > MSS) begin
      len = MSS;
    end
  end

  always_comb begin
    snd_nxt_n = snd_nxt;
    if (syn_go || fin_go) begin
      snd_nxt_n = snd_nxt + 32'd1;
    end else if (data_go) begin
      snd_nxt_n = snd_nxt + len;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= LISTEN;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      LISTEN: next_state = syn_in ? SYN_RCVD : LISTEN;
      SYN_RCVD: next_state = give_up ? LISTEN : (!from_peer ? SYN_RCVD : (f_rst ? LISTEN : (ack_all ? ESTABLISHED : SYN_RCVD)));
      ESTABLISHED: next_state = give_up ? LISTEN : (!from_peer ? ESTABLISHED : (f_rst ? LISTEN : (fin_ok ? CLOSE_WAIT : ESTABLISHED)));
      CLOSE_WAIT: next_state = (give_up || (from_peer && f_rst)) ? LISTEN : (fin_go ? LAST_ACK : CLOSE_WAIT);
      LAST_ACK: next_state = (give_up || (from_peer && (f_rst || ack_all))) ? LISTEN : LAST_ACK;
      default: next_state = LISTEN;
    endcase
  end

  always_ff @(posedge clk) begin // a segment has arrived
    if (!rst_n) begin
      iss_q <= '0;
      peer_ip <= '0;
      peer_port <= '0;
      rcv_nxt <= '0;
      snd_una <= '0;
      snd_wnd <= '0;
    end else begin
      iss_q <= iss_q + 32'd1;
      if (syn_in) begin
        peer_ip <= seg_src_ip;
        peer_port <= seg_src_port;
        rcv_nxt <= seg_seq + 32'd1;
        snd_una <= iss_q;
        snd_wnd <= seg_window;
      end else if (from_peer) begin
        rcv_nxt <= rcv_nxt + rcv_step;
        if (ack_ok) begin
          snd_una <= seg_ack;
          snd_wnd <= seg_window;
        end
      end
    end
  end

  always_ff @(posedge clk) begin // go back to the oldest byte when the timer runs out
    if (!rst_n) begin
      snd_nxt <= '0;
      snd_max <= '0;
      timer <= '0;
      retries <= '0;
    end else begin
      if (snd_una == snd_max || (from_peer && ack_ok && seg_ack != snd_una)) begin
        retries <= '0;
      end else if (rto && !seg_valid) begin
        retries <= retries + 4'd1;
      end
      if (syn_in) begin
        snd_nxt <= iss_q;
        snd_max <= iss_q;
      end else if (from_peer && ack_ok && seg_ack - snd_una > in_flight) begin
        snd_nxt <= seg_ack;
      end else if (rto && !seg_valid) begin
        snd_nxt <= snd_una;
      end else if (decide) begin
        snd_nxt <= snd_nxt_n;
        if (snd_nxt_n - snd_una > snd_max - snd_una) begin
          snd_max <= snd_nxt_n;
        end
      end
      if (snd_una == snd_max || (from_peer && ack_ok && seg_ack != snd_una) || (rto && !seg_valid)) begin
        timer <= 32'(RTO);
      end else if (timer != '0) begin
        timer <= timer - 32'd1;
      end
    end
  end

  always_ff @(posedge clk) begin // the next segment to send
    if (!rst_n) begin
      tx_valid <= 1'b0;
      tx_dst_ip <= '0;
      tx_dst_port <= '0;
      tx_seq <= '0;
      tx_ack <= '0;
      tx_flags <= '0;
      tx_window <= '0;
      tx_len <= '0;
      ack_pend <= 1'b0;
      wnd_small <= 1'b0;
    end else begin
      if (tx_valid && tx_ready) begin
        tx_valid <= 1'b0;
      end
      if (syn_go || data_go || fin_go || ack_go) begin
        tx_valid <= 1'b1;
        tx_dst_ip <= peer_ip;
        tx_dst_port <= peer_port;
        tx_seq <= snd_nxt;
        tx_ack <= rcv_nxt;
        tx_window <= rx_space;
        tx_flags <= syn_go ? (FLAG_SYN | FLAG_ACK) : (data_go ? (FLAG_PSH | FLAG_ACK) : (fin_go ? (FLAG_FIN | FLAG_ACK) : FLAG_ACK));
        tx_len <= data_go ? 16'(len) : 16'd0;
        ack_pend <= 1'b0;
        wnd_small <= rx_space < 16'(MSS);
      end else if (from_peer && state != SYN_RCVD && (seg_len != '0 || f_fin)) begin
        ack_pend <= 1'b1;
      end else if (wnd_small && rx_space >= 16'd2920) begin
        ack_pend <= 1'b1; // the application has made room again
        wnd_small <= 1'b0;
      end
      if (state == LISTEN) begin
        ack_pend <= 1'b0;
      end
    end
  end

endmodule
