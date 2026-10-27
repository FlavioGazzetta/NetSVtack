module uart_tx #(
  parameter int DIV = 1356 // clocks per bit
)(

  input logic clk,
  input logic rst_n,

  input logic [7:0] s_data,
  input logic s_valid,
  output logic s_ready,

  output logic txd // 8 data bits, no parity, 1 stop bit

);

  typedef enum logic {IDLE, SEND} state_t;

  state_t state;
  state_t next_state;

  logic [$clog2(DIV)-1:0] div_cnt; // clocks left of the bit on the wire
  logic [3:0] bit_cnt; // bits left of the frame
  logic [9:0] shift; // stop, data, start -> shift[0] is on the wire
  logic bit_done;

  assign s_ready = state == IDLE;
  assign bit_done = div_cnt == '0;
  assign txd = (state == SEND) ? shift[0] : 1'b1;

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
      IDLE: next_state = s_valid ? SEND : IDLE;
      SEND: next_state = (bit_done && bit_cnt == 4'd0) ? IDLE : SEND;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_cnt <= '0;
      bit_cnt <= '0;
      shift <= '1;
    end else begin
      if (state == IDLE && s_valid) begin
        div_cnt <= ($bits(div_cnt))'(DIV - 1);
        bit_cnt <= 4'd9;
        shift <= {1'b1, s_data, 1'b0};
      end else if (state == SEND && bit_done) begin
        div_cnt <= ($bits(div_cnt))'(DIV - 1);
        bit_cnt <= bit_cnt - 4'd1;
        shift <= {1'b1, shift[9:1]};
      end else if (state == SEND) begin
        div_cnt <= div_cnt - 1'b1;
      end
    end
  end

endmodule
