module hdr_insert #(
  parameter int BYTES = 14 // length of the header
)(

  input logic clk,
  input logic rst_n,

  input logic [BYTES-1:0][7:0] hdr, // the top byte goes out first, held until the first word is taken

  input logic [63:0] s_tdata, // what goes after the header
  input logic [7:0] s_tkeep, // can be 0 on the last word, when there is nothing to add
  input logic s_tvalid,
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser,

  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid, // stays high through the frame if s_tvalid does
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  localparam int WORDS = (BYTES + 7) / 8; // words the header reaches into
  localparam int OFF = BYTES - (WORDS - 1) * 8; // header bytes in the last of them, 1 to 8
  localparam int FREE = 8 - OFF; // room for payload next to them
  localparam int IDXW = $clog2(WORDS + 1);

  typedef enum logic [1:0] {HEADER, PAYLOAD, TAIL} state_t;

  state_t state;
  state_t next_state;

  logic [BYTES-1:0][7:0] hdr_bytes; // byte 0 goes out first
  logic [WORDS-1:0][7:0][7:0] hw; // the header a word at a time
  logic [7:0][7:0] hw_last; // its last bytes, moved to the top of a word
  logic [IDXW-1:0] hidx; // header word going out

  logic slot; // the output register is free or being read
  logic whole; // this header word has no payload in it
  logic take; // a payload word goes in
  logic [7:0][7:0] s_bytes;
  logic [7:0][7:0] prev; // the last payload word, its bytes from FREE up have not gone out yet
  logic [7:0][7:0] carry;
  logic [15:0][7:0] win;
  logic [7:0][7:0] shifted; // the rest of carry, then the start of this word
  logic [3:0] n; // bytes in this word
  logic ends; // the frame ends in this output word
  logic [3:0] tail_cnt;
  logic tail_user;
  logic [7:0] keep;
  logic [7:0][7:0] masked;

  assign hw = (WORDS*64)'(hdr_bytes);
  assign hw_last = hw[WORDS-1] << (FREE * 8);
  assign slot = !m_tvalid || m_tready;
  assign whole = state == HEADER && hidx != IDXW'(WORDS - 1);
  assign s_tready = slot && (state == PAYLOAD || (state == HEADER && !whole));
  assign take = s_tvalid && s_tready;
  assign s_bytes = s_tdata;
  assign carry = (state == HEADER) ? hw_last : prev;
  assign win = {s_bytes, carry};
  assign shifted = win[FREE+7:FREE];
  assign n = s_tlast ? 4'($countones(s_tkeep)) : 4'd8;
  assign ends = s_tlast && n <= 4'(FREE);

  always_comb begin
    for (int i = 0; i < BYTES; i++) begin
      hdr_bytes[i] = hdr[BYTES-1-i];
    end
  end

  always_comb begin
    keep = 8'hFF;
    if (state == TAIL) begin
      keep = 8'hFF >> (4'd8 - tail_cnt);
    end else if (ends) begin
      keep = 8'hFF >> (4'(FREE) - n);
    end
    for (int i = 0; i < 8; i++) begin
      masked[i] = keep[i] ? shifted[i] : 8'h00;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= HEADER;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      HEADER: next_state = !take ? HEADER : (ends ? HEADER : (s_tlast ? TAIL : PAYLOAD));
      PAYLOAD: next_state = !take ? PAYLOAD : (ends ? HEADER : (s_tlast ? TAIL : PAYLOAD));
      TAIL: next_state = slot ? HEADER : TAIL;
      default: next_state = HEADER;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hidx <= '0;
      prev <= '0;
      tail_cnt <= '0;
      tail_user <= 1'b0;
    end else begin
      if (whole && s_tvalid && slot) begin
        hidx <= hidx + 1'b1;
      end else if (take) begin
        hidx <= '0;
      end
      if (take) begin
        prev <= s_bytes;
        tail_cnt <= n - 4'(FREE);
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
    end else if (slot) begin
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
      if (whole && s_tvalid) begin
        m_tdata <= hw[hidx];
        m_tkeep <= 8'hFF;
        m_tvalid <= 1'b1;
      end else if (take) begin
        m_tdata <= masked;
        m_tkeep <= keep;
        m_tvalid <= 1'b1;
        m_tlast <= ends;
        m_tuser <= ends && s_tuser;
      end else if (state == TAIL) begin
        m_tdata <= masked;
        m_tkeep <= keep;
        m_tvalid <= 1'b1;
        m_tlast <= 1'b1;
        m_tuser <= tail_user;
      end
    end
  end

endmodule
