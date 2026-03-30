// =============================================================================
// Module      : fir_filter_L2
// Description : Reduced-complexity 2-parallel (L=2) FIR filter.
//
//   Instead of 4 subfilter convolutions (naive L=2), this uses the Fast FIR
//   identity to compute 2 outputs with only 3 subfilter convolutions (25%
//   fewer multiplications).
//
// Algorithm :
//   Polyphase decomposition:  H(z) = H0(z^2) + z^{-1} H1(z^2)
//     H0 = { h[0], h[2], h[4], ... }   (even-indexed coefficients)
//     H1 = { h[1], h[3], h[5], ... }   (odd-indexed coefficients)
//
//   Input streams:  x0[k] = x[2k],   x1[k] = x[2k+1]
//   Output streams: y0[k] = y[2k],   y1[k] = y[2k+1]
//
//   3 subfilter convolutions (reduced complexity):
//     F0 = H0 * x0
//     F1 = H1 * x1
//     F2 = (H0 + H1) * (x0 + x1)
//
//   Output combination:
//     y0[k] = F0[k] + F1[k-1]              (z^{-1} delay on F1)
//     y1[k] = F2[k] - F0[k] - F1[k]
//
//   Each subfilter has NUM_TAPS/2 taps and is computed serially (one MAC).
//   Total latency per 2 outputs: ceil(NUM_TAPS/2) + 2 clock cycles.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps (should be even for L=2)
//   DATA_WIDTH   Input/output sample width, signed
//   COEFF_WIDTH  Coefficient width, signed
// =============================================================================

