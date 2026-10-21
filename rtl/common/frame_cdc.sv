module frame_cdc (

  input logic s_clk,
  input logic s_rst_n,

  input logic [63:0] s_tdata, // no tready
  input logic [7:0] s_tkeep,
  input logic s_tvalid,
  input logic s_tlast,
  input logic s_tuser,

  input logic m_clk, // any phase, within a few hundred ppm of s_clk
  input logic m_rst_n,

  output logic [63:0] m_tdata, // no tready, a frame that went in without a gap comes out without one
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser

);

  localparam int AW = 4;

  typedef enum logic [1:0] {IDLE, WAIT, READ} state_t;

  state_t state;
  state_t next_state;

  logic [73:0] mem [1 << AW];

  logic [AW:0] wr; // s_clk
  logic [AW:0] wr_next;
  logic [AW:0] wr_gray;
  (* ASYNC_REG = "TRUE" *) logic [AW:0] rd_gray_s1;
  (* ASYNC_REG = "TRUE" *) logic [AW:0] rd_gray_s2;
  logic [AW:0] rd_s; // rd as s_clk sees it
  logic full;
  logic over; // a word of this frame was lost

  logic [AW:0] rd; // m_clk
  logic [AW:0] rd_next;
  logic [AW:0] rd_gray;
  (* ASYNC_REG = "TRUE" *) logic [AW:0] wr_gray_m1;
  (* ASYNC_REG = "TRUE" *) logic [AW:0] wr_gray_m2;
  logic [AW:0] wr_m; // wr as m_clk sees it
  logic [AW:0] level;
  logic empty;
  logic rd_en;
  logic [73:0] rd_word;
  logic rd_last;

  assign wr_next = wr + 1'b1;
  assign full = (wr - rd_s) == (AW + 1)'(1 << AW);
  assign rd_next = rd + 1'b1;
  assign level = wr_m - rd;
  assign empty = level == '0;
  assign rd_en = state == READ && !empty;
  assign rd_word = mem[rd[AW-1:0]];
  assign rd_last = rd_word[72];

  always_comb begin
    rd_s[AW] = rd_gray_s2[AW];
    wr_m[AW] = wr_gray_m2[AW];
    for (int i = AW - 1; i >= 0; i--) begin
      rd_s[i] = rd_s[i+1] ^ rd_gray_s2[i];
      wr_m[i] = wr_m[i+1] ^ wr_gray_m2[i];
    end
  end

  always_ff @(posedge s_clk) begin
    if (s_tvalid && !full) begin
      mem[wr[AW-1:0]] <= {s_tuser || over, s_tlast, s_tkeep, s_tdata};
    end
  end

  always_ff @(posedge s_clk) begin
    if (!s_rst_n) begin
      wr <= '0;
      wr_gray <= '0;
      rd_gray_s1 <= '0;
      rd_gray_s2 <= '0;
      over <= 1'b0;
    end else begin
      rd_gray_s1 <= rd_gray;
      rd_gray_s2 <= rd_gray_s1;
      if (s_tvalid && full) begin
        over <= 1'b1; // the frame goes on with tuser on its last word
      end else if (s_tvalid) begin
        wr <= wr_next;
        wr_gray <= wr_next ^ (wr_next >> 1);
        if (s_tlast) begin
          over <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge m_clk) begin
    if (!m_rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      IDLE: next_state = empty ? IDLE : ((level >= (AW + 1)'(2)) ? READ : WAIT);
      WAIT: next_state = READ; // 2 words ahead, or the frame is that short
      READ: next_state = (rd_en && rd_last) ? IDLE : READ;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge m_clk) begin
    if (!m_rst_n) begin
      rd <= '0;
      rd_gray <= '0;
      wr_gray_m1 <= '0;
      wr_gray_m2 <= '0;
      m_tdata <= '0;
      m_tkeep <= '0;
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
    end else begin
      wr_gray_m1 <= wr_gray;
      wr_gray_m2 <= wr_gray_m1;
      m_tvalid <= rd_en;
      m_tlast <= rd_en && rd_last;
      m_tuser <= rd_en && rd_last && rd_word[73];
      if (rd_en) begin
        rd <= rd_next;
        rd_gray <= rd_next ^ (rd_next >> 1);
        m_tdata <= rd_word[63:0];
        m_tkeep <= rd_word[71:64];
      end
    end
  end

endmodule
