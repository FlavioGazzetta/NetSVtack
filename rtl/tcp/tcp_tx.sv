module tcp_tx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] cfg_ip,
  input logic [15:0] cfg_port,

  input logic tx_valid, // a segment to send, from tcp_ctrl
  output logic tx_ready,
  input logic [31:0] tx_dst_ip,
  input logic [15:0] tx_dst_port,
  input logic [31:0] tx_seq,
  input logic [31:0] tx_ack,
  input logic [7:0] tx_flags, // a SYN goes out with the MSS option
  input logic [15:0] tx_window,
  input logic [15:0] tx_len, // bytes of data, they start at tx_seq in the send buffer

  output logic [31:0] rd_seq, // to tcp_tx_buf
  input logic [63:0] rd_data,

  output logic [31:0] m_dst_ip, // to ipv4_tx
  output logic [15:0] m_len,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  localparam logic [7:0] PROTOCOL_TCP = 8'd6;
  localparam logic [15:0] MSS = 16'd1460;
  localparam logic [63:0] MSS_OPTION = {32'h0, MSS[7:0], MSS[15:8], 8'd4, 8'd2}; // kind 2, length 4

  typedef enum logic [1:0] {IDLE, LOAD, CSUM, SEND} state_t;

  state_t state;
  state_t next_state;

  logic [15:0] dst_port;
  logic [31:0] seq;
  logic [31:0] ack;
  logic [7:0] flags;
  logic [15:0] window;
  logic syn;
  logic [3:0] doff;
  logic [15:0] left; // bytes still to read from the send buffer
  logic go; // first clock of LOAD
  logic issue; // a word is asked for
  logic [3:0] issue_n;

  logic ld_valid; // the word asked for on the clock before is here
  logic [3:0] ld_n;
  logic ld_last;
  logic [7:0] ld_keep;
  logic [7:0][7:0] rd_bytes;
  logic [7:0][7:0] ld_bytes; // bytes past the end zeroed
  logic [63:0] ld_data;

  logic [31:0] hdr_sum; // the pseudo header and the header
  logic [31:0] hdr_sum_q;
  logic [31:0] word_sum;
  logic [31:0] acc_q; // the data
  logic [31:0] total;
  logic [16:0] total_fold;
  logic [15:0] csum_q;
  logic [19:0][7:0] hdr;

  logic [63:0] f_tdata; // the segment waits here for its checksum
  logic [7:0] f_tkeep;
  logic f_tvalid;
  logic f_tlast;
  logic i_tready;

  assign tx_ready = state == IDLE;
  assign syn = flags[1];
  assign doff = syn ? 4'd6 : 4'd5;
  assign issue = state == LOAD && (go || left != '0);
  assign issue_n = (left >= 16'd8) ? 4'd8 : left[3:0];
  assign ld_keep = syn ? 8'h0F : 8'hFF >> (4'd8 - ld_n);
  assign rd_bytes = rd_data;
  assign ld_data = syn ? MSS_OPTION : ld_bytes;
  assign hdr_sum = 32'(cfg_ip[31:16]) + 32'(cfg_ip[15:0]) + 32'(m_dst_ip[31:16]) + 32'(m_dst_ip[15:0])
                   + 32'(PROTOCOL_TCP) + 32'(m_len) + 32'(cfg_port) + 32'(dst_port)
                   + 32'(seq[31:16]) + 32'(seq[15:0]) + 32'(ack[31:16]) + 32'(ack[15:0])
                   + 32'({doff, 4'h0, flags}) + 32'(window);
  assign word_sum = 32'({ld_data[7:0], ld_data[15:8]}) + 32'({ld_data[23:16], ld_data[31:24]})
                    + 32'({ld_data[39:32], ld_data[47:40]}) + 32'({ld_data[55:48], ld_data[63:56]});
  assign total = hdr_sum_q + acc_q;
  assign total_fold = 17'(total[15:0]) + 17'(total[31:16]);
  assign hdr = {cfg_port, dst_port, seq, ack, doff, 4'h0, flags, window, csum_q, 16'h0000};

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      ld_bytes[i] = ld_keep[i] ? rd_bytes[i] : 8'h00;
    end
  end

  frame_fifo #(.DEPTH(256), .META(1)) u_fifo (
    .clk(clk),
    .rst_n(rst_n),
    .s_meta(1'b0),
    .s_tdata(ld_data),
    .s_tkeep(ld_keep),
    .s_tvalid(ld_valid),
    .s_tlast(ld_last),
    .s_tuser(1'b0),
    .m_meta(),
    .m_tdata(f_tdata),
    .m_tkeep(f_tkeep),
    .m_tvalid(f_tvalid),
    .m_tready(i_tready && state == SEND),
    .m_tlast(f_tlast)
  );

  hdr_insert #(.BYTES(20)) u_insert (
    .clk(clk),
    .rst_n(rst_n),
    .hdr(hdr),
    .s_tdata(f_tdata),
    .s_tkeep(f_tkeep),
    .s_tvalid(f_tvalid && state == SEND),
    .s_tready(i_tready),
    .s_tlast(f_tlast),
    .s_tuser(1'b0),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(m_tvalid),
    .m_tready(m_tready),
    .m_tlast(m_tlast),
    .m_tuser(m_tuser)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      IDLE: next_state = tx_valid ? LOAD : IDLE;
      LOAD: next_state = (ld_valid && ld_last) ? CSUM : LOAD;
      CSUM: next_state = SEND;
      SEND: next_state = (f_tvalid && i_tready && f_tlast) ? IDLE : SEND;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_dst_ip <= '0;
      m_len <= '0;
      dst_port <= '0;
      seq <= '0;
      ack <= '0;
      flags <= '0;
      window <= '0;
    end else begin
      if (state == IDLE && tx_valid) begin
        m_dst_ip <= tx_dst_ip;
        m_len <= tx_len + (tx_flags[1] ? 16'd24 : 16'd20);
        dst_port <= tx_dst_port;
        seq <= tx_seq;
        ack <= tx_ack;
        flags <= tx_flags;
        window <= tx_window;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      go <= 1'b0;
      left <= '0;
      rd_seq <= '0;
      ld_valid <= 1'b0;
      ld_n <= '0;
      ld_last <= 1'b0;
    end else begin
      go <= state == IDLE && tx_valid;
      ld_valid <= issue;
      ld_n <= issue_n;
      ld_last <= left <= 16'd8;
      if (state == IDLE && tx_valid) begin
        left <= tx_len;
        rd_seq <= tx_seq;
      end else if (issue) begin
        left <= left - 16'(issue_n);
        rd_seq <= rd_seq + 32'd8;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hdr_sum_q <= '0;
      acc_q <= '0;
      csum_q <= '0;
    end else begin
      hdr_sum_q <= hdr_sum;
      if (state == IDLE) begin
        acc_q <= '0;
      end else if (ld_valid) begin
        acc_q <= acc_q + word_sum;
      end
      if (state == CSUM) begin
        csum_q <= ~(total_fold[15:0] + 16'(total_fold[16]));
      end
    end
  end

endmodule
