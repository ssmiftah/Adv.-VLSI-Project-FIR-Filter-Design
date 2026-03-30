// =============================================================================
// Module      : fir_filter_L3_top
// Description : Top-level wrapper for the 3-parallel reduced-complexity FIR
//               filter.  Instantiates fir_filter_L3 which contains its own
//               coefficient ROM instances internally.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps     (default: 100)
//   DATA_WIDTH   Input/output sample width  (default: 16)
//   COEFF_WIDTH  Coefficient width           (default: 16)
// =============================================================================

module fir_filter_L3_top #(
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
    // L=3 FIR filter (ROM instances are internal)
    // =========================================================================
    fir_filter_L3 #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH)
    ) u_fir_filter (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in0       (data_in0),
        .data_in1       (data_in1),
        .data_in2       (data_in2),
        .data_valid     (data_valid),
        .ready          (ready),
        .data_out0      (data_out0),
        .data_out1      (data_out1),
        .data_out2      (data_out2),
        .data_out_valid (data_out_valid)
    );

endmodule
