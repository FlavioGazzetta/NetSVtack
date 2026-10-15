module tcp_rx_buf #(
  parameter int DEPTH = 2048 // words, a power of 2, up to 8192
)(

  input logic clk,
  input logic rst_n,

  input logic [63:0] s_tdata, // from tcp_rx
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser, // with tlast -> the segment is dropped

  input logic commit, // from tcp_ctrl the clock after the last word, the segment is kept
  input logic rollback,
  output logic over, // the segment did not fit
  output logic [15:0] space, // bytes of room

  output logic [63:0] m_tdata, // to the application, in order
  output logic [7:0] m_tkeep, // a word can have less than 8 bytes where a segment ended
  output logic m_tvalid,
  input logic m_tready

);

  localparam int AW = $clog2(DEPTH);

  logic [71:0] mem [DEPTH];
  logic [71:0] rd_q;
  logic [AW-1:0] wr; // next word to write
  logic [AW-1:0] wr_ok; // end of the last segment kept
  logic [AW-1:0] rd;
  logic [AW-1:0] rd_next;
  logic [AW-1:0] free;
  logic full;
  logic write;

  assign full = wr + 1'b1 == rd;
  assign write = s_tvalid && s_tkeep != '0;
  assign free = rd - wr - 1'b1;
  assign space = 16'({free, 3'b000});
  assign rd_next = (m_tvalid && m_tready) ? rd + 1'b1 : rd;
  assign {m_tkeep, m_tdata} = rd_q;

  always_ff @(posedge clk) begin
    if (write && !full) begin
      mem[wr] <= {s_tkeep, s_tdata};
    end
    rd_q <= mem[rd_next];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr <= '0;
      wr_ok <= '0;
      over <= 1'b0;
    end else begin
      if (commit) begin
        wr_ok <= wr;
        over <= 1'b0;
      end else if (rollback || (s_tvalid && s_tlast && s_tuser)) begin
        wr <= wr_ok;
        over <= 1'b0;
      end else if (write && full) begin
        over <= 1'b1;
      end else if (write) begin
        wr <= wr + 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd <= '0;
      m_tvalid <= 1'b0;
    end else begin
      rd <= rd_next;
      m_tvalid <= rd_next != wr_ok;
    end
  end

endmodule