module fir_filter_L2 #(
    parameter integer NUM_TAPS    = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // 2 parallel inputs (applied simultaneously each valid cycle)
    input  logic signed [DATA_WIDTH-1:0]      data_in0,       // x[2k]
    input  logic signed [DATA_WIDTH-1:0]      data_in1,       // x[2k+1]
    input  logic                              data_valid,
    output logic                              ready,

    // 2 parallel outputs
    output logic signed [DATA_WIDTH-1:0]      data_out0,      // y[2k]
    output logic signed [DATA_WIDTH-1:0]      data_out1,      // y[2k+1]
    output logic                              data_out_valid
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam integer SUBFILTER_TAPS = (NUM_TAPS + 1) / 2;        // ceil(N/2) = 50
    localparam integer ADDR_WIDTH     = $clog2(NUM_TAPS);           // 7
    localparam integer TAP_CNT_W      = $clog2(SUBFILTER_TAPS + 1); // bits for 0..50
    localparam integer ACCUM_WIDTH    = DATA_WIDTH + COEFF_WIDTH
                                        + $clog2(NUM_TAPS) + 2;    // 41 (guard bits)

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [1:0] { S_IDLE, S_MAC, S_DONE } state_t;
    state_t state;

    // =========================================================================
    // Tap counter (shared by all 3 subfilters)
    //   0 .. SUBFILTER_TAPS-1 : address phase
    //   1 .. SUBFILTER_TAPS   : MAC phase (1 cycle behind due to ROM latency)
    // =========================================================================
    logic [TAP_CNT_W-1:0] tap_cnt;

    // =========================================================================
    // Delay lines — one per subfilter, SUBFILTER_TAPS deep
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] delay_f0 [0:SUBFILTER_TAPS-1];   // x0
    logic signed [DATA_WIDTH-1:0] delay_f1 [0:SUBFILTER_TAPS-1];   // x1
    logic signed [DATA_WIDTH:0]   delay_f2 [0:SUBFILTER_TAPS-1];   // x0 + x1 (1 bit wider)

    // Pipeline registers: delay samples aligned with ROM 1-cycle latency
    logic signed [DATA_WIDTH-1:0] dr_f0;
    logic signed [DATA_WIDTH-1:0] dr_f1;
    logic signed [DATA_WIDTH:0]   dr_f2;

    // =========================================================================
    // Coefficient ROM instances (both store all NUM_TAPS coefficients)
    //   ROM_A reads even indices: 0, 2, 4, ...  -> H0
    //   ROM_B reads odd  indices: 1, 3, 5, ...  -> H1
    // =========================================================================
    logic [ADDR_WIDTH-1:0]         rom_a_addr, rom_b_addr;
    logic signed [COEFF_WIDTH-1:0] rom_a_data, rom_b_data;

    coeff_rom #(
        .NUM_TAPS    (NUM_TAPS),
        .COEFF_WIDTH (COEFF_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH)
    ) u_rom_a (
        .clk       (clk),
        .addr      (rom_a_addr),
        .coeff_out (rom_a_data)
    );

    coeff_rom #(
        .NUM_TAPS    (NUM_TAPS),
        .COEFF_WIDTH (COEFF_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH)
    ) u_rom_b (
        .clk       (clk),
        .addr      (rom_b_addr),
        .coeff_out (rom_b_data)
    );

    // =========================================================================
    // ROM address computation + out-of-range gating
    // =========================================================================
    logic [ADDR_WIDTH:0] addr_even, addr_odd;   // 1 extra bit for bounds check

    always_comb begin
        addr_even = (ADDR_WIDTH + 1)'(tap_cnt) << 1;           // 2 * tap_cnt
        addr_odd  = ((ADDR_WIDTH + 1)'(tap_cnt) << 1) | 1'b1;  // 2 * tap_cnt + 1

        rom_a_addr = (addr_even < NUM_TAPS) ? addr_even[ADDR_WIDTH-1:0] : '0;
        rom_b_addr = (addr_odd  < NUM_TAPS) ? addr_odd[ADDR_WIDTH-1:0]  : '0;
    end

    // =========================================================================
    // Coefficient validity — registered to match ROM 1-cycle latency
    // When an address was out of range, force the returned coefficient to 0.
    // (For even NUM_TAPS this is always valid; keeps design general.)
    // =========================================================================
    logic h0_valid_r, h1_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h0_valid_r <= 1'b0;
            h1_valid_r <= 1'b0;
        end else begin
            h0_valid_r <= (addr_even < NUM_TAPS);
            h1_valid_r <= (addr_odd  < NUM_TAPS);
        end
    end

    wire signed [COEFF_WIDTH-1:0] h0_coeff = h0_valid_r ? rom_a_data : '0;
    wire signed [COEFF_WIDTH-1:0] h1_coeff = h1_valid_r ? rom_b_data : '0;

    // H0 + H1 coefficient for F2 — sign-extend to COEFF_WIDTH+1 to avoid overflow
    wire signed [COEFF_WIDTH:0] h0_ext = {h0_coeff[COEFF_WIDTH-1], h0_coeff};
    wire signed [COEFF_WIDTH:0] h1_ext = {h1_coeff[COEFF_WIDTH-1], h1_coeff};
    wire signed [COEFF_WIDTH:0] h2_coeff = h0_ext + h1_ext;

    // =========================================================================
    // Multipliers (combinational)
    // =========================================================================
    wire signed [DATA_WIDTH+COEFF_WIDTH-1:0]  mult_f0 = h0_coeff * dr_f0;
    wire signed [DATA_WIDTH+COEFF_WIDTH-1:0]  mult_f1 = h1_coeff * dr_f1;
    wire signed [DATA_WIDTH+COEFF_WIDTH+1:0]  mult_f2 = h2_coeff * dr_f2;

    // =========================================================================
    // Accumulators
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] accum_f0, accum_f1, accum_f2;

    // z^{-1} register: stores previous block's F1 result
    logic signed [ACCUM_WIDTH-1:0] f1_prev;

    // =========================================================================
    // Post-combination (combinational, used in S_DONE)
    //   y0 = F0 + z^{-1}*F1 = accum_f0 + f1_prev
    //   y1 = F2 - F0 - F1   = accum_f2 - accum_f0 - accum_f1
    // =========================================================================
    wire signed [ACCUM_WIDTH:0] y0_comb = {accum_f0[ACCUM_WIDTH-1], accum_f0}
                                        + {f1_prev[ACCUM_WIDTH-1],  f1_prev};
    wire signed [ACCUM_WIDTH:0] y1_comb = {accum_f2[ACCUM_WIDTH-1], accum_f2}
                                        - {accum_f0[ACCUM_WIDTH-1], accum_f0}
                                        - {accum_f1[ACCUM_WIDTH-1], accum_f1};

    // =========================================================================
    // Control
    // =========================================================================
    assign ready = (state == S_IDLE);

    // =========================================================================
    // FSM + datapath
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            tap_cnt        <= '0;
            accum_f0       <= '0;
            accum_f1       <= '0;
            accum_f2       <= '0;
            f1_prev        <= '0;
            dr_f0          <= '0;
            dr_f1          <= '0;
            dr_f2          <= '0;
            data_out0      <= '0;
            data_out1      <= '0;
            data_out_valid <= 1'b0;
            for (int i = 0; i < SUBFILTER_TAPS; i++) begin
                delay_f0[i] <= '0;
                delay_f1[i] <= '0;
                delay_f2[i] <= '0;
            end
        end else begin
            data_out_valid <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                // IDLE: wait for 2 new input samples
                // ---------------------------------------------------------
                S_IDLE: begin
                    if (data_valid) begin
                        // Shift new samples into the 3 delay lines
                        delay_f0[0] <= data_in0;
                        delay_f1[0] <= data_in1;
                        delay_f2[0] <= {data_in0[DATA_WIDTH-1], data_in0}
                                     + {data_in1[DATA_WIDTH-1], data_in1};
                        for (int i = 1; i < SUBFILTER_TAPS; i++) begin
                            delay_f0[i] <= delay_f0[i-1];
                            delay_f1[i] <= delay_f1[i-1];
                            delay_f2[i] <= delay_f2[i-1];
                        end

                        tap_cnt  <= '0;
                        accum_f0 <= '0;
                        accum_f1 <= '0;
                        accum_f2 <= '0;
                        state    <= S_MAC;
                    end
                end

                // ---------------------------------------------------------
                // MAC: 3 subfilters running in parallel
                //
                // tap_cnt | addr phase         | MAC phase (1 cycle later)
                // --------|--------------------|--------------------------
                //    0    | send addr for k=0  |  (none)
                //    1    | send addr for k=1  |  accumulate k=0 products
                //   ...   |        ...         |          ...
                //   ST-1  | send addr for last |  accumulate k=ST-2
                //    ST   |    (gated)         |  accumulate k=ST-1 (last)
                // ---------------------------------------------------------
                S_MAC: begin
                    // --- Pipeline stage 1: register delay samples ---
                    if (tap_cnt < SUBFILTER_TAPS[TAP_CNT_W-1:0]) begin
                        dr_f0 <= delay_f0[tap_cnt];
                        dr_f1 <= delay_f1[tap_cnt];
                        dr_f2 <= delay_f2[tap_cnt];
                    end

                    // --- Pipeline stage 2: accumulate (from tap_cnt >= 1) ---
                    if (tap_cnt >= 1) begin
                        accum_f0 <= accum_f0 + ACCUM_WIDTH'(mult_f0);
                        accum_f1 <= accum_f1 + ACCUM_WIDTH'(mult_f1);
                        accum_f2 <= accum_f2 + ACCUM_WIDTH'(mult_f2);
                    end

                    // --- Counter / state ---
                    if (tap_cnt == SUBFILTER_TAPS[TAP_CNT_W-1:0])
                        state <= S_DONE;
                    else
                        tap_cnt <= tap_cnt + 1'b1;
                end

                // ---------------------------------------------------------
                // DONE: combine subfilter results, output, store z^{-1}
                //
                //   y0 = F0 + F1_prev    (F1_prev = 0 on first output)
                //   y1 = F2 - F0 - F1
                //
                // Output scaling: >> (COEFF_WIDTH-1), take DATA_WIDTH bits.
                // ---------------------------------------------------------
                S_DONE: begin
                    data_out0 <= y0_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out1 <= y1_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out_valid <= 1'b1;

                    // Store current F1 for next block's z^{-1} term
                    f1_prev <= accum_f1;

                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
// =============================================================================
