module netsvtack (

  input logic clk, // 156.25 MHz
  input logic rst_n,

  input logic [47:0] cfg_mac,
  input logic [31:0] cfg_ip,
  input logic [31:0] cfg_gateway,
  input logic [31:0] cfg_netmask,
  input logic [15:0] cfg_tcp_port,

  input logic [63:0] xgmii_rxd,
  input logic [7:0] xgmii_rxc,
  output logic [63:0] xgmii_txd,
  output logic [7:0] xgmii_txc,

  output logic [31:0] udp_rx_src_ip, // held through the datagram
  output logic [15:0] udp_rx_src_port,
  output logic [15:0] udp_rx_dst_port,
  output logic [15:0] udp_rx_len,
  output logic [63:0] udp_rx_tdata,
  output logic [7:0] udp_rx_tkeep,
  output logic udp_rx_tvalid, // no tready
  output logic udp_rx_tlast,
  output logic udp_rx_tuser, // with tlast -> drop the datagram

  input logic [31:0] udp_tx_dst_ip, // held until the first word is taken
  input logic [15:0] udp_tx_src_port,
  input logic [15:0] udp_tx_dst_port,
  input logic [15:0] udp_tx_len,
  input logic [63:0] udp_tx_tdata,
  input logic [7:0] udp_tx_tkeep,
  input logic udp_tx_tvalid, // has to stay high from the first word to tlast
  output logic udp_tx_tready,
  input logic udp_tx_tlast,
  input logic udp_tx_tuser,

  output logic tcp_connected,

  output logic stat_rx_good,
  output logic stat_rx_bad

);

  localparam logic [15:0] ETHERTYPE_IPV4 = 16'h0800;
  localparam logic [15:0] ETHERTYPE_ARP = 16'h0806;
  localparam logic [7:0] PROTOCOL_TCP = 8'd6;
  localparam logic [7:0] PROTOCOL_UDP = 8'd17;

  logic [63:0] mrx_tdata; // mac_rx -> eth_rx
  logic [7:0] mrx_tkeep;
  logic mrx_tvalid;
  logic mrx_tlast;
  logic mrx_tuser;

  logic erx_arp; // eth_rx -> arp, ipv4_rx
  logic erx_ipv4;
  logic [63:0] erx_tdata;
  logic [7:0] erx_tkeep;
  logic erx_tvalid;
  logic erx_tlast;
  logic erx_tuser;

  logic [31:0] irx_src_ip; // ipv4_rx -> udp_rx, tcp_rx
  logic [15:0] irx_len;
  logic irx_udp;
  logic irx_tcp;
  logic [63:0] irx_tdata;
  logic [7:0] irx_tkeep;
  logic irx_tvalid;
  logic irx_tlast;
  logic irx_tuser;

  logic learn_valid; // arp -> arp_cache
  logic [31:0] learn_ip;
  logic [47:0] learn_mac;
  logic [31:0] lk_ip; // ipv4_tx -> arp_cache
  logic lk_hit;
  logic [47:0] lk_mac;
  logic arp_req_valid; // ipv4_tx -> arp
  logic [31:0] arp_req_ip;

  logic [47:0] atx_dst_mac; // arp -> eth mux
  logic [63:0] atx_tdata;
  logic [7:0] atx_tkeep;
  logic atx_tvalid;
  logic atx_tready;
  logic atx_tlast;
  logic atx_tuser;

  logic [31:0] utx_dst_ip; // udp_tx -> ip mux
  logic [15:0] utx_len;
  logic [63:0] utx_tdata;
  logic [7:0] utx_tkeep;
  logic utx_tvalid;
  logic utx_tready;
  logic utx_tlast;
  logic utx_tuser;

  logic [31:0] ttx_dst_ip; // tcp_tx -> ip mux
  logic [15:0] ttx_len;
  logic [63:0] ttx_tdata;
  logic [7:0] ttx_tkeep;
  logic ttx_tvalid;
  logic ttx_tready;
  logic ttx_tlast;
  logic ttx_tuser;

  logic [31:0] pmux_dst_ip; // ip mux -> ipv4_tx
  logic [7:0] pmux_protocol;
  logic [15:0] pmux_len;
  logic [63:0] pmux_tdata;
  logic [7:0] pmux_tkeep;
  logic pmux_tvalid;
  logic pmux_tready;
  logic pmux_tlast;
  logic pmux_tuser;

  logic [47:0] itx_dst_mac; // ipv4_tx -> eth mux
  logic [63:0] itx_tdata;
  logic [7:0] itx_tkeep;
  logic itx_tvalid;
  logic itx_tready;
  logic itx_tlast;
  logic itx_tuser;

  logic [47:0] emux_dst_mac; // eth mux -> eth_tx
  logic [15:0] emux_ethertype;
  logic [63:0] emux_tdata;
  logic [7:0] emux_tkeep;
  logic emux_tvalid;
  logic emux_tready;
  logic emux_tlast;
  logic emux_tuser;

  logic [63:0] mtx_tdata; // eth_tx -> mac_tx
  logic [7:0] mtx_tkeep;
  logic mtx_tvalid;
  logic mtx_tready;
  logic mtx_tlast;
  logic mtx_tuser;

  logic seg_valid; // tcp_rx -> tcp_ctrl
  logic [31:0] seg_src_ip;
  logic [15:0] seg_src_port;
  logic [15:0] seg_dst_port;
  logic [31:0] seg_seq;
  logic [31:0] seg_ack;
  logic [7:0] seg_flags;
  logic [15:0] seg_window;
  logic [15:0] seg_len;

  logic tseg_valid; // tcp_ctrl -> tcp_tx
  logic tseg_ready;
  logic [31:0] tseg_dst_ip;
  logic [15:0] tseg_dst_port;
  logic [31:0] tseg_seq;
  logic [31:0] tseg_ack;
  logic [7:0] tseg_flags;
  logic [15:0] tseg_window;
  logic [15:0] tseg_len;

  mac_rx u_mac_rx (
    .clk(clk),
    .rst_n(rst_n),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .m_tdata(mrx_tdata),
    .m_tkeep(mrx_tkeep),
    .m_tvalid(mrx_tvalid),
    .m_tlast(mrx_tlast),
    .m_tuser(mrx_tuser),
    .stat_good(stat_rx_good),
    .stat_bad(stat_rx_bad)
  );

  eth_rx u_eth_rx (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_mac(cfg_mac),
    .s_tdata(mrx_tdata),
    .s_tkeep(mrx_tkeep),
    .s_tvalid(mrx_tvalid),
    .s_tlast(mrx_tlast),
    .s_tuser(mrx_tuser),
    .m_src_mac(),
    .m_arp(erx_arp),
    .m_ipv4(erx_ipv4),
    .m_tdata(erx_tdata),
    .m_tkeep(erx_tkeep),
    .m_tvalid(erx_tvalid),
    .m_tlast(erx_tlast),
    .m_tuser(erx_tuser)
  );

  arp u_arp (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_mac(cfg_mac),
    .cfg_ip(cfg_ip),
    .s_tdata(erx_tdata),
    .s_tkeep(erx_tkeep),
    .s_tvalid(erx_tvalid && erx_arp),
    .s_tlast(erx_tlast),
    .s_tuser(erx_tuser),
    .req_valid(arp_req_valid),
    .req_ip(arp_req_ip),
    .learn_valid(learn_valid),
    .learn_ip(learn_ip),
    .learn_mac(learn_mac),
    .m_dst_mac(atx_dst_mac),
    .m_tdata(atx_tdata),
    .m_tkeep(atx_tkeep),
    .m_tvalid(atx_tvalid),
    .m_tready(atx_tready),
    .m_tlast(atx_tlast),
    .m_tuser(atx_tuser)
  );

  arp_cache u_arp_cache (
    .clk(clk),
    .rst_n(rst_n),
    .wr_valid(learn_valid),
    .wr_ip(learn_ip),
    .wr_mac(learn_mac),
    .lk_ip(lk_ip),
    .lk_hit(lk_hit),
    .lk_mac(lk_mac)
  );

  ipv4_rx u_ipv4_rx (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_ip(cfg_ip),
    .s_tdata(erx_tdata),
    .s_tkeep(erx_tkeep),
    .s_tvalid(erx_tvalid && erx_ipv4),
    .s_tlast(erx_tlast),
    .s_tuser(erx_tuser),
    .m_src_ip(irx_src_ip),
    .m_len(irx_len),
    .m_udp(irx_udp),
    .m_tcp(irx_tcp),
    .m_tdata(irx_tdata),
    .m_tkeep(irx_tkeep),
    .m_tvalid(irx_tvalid),
    .m_tlast(irx_tlast),
    .m_tuser(irx_tuser)
  );

  udp_rx u_udp_rx (
    .clk(clk),
    .rst_n(rst_n),
    .s_src_ip(irx_src_ip),
    .s_len(irx_len),
    .s_tdata(irx_tdata),
    .s_tkeep(irx_tkeep),
    .s_tvalid(irx_tvalid && irx_udp),
    .s_tlast(irx_tlast),
    .s_tuser(irx_tuser),
    .m_src_ip(udp_rx_src_ip),
    .m_src_port(udp_rx_src_port),
    .m_dst_port(udp_rx_dst_port),
    .m_len(udp_rx_len),
    .m_tdata(udp_rx_tdata),
    .m_tkeep(udp_rx_tkeep),
    .m_tvalid(udp_rx_tvalid),
    .m_tlast(udp_rx_tlast),
    .m_tuser(udp_rx_tuser)
  );

  tcp_rx u_tcp_rx ( // the data stream waits for the receive buffer
    .clk(clk),
    .rst_n(rst_n),
    .s_src_ip(irx_src_ip),
    .s_len(irx_len),
    .s_tdata(irx_tdata),
    .s_tkeep(irx_tkeep),
    .s_tvalid(irx_tvalid && irx_tcp),
    .s_tlast(irx_tlast),
    .s_tuser(irx_tuser),
    .seg_valid(seg_valid),
    .seg_src_ip(seg_src_ip),
    .seg_src_port(seg_src_port),
    .seg_dst_port(seg_dst_port),
    .seg_seq(seg_seq),
    .seg_ack(seg_ack),
    .seg_flags(seg_flags),
    .seg_window(seg_window),
    .seg_len(seg_len),
    .m_tdata(),
    .m_tkeep(),
    .m_tvalid(),
    .m_tlast(),
    .m_tuser()
  );

  tcp_ctrl u_tcp_ctrl (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_port(cfg_tcp_port),
    .seg_valid(seg_valid),
    .seg_src_ip(seg_src_ip),
    .seg_src_port(seg_src_port),
    .seg_dst_port(seg_dst_port),
    .seg_seq(seg_seq),
    .seg_ack(seg_ack),
    .seg_flags(seg_flags),
    .seg_window(seg_window),
    .seg_len(seg_len),
    .rx_accept(),
    .rx_space(16'h0),
    .tx_valid(tseg_valid),
    .tx_ready(tseg_ready),
    .tx_dst_ip(tseg_dst_ip),
    .tx_dst_port(tseg_dst_port),
    .tx_seq(tseg_seq),
    .tx_ack(tseg_ack),
    .tx_flags(tseg_flags),
    .tx_window(tseg_window),
    .tx_len(tseg_len),
    .tx_avail(16'h0),
    .tx_acked(),
    .connected(tcp_connected)
  );

  tcp_tx u_tcp_tx ( // the data stream waits for the send buffer
    .clk(clk),
    .rst_n(rst_n),
    .cfg_port(cfg_tcp_port),
    .tx_valid(tseg_valid),
    .tx_ready(tseg_ready),
    .tx_dst_ip(tseg_dst_ip),
    .tx_dst_port(tseg_dst_port),
    .tx_seq(tseg_seq),
    .tx_ack(tseg_ack),
    .tx_flags(tseg_flags),
    .tx_window(tseg_window),
    .tx_len(tseg_len),
    .s_tdata(64'h0),
    .s_tkeep(8'h00),
    .s_tvalid(1'b0),
    .s_tready(),
    .s_tlast(1'b0),
    .m_dst_ip(ttx_dst_ip),
    .m_len(ttx_len),
    .m_tdata(ttx_tdata),
    .m_tkeep(ttx_tkeep),
    .m_tvalid(ttx_tvalid),
    .m_tready(ttx_tready),
    .m_tlast(ttx_tlast),
    .m_tuser(ttx_tuser)
  );

  udp_tx u_udp_tx (
    .clk(clk),
    .rst_n(rst_n),
    .s_dst_ip(udp_tx_dst_ip),
    .s_src_port(udp_tx_src_port),
    .s_dst_port(udp_tx_dst_port),
    .s_len(udp_tx_len),
    .s_tdata(udp_tx_tdata),
    .s_tkeep(udp_tx_tkeep),
    .s_tvalid(udp_tx_tvalid),
    .s_tready(udp_tx_tready),
    .s_tlast(udp_tx_tlast),
    .s_tuser(udp_tx_tuser),
    .m_dst_ip(utx_dst_ip),
    .m_len(utx_len),
    .m_tdata(utx_tdata),
    .m_tkeep(utx_tkeep),
    .m_tvalid(utx_tvalid),
    .m_tready(utx_tready),
    .m_tlast(utx_tlast),
    .m_tuser(utx_tuser)
  );

  frame_mux #(.META(56)) u_ip_mux ( // TCP before UDP
    .clk(clk),
    .rst_n(rst_n),
    .s0_meta({ttx_dst_ip, PROTOCOL_TCP, ttx_len}),
    .s0_tdata(ttx_tdata),
    .s0_tkeep(ttx_tkeep),
    .s0_tvalid(ttx_tvalid),
    .s0_tready(ttx_tready),
    .s0_tlast(ttx_tlast),
    .s0_tuser(ttx_tuser),
    .s1_meta({utx_dst_ip, PROTOCOL_UDP, utx_len}),
    .s1_tdata(utx_tdata),
    .s1_tkeep(utx_tkeep),
    .s1_tvalid(utx_tvalid),
    .s1_tready(utx_tready),
    .s1_tlast(utx_tlast),
    .s1_tuser(utx_tuser),
    .m_meta({pmux_dst_ip, pmux_protocol, pmux_len}),
    .m_tdata(pmux_tdata),
    .m_tkeep(pmux_tkeep),
    .m_tvalid(pmux_tvalid),
    .m_tready(pmux_tready),
    .m_tlast(pmux_tlast),
    .m_tuser(pmux_tuser)
  );

  ipv4_tx u_ipv4_tx (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_ip(cfg_ip),
    .cfg_gateway(cfg_gateway),
    .cfg_netmask(cfg_netmask),
    .s_dst_ip(pmux_dst_ip),
    .s_protocol(pmux_protocol),
    .s_len(pmux_len),
    .s_tdata(pmux_tdata),
    .s_tkeep(pmux_tkeep),
    .s_tvalid(pmux_tvalid),
    .s_tready(pmux_tready),
    .s_tlast(pmux_tlast),
    .s_tuser(pmux_tuser),
    .lk_ip(lk_ip),
    .lk_hit(lk_hit),
    .lk_mac(lk_mac),
    .arp_req_valid(arp_req_valid),
    .arp_req_ip(arp_req_ip),
    .m_dst_mac(itx_dst_mac),
    .m_tdata(itx_tdata),
    .m_tkeep(itx_tkeep),
    .m_tvalid(itx_tvalid),
    .m_tready(itx_tready),
    .m_tlast(itx_tlast),
    .m_tuser(itx_tuser)
  );

  frame_mux #(.META(64)) u_eth_mux ( // ARP before IPv4
    .clk(clk),
    .rst_n(rst_n),
    .s0_meta({atx_dst_mac, ETHERTYPE_ARP}),
    .s0_tdata(atx_tdata),
    .s0_tkeep(atx_tkeep),
    .s0_tvalid(atx_tvalid),
    .s0_tready(atx_tready),
    .s0_tlast(atx_tlast),
    .s0_tuser(atx_tuser),
    .s1_meta({itx_dst_mac, ETHERTYPE_IPV4}),
    .s1_tdata(itx_tdata),
    .s1_tkeep(itx_tkeep),
    .s1_tvalid(itx_tvalid),
    .s1_tready(itx_tready),
    .s1_tlast(itx_tlast),
    .s1_tuser(itx_tuser),
    .m_meta({emux_dst_mac, emux_ethertype}),
    .m_tdata(emux_tdata),
    .m_tkeep(emux_tkeep),
    .m_tvalid(emux_tvalid),
    .m_tready(emux_tready),
    .m_tlast(emux_tlast),
    .m_tuser(emux_tuser)
  );

  eth_tx u_eth_tx (
    .clk(clk),
    .rst_n(rst_n),
    .cfg_mac(cfg_mac),
    .s_dst_mac(emux_dst_mac),
    .s_ethertype(emux_ethertype),
    .s_tdata(emux_tdata),
    .s_tkeep(emux_tkeep),
    .s_tvalid(emux_tvalid),
    .s_tready(emux_tready),
    .s_tlast(emux_tlast),
    .s_tuser(emux_tuser),
    .m_tdata(mtx_tdata),
    .m_tkeep(mtx_tkeep),
    .m_tvalid(mtx_tvalid),
    .m_tready(mtx_tready),
    .m_tlast(mtx_tlast),
    .m_tuser(mtx_tuser)
  );

  mac_tx u_mac_tx (
    .clk(clk),
    .rst_n(rst_n),
    .s_tdata(mtx_tdata),
    .s_tkeep(mtx_tkeep),
    .s_tvalid(mtx_tvalid),
    .s_tready(mtx_tready),
    .s_tlast(mtx_tlast),
    .s_tuser(mtx_tuser),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc)
  );

endmodule
