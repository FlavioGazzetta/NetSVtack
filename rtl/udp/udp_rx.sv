module udp_rx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] s_src_ip, // from ipv4_rx
  input logic [15:0] s_len,
  input logic [63:0] s_tdata, // UDP packets
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic [31:0] m_src_ip, // held through the datagram
  output logic [15:0] m_src_port,
  output logic [15:0] m_dst_port,
  output logic [15:0] m_len, // bytes of data
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser // with tlast -> drop the datagram

);

  logic [7:0][7:0] hdr;
  logic hdr_valid;
  logic [15:0] src_port;
  logic [15:0] dst_port;
  logic [15:0] length;
  logic [15:0] csum; // not checked, the FCS covers the frame
  logic accept;
  logic p_tvalid;

  assign {src_port, dst_port, length, csum} = hdr;
  assign m_tvalid = p_tvalid && accept;

  hdr_strip #(.BYTES(8)) u_strip (
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
      m_src_ip <= '0;
      m_src_port <= '0;
      m_dst_port <= '0;
      m_len <= '0;
    end else begin
      if (hdr_valid) begin
        accept <= length == s_len;
        m_src_ip <= s_src_ip;
        m_src_port <= src_port;
        m_dst_port <= dst_port;
        m_len <= length - 16'd8;
      end
    end
  end

endmodule
