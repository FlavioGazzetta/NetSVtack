module eth_rx (

  input logic clk,
  input logic rst_n,

  input logic [47:0] cfg_mac,

  input logic [63:0] s_tdata, // from mac_rx
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic [47:0] m_src_mac, // held through the frame
  output logic m_arp, // EtherType of the frame
  output logic m_ipv4,
  output logic [63:0] m_tdata, // the payload, padding included
  output logic [7:0] m_tkeep,
  output logic m_tvalid, // only frames for this MAC or broadcast
  output logic m_tlast,
  output logic m_tuser

);

  localparam logic [15:0] ETHERTYPE_IPV4 = 16'h0800;
  localparam logic [15:0] ETHERTYPE_ARP = 16'h0806;

  logic [13:0][7:0] hdr;
  logic hdr_valid;
  logic [47:0] dst_mac;
  logic [47:0] src_mac;
  logic [15:0] ethertype;
  logic accept;
  logic p_tvalid;

  assign {dst_mac, src_mac, ethertype} = hdr;
  assign m_tvalid = p_tvalid && accept;

  hdr_strip #(.BYTES(14)) u_strip (
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
    .m_tlast(m_tlast),
    .m_tuser(m_tuser)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      accept <= 1'b0;
      m_src_mac <= '0;
      m_arp <= 1'b0;
      m_ipv4 <= 1'b0;
    end else begin
      if (hdr_valid) begin
        accept <= dst_mac == cfg_mac || dst_mac == '1;
        m_src_mac <= src_mac;
        m_arp <= ethertype == ETHERTYPE_ARP;
        m_ipv4 <= ethertype == ETHERTYPE_IPV4;
      end
    end
  end

endmodule
