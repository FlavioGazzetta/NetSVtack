module arp_cache #(
  parameter int ENTRIES = 8
)(

  input logic clk,
  input logic rst_n,

  input logic wr_valid, // an address seen in an ARP packet
  input logic [31:0] wr_ip,
  input logic [47:0] wr_mac,

  input logic [31:0] lk_ip,
  output logic lk_hit, // same clock
  output logic [47:0] lk_mac

);

  localparam int IDXW = $clog2(ENTRIES);

  logic [ENTRIES-1:0] valid;
  logic [31:0] ip [ENTRIES];
  logic [47:0] mac [ENTRIES];
  logic [ENTRIES-1:0] wr_match;
  logic [ENTRIES-1:0] lk_match;
  logic [IDXW-1:0] oldest; // replaced by the next new address

  assign lk_hit = |lk_match;

  always_comb begin
    lk_mac = '0;
    for (int i = 0; i < ENTRIES; i++) begin
      wr_match[i] = valid[i] && ip[i] == wr_ip;
      lk_match[i] = valid[i] && ip[i] == lk_ip;
      lk_mac = lk_mac | (lk_match[i] ? mac[i] : 48'h0);
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid <= '0;
      oldest <= '0;
      for (int i = 0; i < ENTRIES; i++) begin
        ip[i] <= '0;
        mac[i] <= '0;
      end
    end else begin
      if (wr_valid && |wr_match) begin
        for (int i = 0; i < ENTRIES; i++) begin
          if (wr_match[i]) begin
            mac[i] <= wr_mac;
          end
        end
      end else if (wr_valid) begin
        valid[oldest] <= 1'b1;
        ip[oldest] <= wr_ip;
        mac[oldest] <= wr_mac;
        oldest <= oldest + 1'b1;
      end
    end
  end

endmodule
