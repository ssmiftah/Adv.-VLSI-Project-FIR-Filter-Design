// =============================================================================
// Module      : fir_filter_pipelined_L3
// Description : Combined pipelining + reduced-complexity 3-parallel FIR filter.
//
//   Same L=3 reduced-complexity algorithm as fir_filter_L3 (6 subfilter
//   convolutions instead of 9), but with an additional pipeline register
//   between the multiplier and accumulator in each subfilter MAC.
//
// Why pipeline?
//   In the non-pipelined L=3, the critical path is:
//     ROM_read -> coeff_gate -> MULTIPLY -> ACCUMULATE  (T_mult + T_add)
//
//   By inserting a register after the multiplier, the critical path becomes:
//     max(T_mult, T_add)
//
//   This allows a significantly higher clock frequency at the cost of
//   1 extra cycle of latency per MAC phase.
//
// 3-stage MAC pipeline (per subfilter):
//   Stage 1 (Address)   : ROM addr sent, delay_line sample registered
//   Stage 2 (Multiply)  : ROM data arrives, multiply with delay sample, REGISTER product
//   Stage 3 (Accumulate): Registered product added to accumulator
//
// Pipeline timing (tap_cnt):
//   cnt | Stage 1 (addr)  | Stage 2 (mult reg) | Stage 3 (accum)
//   ----|-----------------|--------------------|-----------------
//    0  | addr[0], dr[0]  |       --           |       --
//    1  | addr[1], dr[1]  | mult_r = h[0]*d[0] |       --
//    2  | addr[2], dr[2]  | mult_r = h[1]*d[1] | acc += h[0]*d[0]
//   ... |      ...        |       ...          |      ...
//   ST-1| addr[ST-1],dr[ST-1]| mult_r=h[ST-2]*d[ST-2] | acc += ...
//    ST | (gated)         | mult_r = h[ST-1]*d[ST-1]   | acc += ...
//   ST+1|    --           |       --           | acc += h[ST-1]*d[ST-1]
//
//   MAC phase: ST + 2 cycles  (1 more than non-pipelined)
//   Total latency per 3 outputs: ceil(NUM_TAPS/3) + 3 clock cycles.
//
// Algorithm (unchanged from L=3):
//   P0 = H0*x0    P1 = H1*x1    P2 = H2*x2
//   P3 = (H0+H1)*(x0+x1)    P4 = (H1+H2)*(x1+x2)    P5 = (H0+H2)*(x0+x2)
//
//   y0[k] = P0[k] + (P4[k-1] - P1[k-1] - P2[k-1])
//   y1[k] = (P3[k] - P0[k] - P1[k]) + P2[k-1]
//   y2[k] = (P5[k] - P0[k] - P2[k]) + P1[k]
//
// Parameters  :
//   NUM_TAPS     Number of filter taps
//   DATA_WIDTH   Input/output sample width, signed
//   COEFF_WIDTH  Coefficient width, signed
// =============================================================================

