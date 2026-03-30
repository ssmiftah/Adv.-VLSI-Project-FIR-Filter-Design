// =============================================================================
// Module      : fir_filter_L3
// Description : Reduced-complexity 3-parallel (L=3) FIR filter.
//
//   Instead of 9 subfilter convolutions (naive L=3), this uses the Fast FIR
//   identity to compute 3 outputs with only 6 subfilter convolutions (33%
//   fewer multiplications).
//
// Algorithm :
//   Polyphase decomposition:
//     H(z) = H0(z^3) + z^{-1} H1(z^3) + z^{-2} H2(z^3)
//       H0 = { h[0], h[3], h[6], ... }
//       H1 = { h[1], h[4], h[7], ... }
//       H2 = { h[2], h[5], h[8], ... }
//
//   Input streams:  x0[k]=x[3k],  x1[k]=x[3k+1],  x2[k]=x[3k+2]
//   Output streams: y0[k]=y[3k],  y1[k]=y[3k+1],  y2[k]=y[3k+2]
//
//   6 subfilter convolutions (reduced complexity):
//     P0 = H0 * x0               P3 = (H0+H1) * (x0+x1)
//     P1 = H1 * x1               P4 = (H1+H2) * (x1+x2)
//     P2 = H2 * x2               P5 = (H0+H2) * (x0+x2)
//
//   Cross-products recovered via:
//     H0*x1 + H1*x0 = P3 - P0 - P1
//     H1*x2 + H2*x1 = P4 - P1 - P2
//     H0*x2 + H2*x0 = P5 - P0 - P2
//
//   Output combination (z^{-1} is one block delay):
//     y0[k] = P0[k]                  + (P4[k-1] - P1[k-1] - P2[k-1])
//     y1[k] = (P3[k] - P0[k] - P1[k]) + P2[k-1]
//     y2[k] = (P5[k] - P0[k] - P2[k]) + P1[k]
//
//   Each subfilter has ceil(NUM_TAPS/3) taps and is computed serially.
//   Total latency per 3 outputs: ceil(NUM_TAPS/3) + 2 clock cycles.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps
//   DATA_WIDTH   Input/output sample width, signed
//   COEFF_WIDTH  Coefficient width, signed
// =============================================================================

