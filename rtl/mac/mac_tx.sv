module mac_tx (

  input logic clk,
  input logic rst_n,

  input logic [63:0] s_tdata, // from the destination MAC to the end of the payload
  input logic [7:0] s_tkeep,
  input logic s_tvalid, // has to stay high from the first word to tlast
  output logic s_tready,
  input logic s_tlast,
  input logic s_tuser, // with tlast -> abort, the frame ends in error characters

  output logic [63:0] xgmii_txd,
  output logic [7:0] xgmii_txc

);

  localparam logic [7:0] XGMII_IDLE = 8'h07;
  localparam logic [7:0] XGMII_START = 8'hFB;
  localparam logic [7:0] XGMII_TERM = 8'hFD;
  localparam logic [7:0] XGMII_ERROR = 8'hFE;
  localparam logic [63:0] PREAMBLE = 64'hD555_5555_5555_55FB; // start, 6 x 0x55, SFD

  typedef enum logic [2:0] {IDLE, DATA, PAD, FCS, TERM, IPG, DROP} state_t;

  state_t state;
  state_t next_state;

  logic [31:0] crc_q; // CRC of the frame so far
  logic [31:0] crc_n [1:8]; // crc_q after 1 to 8 more bytes
  logic [63:0] crc_data;
  logic [31:0] fcs;
  logic [31:0] fcs_q;
  logic [2:0] rem_q; // FCS bytes left for the word after the last data word
  logic [3:0] widx; // which word of the frame this is, stops at 8
  logic [1:0] ipg_q; // idle words still owed after the terminate

  logic [7:0][7:0] s_bytes; // s_tdata a byte at a time, byte 0 goes out first
  logic [7:0][7:0] data_m; // the word with the bytes past tkeep zeroed
  logic [3:0] n; // bytes of this word that go on the wire
  logic abort; // nothing to send in the middle of a frame, or tuser
  logic whole; // this word goes out as 8 bytes and more follow, data or padding
  logic [63:0] last_d; // last data word with as much FCS as fits and the terminate
  logic [7:0] last_c;
  logic [63:0] fcs_d; // the rest of the FCS and the terminate
  logic [7:0] fcs_c;

  assign s_bytes = s_tdata;
  assign s_tready = state == DATA || state == DROP;
  assign abort = !s_tvalid || (s_tlast && s_tuser);
  assign whole = !s_tlast || widx < 4'd7; // a frame that ends before byte 56 is padded to 60
  assign crc_data = (state == PAD) ? 64'h0 : data_m;
  assign fcs = ~crc_n[n];

  always_comb begin
    n = 4'd8;
    if (s_tlast) begin
      n = 4'($countones(s_tkeep));
      if (widx == 4'd7 && n < 4'd4) begin
        n = 4'd4; // bytes 56 to 59, padded up to the minimum
      end
    end
  end

  always_comb begin
    for (int i = 0; i < 8; i++) begin
      data_m[i] = (!s_tlast || s_tkeep[i]) ? s_bytes[i] : 8'h00;
    end
  end

  for (genvar b = 1; b <= 8; b++) begin : g_crc
    crc32 #(.BYTES(b)) u_crc (.crc_in(crc_q), .data(crc_data), .crc_out(crc_n[b]));
  end

  always_comb begin
    case (n)
      4'd1: begin
        last_d = {XGMII_IDLE, XGMII_IDLE, XGMII_TERM, fcs, data_m[0]};
        last_c = 8'b1110_0000;
      end
      4'd2: begin
        last_d = {XGMII_IDLE, XGMII_TERM, fcs, data_m[1:0]};
        last_c = 8'b1100_0000;
      end
      4'd3: begin
        last_d = {XGMII_TERM, fcs, data_m[2:0]};
        last_c = 8'b1000_0000;
      end
      4'd4: begin
        last_d = {fcs, data_m[3:0]};
        last_c = 8'b0000_0000;
      end
      4'd5: begin
        last_d = {fcs[23:0], data_m[4:0]};
        last_c = 8'b0000_0000;
      end
      4'd6: begin
        last_d = {fcs[15:0], data_m[5:0]};
        last_c = 8'b0000_0000;
      end
      4'd7: begin
        last_d = {fcs[7:0], data_m[6:0]};
        last_c = 8'b0000_0000;
      end
      default: begin
        last_d = data_m;
        last_c = 8'b0000_0000;
      end
    endcase
  end

  always_comb begin
    case (rem_q)
      3'd1: begin
        fcs_d = {{6{XGMII_IDLE}}, XGMII_TERM, fcs_q[31:24]};
        fcs_c = 8'b1111_1110;
      end
      3'd2: begin
        fcs_d = {{5{XGMII_IDLE}}, XGMII_TERM, fcs_q[31:16]};
        fcs_c = 8'b1111_1100;
      end
      3'd3: begin
        fcs_d = {{4{XGMII_IDLE}}, XGMII_TERM, fcs_q[31:8]};
        fcs_c = 8'b1111_1000;
      end
      default: begin
        fcs_d = {{3{XGMII_IDLE}}, XGMII_TERM, fcs_q};
        fcs_c = 8'b1111_0000;
      end
    endcase
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
      IDLE: next_state = s_tvalid ? DATA : IDLE;
      DATA: begin
        if (abort) begin
          next_state = s_tvalid ? IPG : DROP;
        end else if (!s_tlast) begin
          next_state = DATA;
        end else if (whole) begin
          next_state = PAD;
        end else begin
          next_state = (n < 4'd4) ? IPG : ((n == 4'd4) ? TERM : FCS); // where the FCS ends
        end
      end
      PAD: next_state = (widx == 4'd7) ? TERM : PAD;
      FCS: next_state = IPG;
      TERM: next_state = IPG;
      IPG: next_state = (ipg_q == 2'd1) ? IDLE : IPG;
      DROP: next_state = (s_tvalid && s_tlast) ? IPG : DROP; // the rest of a frame that was cut short
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      crc_q <= '1;
      widx <= '0;
      fcs_q <= '0;
      rem_q <= '0;
    end else begin
      if (state == IDLE) begin
        crc_q <= '1;
        widx <= '0;
      end else if (state == DATA && !abort) begin
        crc_q <= crc_n[8];
        fcs_q <= fcs;
        rem_q <= 3'(n - 4'd4);
        if (widx != 4'd8) begin
          widx <= widx + 4'd1;
        end
      end else if (state == PAD) begin
        crc_q <= crc_n[8];
        widx <= widx + 4'd1;
      end
    end
  end

  always_ff @(posedge clk) begin // 12 bytes of gap, counting from the terminate
    if (!rst_n) begin
      ipg_q <= '0;
    end else begin
      if (state == DATA) begin
        ipg_q <= 2'd2; // terminate in lane 5 to 7, or no terminate at all
      end else if (state == FCS || state == TERM) begin
        ipg_q <= 2'd1; // terminate in lane 0 to 4
      end else if (state == IPG) begin
        ipg_q <= ipg_q - 2'd1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      xgmii_txd <= {8{XGMII_IDLE}};
      xgmii_txc <= '1;
    end else begin
      xgmii_txd <= {8{XGMII_IDLE}};
      xgmii_txc <= '1;
      if (state == IDLE && s_tvalid) begin
        xgmii_txd <= PREAMBLE;
        xgmii_txc <= 8'h01;
      end else if (state == DATA && abort) begin
        xgmii_txd <= {8{XGMII_ERROR}};
      end else if (state == DATA && whole) begin
        xgmii_txd <= data_m;
        xgmii_txc <= '0;
      end else if (state == DATA) begin
        xgmii_txd <= last_d;
        xgmii_txc <= last_c;
      end else if (state == PAD && widx != 4'd7) begin
        xgmii_txd <= '0;
        xgmii_txc <= '0;
      end else if (state == PAD) begin
        xgmii_txd <= {~crc_n[4], 32'h0}; // bytes 56 to 59 are padding, then the FCS
        xgmii_txc <= '0;
      end else if (state == FCS) begin
        xgmii_txd <= fcs_d;
        xgmii_txc <= fcs_c;
      end else if (state == TERM) begin
        xgmii_txd <= {{7{XGMII_IDLE}}, XGMII_TERM};
      end
    end
  end

endmodule
