module crc32 #(
  parameter int BYTES = 8
)(

  input logic [31:0] crc_in, // all ones at the start of a frame
  input logic [63:0] data, // the low BYTES bytes go through, byte 0 first
  output logic [31:0] crc_out // inverted -> the FCS

);

  always_comb begin
    crc_out = crc_in;
    for (int i = 0; i < BYTES * 8; i++) begin
      crc_out = (crc_out >> 1) ^ ({32{crc_out[0] ^ data[i]}} & 32'hEDB88320);
    end
  end

endmodule
