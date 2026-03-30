// =============================================================================
// Testbench : fir_filter_systolic_tb
// Description : Verifies fir_filter_systolic_top with impulse, step, and gap tests.
// =============================================================================
`timescale 1ns / 1ps

module fir_filter_systolic_tb;

    localparam integer NUM_TAPS    = 100;
    localparam integer DATA_WIDTH  = 16;
    localparam integer COEFF_WIDTH = 16;
    localparam integer NUM_PES     = NUM_TAPS;

    // Clock & reset
    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;   // 100 MHz

    // DUT signals
    logic signed [DATA_WIDTH-1:0] data_in;
    logic                         data_valid;
    logic                         ready;
    logic signed [DATA_WIDTH-1:0] data_out;
    logic                         data_out_valid;

    fir_filter_systolic_top #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH),
        .NUM_PES     (NUM_PES)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in        (data_in),
        .data_valid     (data_valid),
        .ready          (ready),
        .data_out       (data_out),
        .data_out_valid (data_out_valid)
    );

    // Monitor
    integer out_cnt = 0;
    always @(posedge clk) begin
        if (data_out_valid) begin
            $display("[%0t] y[%0d] = %6d (0x%04h)", $time, out_cnt, data_out, data_out);
            out_cnt <= out_cnt + 1;
        end
    end

    // Test sequence
    initial begin
        rst_n      = 0;
        data_in    = 0;
        data_valid = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;

        // Wait for coefficient loading to complete
        $display("\n=== Waiting for coefficient loading ===");
        while (!ready) @(posedge clk);
        $display("[%0t] Coefficients loaded, filter ready.\n", $time);

        // --- Test 1: Impulse response ---
        $display("=== Test 1: Impulse (x[0]=16384, then zeros) ===");
        @(posedge clk);
        data_in    <= 16'sd16384;   // ~0.5 in Q1.15
        data_valid <= 1'b1;
        @(posedge clk);
        data_in    <= 16'sd0;
        // Keep streaming zeros to flush the impulse through
        repeat (NUM_PES + 10) @(posedge clk);
        data_valid <= 1'b0;

        repeat (5) @(posedge clk);

        // --- Test 2: Step response (continuous 1000 for 150 cycles) ---
        $display("\n=== Test 2: Step (x=1000 for 150 cycles) ===");
        out_cnt = 0;
        @(posedge clk);
        data_valid <= 1'b1;
        for (int i = 0; i < 150; i++) begin
            data_in <= 16'sd1000;
            @(posedge clk);
        end
        data_valid <= 1'b0;
        data_in    <= 16'sd0;

        repeat (NUM_PES + 10) @(posedge clk);

        // --- Test 3: Data with gaps ---
        $display("\n=== Test 3: Impulse with gaps in data_valid ===");
        out_cnt = 0;
        @(posedge clk);
        data_in    <= 16'sd8000;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;
        data_in    <= 16'sd0;
        repeat (3) @(posedge clk);    // 3-cycle gap
        data_valid <= 1'b1;
        data_in    <= -16'sd8000;     // negative impulse
        @(posedge clk);
        data_valid <= 1'b0;
        data_in    <= 16'sd0;
        repeat (NUM_PES + 10) @(posedge clk);

        // Done
        repeat (10) @(posedge clk);
        $display("\n=== Simulation Complete ===");
        $finish;
    end

    // Timeout
    initial begin #1_000_000; $display("TIMEOUT"); $finish; end

endmodule
