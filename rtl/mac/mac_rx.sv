module mac_rx (

  input logic clk,
  input logic rst_n,

  input logic [63:0] xgmii_rxd,
  input logic [7:0] xgmii_rxc,

  output logic [63:0] m_tdata, // from the destination MAC to the end of the payload, no tready
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  output logic m_tlast,
  output logic m_tuser, // with tlast -> drop the frame: bad FCS, error character or under 64 bytes

  output logic stat_good, // one clock per good frame
  output logic stat_bad // one clock per frame that started and ended badly

);

  localparam logic [7:0] XGMII_IDLE = 8'h07;
  localparam logic [7:0] XGMII_START = 8'hFB;
  localparam logic [7:0] XGMII_TERM = 8'hFD;
  localparam logic [63:0] PREAMBLE = 64'hD555_5555_5555_55FB; // start, 6 x 0x55, SFD
  localparam logic [31:0] CRC_RESIDUE = 32'hDEBB20E3; // crc_q once the FCS has gone through it

  typedef enum logic [1:0] {IDLE, PAYLOAD, LAST} state_t;

  state_t state;
  state_t next_state;

  logic start0; // start character in lane 0
  logic start4;
  logic swap; // this frame started in lane 4 -> delayed 4 bytes so it starts in lane 0
  logic [31:0] prev_d; // upper half of the last word
  logic [3:0] prev_c;
  logic [7:0][7:0] al_d; // the aligned word, 8 bytes, byte 0 arrived first
  logic [7:0] al_c;

  logic sof; // the preamble word
  logic [3:0] nbytes; // data bytes before the first control character, 8 if there is none
  logic full;
  logic term; // that control character is a terminate
  logic split; // the FCS ends past byte 4 -> this word still has payload in it
  logic [31:0] crc_q; // CRC of the frame so far
  logic [31:0] crc_n [1:8]; // crc_q after 1 to 8 more bytes
  logic [31:0] crc_end;
  logic bad;
  logic [3:0] words; // full words so far, stops at 8 (64 bytes)
  logic [7:0][7:0] d1_data; // one word behind, so the FCS can be cut off the end
  logic d1_valid;
  logic [7:0] d1_keep; // payload bytes in d1_data when the frame ends in this word
  logic [7:0][7:0] d1_masked; // bytes past tkeep zeroed
  logic [7:0] tail_keep; // payload bytes in this word when the frame ends in it
  logic [7:0][7:0] tail_masked;
  logic [63:0] hold_data; // the tail, sent the clock after
  logic [7:0] hold_keep;
  logic hold_bad;

  assign start0 = xgmii_rxc[0] && xgmii_rxd[7:0] == XGMII_START;
  assign start4 = xgmii_rxc[4] && xgmii_rxd[39:32] == XGMII_START;
  assign sof = al_c == 8'h01 && al_d == PREAMBLE;
  assign full = nbytes == 4'd8;
  assign split = !full && nbytes > 4'd4;
  assign crc_end = (nbytes == 4'd0) ? crc_q : crc_n[nbytes];
  assign bad = !term || crc_end != CRC_RESIDUE || words != 4'd8;
  assign d1_keep = 8'hFF >> (4'd4 - nbytes); // the last 4 bytes of a frame are the FCS
  assign tail_keep = 8'hFF >> (4'd12 - nbytes);

  always_ff @(posedge clk) begin // relies on the 5 byte minimum gap between frames
    if (!rst_n) begin
      swap <= 1'b0;
      prev_d <= {4{XGMII_IDLE}};
      prev_c <= '1;
      al_d <= {8{XGMII_IDLE}};
      al_c <= '1;
    end else begin
      prev_d <= xgmii_rxd[63:32];
      prev_c <= xgmii_rxc[7:4];
      if (start0) begin
        swap <= 1'b0;
        al_d <= xgmii_rxd;
        al_c <= xgmii_rxc;
      end else if (start4 && !swap) begin
        swap <= 1'b1;
        al_d <= {8{XGMII_IDLE}}; // the lower half is idle and the last word has gone out whole
        al_c <= '1;
      end else if (swap) begin
        al_d <= {xgmii_rxd[31:0], prev_d};
        al_c <= {xgmii_rxc[3:0], prev_c};
      end else begin
        al_d <= xgmii_rxd;
        al_c <= xgmii_rxc;
      end
    end
  end

  always_comb begin
    nbytes = 4'd8;
    term = 1'b0;
    for (int i = 7; i >= 0; i--) begin
      if (al_c[i]) begin
        nbytes = 4'(i);
        term = al_d[i] == XGMII_TERM;
      end
    end
  end

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      d1_masked[i] = d1_keep[i] ? d1_data[i] : 8'h00;
      tail_masked[i] = tail_keep[i] ? al_d[i] : 8'h00;
    end
  end

  for (genvar b = 1; b <= 8; b++) begin : g_crc
    crc32 #(.BYTES(b)) u_crc (.crc_in(crc_q), .data(al_d), .crc_out(crc_n[b]));
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      IDLE: next_state = sof ? PAYLOAD : IDLE;
      PAYLOAD: next_state = full ? PAYLOAD : (split ? LAST : IDLE);
      LAST: next_state = sof ? PAYLOAD : IDLE;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      crc_q <= '1;
      words <= '0;
      d1_data <= '0;
      d1_valid <= 1'b0;
      hold_data <= '0;
      hold_keep <= '0;
      hold_bad <= 1'b0;
    end else begin
      if (state != PAYLOAD) begin
        crc_q <= '1;
        words <= '0;
        d1_valid <= 1'b0;
      end else if (full) begin
        crc_q <= crc_n[8];
        d1_data <= al_d;
        d1_valid <= 1'b1;
        if (words != 4'd8) begin
          words <= words + 4'd1;
        end
      end else begin
        d1_valid <= 1'b0;
        hold_data <= tail_masked;
        hold_keep <= tail_keep;
        hold_bad <= bad;
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
      stat_good <= 1'b0;
      stat_bad <= 1'b0;
    end else begin
      m_tvalid <= 1'b0;
      m_tlast <= 1'b0;
      m_tuser <= 1'b0;
      stat_good <= state == PAYLOAD && !full && !bad;
      stat_bad <= state == PAYLOAD && !full && bad;
      if (state == PAYLOAD && (full || split)) begin
        m_tdata <= d1_data;
        m_tkeep <= 8'hFF;
        m_tvalid <= d1_valid;
      end else if (state == PAYLOAD) begin
        m_tdata <= d1_masked;
        m_tkeep <= d1_keep;
        m_tvalid <= d1_valid; // nothing has gone out yet for a frame this short
        m_tlast <= d1_valid;
        m_tuser <= d1_valid && bad;
      end else if (state == LAST) begin
        m_tdata <= hold_data;
        m_tkeep <= hold_keep;
        m_tvalid <= 1'b1;
        m_tlast <= 1'b1;
        m_tuser <= hold_bad;
      end
    end
  end

endmodule
