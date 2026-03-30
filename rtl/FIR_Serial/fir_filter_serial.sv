// =============================================================================
// Module      : fir_filter_serial
// Description : Parameterized serial (time-multiplexed) FIR filter.
//               Uses a single MAC unit to iterate through all taps sequentially.
//               Coefficients are read from an external ROM (1-cycle read latency).
//
// Architecture: Serial MAC — one multiplier, one accumulator.
//
//   y[n] = sum_{k=0}^{NUM_TAPS-1} h[k] * x[n-k]
//
//   Pipeline timing (ROM has 1-cycle registered read):
//     Cycle 0 : IDLE -> MAC. Shift in new sample. addr=0 sent to ROM.
//     Cycle 1 : h[0] and d[0] available.  Accumulate h[0]*d[0].  addr=1 sent.
//     Cycle 2 : h[1] and d[1] available.  Accumulate h[1]*d[1].  addr=2 sent.
//      ...
//     Cycle N : h[N-1]*d[N-1] accumulated.  Transition to DONE.
//     Cycle N+1: Output valid.  Back to IDLE.
//
//   Total latency per output sample: NUM_TAPS + 2 clock cycles.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps              (default: 100)
//   DATA_WIDTH   Input/output sample width, signed  (default: 16)
//   COEFF_WIDTH  Coefficient width, signed           (default: 16)
//
// Derived (do not override) :
//   ADDR_WIDTH   = $clog2(NUM_TAPS)
//   ACCUM_WIDTH  = DATA_WIDTH + COEFF_WIDTH + $clog2(NUM_TAPS)
// =============================================================================

module fir_filter_serial #(
    parameter integer NUM_TAPS    = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer ADDR_WIDTH  = $clog2(NUM_TAPS),
    parameter integer ACCUM_WIDTH = DATA_WIDTH + COEFF_WIDTH + $clog2(NUM_TAPS)
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // Input sample interface
    input  logic signed [DATA_WIDTH-1:0]      data_in,
    input  logic                              data_valid,
    output logic                              ready,

    // Output sample interface
    output logic signed [DATA_WIDTH-1:0]      data_out,
    output logic                              data_out_valid,

    // Coefficient ROM interface
    output logic [ADDR_WIDTH-1:0]             coeff_addr,
    input  logic signed [COEFF_WIDTH-1:0]     coeff_data
);

    // =========================================================================
    // FSM states
    // =========================================================================
    typedef enum logic [1:0] {
        S_IDLE,     // Waiting for a valid input sample
        S_MAC,      // Multiply-accumulate phase (NUM_TAPS + 1 cycles)
        S_DONE      // Output the result (1 cycle)
    } state_t;

    state_t state;

    // =========================================================================
    // Internal signals
    // =========================================================================

    // Delay line (shift register) — stores last NUM_TAPS input samples
    logic signed [DATA_WIDTH-1:0] delay_line [0:NUM_TAPS-1];

    // Tap counter: counts from 0 to NUM_TAPS during S_MAC
    //   0 .. NUM_TAPS-1 : address phase (drives ROM addr, registers delay sample)
    //   1 .. NUM_TAPS   : MAC phase     (ROM data valid, accumulate)
    logic [$clog2(NUM_TAPS+1)-1:0] tap_cnt;

    // Pipeline register: delay_line sample, aligned with ROM 1-cycle latency
    logic signed [DATA_WIDTH-1:0] delay_sample_r;

    // Accumulator
    logic signed [ACCUM_WIDTH-1:0] accum;

    // =========================================================================
    // Combinational: multiply & ROM address
    // =========================================================================

    // Multiplier output (combinational — input to accumulator)
    logic signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult;
    assign mult = coeff_data * delay_sample_r;

    // ROM address: gated to valid range to avoid out-of-bounds reads
    assign coeff_addr = (tap_cnt < NUM_TAPS[$clog2(NUM_TAPS+1)-1:0])
                        ? tap_cnt[ADDR_WIDTH-1:0]
                        : '0;

    // Ready to accept new data when idle
    assign ready = (state == S_IDLE);

    // =========================================================================
    // Sequential logic: FSM + datapath
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            tap_cnt        <= '0;
            accum          <= '0;
            delay_sample_r <= '0;
            data_out       <= '0;
            data_out_valid <= 1'b0;
            for (int i = 0; i < NUM_TAPS; i++)
                delay_line[i] <= '0;
        end else begin
            // Default: de-assert output valid each cycle
            data_out_valid <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                // S_IDLE: Wait for new input sample
                // ---------------------------------------------------------
                S_IDLE: begin
                    if (data_valid) begin
                        // Shift new sample into delay line
                        delay_line[0] <= data_in;
                        for (int i = 1; i < NUM_TAPS; i++)
                            delay_line[i] <= delay_line[i-1];

                        // Initialise MAC control
                        tap_cnt <= '0;
                        accum   <= '0;
                        state   <= S_MAC;
                    end
                end

                // ---------------------------------------------------------
                // S_MAC: Iterate through all taps
                //
                //  tap_cnt | ROM addr sent | ROM data avail | Accumulate
                //  --------+--------------+----------------+-----------
                //     0    |      0        |     (none)     |    no
                //     1    |      1        |     h[0]       |    yes: h[0]*d[0]
                //     2    |      2        |     h[1]       |    yes: h[1]*d[1]
                //    ...   |     ...       |      ...       |    ...
                //    N-1   |     N-1       |    h[N-2]      |    yes
                //     N    |   (gated)     |    h[N-1]      |    yes: h[N-1]*d[N-1]
                // ---------------------------------------------------------
                S_MAC: begin
                    // --- Pipeline stage 1: register delay line sample ---
                    // Only during the address phase (tap_cnt 0..NUM_TAPS-1)
                    if (tap_cnt < NUM_TAPS[$clog2(NUM_TAPS+1)-1:0])
                        delay_sample_r <= delay_line[tap_cnt];

                    // --- Pipeline stage 2: accumulate ---
                    // ROM data is valid one cycle after address was sent,
                    // i.e. starting from tap_cnt = 1.
                    if (tap_cnt >= 1)
                        accum <= accum + mult;

                    // --- Counter / state control ---
                    if (tap_cnt == NUM_TAPS[$clog2(NUM_TAPS+1)-1:0])
                        state <= S_DONE;
                    else
                        tap_cnt <= tap_cnt + 1'b1;
                end

                // ---------------------------------------------------------
                // S_DONE: Present output and return to idle
                //
                // Output scaling: the accumulator contains the result in
                // Q(INT_BITS+clog2(NUM_TAPS)).(COEFF_WIDTH-1) format.
                // We extract DATA_WIDTH bits starting from the coefficient
                // fractional-bit boundary (bit COEFF_WIDTH-1), which
                // effectively performs: output = accum >> (COEFF_WIDTH - 1)
                // truncated to DATA_WIDTH bits.
                // ---------------------------------------------------------
                S_DONE: begin
                    data_out       <= accum[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out_valid <= 1'b1;
                    state          <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
// =============================================================================