module fir_filter_L3 #(
    parameter integer NUM_TAPS    = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // 3 parallel inputs
    input  logic signed [DATA_WIDTH-1:0]      data_in0,       // x[3k]
    input  logic signed [DATA_WIDTH-1:0]      data_in1,       // x[3k+1]
    input  logic signed [DATA_WIDTH-1:0]      data_in2,       // x[3k+2]
    input  logic                              data_valid,
    output logic                              ready,

    // 3 parallel outputs
    output logic signed [DATA_WIDTH-1:0]      data_out0,      // y[3k]
    output logic signed [DATA_WIDTH-1:0]      data_out1,      // y[3k+1]
    output logic signed [DATA_WIDTH-1:0]      data_out2,      // y[3k+2]
    output logic                              data_out_valid
);

    // =========================================================================
    // Derived parameters
    // =========================================================================
    localparam integer SUBFILTER_TAPS = (NUM_TAPS + 2) / 3;        // ceil(N/3) = 34
    localparam integer ADDR_WIDTH     = $clog2(NUM_TAPS);           // 7
    localparam integer TAP_CNT_W      = $clog2(SUBFILTER_TAPS + 1); // bits for 0..34
    localparam integer ACCUM_WIDTH    = DATA_WIDTH + COEFF_WIDTH
                                        + $clog2(NUM_TAPS) + 2;    // 41

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [1:0] { S_IDLE, S_MAC, S_DONE } state_t;
    state_t state;

    // =========================================================================
    // Tap counter (shared by all 6 subfilters)
    // =========================================================================
    logic [TAP_CNT_W-1:0] tap_cnt;

    // =========================================================================
    // Delay lines — 6 total, SUBFILTER_TAPS deep
    //   Base data:   delay_0 (x0), delay_1 (x1), delay_2 (x2)
    //   Sum data:    delay_3 (x0+x1), delay_4 (x1+x2), delay_5 (x0+x2)
    // Sum data is DATA_WIDTH+1 bits to avoid overflow.
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] delay_0 [0:SUBFILTER_TAPS-1];
    logic signed [DATA_WIDTH-1:0] delay_1 [0:SUBFILTER_TAPS-1];
    logic signed [DATA_WIDTH-1:0] delay_2 [0:SUBFILTER_TAPS-1];
    logic signed [DATA_WIDTH:0]   delay_3 [0:SUBFILTER_TAPS-1];    // x0 + x1
    logic signed [DATA_WIDTH:0]   delay_4 [0:SUBFILTER_TAPS-1];    // x1 + x2
    logic signed [DATA_WIDTH:0]   delay_5 [0:SUBFILTER_TAPS-1];    // x0 + x2

    // Pipeline registers: delay samples aligned with ROM 1-cycle latency
    logic signed [DATA_WIDTH-1:0] dr_0, dr_1, dr_2;
    logic signed [DATA_WIDTH:0]   dr_3, dr_4, dr_5;

    // =========================================================================
    // Coefficient ROM instances (all store the full NUM_TAPS coefficients)
    //   ROM_A reads stride-3 at offset 0: h[0], h[3], h[6], ...  -> H0
    //   ROM_B reads stride-3 at offset 1: h[1], h[4], h[7], ...  -> H1
    //   ROM_C reads stride-3 at offset 2: h[2], h[5], h[8], ...  -> H2
    // =========================================================================
    logic [ADDR_WIDTH-1:0]         rom_a_addr, rom_b_addr, rom_c_addr;
    logic signed [COEFF_WIDTH-1:0] rom_a_data, rom_b_data, rom_c_data;

    coeff_rom #(.NUM_TAPS(NUM_TAPS), .COEFF_WIDTH(COEFF_WIDTH), .ADDR_WIDTH(ADDR_WIDTH))
    u_rom_a (.clk(clk), .addr(rom_a_addr), .coeff_out(rom_a_data));

    coeff_rom #(.NUM_TAPS(NUM_TAPS), .COEFF_WIDTH(COEFF_WIDTH), .ADDR_WIDTH(ADDR_WIDTH))
    u_rom_b (.clk(clk), .addr(rom_b_addr), .coeff_out(rom_b_data));

    coeff_rom #(.NUM_TAPS(NUM_TAPS), .COEFF_WIDTH(COEFF_WIDTH), .ADDR_WIDTH(ADDR_WIDTH))
    u_rom_c (.clk(clk), .addr(rom_c_addr), .coeff_out(rom_c_data));

    // =========================================================================
    // ROM address computation + gating
    //   addr_a = 3*tap_cnt,  addr_b = 3*tap_cnt+1,  addr_c = 3*tap_cnt+2
    //   For NUM_TAPS=100, at tap_cnt=33: addr_a=99(ok), addr_b=100(OOB), addr_c=101(OOB)
    // =========================================================================
    logic [ADDR_WIDTH+1:0] addr_a_calc, addr_b_calc, addr_c_calc;  // wide for 3*tap_cnt

    always_comb begin
        addr_a_calc = (ADDR_WIDTH + 2)'(tap_cnt) * 3;
        addr_b_calc = (ADDR_WIDTH + 2)'(tap_cnt) * 3 + 1;
        addr_c_calc = (ADDR_WIDTH + 2)'(tap_cnt) * 3 + 2;

        rom_a_addr = (addr_a_calc < NUM_TAPS) ? addr_a_calc[ADDR_WIDTH-1:0] : '0;
        rom_b_addr = (addr_b_calc < NUM_TAPS) ? addr_b_calc[ADDR_WIDTH-1:0] : '0;
        rom_c_addr = (addr_c_calc < NUM_TAPS) ? addr_c_calc[ADDR_WIDTH-1:0] : '0;
    end

    // =========================================================================
    // Coefficient validity — registered to match ROM 1-cycle latency
    // =========================================================================
    logic ha_valid_r, hb_valid_r, hc_valid_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ha_valid_r <= 1'b0;
            hb_valid_r <= 1'b0;
            hc_valid_r <= 1'b0;
        end else begin
            ha_valid_r <= (addr_a_calc < NUM_TAPS);
            hb_valid_r <= (addr_b_calc < NUM_TAPS);
            hc_valid_r <= (addr_c_calc < NUM_TAPS);
        end
    end

    // Gated base coefficients
    wire signed [COEFF_WIDTH-1:0] h0 = ha_valid_r ? rom_a_data : '0;
    wire signed [COEFF_WIDTH-1:0] h1 = hb_valid_r ? rom_b_data : '0;
    wire signed [COEFF_WIDTH-1:0] h2 = hc_valid_r ? rom_c_data : '0;

    // Sum coefficients (COEFF_WIDTH+1 bits, sign-extended before add)
    wire signed [COEFF_WIDTH:0] h0_w = {h0[COEFF_WIDTH-1], h0};
    wire signed [COEFF_WIDTH:0] h1_w = {h1[COEFF_WIDTH-1], h1};
    wire signed [COEFF_WIDTH:0] h2_w = {h2[COEFF_WIDTH-1], h2};

    wire signed [COEFF_WIDTH:0] h01 = h0_w + h1_w;     // H0 + H1  (for P3)
    wire signed [COEFF_WIDTH:0] h12 = h1_w + h2_w;     // H1 + H2  (for P4)
    wire signed [COEFF_WIDTH:0] h02 = h0_w + h2_w;     // H0 + H2  (for P5)

    // =========================================================================
    // Multipliers (combinational)
    //   Base:  DATA_WIDTH x COEFF_WIDTH
    //   Sum:  (DATA_WIDTH+1) x (COEFF_WIDTH+1)
    // =========================================================================
    wire signed [DATA_WIDTH+COEFF_WIDTH-1:0]  mult_0 = h0  * dr_0;
    wire signed [DATA_WIDTH+COEFF_WIDTH-1:0]  mult_1 = h1  * dr_1;
    wire signed [DATA_WIDTH+COEFF_WIDTH-1:0]  mult_2 = h2  * dr_2;
    wire signed [DATA_WIDTH+COEFF_WIDTH+1:0]  mult_3 = h01 * dr_3;
    wire signed [DATA_WIDTH+COEFF_WIDTH+1:0]  mult_4 = h12 * dr_4;
    wire signed [DATA_WIDTH+COEFF_WIDTH+1:0]  mult_5 = h02 * dr_5;

    // =========================================================================
    // Accumulators — 6 subfilters
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] acc_0, acc_1, acc_2, acc_3, acc_4, acc_5;

    // =========================================================================
    // z^{-1} registers (from previous block)
    //   prev_cross = P4[k-1] - P1[k-1] - P2[k-1]  (for Y0)
    //   prev_p2    = P2[k-1]                        (for Y1)
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] prev_cross;
    logic signed [ACCUM_WIDTH-1:0] prev_p2;

    // =========================================================================
    // Post-combination (combinational, used in S_DONE)
    //   y0 = P0 + prev_cross
    //   y1 = (P3 - P0 - P1) + prev_p2
    //   y2 = (P5 - P0 - P2) + P1
    // =========================================================================
    wire signed [ACCUM_WIDTH:0] y0_comb = {acc_0[ACCUM_WIDTH-1], acc_0}
                                        + {prev_cross[ACCUM_WIDTH-1], prev_cross};

    wire signed [ACCUM_WIDTH:0] y1_comb = {acc_3[ACCUM_WIDTH-1], acc_3}
                                        - {acc_0[ACCUM_WIDTH-1], acc_0}
                                        - {acc_1[ACCUM_WIDTH-1], acc_1}
                                        + {prev_p2[ACCUM_WIDTH-1], prev_p2};

    wire signed [ACCUM_WIDTH:0] y2_comb = {acc_5[ACCUM_WIDTH-1], acc_5}
                                        - {acc_0[ACCUM_WIDTH-1], acc_0}
                                        - {acc_2[ACCUM_WIDTH-1], acc_2}
                                        + {acc_1[ACCUM_WIDTH-1], acc_1};

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
            acc_0 <= '0;  acc_1 <= '0;  acc_2 <= '0;
            acc_3 <= '0;  acc_4 <= '0;  acc_5 <= '0;
            prev_cross     <= '0;
            prev_p2        <= '0;
            dr_0 <= '0;  dr_1 <= '0;  dr_2 <= '0;
            dr_3 <= '0;  dr_4 <= '0;  dr_5 <= '0;
            data_out0      <= '0;
            data_out1      <= '0;
            data_out2      <= '0;
            data_out_valid <= 1'b0;
            for (int i = 0; i < SUBFILTER_TAPS; i++) begin
                delay_0[i] <= '0;  delay_1[i] <= '0;  delay_2[i] <= '0;
                delay_3[i] <= '0;  delay_4[i] <= '0;  delay_5[i] <= '0;
            end
        end else begin
            data_out_valid <= 1'b0;

            case (state)
                // ---------------------------------------------------------
                // IDLE: wait for 3 new input samples
                // ---------------------------------------------------------
                S_IDLE: begin
                    if (data_valid) begin
                        // Pre-addition for sum data (sign-extend before add)
                        automatic logic signed [DATA_WIDTH:0] x0w, x1w, x2w;
                        x0w = {data_in0[DATA_WIDTH-1], data_in0};
                        x1w = {data_in1[DATA_WIDTH-1], data_in1};
                        x2w = {data_in2[DATA_WIDTH-1], data_in2};

                        // Shift into all 6 delay lines
                        delay_0[0] <= data_in0;
                        delay_1[0] <= data_in1;
                        delay_2[0] <= data_in2;
                        delay_3[0] <= x0w + x1w;
                        delay_4[0] <= x1w + x2w;
                        delay_5[0] <= x0w + x2w;
                        for (int i = 1; i < SUBFILTER_TAPS; i++) begin
                            delay_0[i] <= delay_0[i-1];
                            delay_1[i] <= delay_1[i-1];
                            delay_2[i] <= delay_2[i-1];
                            delay_3[i] <= delay_3[i-1];
                            delay_4[i] <= delay_4[i-1];
                            delay_5[i] <= delay_5[i-1];
                        end

                        tap_cnt <= '0;
                        acc_0 <= '0;  acc_1 <= '0;  acc_2 <= '0;
                        acc_3 <= '0;  acc_4 <= '0;  acc_5 <= '0;
                        state   <= S_MAC;
                    end
                end

                // ---------------------------------------------------------
                // MAC: 6 subfilters running in parallel, serial within each
                // ---------------------------------------------------------
                S_MAC: begin
                    // --- Pipeline stage 1: register delay samples ---
                    if (tap_cnt < SUBFILTER_TAPS[TAP_CNT_W-1:0]) begin
                        dr_0 <= delay_0[tap_cnt];
                        dr_1 <= delay_1[tap_cnt];
                        dr_2 <= delay_2[tap_cnt];
                        dr_3 <= delay_3[tap_cnt];
                        dr_4 <= delay_4[tap_cnt];
                        dr_5 <= delay_5[tap_cnt];
                    end

                    // --- Pipeline stage 2: accumulate ---
                    if (tap_cnt >= 1) begin
                        acc_0 <= acc_0 + ACCUM_WIDTH'(mult_0);
                        acc_1 <= acc_1 + ACCUM_WIDTH'(mult_1);
                        acc_2 <= acc_2 + ACCUM_WIDTH'(mult_2);
                        acc_3 <= acc_3 + ACCUM_WIDTH'(mult_3);
                        acc_4 <= acc_4 + ACCUM_WIDTH'(mult_4);
                        acc_5 <= acc_5 + ACCUM_WIDTH'(mult_5);
                    end

                    // --- Counter / state ---
                    if (tap_cnt == SUBFILTER_TAPS[TAP_CNT_W-1:0])
                        state <= S_DONE;
                    else
                        tap_cnt <= tap_cnt + 1'b1;
                end

                // ---------------------------------------------------------
                // DONE: post-combination + output + store z^{-1} registers
                //
                //   y0 = P0 + prev_cross
                //   y1 = (P3 - P0 - P1) + prev_p2
                //   y2 = (P5 - P0 - P2) + P1
                //
                //   Store for next block:
                //     prev_cross <= P4 - P1 - P2
                //     prev_p2    <= P2
                // ---------------------------------------------------------
                S_DONE: begin
                    // Output: >> (COEFF_WIDTH-1) then take DATA_WIDTH bits
                    data_out0 <= y0_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out1 <= y1_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out2 <= y2_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out_valid <= 1'b1;

                    // z^{-1} registers for next block
                    prev_cross <= acc_4 - acc_1 - acc_2;
                    prev_p2    <= acc_2;

                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
// =============================================================================
