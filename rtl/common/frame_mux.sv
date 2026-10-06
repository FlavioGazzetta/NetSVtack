module frame_mux #(
  parameter int META = 1 // width of what travels next to each frame
)(

  input logic clk,
  input logic rst_n,

  input logic [META-1:0] s0_meta, // input 0 goes first when both have a frame
  input logic [63:0] s0_tdata,
  input logic [7:0] s0_tkeep,
  input logic s0_tvalid,
  output logic s0_tready,
  input logic s0_tlast,
  input logic s0_tuser,

  input logic [META-1:0] s1_meta,
  input logic [63:0] s1_tdata,
  input logic [7:0] s1_tkeep,
  input logic s1_tvalid,
  output logic s1_tready,
  input logic s1_tlast,
  input logic s1_tuser,

  output logic [META-1:0] m_meta,
  output logic [63:0] m_tdata,
  output logic [7:0] m_tkeep,
  output logic m_tvalid,
  input logic m_tready,
  output logic m_tlast,
  output logic m_tuser

);

  typedef enum logic [1:0] {IDLE, LOCK0, LOCK1} state_t;

  state_t state;
  state_t next_state;

  logic pick1; // input 1 has the output
  logic done; // the last word of the frame is taken

  assign pick1 = state == LOCK1 || (state == IDLE && !s0_tvalid);
  assign done = m_tvalid && m_tready && m_tlast;

  assign m_meta = pick1 ? s1_meta : s0_meta;
  assign m_tdata = pick1 ? s1_tdata : s0_tdata;
  assign m_tkeep = pick1 ? s1_tkeep : s0_tkeep;
  assign m_tvalid = pick1 ? s1_tvalid : s0_tvalid;
  assign m_tlast = pick1 ? s1_tlast : s0_tlast;
  assign m_tuser = pick1 ? s1_tuser : s0_tuser;
  assign s0_tready = !pick1 && m_tready;
  assign s1_tready = pick1 && m_tready;

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
      IDLE: next_state = (!m_tvalid || done) ? IDLE : (pick1 ? LOCK1 : LOCK0); // held from the first word on
      LOCK0: next_state = done ? IDLE : LOCK0;
      LOCK1: next_state = done ? IDLE : LOCK1;
      default: next_state = IDLE;
    endcase
  end

endmodule
