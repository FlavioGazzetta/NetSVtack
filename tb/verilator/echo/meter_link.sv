module meter_link (
  input logic clk,
  input logic rst_n,
  input logic loop, // the meter hears itself and not the echo side
  input logic cut, // the link from the echo side back to the meter is down
  input logic [9:0] dly, // clocks that link takes, a frame the change jumps over is lost

  output logic m_start, // a frame starts leaving the meter
  output logic b_start, // a frame starts arriving back at the meter
  output logic [63:0] back_d,

  output logic rep_valid,
  output logic [15:0] rep_min,
  output logic [15:0] rep_max,
  output logic [15:0] rep_avg,
  output logic [15:0] rep_lost,
  output logic uart_txd
);

  logic [63:0] m_txd;
  logic [7:0] m_txc;
  logic [63:0] e_txd;
  logic [7:0] e_txc;
  logic [71:0] line [1024]; // the way back, line[0] is the newest word
  logic [7:0] back_c;

  assign m_start = m_txc == 8'h01 && m_txd[7:0] == 8'hFB;
  assign b_start = back_c == 8'h01 && back_d[7:0] == 8'hFB;
  assign {back_c, back_d} = cut ? {8'hFF, {8{8'h07}}} : line[dly];

  always_ff @(posedge clk) begin
    line[0] <= loop ? {m_txc, m_txd} : {e_txc, e_txd};
    for (int i = 1; i < 1024; i++) begin
      line[i] <= line[i-1];
    end
  end

  echo_meter #(.GAP(9), .WINDOW(4), .UART_DIV(4)) u_meter (
    .clk(clk),
    .rst_n(rst_n),
    .rx_clk(clk),
    .rx_rst_n(rst_n),
    .raw(loop),
    .xgmii_rxd(back_d),
    .xgmii_rxc(back_c),
    .xgmii_txd(m_txd),
    .xgmii_txc(m_txc),
    .rep_valid(rep_valid),
    .rep_min(rep_min),
    .rep_max(rep_max),
    .rep_avg(rep_avg),
    .rep_lost(rep_lost),
    .uart_txd(uart_txd)
  );

  netsvtack_echo u_echo (
    .clk(clk),
    .rst_n(rst_n),
    .rx_clk(clk),
    .rx_rst_n(rst_n),
    .xgmii_rxd(m_txd),
    .xgmii_rxc(m_txc),
    .xgmii_txd(e_txd),
    .xgmii_txc(e_txc),
    .tcp_connected(),
    .stat_rx_good(),
    .stat_rx_bad()
  );

endmodule
