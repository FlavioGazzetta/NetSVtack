module arp (

  input logic clk,
  input logic rst_n,

  input logic [47:0] cfg_mac,
  input logic [31:0] cfg_ip,

  input logic [63:0] s_tdata, // ARP frames from eth_rx
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  input logic req_valid, // ask who has this address, lost if a packet is already waiting
  input logic [31:0] req_ip,

  output logic learn_valid, // to the cache, one clock
  output logic [31:0] learn_ip,
  output logic [47:0] learn_mac,

  output logic [47:0] m_dst_mac, // to eth_tx
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  localparam logic [15:0] OPER_REQUEST = 16'd1;
  localparam logic [15:0] OPER_REPLY = 16'd2;

  typedef enum logic {IDLE, SEND} state_t;

  state_t state;
  state_t next_state;

  logic [27:0][7:0] rx_hdr;
  logic rx_hdr_valid;
  logic [15:0] htype;
  logic [15:0] ptype;
  logic [7:0] hlen;
  logic [7:0] plen;
  logic [15:0] oper;
  logic [47:0] sha; // sender MAC
  logic [31:0] spa; // sender IP
  logic [47:0] tha;
  logic [31:0] tpa; // the IP being asked for
  logic p_tvalid;
  logic p_tlast;
  logic p_tuser;

  logic rx_ok; // an Ethernet / IPv4 ARP packet for this IP
  logic rx_request;
  logic [47:0] rx_sha;
  logic [31:0] rx_spa;
  logic rx_good; // it ended with a good FCS
  logic reply;

  logic [27:0][7:0] tx_hdr;
  logic [15:0] tx_oper;
  logic [47:0] tx_tha;
  logic [31:0] tx_tpa;
  logic i_tready;

  assign {htype, ptype, hlen, plen, oper, sha, spa, tha, tpa} = rx_hdr;
  assign rx_good = p_tvalid && p_tlast && !p_tuser && rx_ok;
  assign reply = rx_good && rx_request;
  assign tx_hdr = {16'd1, 16'h0800, 8'd6, 8'd4, tx_oper, cfg_mac, cfg_ip, tx_tha, tx_tpa};

  hdr_strip #(.BYTES(28)) u_strip (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser),
    .hdr(rx_hdr),
    .hdr_valid(rx_hdr_valid),
    .m_tdata(),
    .m_tkeep(),
    .m_tvalid(p_tvalid),
    .m_tlast(p_tlast),
    .m_tuser(p_tuser)
  );

  hdr_insert #(.BYTES(28)) u_insert ( // the packet is all header
    .clk(clk),
    .rst_n(rst_n),
    .hdr(tx_hdr),
    .s_tdata(64'h0),
    .s_tkeep(8'h00),
    .s_tvalid(state == SEND),
    .s_tready(i_tready),
    .s_tlast(1'b1),
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
      rx_ok <= 1'b0;
      rx_request <= 1'b0;
      rx_sha <= '0;
      rx_spa <= '0;
    end else begin
      if (rx_hdr_valid) begin
        rx_ok <= htype == 16'd1 && ptype == 16'h0800 && hlen == 8'd6 && plen == 8'd4 && tpa == cfg_ip;
        rx_request <= oper == OPER_REQUEST;
        rx_sha <= sha;
        rx_spa <= spa;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      learn_valid <= 1'b0;
      learn_ip <= '0;
      learn_mac <= '0;
    end else begin
      learn_valid <= rx_good;
      learn_ip <= rx_spa;
      learn_mac <= rx_sha;
    end
  end

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
      IDLE: next_state = (reply || req_valid) ? SEND : IDLE;
      SEND: next_state = i_tready ? IDLE : SEND;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_oper <= '0;
      tx_tha <= '0;
      tx_tpa <= '0;
      m_dst_mac <= '0;
    end else begin
      if (state == IDLE && reply) begin
        tx_oper <= OPER_REPLY;
        tx_tha <= rx_sha;
        tx_tpa <= rx_spa;
        m_dst_mac <= rx_sha;
      end else if (state == IDLE && req_valid) begin
        tx_oper <= OPER_REQUEST;
        tx_tha <= '0;
        tx_tpa <= req_ip;
        m_dst_mac <= '1;
      end
    end
  end

endmodule
