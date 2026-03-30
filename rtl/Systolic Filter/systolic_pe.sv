// =============================================================================
// Module      : systolic_pe
// Description : Processing element for a transposed direct-form FIR filter
//               systolic array.
//
//               Each PE computes:
//                   cascade_out <= cascade_in + coeff_r * data_in
//
//               The multiply is combinational; the add-and-register forms the
//               pipeline stage.  Coefficients are loaded via a daisy-chained
//               shift register (coeff_shift_in -> coeff_r -> coeff_shift_out).
//
// Parameters  :
//   DATA_WIDTH   Input sample width, signed       (default: 16)
//   COEFF_WIDTH  Coefficient width, signed         (default: 16)
//   ACCUM_WIDTH  Cascade / accumulator width        (default: 39)
//
// Ports :
//   clk             Clock (posedge)
//   rst_n           Asynchronous active-low reset
//   data_in         Broadcast input sample x[n]      (signed, DATA_WIDTH)
//   cascade_in      Partial sum from right neighbor   (signed, ACCUM_WIDTH)
//   cascade_out     Partial sum to left neighbor      (signed, ACCUM_WIDTH, registered)
//   coeff_shift_in  Coefficient shift-chain input     (signed, COEFF_WIDTH)
//   coeff_shift_out Coefficient shift-chain output    (signed, COEFF_WIDTH)
//   coeff_load_en   When high, shift the coefficient register
// =============================================================================

module systolic_pe #(
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer ACCUM_WIDTH = 39
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // Data path
    input  logic signed [DATA_WIDTH-1:0]      data_in,
    input  logic signed [ACCUM_WIDTH-1:0]     cascade_in,
    output logic signed [ACCUM_WIDTH-1:0]     cascade_out,

    // Coefficient shift chain
    input  logic signed [COEFF_WIDTH-1:0]     coeff_shift_in,
    output logic signed [COEFF_WIDTH-1:0]     coeff_shift_out,
    input  logic                              coeff_load_en
);

    // =========================================================================
    // Internal coefficient register
    // =========================================================================
    logic signed [COEFF_WIDTH-1:0] coeff_r;

    // =========================================================================
    // Combinational multiply
    // =========================================================================
    logic signed [DATA_WIDTH+COEFF_WIDTH-1:0] mult;
    assign mult = coeff_r * data_in;

    // =========================================================================
    // Sequential logic
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coeff_r        <= '0;
            coeff_shift_out <= '0;
            cascade_out    <= '0;
        end else begin
            // Coefficient shift chain: load when enabled
            if (coeff_load_en) begin
                coeff_shift_out <= coeff_r;
                coeff_r         <= coeff_shift_in;
            end

            // Cascade computation: runs every cycle
            cascade_out <= cascade_in + ACCUM_WIDTH'(mult);
        end
    end

endmodule
// =============================================================================
