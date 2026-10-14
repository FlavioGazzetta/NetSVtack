module tcp_rx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] cfg_ip,

  input logic [31:0] s_src_ip, // from ipv4_rx
  input logic [15:0] s_len,
  input logic [63:0] s_tdata, // TCP packets
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic seg_valid, // one clock, a segment with a good checksum has ended
  output logic [31:0] seg_src_ip, // held from the first word of data to seg_valid
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

  localparam logic [7:0] PROTOCOL_TCP = 8'd6;

  logic [19:0][7:0] hdr;
  logic hdr_valid;
  logic [15:0] src_port;
  logic [15:0] dst_port;
  logic [31:0] seq;
  logic [31:0] ack;
  logic [3:0] doff; // header length in 32 bit words
  logic [3:0] rsvd;
  logic [7:0] flags;
  logic [15:0] window;
  logic [15:0] csum;
  logic [15:0] urgent;
  logic [15:0] hdr_len;

  logic first; // this word starts a packet
  logic [7:0][7:0] s_bytes;
  logic [31:0] pseudo; // the addresses, the protocol and the length
  logic [31:0] word_sum; // this word as four 16 bit numbers
  logic [31:0] acc_q;
  logic [16:0] acc_fold;
  logic [15:0] acc_end; // all ones when the checksum is right
  logic ended; // the last word went in on the clock before
  logic ok_q;
  logic ok;

  logic accept; // the lengths make sense
  logic options; // the header has options, any data after them is not taken
  logic p_tvalid;
  logic p_tlast;
  logic p_tuser;
  logic good;

  assign {src_port, dst_port, seq, ack, doff, rsvd, flags, window, csum, urgent} = hdr;
  assign hdr_len = {10'd0, doff, 2'b00};
  assign s_bytes = s_tdata;
  assign pseudo = 32'(s_src_ip[31:16]) + 32'(s_src_ip[15:0]) + 32'(cfg_ip[31:16]) + 32'(cfg_ip[15:0])
                  + 32'(PROTOCOL_TCP) + 32'(s_len);
  assign word_sum = 32'({s_bytes[0], s_bytes[1]}) + 32'({s_bytes[2], s_bytes[3]})
                    + 32'({s_bytes[4], s_bytes[5]}) + 32'({s_bytes[6], s_bytes[7]});
  assign acc_fold = 17'(acc_q[15:0]) + 17'(acc_q[31:16]);
  assign acc_end = acc_fold[15:0] + 16'(acc_fold[16]);
  assign ok = ended ? acc_end == '1 : ok_q;
  assign good = p_tvalid && p_tlast && accept && !p_tuser && ok;
  assign m_tvalid = p_tvalid && accept && !options;
  assign m_tlast = p_tlast;
  assign m_tuser = p_tuser || !ok;

  hdr_strip #(.BYTES(20)) u_strip (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
    .hdr(hdr),
    .hdr_valid(hdr_valid),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(p_tvalid),
    .m_tlast(p_tlast),
    .m_tuser(p_tuser)
  );

  always_ff @(posedge clk) begin // bytes past tkeep are 0, so an odd length needs nothing more
    if (!rst_n) begin
      first <= 1'b1;
      acc_q <= '0;
      ended <= 1'b0;
      ok_q <= 1'b0;
    end else begin
      ended <= s_tvalid && s_tlast;
      if (s_tvalid) begin
        first <= s_tlast;
        acc_q <= (first ? pseudo : acc_q) + word_sum;
      end
      if (ended) begin
        ok_q <= acc_end == '1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      accept <= 1'b0;
      options <= 1'b0;
      seg_src_ip <= '0;
      seg_src_port <= '0;
      seg_dst_port <= '0;
      seg_seq <= '0;
      seg_ack <= '0;
      seg_flags <= '0;
      seg_window <= '0;
      seg_len <= '0;
    end else begin
      if (hdr_valid) begin
        accept <= doff >= 4'd5 && hdr_len <= s_len;
        options <= doff != 4'd5;
        seg_src_ip <= s_src_ip;
        seg_src_port <= src_port;
        seg_dst_port <= dst_port;
        seg_seq <= seq;
        seg_ack <= ack;
        seg_flags <= flags;
        seg_window <= window;
        seg_len <= s_len - hdr_len;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      seg_valid <= 1'b0;
    end else begin
      seg_valid <= good && (!options || seg_len == '0);
    end
  end

endmodule
