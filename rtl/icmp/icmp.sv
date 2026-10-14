module icmp (

  input logic clk,
  input logic rst_n,

  input logic [31:0] s_src_ip, // from ipv4_rx
  input logic [15:0] s_len,
  input logic [63:0] s_tdata, // ICMP packets
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic [31:0] m_dst_ip, // echo replies, to ipv4_tx
  output logic [15:0] m_len,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  localparam logic [7:0] TYPE_ECHO_REQUEST = 8'd8;
  localparam logic [7:0] TYPE_ECHO_REPLY = 8'd0;

  logic first; // this word starts a packet
  logic [7:0][7:0] s_bytes;
  logic echo; // type, code and length of an echo request
  logic skip_q; // the packet is something else
  logic skip;
  logic [15:0] csum;
  logic [16:0] csum_sum;
  logic [15:0] csum_reply; // the type went from 8 to 0, the rest of the packet is the same
  logic [7:0][7:0] reply;
  logic [63:0] f_tdata;

  assign s_bytes = s_tdata;
  assign echo = s_bytes[0] == TYPE_ECHO_REQUEST && s_bytes[1] == 8'd0 && s_len >= 16'd8;
  assign skip = first ? !echo : skip_q;
  assign csum = {s_bytes[2], s_bytes[3]};
  assign csum_sum = 17'(csum) + 17'h00800;
  assign csum_reply = csum_sum[15:0] + 16'(csum_sum[16]);
  assign reply = {s_bytes[7:4], csum_reply[7:0], csum_reply[15:8], s_bytes[1], TYPE_ECHO_REPLY};
  assign f_tdata = first ? reply : s_tdata;
  assign m_tuser = 1'b0;

  frame_fifo #(.DEPTH(256), .META(48)) u_fifo ( // the reply waits for the FCS check
    .clk(clk),
    .rst_n(rst_n),
    .s_meta({s_src_ip, s_len}),
    .s_tdata(f_tdata),
    .s_tkeep(s_tkeep),
    .s_tvalid(s_tvalid),
    .s_tlast(s_tlast),
    .s_tuser(s_tuser || skip),
    .m_meta({m_dst_ip, m_len}),
    .m_tdata(m_tdata),
    .m_tkeep(m_tkeep),
    .m_tvalid(m_tvalid),
    .m_tready(m_tready),
    .m_tlast(m_tlast)
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      first <= 1'b1;
      skip_q <= 1'b0;
    end else begin
      if (s_tvalid) begin
        first <= s_tlast;
        skip_q <= skip;
      end
    end
  end

endmodule
