module ipv4_tx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] cfg_ip,
  input logic [31:0] cfg_gateway,
  input logic [31:0] cfg_netmask,

  input logic [31:0] s_dst_ip, // with the first word
  input logic [7:0] s_protocol,
  input logic [15:0] s_len, // bytes of payload
  input logic [63:0] s_tdata,
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser,

  output logic [31:0] lk_ip, // to the ARP cache
  input logic lk_hit,
  input logic [47:0] lk_mac,

  output logic arp_req_valid, // no MAC for this packet, it is dropped
  output logic [31:0] arp_req_ip,

  output logic [47:0] m_dst_mac, // to eth_tx, held through the packet
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  localparam logic [7:0] TTL = 8'd64;

  typedef enum logic [1:0] {IDLE, SEND, DROP} state_t;

  state_t state;
  state_t next_state;

  logic local_net; // the destination is on this subnet
  logic [15:0] total_len;
  logic [15:0] id_q; // goes up by one a packet
  logic [19:0] sum;
  logic [16:0] sum_fold;
  logic [15:0] csum;
  logic [19:0][7:0] hdr;
  logic [19:0][7:0] hdr_q;
  logic i_tready;

  assign local_net = ((s_dst_ip ^ cfg_ip) & cfg_netmask) == '0;
  assign lk_ip = local_net ? s_dst_ip : cfg_gateway;
  assign total_len = s_len + 16'd20;
  assign sum = 20'h04500 + 20'(total_len) + 20'(id_q) + 20'h04000 + 20'({TTL, s_protocol})
               + 20'(cfg_ip[31:16]) + 20'(cfg_ip[15:0]) + 20'(s_dst_ip[31:16]) + 20'(s_dst_ip[15:0]);
  assign sum_fold = 17'(sum[15:0]) + 17'(sum[19:16]);
  assign csum = ~(sum_fold[15:0] + 16'(sum_fold[16]));
  assign hdr = {16'h4500, total_len, id_q, 16'h4000, TTL, s_protocol, csum, cfg_ip, s_dst_ip}; // do not fragment
  assign s_tready = (state == SEND && i_tready) || state == DROP;

  hdr_insert #(.BYTES(20)) u_insert (
    .clk(clk),
    .rst_n(rst_n),
    .hdr(hdr_q),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid && state == SEND),
    .s_tready(i_tready),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
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
      IDLE: next_state = !s_tvalid ? IDLE : (lk_hit ? SEND : DROP);
      SEND: next_state = (s_tvalid && s_tready && s_tlast) ? IDLE : SEND;
      DROP: next_state = (s_tvalid && s_tlast) ? IDLE : DROP;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      id_q <= '0;
      hdr_q <= '0;
      m_dst_mac <= '0;
      arp_req_valid <= 1'b0;
      arp_req_ip <= '0;
    end else begin
      arp_req_valid <= 1'b0;
      if (state == IDLE && s_tvalid && lk_hit) begin
        id_q <= id_q + 16'd1;
        hdr_q <= hdr;
        m_dst_mac <= lk_mac;
      end else if (state == IDLE && s_tvalid) begin
        arp_req_valid <= 1'b1;
        arp_req_ip <= lk_ip;
      end
    end
  end

endmodule
