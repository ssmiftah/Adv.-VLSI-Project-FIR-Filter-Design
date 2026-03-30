// =============================================================================
// Module      : fir_filter_systolic
// Description : Top-level controller for the systolic-array FIR filter.
//               Connects an external coeff_rom to a systolic_array of
//               transposed direct-form processing elements.
//
//   y[n] = sum_{k=0}^{NUM_TAPS-1} h[k] * x[n-k]
//
//   Startup sequence:
//     1. S_LOAD_COEFFS — Read coefficients from ROM in reverse order
//        (h[N-1] first, h[0] last) and shift them into the PE chain.
//        After loading, PE[k] holds h[k].
//     2. S_RUN — Stream data.  The systolic array computes every cycle.
//        When data_valid is de-asserted, zero is fed to the array (treated
//        as a zero-valued sample).  A validity shift register of length
//        NUM_PES tracks pipeline latency; data_out_valid is asserted once
//        the first valid sample has propagated through all PEs.
//
//   Output scaling: same as the serial filter —
//     data_out = result[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1]
//     which is equivalent to >> (COEFF_WIDTH - 1) truncated to DATA_WIDTH.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps              (default: 100)
//   DATA_WIDTH   Input/output sample width, signed  (default: 16)
//   COEFF_WIDTH  Coefficient width, signed           (default: 16)
//   NUM_PES      Number of processing elements       (default: NUM_TAPS)
//
// Derived (do not override) :
//   ADDR_WIDTH   = $clog2(NUM_TAPS)
//   ACCUM_WIDTH  = DATA_WIDTH + COEFF_WIDTH + $clog2(NUM_TAPS)
// =============================================================================

module fir_filter_systolic #(
    parameter integer NUM_TAPS    = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer NUM_PES     = NUM_TAPS,
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
    output logic                              data_out_valid
);

    // =========================================================================
    // FSM states
    // =========================================================================
    typedef enum logic [1:0] {
        S_LOAD_COEFFS,  // Read coefficients from ROM into PE shift chain
        S_RUN            // Normal streaming operation
    } state_t;

    state_t state;

    // =========================================================================
    // Internal signals
    // =========================================================================

    // ROM interface
    logic [ADDR_WIDTH-1:0]             rom_addr;
    logic signed [COEFF_WIDTH-1:0]     rom_data;

    // Systolic array interface
    logic signed [DATA_WIDTH-1:0]      array_data_in;
    logic signed [ACCUM_WIDTH-1:0]     array_result;
    logic signed [COEFF_WIDTH-1:0]     array_coeff_shift_in;
    logic                              array_coeff_load_en;

    // Coefficient loading counter
    //   Counts from 0 to NUM_TAPS.  Address is presented at count 0..NUM_TAPS-1;
    //   ROM data is valid one cycle later (count 1..NUM_TAPS).
    logic [$clog2(NUM_TAPS+1):0]       load_cnt;

    // ROM data valid flag (1-cycle delayed from address presentation)
    logic                              rom_data_valid;

    // Validity shift register for pipeline latency tracking
    logic [NUM_PES-1:0]               valid_sr;

    // =========================================================================
    // Coefficient ROM instance
    // =========================================================================
    coeff_rom #(
        .NUM_TAPS    (NUM_TAPS),
        .COEFF_WIDTH (COEFF_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH)
    ) u_coeff_rom (
        .clk       (clk),
        .addr      (rom_addr),
        .coeff_out (rom_data)
    );

    // =========================================================================
    // Systolic array instance
    // =========================================================================
    systolic_array #(
        .NUM_PES     (NUM_PES),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH)
    ) u_systolic_array (
        .clk             (clk),
        .rst_n           (rst_n),
        .data_in         (array_data_in),
        .result_out      (array_result),
        .coeff_shift_in  (array_coeff_shift_in),
        .coeff_load_en   (array_coeff_load_en)
    );

    // =========================================================================
    // Datapath gating
    // =========================================================================

    // During S_RUN: feed data_in when valid, otherwise 0
    // During S_LOAD_COEFFS: feed 0 (array is not computing useful data)
    assign array_data_in = (state == S_RUN && data_valid) ? data_in
                                                          : {DATA_WIDTH{1'b0}};

    // Coefficient shift chain: driven during loading
    assign array_coeff_shift_in = rom_data;
    assign array_coeff_load_en  = (state == S_LOAD_COEFFS) && rom_data_valid;

    // Ready when running
    assign ready = (state == S_RUN);

    // =========================================================================
    // Output scaling (same as serial filter)
    //   result >> (COEFF_WIDTH - 1), truncated to DATA_WIDTH bits
    // =========================================================================
    assign data_out       = array_result[DATA_WIDTH + COEFF_WIDTH - 2 : COEFF_WIDTH - 1];
    assign data_out_valid = valid_sr[NUM_PES-1];

    // =========================================================================
    // Sequential logic: FSM + datapath control
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_LOAD_COEFFS;
            load_cnt       <= '0;
            rom_addr       <= '0;
            rom_data_valid <= 1'b0;
            valid_sr       <= '0;
        end else begin
            case (state)
                // -------------------------------------------------------------
                // S_LOAD_COEFFS: Read ROM in reverse order, shift into PEs
                //
                //  load_cnt | rom_addr sent | rom_data avail | coeff_load_en
                //  ---------+--------------+----------------+--------------
                //     0     |   N-1        |    (none)      |      0
                //     1     |   N-2        |   h[N-1]       |      1
                //     2     |   N-3        |   h[N-2]       |      1
                //    ...    |    ...       |     ...        |      1
                //    N-1    |     0        |    h[1]        |      1
                //     N     |   (done)     |    h[0]        |      1
                //    N+1    |              |                |   -> S_RUN
                // -------------------------------------------------------------
                S_LOAD_COEFFS: begin
                    if (load_cnt <= NUM_TAPS[$clog2(NUM_TAPS+1):0]) begin
                        // Present ROM address (reverse order) while count < NUM_TAPS
                        if (load_cnt < NUM_TAPS[$clog2(NUM_TAPS+1):0])
                            rom_addr <= ADDR_WIDTH'(NUM_TAPS - 1 - load_cnt);

                        // ROM data is valid starting from load_cnt == 1
                        rom_data_valid <= (load_cnt >= 1);

                        load_cnt <= load_cnt + 1'b1;
                    end

                    // Transition after last coefficient has been shifted in
                    if (load_cnt == ($clog2(NUM_TAPS+1)+1)'(NUM_TAPS + 1)) begin
                        rom_data_valid <= 1'b0;
                        state          <= S_RUN;
                    end
                end

                // -------------------------------------------------------------
                // S_RUN: Stream data through systolic array
                //
                //   - data_in is gated by data_valid (0 when not valid)
                //   - Validity shift register tracks pipeline latency
                //   - data_out_valid asserted after NUM_PES valid samples
                // -------------------------------------------------------------
                S_RUN: begin
                    // Shift the validity bit through the pipeline
                    valid_sr <= {valid_sr[NUM_PES-2:0], data_valid};
                end

                default: state <= S_LOAD_COEFFS;
            endcase
        end
    end

endmodule
// =============================================================================