module fir_filter_pipelined_L3 #(
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
    localparam integer TAP_CNT_W      = $clog2(SUBFILTER_TAPS + 2); // 0..ST+1
    localparam integer ACCUM_WIDTH    = DATA_WIDTH + COEFF_WIDTH
                                        + $clog2(NUM_TAPS) + 2;    // 41

    // Multiplier output widths
    localparam integer MULT_BASE_W    = DATA_WIDTH + COEFF_WIDTH;       // 32
    localparam integer MULT_SUM_W     = DATA_WIDTH + COEFF_WIDTH + 2;   // 34

    // =========================================================================
    // FSM
    // =========================================================================
    typedef enum logic [1:0] { S_IDLE, S_MAC, S_DONE } state_t;
    state_t state;

    // =========================================================================
    // Tap counter (shared by all 6 subfilters, 0 .. SUBFILTER_TAPS+1)
    // =========================================================================
    logic [TAP_CNT_W-1:0] tap_cnt;

    // =========================================================================
    // Delay lines — 6 total, SUBFILTER_TAPS deep
    // =========================================================================
    logic signed [DATA_WIDTH-1:0] delay_0 [0:SUBFILTER_TAPS-1];    // x0
    logic signed [DATA_WIDTH-1:0] delay_1 [0:SUBFILTER_TAPS-1];    // x1
    logic signed [DATA_WIDTH-1:0] delay_2 [0:SUBFILTER_TAPS-1];    // x2
    logic signed [DATA_WIDTH:0]   delay_3 [0:SUBFILTER_TAPS-1];    // x0 + x1
    logic signed [DATA_WIDTH:0]   delay_4 [0:SUBFILTER_TAPS-1];    // x1 + x2
    logic signed [DATA_WIDTH:0]   delay_5 [0:SUBFILTER_TAPS-1];    // x0 + x2

    // Stage 1 pipeline regs: delay samples (aligned with ROM 1-cycle latency)
    logic signed [DATA_WIDTH-1:0] dr_0, dr_1, dr_2;
    logic signed [DATA_WIDTH:0]   dr_3, dr_4, dr_5;

    // =========================================================================
    // Coefficient ROM instances
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
    // =========================================================================
    logic [ADDR_WIDTH+1:0] addr_a_calc, addr_b_calc, addr_c_calc;

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

    // Sum coefficients (COEFF_WIDTH+1 bits)
    wire signed [COEFF_WIDTH:0] h0_w = {h0[COEFF_WIDTH-1], h0};
    wire signed [COEFF_WIDTH:0] h1_w = {h1[COEFF_WIDTH-1], h1};
    wire signed [COEFF_WIDTH:0] h2_w = {h2[COEFF_WIDTH-1], h2};

    wire signed [COEFF_WIDTH:0] h01 = h0_w + h1_w;     // H0 + H1
    wire signed [COEFF_WIDTH:0] h12 = h1_w + h2_w;     // H1 + H2
    wire signed [COEFF_WIDTH:0] h02 = h0_w + h2_w;     // H0 + H2

    // =========================================================================
    // Multipliers (combinational — Stage 2 input)
    // =========================================================================
    wire signed [MULT_BASE_W-1:0] mult_0 = h0  * dr_0;
    wire signed [MULT_BASE_W-1:0] mult_1 = h1  * dr_1;
    wire signed [MULT_BASE_W-1:0] mult_2 = h2  * dr_2;
    wire signed [MULT_SUM_W-1:0]  mult_3 = h01 * dr_3;
    wire signed [MULT_SUM_W-1:0]  mult_4 = h12 * dr_4;
    wire signed [MULT_SUM_W-1:0]  mult_5 = h02 * dr_5;

    // =========================================================================
    // >>> NEW: Stage 2 pipeline registers — registered multiplier outputs <<<
    //
    // This is the key difference from fir_filter_L3:
    //   Non-pipelined:  mult (comb) -> accumulate  (critical path = T_mult + T_add)
    //   Pipelined:      mult (comb) -> mult_r (reg) -> accumulate  (max(T_mult, T_add))
    // =========================================================================
    logic signed [MULT_BASE_W-1:0] mult_r0, mult_r1, mult_r2;
    logic signed [MULT_SUM_W-1:0]  mult_r3, mult_r4, mult_r5;

    // =========================================================================
    // Accumulators — 6 subfilters
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] acc_0, acc_1, acc_2, acc_3, acc_4, acc_5;

    // =========================================================================
    // z^{-1} registers (from previous block)
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] prev_cross;  // P4[k-1] - P1[k-1] - P2[k-1]
    logic signed [ACCUM_WIDTH-1:0] prev_p2;     // P2[k-1]

    // =========================================================================
    // Post-combination (combinational, used in S_DONE)
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

    // Upper limit for tap_cnt in S_MAC (SUBFILTER_TAPS + 1)
    localparam logic [TAP_CNT_W-1:0] TAP_CNT_MAX = TAP_CNT_W'(SUBFILTER_TAPS + 1);

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
            mult_r0 <= '0;  mult_r1 <= '0;  mult_r2 <= '0;
            mult_r3 <= '0;  mult_r4 <= '0;  mult_r5 <= '0;
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
                // MAC: 6 pipelined subfilters, 3 stages each
                //
                //   Stage 1 (tap_cnt 0..ST-1):
                //       Send ROM address, register delay sample
                //
                //   Stage 2 (tap_cnt 1..ST):
                //       Multiply is combinational from ROM data + delay_r.
                //       REGISTER the product into mult_r (pipeline cut).
                //
                //   Stage 3 (tap_cnt 2..ST+1):
                //       Accumulate from registered mult_r.
                //
                //   tap_cnt runs from 0 to ST+1 (= SUBFILTER_TAPS + 1).
                // ---------------------------------------------------------
                S_MAC: begin
                    // ======= Stage 1: address + delay register =======
                    if (tap_cnt < TAP_CNT_W'(SUBFILTER_TAPS)) begin
                        dr_0 <= delay_0[tap_cnt];
                        dr_1 <= delay_1[tap_cnt];
                        dr_2 <= delay_2[tap_cnt];
                        dr_3 <= delay_3[tap_cnt];
                        dr_4 <= delay_4[tap_cnt];
                        dr_5 <= delay_5[tap_cnt];
                    end

                    // ======= Stage 2: register multiplier outputs =======
                    // mult (combinational) is valid when ROM data and delay_r
                    // are valid: tap_cnt >= 1 and tap_cnt <= SUBFILTER_TAPS.
                    if (tap_cnt >= 1 && tap_cnt <= TAP_CNT_W'(SUBFILTER_TAPS)) begin
                        mult_r0 <= mult_0;
                        mult_r1 <= mult_1;
                        mult_r2 <= mult_2;
                        mult_r3 <= mult_3;
                        mult_r4 <= mult_4;
                        mult_r5 <= mult_5;
                    end

                    // ======= Stage 3: accumulate from registered product =======
                    // mult_r is valid 1 cycle after Stage 2, i.e. tap_cnt >= 2.
                    if (tap_cnt >= 2) begin
                        acc_0 <= acc_0 + ACCUM_WIDTH'(mult_r0);
                        acc_1 <= acc_1 + ACCUM_WIDTH'(mult_r1);
                        acc_2 <= acc_2 + ACCUM_WIDTH'(mult_r2);
                        acc_3 <= acc_3 + ACCUM_WIDTH'(mult_r3);
                        acc_4 <= acc_4 + ACCUM_WIDTH'(mult_r4);
                        acc_5 <= acc_5 + ACCUM_WIDTH'(mult_r5);
                    end

                    // ======= Counter / state transition =======
                    if (tap_cnt == TAP_CNT_MAX)
                        state <= S_DONE;
                    else
                        tap_cnt <= tap_cnt + 1'b1;
                end

                // ---------------------------------------------------------
                // DONE: post-combination + output + store z^{-1}
                // ---------------------------------------------------------
                S_DONE: begin
                    data_out0 <= y0_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out1 <= y1_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out2 <= y2_comb[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
                    data_out_valid <= 1'b1;

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
