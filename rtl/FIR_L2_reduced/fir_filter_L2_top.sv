// =============================================================================
// Module      : fir_filter_L2_top
// Description : Top-level wrapper for the 2-parallel reduced-complexity FIR
//               filter.  Instantiates fir_filter_L2 which contains its own
//               coefficient ROM instances internally.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps (should be even)  (default: 100)
//   DATA_WIDTH   Input/output sample width, signed       (default: 16)
//   COEFF_WIDTH  Coefficient width, signed                (default: 16)
// =============================================================================

module fir_filter_L2_top #(
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
    // L=2 FIR filter (ROM instances are internal)
    // =========================================================================
    fir_filter_L2 #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH)
    ) u_fir_filter (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in0       (data_in0),
        .data_in1       (data_in1),
        .data_valid     (data_valid),
        .ready          (ready),
        .data_out0      (data_out0),
        .data_out1      (data_out1),
        .data_out_valid (data_out_valid)
    );

endmodule
