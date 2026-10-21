module pcs_rx #(
  parameter int SLIP_WAIT = 32 // clocks for a slip to show in the data
)(

  input logic clk, // the recovered receive clock
  input logic rst_n,

  input logic [1:0] rx_header, // bit 0 came off the wire first, then rx_data from bit 0 up
  input logic [63:0] rx_data,
  input logic rx_valid,
  output logic rx_slip, // one clock -> move the block boundary by one bit

  output logic [63:0] xgmii_rxd, // idle until block_lock
  output logic [7:0] xgmii_rxc,
  output logic block_lock

);

  localparam logic [7:0] XGMII_IDLE = 8'h07;
  localparam logic [7:0] XGMII_START = 8'hFB;
  localparam logic [7:0] XGMII_TERM = 8'hFD;
  localparam logic [7:0] XGMII_ERROR = 8'hFE;
  localparam logic [7:0] XGMII_SEQ = 8'h9C;
  localparam logic [1:0] SYNC_DATA = 2'b10;
  localparam logic [1:0] SYNC_CTRL = 2'b01;
  localparam logic [6:0] CODE_IDLE = 7'h00;

  typedef enum logic [1:0] {SEARCH, SLIP, LOCKED} state_t;

  state_t state;
  state_t next_state;

  logic hdr_ok; // the two header bits differ
  logic [5:0] blocks; // blocks counted in this window of 64
  logic [4:0] bad_cnt; // bad headers in this window
  logic lost; // 16 bad headers in one window
  logic [$clog2(SLIP_WAIT + 1) - 1:0] wait_cnt;

  logic [57:0] scr_q; // the last 58 bits that came in
  logic [57:0] scr_n;
  logic [63:0] block; // descrambled
  logic [7:0][7:0] b; // block a byte at a time, the block type is b[0]
  logic [7:0][6:0] code; // the control codes, lane i is code[i] in every block type
  logic [7:0][7:0] cchar; // those as XGMII characters
  logic [63:0] dec_d;
  logic [7:0] dec_c;

  assign hdr_ok = rx_header[0] != rx_header[1];
  assign lost = !hdr_ok && bad_cnt == 5'd15;
  assign b = block;
  assign code = block[63:8];
  assign block_lock = state == LOCKED;

  always_comb begin
    scr_n = scr_q;
    for (int i = 0; i < 64; i++) begin
      block[i] = rx_data[i] ^ scr_n[38] ^ scr_n[57];
      scr_n = {scr_n[56:0], rx_data[i]};
    end
  end

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      cchar[i] = (code[i] == CODE_IDLE) ? XGMII_IDLE : XGMII_ERROR;
    end
  end

  always_comb begin
    dec_d = {8{XGMII_ERROR}};
    dec_c = 8'hFF;
    if (rx_header == SYNC_DATA) begin
      dec_d = block;
      dec_c = 8'h00;
    end else if (rx_header == SYNC_CTRL) begin
      case (b[0])
        8'h1E: begin
          dec_d = cchar;
          dec_c = 8'hFF;
        end
        8'h78: begin
          dec_d = {b[7:1], XGMII_START};
          dec_c = 8'h01;
        end
        8'h33: begin
          dec_d = {b[7:5], XGMII_START, cchar[3:0]};
          dec_c = 8'h1F;
        end
        8'h87: begin
          dec_d = {cchar[7:1], XGMII_TERM};
          dec_c = 8'hFF;
        end
        8'h99: begin
          dec_d = {cchar[7:2], XGMII_TERM, b[1]};
          dec_c = 8'hFE;
        end
        8'hAA: begin
          dec_d = {cchar[7:3], XGMII_TERM, b[2:1]};
          dec_c = 8'hFC;
        end
        8'hB4: begin
          dec_d = {cchar[7:4], XGMII_TERM, b[3:1]};
          dec_c = 8'hF8;
        end
        8'hCC: begin
          dec_d = {cchar[7:5], XGMII_TERM, b[4:1]};
          dec_c = 8'hF0;
        end
        8'hD2: begin
          dec_d = {cchar[7:6], XGMII_TERM, b[5:1]};
          dec_c = 8'hE0;
        end
        8'hE1: begin
          dec_d = {cchar[7], XGMII_TERM, b[6:1]};
          dec_c = 8'hC0;
        end
        8'hFF: begin
          dec_d = {XGMII_TERM, b[7:1]};
          dec_c = 8'h80;
        end
        8'h4B: begin // ordered set in lane 0, a link fault
          dec_d = {cchar[7:4], b[3:1], XGMII_SEQ};
          dec_c = 8'hF1;
        end
        8'h2D: begin
          dec_d = {b[7:5], XGMII_SEQ, cchar[3:0]};
          dec_c = 8'h1F;
        end
        8'h55: begin
          dec_d = {b[7:5], XGMII_SEQ, b[3:1], XGMII_SEQ};
          dec_c = 8'h11;
        end
        8'h66: begin
          dec_d = {b[7:5], XGMII_START, b[3:1], XGMII_SEQ};
          dec_c = 8'h11;
        end
        default: begin
          dec_d = {8{XGMII_ERROR}};
          dec_c = 8'hFF;
        end
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= SEARCH;
    end else begin
      state <= next_state;
    end
  end

  always_comb begin
    next_state = state;
    case (state)
      SEARCH: begin
        if (rx_valid) begin
          next_state = !hdr_ok ? SLIP : ((blocks == 6'd63) ? LOCKED : SEARCH); // 64 good headers in a row
        end
      end
      SLIP: next_state = (wait_cnt == '0) ? SEARCH : SLIP;
      LOCKED: next_state = (rx_valid && lost) ? SLIP : LOCKED;
      default: next_state = SEARCH;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      blocks <= '0;
      bad_cnt <= '0;
      wait_cnt <= '0;
      rx_slip <= 1'b0;
    end else begin
      rx_slip <= state != SLIP && next_state == SLIP;
      if (state == SLIP) begin
        blocks <= '0;
        bad_cnt <= '0;
        if (wait_cnt != '0) begin
          wait_cnt <= wait_cnt - 1'b1;
        end
      end else begin
        wait_cnt <= ($bits(wait_cnt))'(SLIP_WAIT);
        if (rx_valid) begin
          blocks <= blocks + 6'd1;
          if (blocks == 6'd63) begin
            bad_cnt <= '0;
          end else if (!hdr_ok) begin
            bad_cnt <= bad_cnt + 5'd1;
          end
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      scr_q <= '0;
      xgmii_rxd <= {8{XGMII_IDLE}};
      xgmii_rxc <= '1;
    end else begin
      xgmii_rxd <= {8{XGMII_IDLE}};
      xgmii_rxc <= '1;
      if (rx_valid) begin
        scr_q <= scr_n;
      end
      if (rx_valid && state == LOCKED) begin
        xgmii_rxd <= dec_d;
        xgmii_rxc <= dec_c;
      end
    end
  end

endmodule
