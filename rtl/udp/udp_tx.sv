module udp_tx (

  input logic clk,
  input logic rst_n,

  input logic [31:0] s_dst_ip, // held until the first word is taken
  input logic [15:0] s_src_port,
  input logic [15:0] s_dst_port,
  input logic [15:0] s_len, // bytes of data
  input logic [63:0] s_tdata,
  input logic [7:0] s_tkeep,
  input logic s_tvalid, // has to stay high from the first word to tlast
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser,

  output logic [31:0] m_dst_ip, // to ipv4_tx
  output logic [15:0] m_len,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  logic [7:0][7:0] hdr;
  logic [15:0] length;
  logic first; // the next word starts a datagram

  assign length = s_len + 16'd8;
  assign hdr = {s_src_port, s_dst_port, length, 16'h0000}; // no checksum

  hdr_insert #(.BYTES(8)) u_insert (
    .clk(clk),
    .rst_n(rst_n),
    .hdr(hdr),
    .s_tdata(s_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tready(s_tready),
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
      first <= 1'b1;
      m_dst_ip <= '0;
      m_len <= '0;
    end else begin
      if (s_tvalid && s_tready) begin
        first <= s_tlast;
      end
      if (s_tvalid && s_tready && first) begin
        m_dst_ip <= s_dst_ip;
        m_len <= length;
      end
    end
  end

endmodule
