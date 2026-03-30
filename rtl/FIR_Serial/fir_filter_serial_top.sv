// =============================================================================
// Module      : fir_filter_serial_top
// Description : Top-level wrapper for the serial FIR filter.
//               Instantiates fir_filter_serial and coeff_rom, connecting the
//               coefficient address/data interface internally.
//
// Parameters  :
//   NUM_TAPS     Number of filter taps              (default: 100)
//   DATA_WIDTH   Input/output sample width, signed  (default: 16)
//   COEFF_WIDTH  Coefficient width, signed           (default: 16)
// =============================================================================

module fir_filter_serial_top #(
    parameter integer NUM_TAPS    = 100,
    parameter integer DATA_WIDTH  = 16,
    parameter integer COEFF_WIDTH = 16
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
    // Internal signals — coefficient ROM <-> filter
    // =========================================================================
    logic [ADDR_WIDTH-1:0]             coeff_addr;
    logic signed [COEFF_WIDTH-1:0]     coeff_data;

    // =========================================================================
    // Coefficient ROM
    // =========================================================================
    coeff_rom #(
        .NUM_TAPS    (NUM_TAPS),
        .COEFF_WIDTH (COEFF_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH)
    ) u_coeff_rom (
        .clk       (clk),
        .addr      (coeff_addr),
        .coeff_out (coeff_data)
    );

    // =========================================================================
    // Serial FIR filter
    // =========================================================================
    fir_filter_serial #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH),
        .ADDR_WIDTH  (ADDR_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH)
    ) u_fir_filter (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in        (data_in),
        .data_valid     (data_valid),
        .ready          (ready),
        .data_out       (data_out),
        .data_out_valid (data_out_valid),
        .coeff_addr     (coeff_addr),
        .coeff_data     (coeff_data)
    );

endmodule
