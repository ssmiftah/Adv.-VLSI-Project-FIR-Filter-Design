// =============================================================================
// Module      : fir_filter_systolic_top
// Description : Top-level wrapper for the systolic-array FIR filter.
//               Instantiates fir_filter_systolic which contains its own
//               coeff_rom and systolic_array internally.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps              (default: 100)
//   DATA_WIDTH   Input/output sample width, signed  (default: 16)
//   COEFF_WIDTH  Coefficient width, signed           (default: 16)
//   NUM_PES      Number of processing elements       (default: NUM_TAPS)
// =============================================================================

module fir_filter_systolic_top #(
    parameter integer NUM_TAPS    = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16,
    parameter integer NUM_PES     = NUM_TAPS
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
    // Derived parameters
    // =========================================================================
    localparam integer ADDR_WIDTH  = $clog2(NUM_TAPS);
    localparam integer ACCUM_WIDTH = DATA_WIDTH + COEFF_WIDTH + $clog2(NUM_TAPS);

    // =========================================================================
    // Systolic FIR filter (ROM + systolic array are internal)
    // =========================================================================
    fir_filter_systolic #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH),
        .NUM_PES     (NUM_PES),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH)
    ) u_fir_filter (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in        (data_in),
        .data_valid     (data_valid),
        .ready          (ready),
        .data_out       (data_out),
        .data_out_valid (data_out_valid)
    );

endmodule
