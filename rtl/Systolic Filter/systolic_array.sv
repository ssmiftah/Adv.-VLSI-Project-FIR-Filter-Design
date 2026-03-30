// =============================================================================
// Module      : systolic_array
// Description : Chain of NUM_PES transposed direct-form processing elements
//               forming a systolic FIR filter array.
//
//               Data (x[n]) is broadcast to all PEs simultaneously.
//               The cascade chain flows from right (PE[NUM_PES-1]) to left
//               (PE[0]).  PE[NUM_PES-1] has cascade_in tied to zero.
//               PE[0].cascade_out is the filter output y[n].
//
//               Coefficients are loaded via a shift chain:
//                 coeff_shift_in -> PE[0] -> PE[1] -> ... -> PE[NUM_PES-1]
//               The first coefficient shifted in ends up in PE[NUM_PES-1];
//               the last coefficient shifted in stays in PE[0].
//
// Parameters  :
//   NUM_PES      Number of processing elements       (default: 100)
//   DATA_WIDTH   Input sample width, signed           (default: 16)
//   COEFF_WIDTH  Coefficient width, signed             (default: 16)
//   ACCUM_WIDTH  Cascade / accumulator width            (default: 39)
//
// Ports :
//   clk             Clock (posedge)
//   rst_n           Asynchronous active-low reset
//   data_in         Broadcast input sample x[n]        (signed, DATA_WIDTH)
//   coeff_shift_in  Coefficient shift-chain input       (signed, COEFF_WIDTH)
//   coeff_load_en   Shift enable for coefficient chain
//   result_out      Filter output y[n] = PE[0].cascade_out (signed, ACCUM_WIDTH)
// =============================================================================

module systolic_array #(
    parameter integer NUM_PES     = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer ACCUM_WIDTH = 39
)(
    input  logic                              clk,
    input  logic                              rst_n,

    // Data path
    input  logic signed [DATA_WIDTH-1:0]      data_in,
    output logic signed [ACCUM_WIDTH-1:0]     result_out,

    // Coefficient shift chain
    input  logic signed [COEFF_WIDTH-1:0]     coeff_shift_in,
    input  logic                              coeff_load_en
);

    // =========================================================================
    // Inter-PE wiring
    // =========================================================================
    logic signed [ACCUM_WIDTH-1:0] cascade_w [0:NUM_PES];   // cascade_w[k] = PE[k].cascade_out
    logic signed [COEFF_WIDTH-1:0] coeff_chain [0:NUM_PES]; // coeff_chain[k] = PE[k-1].coeff_shift_out

    // Boundary conditions
    assign coeff_chain[0] = coeff_shift_in;          // shift chain input feeds PE[0]
    assign result_out     = cascade_w[0];            // PE[0] cascade_out is the filter output

    // =========================================================================
    // Generate PE instances
    // =========================================================================
    genvar k;
    generate
        for (k = 0; k < NUM_PES; k++) begin : gen_pe
            systolic_pe #(
                .DATA_WIDTH  (DATA_WIDTH),
                .COEFF_WIDTH (COEFF_WIDTH),
                .ACCUM_WIDTH (ACCUM_WIDTH)
            ) u_pe (
                .clk             (clk),
                .rst_n           (rst_n),
                .data_in         (data_in),
                .cascade_in      ( (k == NUM_PES-1) ? {ACCUM_WIDTH{1'b0}} : cascade_w[k+1] ),
                .cascade_out     (cascade_w[k]),
                .coeff_shift_in  (coeff_chain[k]),
                .coeff_shift_out (coeff_chain[k+1]),
                .coeff_load_en   (coeff_load_en)
            );
        end
    endgenerate

endmodule
// =============================================================================
