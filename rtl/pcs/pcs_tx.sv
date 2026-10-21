module pcs_tx (

  input logic clk,
  input logic rst_n,

  input logic [63:0] xgmii_txd,
  input logic [7:0] xgmii_txc,

  output logic [1:0] tx_header, // bit 0 goes on the wire first, then tx_data from bit 0 up
  output logic [63:0] tx_data // scrambled

);

  localparam logic [7:0] XGMII_IDLE = 8'h07;
  localparam logic [7:0] XGMII_START = 8'hFB;
  localparam logic [7:0] XGMII_TERM = 8'hFD;
  localparam logic [1:0] SYNC_DATA = 2'b10;
  localparam logic [1:0] SYNC_CTRL = 2'b01;
  localparam logic [6:0] CODE_IDLE = 7'h00;
  localparam logic [6:0] CODE_ERROR = 7'h1E;

  logic [7:0][7:0] d; // the XGMII word a byte at a time
  logic [7:0][6:0] code; // each lane as a control code
  logic [7:0] start; // start in this lane
  logic [7:0] term; // terminate in this lane
  logic [1:0] header;
  logic [63:0] block; // the encoded word before the scrambler
  logic [57:0] scr_q; // the last 58 bits that went out
  logic [57:0] scr_n;
  logic [63:0] scrambled;

  assign d = xgmii_txd;
  assign header = (xgmii_txc == 8'h00) ? SYNC_DATA : SYNC_CTRL;

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      code[i] = (xgmii_txc[i] && d[i] == XGMII_IDLE) ? CODE_IDLE : CODE_ERROR;
      start[i] = xgmii_txc[i] && d[i] == XGMII_START;
      term[i] = xgmii_txc[i] && d[i] == XGMII_TERM;
    end
  end

  always_comb begin
    block = {{8{CODE_ERROR}}, 8'h1E}; // anything that has no block type goes out as errors
    if (xgmii_txc == 8'h00) begin
      block = d;
    end else if (xgmii_txc == 8'h01 && start[0]) begin
      block = {d[7:1], 8'h78};
    end else if (xgmii_txc == 8'h1F && start == 8'h10 && term == 8'h00) begin
      block = {d[7:5], 4'h0, code[3:0], 8'h33};
    end else if (xgmii_txc == 8'hFF && term == 8'h01 && start == 8'h00) begin
      block = {code[7:1], 7'h0, 8'h87};
    end else if (xgmii_txc == 8'hFE && term == 8'h02 && start == 8'h00) begin
      block = {code[7:2], 6'h0, d[0], 8'h99};
    end else if (xgmii_txc == 8'hFC && term == 8'h04 && start == 8'h00) begin
      block = {code[7:3], 5'h0, d[1:0], 8'hAA};
    end else if (xgmii_txc == 8'hF8 && term == 8'h08 && start == 8'h00) begin
      block = {code[7:4], 4'h0, d[2:0], 8'hB4};
    end else if (xgmii_txc == 8'hF0 && term == 8'h10 && start == 8'h00) begin
      block = {code[7:5], 3'h0, d[3:0], 8'hCC};
    end else if (xgmii_txc == 8'hE0 && term == 8'h20 && start == 8'h00) begin
      block = {code[7:6], 2'h0, d[4:0], 8'hD2};
    end else if (xgmii_txc == 8'hC0 && term == 8'h40 && start == 8'h00) begin
      block = {code[7], 1'h0, d[5:0], 8'hE1};
    end else if (xgmii_txc == 8'h80 && term == 8'h80 && start == 8'h00) begin
      block = {d[6:0], 8'hFF};
    end else if (xgmii_txc == 8'hFF && term == 8'h00 && start == 8'h00) begin
      block = {code, 8'h1E}; // idle
    end
  end

  always_comb begin // x^58 + x^39 + 1, bit 0 first
    scr_n = scr_q;
    for (int i = 0; i < 64; i++) begin
      scrambled[i] = block[i] ^ scr_n[38] ^ scr_n[57];
      scr_n = {scr_n[56:0], scrambled[i]};
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      scr_q <= '1;
      tx_header <= SYNC_CTRL;
      tx_data <= '0;
    end else begin
      scr_q <= scr_n;
      tx_header <= header;
      tx_data <= scrambled;
    end
  end

endmodule
