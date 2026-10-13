module frame_fifo #(
  parameter int DEPTH = 256, // words, a power of 2
  parameter int META = 1 // width of what is stored next to every word
)(

  input logic clk,
  input logic rst_n,

  input logic [META-1:0] s_meta,
  input logic [63:0] s_tdata, // no tready, a frame that does not fit is dropped
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser, // with tlast -> the frame is dropped

  output logic [META-1:0] m_meta,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid, // only whole frames come out, so it stays high through one
  input logic m_tready,
  output logic m_tlast

);

  localparam int AW = $clog2(DEPTH);
  localparam int W = META + 73;

  logic [W-1:0] mem [DEPTH];
  logic [W-1:0] rd_q;
  logic [AW-1:0] wr; // next word to write
  logic [AW-1:0] wr_ok; // end of the last whole frame
  logic [AW-1:0] rd;
  logic [AW-1:0] rd_next;
  logic full;
  logic over; // this frame ran out of room

  assign full = wr + 1'b1 == rd;
  assign rd_next = (m_tvalid && m_tready) ? rd + 1'b1 : rd;
  assign {m_meta, m_tlast, m_tkeep, m_tdata} = rd_q;

  always_ff @(posedge clk) begin
    if (s_tvalid && !full) begin
      mem[wr] <= {s_meta, s_tlast, s_tkeep, s_tdata};
    end
    rd_q <= mem[rd_next];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr <= '0;
      wr_ok <= '0;
      over <= 1'b0;
    end else begin
      if (s_tvalid && s_tlast && (s_tuser || full || over)) begin
        wr <= wr_ok;
        over <= 1'b0;
      end else if (s_tvalid && s_tlast) begin
        wr <= wr + 1'b1;
        wr_ok <= wr + 1'b1;
      end else if (s_tvalid && full) begin
        over <= 1'b1;
      end else if (s_tvalid) begin
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
