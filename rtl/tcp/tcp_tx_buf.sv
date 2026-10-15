module tcp_tx_buf #(
  parameter int AW = 14 // holds 2^AW bytes
)(

  input logic clk,
  input logic rst_n,

  input logic init, // a new connection
  input logic [31:0] init_seq, // sequence number of the first byte it will send
  input logic open, // data is taken from the application
  input logic [31:0] acked, // everything before this can go

  input logic [63:0] s_tdata, // from the application
  input logic [7:0] s_tkeep, // any number of bytes, from byte 0 up
  input logic s_tvalid,
  output logic s_tready,

  output logic [31:0] wr_seq, // sequence number of the next byte written

  input logic [31:0] rd_seq, // 8 bytes from this sequence number
  output logic [63:0] rd_data // the clock after

);

  localparam int WORDS = 2 ** (AW - 3);
  localparam logic [31:0] SIZE = 32'(2 ** AW);

  logic [31:0] used;
  logic take;
  logic [3:0] n; // bytes in this word
  logic [2:0] wr_off; // lane the first byte goes in
  logic [AW-4:0] wr_word;
  logic [127:0] wr_twice;
  logic [7:0][7:0] wr_lanes; // the word turned so that each byte is in its lane
  logic [7:0][2:0] wr_idx; // byte of the word that lane l takes
  logic [7:0] wr_en;
  logic [2:0] rd_off;
  logic [AW-4:0] rd_word;
  logic [7:0][7:0] rd_lanes;
  logic [2:0] rd_off_q;
  logic [127:0] rd_twice;

  assign used = wr_seq - acked;
  assign s_tready = open && used <= SIZE - 32'd8;
  assign take = s_tvalid && s_tready;
  assign n = 4'($countones(s_tkeep));
  assign wr_off = wr_seq[2:0];
  assign wr_word = wr_seq[AW-1:3];
  assign wr_twice = {s_tdata, s_tdata} << {wr_off, 3'b000};
  assign wr_lanes = wr_twice[127:64];
  assign rd_off = rd_seq[2:0];
  assign rd_word = rd_seq[AW-1:3];
  assign rd_twice = {rd_lanes, rd_lanes} >> {rd_off_q, 3'b000};
  assign rd_data = rd_twice[63:0];

  always_comb begin
    for (int l = 0; l < 8; l++) begin
      wr_idx[l] = 3'(l) - wr_off;
      wr_en[l] = take && {1'b0, wr_idx[l]} < n;
    end
  end

  for (genvar l = 0; l < 8; l++) begin : g_lane // a lane before the offset is in the next word
    logic [7:0] mem [WORDS];

    always_ff @(posedge clk) begin
      if (wr_en[l]) begin
        mem[(4'(l) >= 4'(wr_off)) ? wr_word : wr_word + 1'b1] <= wr_lanes[l];
      end
      rd_lanes[l] <= mem[(4'(l) >= 4'(rd_off)) ? rd_word : rd_word + 1'b1];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_seq <= '0;
      rd_off_q <= '0;
    end else begin
      rd_off_q <= rd_off;
      if (init) begin
        wr_seq <= init_seq;
      end else if (take) begin
        wr_seq <= wr_seq + 32'(n);
      end
    end
  end

endmodule
