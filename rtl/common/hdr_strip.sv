module hdr_strip #(
  parameter int BYTES = 14 // length of the header
)(

  input logic clk,
  input logic rst_n,

  input logic [63:0] s_tdata, // no tready, a frame shorter than the header is dropped
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  output logic [BYTES-1:0][7:0] hdr, // the first byte on the wire is the top one
  output logic hdr_valid, // one clock, at least a clock before the first payload word

  output logic [63:0] m_tdata, // what follows the header, starting in byte 0
  output logic [7:0] m_tkeep, // can be 0 on the last word, when there is no payload
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser

);

  localparam int WORDS = (BYTES + 7) / 8; // words the header reaches into
  localparam int OFF = BYTES - (WORDS - 1) * 8; // header bytes in the last of them, 1 to 8
  localparam int IDXW = $clog2(WORDS + 1);

  logic [WORDS-1:0][7:0][7:0] hw; // the words of the header as they arrived
  logic [WORDS*8-1:0][7:0] hw_bytes;
  logic [BYTES-1:0][7:0] hdr_bytes; // byte 0 arrived first
  logic [IDXW-1:0] widx; // word of the frame, stops at WORDS
  logic split; // this word has the end of the header in it
  logic payload; // this word is all payload

  logic [7:0][7:0] s_bytes;
  logic [7:0][7:0] prev; // the last word, its bytes from OFF up have not gone out yet
  logic [15:0][7:0] win;
  logic [7:0][7:0] shifted; // the rest of prev, then the start of this word
  logic [3:0] n; // bytes in this word
  logic ends; // the frame ends in this output word
  logic [7:0] keep;
  logic [7:0][7:0] masked;

  logic tail; // what is left in prev goes out as one more word
  logic [3:0] tail_cnt;
  logic tail_user;

  assign s_bytes = s_tdata;
  assign hw_bytes = hw;
  assign hdr_bytes = hw_bytes[BYTES-1:0];
  assign split = widx == IDXW'(WORDS - 1);
  assign payload = widx == IDXW'(WORDS);
  assign n = s_tlast ? 4'($countones(s_tkeep)) : 4'd8;
  assign win = {s_bytes, prev};
  assign shifted = win[OFF+7:OFF];
  assign ends = s_tlast && n <= 4'(OFF);

  always_comb begin
    for (int i = 0; i < BYTES; i++) begin
      hdr[i] = hdr_bytes[BYTES-1-i];
    end
  end

  always_comb begin
    keep = 8'hFF;
    if (tail) begin
      keep = 8'hFF >> (4'd8 - tail_cnt);
    end else if (ends) begin
      keep = 8'hFF >> (4'(OFF) - n);
    end
    for (int i = 0; i < 8; i++) begin
      masked[i] = keep[i] ? shifted[i] : 8'h00;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      widx <= '0;
      hw <= '0;
      prev <= '0;
      hdr_valid <= 1'b0;
    end else begin
      hdr_valid <= s_tvalid && split && n >= 4'(OFF);
      if (s_tvalid && s_tlast) begin
        widx <= '0;
      end else if (s_tvalid && !payload) begin
        widx <= widx + 1'b1;
      end
      if (s_tvalid && !payload) begin
        hw[widx] <= s_bytes;
      end
      if (s_tvalid && (split || payload)) begin
        prev <= s_bytes;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tail <= 1'b0;
      tail_cnt <= '0;
      tail_user <= 1'b0;
    end else begin
      tail <= 1'b0;
      if (s_tvalid && s_tlast && split && n >= 4'(OFF)) begin
        tail <= 1'b1;
      end else if (s_tvalid && s_tlast && payload && n > 4'(OFF)) begin
        tail <= 1'b1;
      end
      if (s_tvalid) begin
        tail_cnt <= n - 4'(OFF);
        tail_user <= s_tuser;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_tdata <= '0;
      m_tkeep <= '0;
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
    end else begin
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
      if (tail) begin
        m_tdata <= masked;
        m_tkeep <= keep;
        m_tvalid <= 1'b1;
        m_tlast <= 1'b1;
        m_tuser <= tail_user;
      end else if (s_tvalid && payload) begin
        m_tdata <= masked;
        m_tkeep <= keep;
        m_tvalid <= 1'b1;
        m_tlast <= ends;
        m_tuser <= ends && s_tuser;
      end
    end
  end

endmodule
