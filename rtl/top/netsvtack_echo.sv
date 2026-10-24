module netsvtack_echo #(
  parameter logic [47:0] MAC = 48'h02_00_00_00_00_01,
  parameter logic [31:0] IP = {8'd192, 8'd168, 8'd1, 8'd128},
  parameter logic [31:0] GATEWAY = {8'd192, 8'd168, 8'd1, 8'd1},
  parameter logic [31:0] NETMASK = {8'd255, 8'd255, 8'd255, 8'd0},
  parameter logic [15:0] TCP_PORT = 16'd5001,
  parameter int TCP_RTO = 31_250_000
)(

  input logic clk, // 156.25 MHz
  input logic rst_n,
  input logic rx_clk,
  input logic rx_rst_n,

  input logic [63:0] xgmii_rxd, // on rx_clk
  input logic [7:0] xgmii_rxc,
  output logic [63:0] xgmii_txd,
  output logic [7:0] xgmii_txc,

  output logic tcp_connected,
  output logic stat_rx_good,
  output logic stat_rx_bad

);

  logic [31:0] urx_src_ip; // stack -> udp_echo
  logic [15:0] urx_src_port;
  logic [15:0] urx_dst_port;
  logic [15:0] urx_len;
  logic [63:0] urx_tdata;
  logic [7:0] urx_tkeep;
  logic urx_tvalid;
  logic urx_tlast;
  logic urx_tuser;

  logic [31:0] utx_dst_ip; // udp_echo -> stack
  logic [15:0] utx_src_port;
  logic [15:0] utx_dst_port;
  logic [15:0] utx_len;
  logic [63:0] utx_tdata;
  logic [7:0] utx_tkeep;
  logic utx_tvalid;
  logic utx_tready;
  logic utx_tlast;
  logic utx_tuser;

  logic [63:0] tcp_tdata; // what the connection receives goes straight back into it
  logic [7:0] tcp_tkeep;
  logic tcp_tvalid;
  logic tcp_tready;

  netsvtack #(.TCP_RTO(TCP_RTO)) u_stack (
    .clk(clk),
    .rst_n(rst_n),
    .rx_clk(rx_clk),
    .rx_rst_n(rx_rst_n),
    .cfg_mac(MAC),
    .cfg_ip(IP),
    .cfg_gateway(GATEWAY),
    .cfg_netmask(NETMASK),
    .cfg_tcp_port(TCP_PORT),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc),
    .udp_rx_src_ip(urx_src_ip),
    .udp_rx_src_port(urx_src_port),
    .udp_rx_dst_port(urx_dst_port),
    .udp_rx_len(urx_len),
    .udp_rx_tdata(urx_tdata),
    .udp_rx_tkeep(urx_tkeep),
    .udp_rx_tvalid(urx_tvalid),
    .udp_rx_tlast(urx_tlast),
    .udp_rx_tuser(urx_tuser),
    .udp_tx_dst_ip(utx_dst_ip),
    .udp_tx_src_port(utx_src_port),
    .udp_tx_dst_port(utx_dst_port),
    .udp_tx_len(utx_len),
    .udp_tx_tdata(utx_tdata),
    .udp_tx_tkeep(utx_tkeep),
    .udp_tx_tvalid(utx_tvalid),
    .udp_tx_tready(utx_tready),
    .udp_tx_tlast(utx_tlast),
    .udp_tx_tuser(utx_tuser),
    .tcp_rx_tdata(tcp_tdata),
    .tcp_rx_tkeep(tcp_tkeep),
    .tcp_rx_tvalid(tcp_tvalid),
    .tcp_rx_tready(tcp_tready),
    .tcp_tx_tdata(tcp_tdata),
    .tcp_tx_tkeep(tcp_tkeep),
    .tcp_tx_tvalid(tcp_tvalid),
    .tcp_tx_tready(tcp_tready),
    .tcp_connected(tcp_connected),
    .stat_rx_good(stat_rx_good),
    .stat_rx_bad(stat_rx_bad)
  );

  udp_echo u_udp_echo (
    .clk(clk),
    .rst_n(rst_n),
    .rx_src_ip(urx_src_ip),
    .rx_src_port(urx_src_port),
    .rx_dst_port(urx_dst_port),
    .rx_len(urx_len),
    .rx_tdata(urx_tdata),
    .rx_tkeep(urx_tkeep),
    .rx_tvalid(urx_tvalid),
    .rx_tlast(urx_tlast),
    .rx_tuser(urx_tuser),
    .tx_dst_ip(utx_dst_ip),
    .tx_src_port(utx_src_port),
    .tx_dst_port(utx_dst_port),
    .tx_len(utx_len),
    .tx_tdata(utx_tdata),
    .tx_tkeep(utx_tkeep),
    .tx_tvalid(utx_tvalid),
    .tx_tready(utx_tready),
    .tx_tlast(utx_tlast),
    .tx_tuser(utx_tuser)
  );

endmodule
