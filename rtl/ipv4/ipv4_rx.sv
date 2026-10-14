module ipv4_rx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] cfg_ip,

  input logic [63:0] s_tdata, // IPv4 frames from eth_rx
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic [31:0] m_src_ip, // held through the packet
  output logic [15:0] m_len, // bytes of payload
  output logic m_icmp, // protocol of the packet
  output logic m_udp,
  output logic m_tcp,
  output logic [63:0] m_tdata, // the payload without the Ethernet padding
  output logic [7:0] m_tkeep,
  output logic m_tvalid, // only packets for this IP with a good header
  output logic m_tlast,
  output logic m_tuser // also set when the packet is shorter than its length field

);

  localparam logic [7:0] PROTOCOL_ICMP = 8'd1;
  localparam logic [7:0] PROTOCOL_TCP = 8'd6;
  localparam logic [7:0] PROTOCOL_UDP = 8'd17;

  typedef enum logic {PASS, HOLD} state_t;

  state_t state;
  state_t next_state;

  logic [19:0][7:0] hdr;
  logic hdr_valid;
  logic [3:0] version;
  logic [3:0] ihl;
  logic [7:0] tos;
  logic [15:0] total_len;
  logic [15:0] id;
  logic [2:0] flags;
  logic [12:0] frag;
  logic [7:0] ttl;
  logic [7:0] protocol;
  logic [15:0] csum;
  logic [31:0] src_ip;
  logic [31:0] dst_ip;
  logic [9:0][15:0] hdr_words;
  logic [19:0] sum;
  logic [16:0] sum_fold;
  logic [15:0] sum_end; // all ones when the checksum is right
  logic accept;

  logic [63:0] p_tdata;
  logic [7:0][7:0] p_bytes;
  logic [7:0] p_tkeep;
  logic p_tvalid;
  logic p_tlast;
  logic p_tuser;
  logic beat;
  logic [3:0] n; // bytes in this word
  logic [15:0] left; // payload bytes still to come, this word included
  logic fits; // the payload ends in this word, the rest is padding
  logic [7:0] cut_keep;
  logic [7:0][7:0] cut;
  logic [63:0] hold_data; // the last word waits here for the FCS check
  logic [7:0] hold_keep;

  assign {version, ihl, tos, total_len, id, flags, frag, ttl, protocol, csum, src_ip, dst_ip} = hdr;
  assign hdr_words = hdr;
  assign sum_fold = 17'(sum[15:0]) + 17'(sum[19:16]);
  assign sum_end = sum_fold[15:0] + 16'(sum_fold[16]);
  assign p_bytes = p_tdata;
  assign beat = p_tvalid && accept;
  assign n = p_tlast ? 4'($countones(p_tkeep)) : 4'd8;
  assign fits = left <= 16'd8;
  assign cut_keep = 8'hFF >> (4'd8 - left[3:0]);

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
    .m_tdata(p_tdata),
    .m_tkeep(p_tkeep),
    .m_tvalid(p_tvalid),
    .m_tlast(p_tlast),
    .m_tuser(p_tuser)
  );

  always_comb begin
    sum = '0;
    for (int i = 0; i < 10; i++) begin
      sum = sum + 20'(hdr_words[i]);
    end
  end

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      cut[i] = cut_keep[i] ? p_bytes[i] : 8'h00;
    end
  end

  always_ff @(posedge clk) begin // packets with options or in fragments are dropped
    if (!rst_n) begin
      accept <= 1'b0;
      m_src_ip <= '0;
      m_len <= '0;
      m_icmp <= 1'b0;
      m_udp <= 1'b0;
      m_tcp <= 1'b0;
    end else begin
      if (hdr_valid) begin
        accept <= version == 4'd4 && ihl == 4'd5 && sum_end == '1 && !flags[0] && frag == '0
                  && total_len >= 16'd20 && dst_ip == cfg_ip;
        m_src_ip <= src_ip;
        m_len <= total_len - 16'd20;
        m_icmp <= protocol == PROTOCOL_ICMP;
        m_udp <= protocol == PROTOCOL_UDP;
        m_tcp <= protocol == PROTOCOL_TCP;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= PASS;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      PASS: next_state = (beat && fits && !p_tlast) ? HOLD : PASS;
      HOLD: next_state = (beat && p_tlast) ? PASS : HOLD;
      default: next_state = PASS;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      left <= '0;
      hold_data <= '0;
      hold_keep <= '0;
    end else begin
      if (hdr_valid) begin
        left <= total_len - 16'd20;
      end else if (state == PASS && beat && !fits) begin
        left <= left - 16'd8;
      end
      if (state == PASS && beat && fits) begin
        hold_data <= cut;
        hold_keep <= cut_keep;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_tdata <= '0;
      m_tkeep <= '0;
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
    end else begin
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
      if (state == PASS && beat && !fits) begin
        m_tdata <= p_tdata;
        m_tkeep <= p_tkeep;
        m_tvalid <= 1'b1;
        m_tlast <= p_tlast; // ended before its length
        m_tuser <= p_tlast;
      end else if (state == PASS && beat && p_tlast) begin
        m_tdata <= cut;
        m_tkeep <= cut_keep;
        m_tvalid <= 1'b1;
        m_tlast <= 1'b1;
        m_tuser <= p_tuser || n < left[3:0];
      end else if (state == HOLD && beat && p_tlast) begin
        m_tdata <= hold_data;
        m_tkeep <= hold_keep;
        m_tvalid <= 1'b1;
        m_tlast <= 1'b1;
        m_tuser <= p_tuser;
      end
    end
  end

endmodule
