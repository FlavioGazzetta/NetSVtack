module echo_meter #(
  parameter logic [47:0] MAC = 48'h02_00_00_00_00_02,
  parameter logic [31:0] IP = {8'd192, 8'd168, 8'd1, 8'd129},
  parameter logic [31:0] PEER_IP = {8'd192, 8'd168, 8'd1, 8'd128}, // something that echoes UDP
  parameter logic [31:0] NETMASK = {8'd255, 8'd255, 8'd255, 8'd0},
  parameter int GAP = 15, // a probe every 2^GAP clocks
  parameter int WINDOW = 12, // a report every 2^WINDOW probes
  parameter int UART_DIV = 1356 // clocks per bit, 115200 baud at 156.25 MHz
)(

  input logic clk, // 156.25 MHz
  input logic rst_n,
  input logic rx_clk,
  input logic rx_rst_n,
  input logic raw, // time any frame that comes in, for a link looped back on itself where nothing echoes

  input logic [63:0] xgmii_rxd, // on rx_clk
  input logic [7:0] xgmii_rxc,
  output logic [63:0] xgmii_txd,
  output logic [7:0] xgmii_txc,

  output logic rep_valid, // one clock, the numbers below are new
  output logic [15:0] rep_min, // clocks from the start of a probe going out to the start of its echo coming in
  output logic [15:0] rep_max,
  output logic [15:0] rep_avg, // only right when rep_lost is 0
  output logic [15:0] rep_lost, // probes that got no echo

  output logic uart_txd // each report as a line: min max avg lost, in hex

);

  localparam logic [7:0] XGMII_START = 8'hFB;
  localparam logic [15:0] PROBE_PORT = 16'd7000;
  localparam logic [15:0] ECHO_PORT = 16'd7;
  localparam logic [15:0] PROBE_LEN = 16'd18; // makes a 64 byte frame

  typedef enum logic [1:0] {IDLE, WORD0, WORD1, WORD2} state_t;

  state_t state;
  state_t next_state;

  logic [GAP-1:0] gap_cnt;
  logic tick; // time for the next probe
  logic [31:0] seq; // number of the probe that is out
  logic pending; // that probe has no echo yet

  logic [63:0] ptx_tdata; // probe -> stack
  logic [7:0] ptx_tkeep;
  logic ptx_tvalid;
  logic ptx_tready;
  logic ptx_tlast;

  logic [63:0] prx_tdata; // stack -> echo check
  logic prx_tvalid;
  logic prx_tlast;
  logic prx_tuser;
  logic prx_first; // the next word starts a datagram
  logic seq_ok; // this datagram carries seq
  logic seq_ok_q;

  logic tx_start; // a frame starts going out
  logic rx_start; // a frame starts coming in, on rx_clk
  logic rx_tgl; // flips on every rx_start
  (* ASYNC_REG = "TRUE" *) logic [2:0] rx_sync;
  logic rx_seen; // rx_start on clk
  logic [15:0] timer; // clocks since tx_start
  logic [15:0] delta; // timer at the first frame in after tx_start
  logic [1:0] rx_cnt; // frames in since tx_start
  logic first_q; // delta was taken the clock before
  logic sample; // the echo of the probe has come in whole, delta is its round trip

  logic [15:0] min_q;
  logic [15:0] max_q;
  logic [16+WINDOW-1:0] sum_q;
  logic [15:0] lost_q;
  logic [WINDOW:0] done; // probes of this window with a known end

  logic [63:0] line; // the report being printed, the next digit is on top
  logic [4:0] idx; // character of the line
  logic printing;
  logic digit; // this character is a hex digit
  logic [7:0] ch;
  logic ch_ready;

  assign tick = gap_cnt == '0 && state == IDLE;
  assign ptx_tvalid = state != IDLE;
  assign ptx_tlast = state == WORD2;
  assign ptx_tdata = (state == WORD0) ? {32'h0, seq} : 64'h0;
  assign ptx_tkeep = (state == WORD2) ? 8'h03 : 8'hFF;

  assign tx_start = xgmii_txc == 8'h01 && xgmii_txd[7:0] == XGMII_START;
  assign rx_start = (xgmii_rxc[0] && xgmii_rxd[7:0] == XGMII_START) || (xgmii_rxc[4] && xgmii_rxd[39:32] == XGMII_START);
  assign rx_seen = rx_sync[2] != rx_sync[1];
  assign seq_ok = prx_first ? prx_tdata[31:0] == seq : seq_ok_q;
  assign sample = pending && (raw ? first_q : prx_tvalid && prx_tlast && !prx_tuser && seq_ok && rx_cnt == 2'd1);

  assign digit = idx != 5'd4 && idx != 5'd9 && idx != 5'd14 && idx < 5'd19;

  always_comb begin
    if (digit) begin
      ch = (line[63:60] < 4'd10) ? 8'h30 + 8'(line[63:60]) : 8'h37 + 8'(line[63:60]);
    end else if (idx == 5'd19) begin
      ch = 8'h0D;
    end else if (idx == 5'd20) begin
      ch = 8'h0A;
    end else begin
      ch = 8'h20;
    end
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
      IDLE: next_state = tick ? WORD0 : IDLE;
      WORD0: next_state = ptx_tready ? WORD1 : WORD0;
      WORD1: next_state = ptx_tready ? WORD2 : WORD1;
      WORD2: next_state = ptx_tready ? IDLE : WORD2;
      default: next_state = IDLE;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gap_cnt <= '0;
      seq <= '0;
      pending <= 1'b0;
      prx_first <= 1'b1;
      seq_ok_q <= 1'b0;
    end else begin
      gap_cnt <= gap_cnt + 1'b1;
      if (tick) begin
        seq <= seq + 32'd1;
        pending <= 1'b1;
      end else if (sample) begin
        pending <= 1'b0;
      end
      if (prx_tvalid) begin
        prx_first <= prx_tlast;
        seq_ok_q <= seq_ok;
      end
    end
  end

  always_ff @(posedge rx_clk) begin
    if (!rx_rst_n) begin
      rx_tgl <= 1'b0;
    end else begin
      if (rx_start) begin
        rx_tgl <= !rx_tgl;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_sync <= '0;
      timer <= '0;
      delta <= '0;
      rx_cnt <= '0;
      first_q <= 1'b0;
    end else begin
      rx_sync <= {rx_sync[1:0], rx_tgl};
      first_q <= !tx_start && rx_seen && rx_cnt == 2'd0;
      if (tx_start) begin
        timer <= 16'd1;
        rx_cnt <= '0;
      end else begin
        if (timer != '1) begin
          timer <= timer + 16'd1;
        end
        if (rx_seen && rx_cnt == 2'd0) begin
          delta <= timer;
        end
        if (rx_seen && rx_cnt != 2'd3) begin
          rx_cnt <= rx_cnt + 2'd1;
        end
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      min_q <= '1;
      max_q <= '0;
      sum_q <= '0;
      lost_q <= '0;
      done <= '0;
      rep_valid <= 1'b0;
      rep_min <= '0;
      rep_max <= '0;
      rep_avg <= '0;
      rep_lost <= '0;
    end else begin
      rep_valid <= 1'b0;
      if (done[WINDOW]) begin
        rep_valid <= 1'b1;
        rep_min <= min_q;
        rep_max <= max_q;
        rep_avg <= sum_q[WINDOW +: 16];
        rep_lost <= lost_q;
        min_q <= '1;
        max_q <= '0;
        sum_q <= '0;
        lost_q <= '0;
        done <= '0;
      end else if (sample) begin
        min_q <= (delta < min_q) ? delta : min_q;
        max_q <= (delta > max_q) ? delta : max_q;
        sum_q <= sum_q + (16 + WINDOW)'(delta);
        done <= done + 1'b1;
      end else if (tick && pending) begin
        lost_q <= lost_q + 16'd1; // the probe before this one never came back
        done <= done + 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      line <= '0;
      idx <= '0;
      printing <= 1'b0;
    end else begin
      if (rep_valid) begin
        line <= {rep_min, rep_max, rep_avg, rep_lost};
        idx <= '0;
        printing <= 1'b1;
      end else if (printing && ch_ready) begin
        idx <= idx + 5'd1;
        if (digit) begin
          line <= {line[59:0], 4'h0};
        end
        if (idx == 5'd20) begin
          printing <= 1'b0;
        end
      end
    end
  end

  uart_tx #(.DIV(UART_DIV)) u_uart (
    .clk(clk),
    .rst_n(rst_n),
    .s_data(ch),
    .s_valid(printing),
    .s_ready(ch_ready),
    .txd(uart_txd)
  );

  netsvtack u_stack ( // only its UDP side is used
    .clk(clk),
    .rst_n(rst_n),
    .rx_clk(rx_clk),
    .rx_rst_n(rx_rst_n),
    .cfg_mac(MAC),
    .cfg_ip(IP),
    .cfg_gateway(PEER_IP),
    .cfg_netmask(NETMASK),
    .cfg_tcp_port(16'd0),
    .xgmii_rxd(xgmii_rxd),
    .xgmii_rxc(xgmii_rxc),
    .xgmii_txd(xgmii_txd),
    .xgmii_txc(xgmii_txc),
    .udp_rx_src_ip(),
    .udp_rx_src_port(),
    .udp_rx_dst_port(),
    .udp_rx_len(),
    .udp_rx_tdata(prx_tdata),
    .udp_rx_tkeep(),
    .udp_rx_tvalid(prx_tvalid),
    .udp_rx_tlast(prx_tlast),
    .udp_rx_tuser(prx_tuser),
    .udp_tx_dst_ip(PEER_IP),
    .udp_tx_src_port(PROBE_PORT),
    .udp_tx_dst_port(ECHO_PORT),
    .udp_tx_len(PROBE_LEN),
    .udp_tx_tdata(ptx_tdata),
    .udp_tx_tkeep(ptx_tkeep),
    .udp_tx_tvalid(ptx_tvalid),
    .udp_tx_tready(ptx_tready),
    .udp_tx_tlast(ptx_tlast),
    .udp_tx_tuser(1'b0),
    .tcp_rx_tdata(),
    .tcp_rx_tkeep(),
    .tcp_rx_tvalid(),
    .tcp_rx_tready(1'b1),
    .tcp_tx_tdata(64'h0),
    .tcp_tx_tkeep(8'h00),
    .tcp_tx_tvalid(1'b0),
    .tcp_tx_tready(),
    .tcp_connected(),
    .stat_rx_good(),
    .stat_rx_bad()
  );

endmodule
