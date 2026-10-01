module crc32_top (
  input logic clk,
  input logic [31:0] crc_in,
  input logic [63:0] data,
  output logic [31:0] crc_out [1:8]
);

  for (genvar b = 1; b <= 8; b++) begin : g_crc
    crc32 #(.BYTES(b)) u_crc (.crc_in(crc_in), .data(data), .crc_out(crc_out[b]));
  end

endmodule
