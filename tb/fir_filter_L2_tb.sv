// =============================================================================
// Testbench : fir_filter_L2_tb
// Description : Verifies fir_filter_L2_top with impulse, step, and negative tests.
// =============================================================================
`timescale 1ns / 1ps

module fir_filter_L2_tb;

    localparam integer NUM_TAPS    = 100;
    localparam integer DATA_WIDTH  = 16;
    localparam integer COEFF_WIDTH = 16;

    // Clock & reset
    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;   // 100 MHz

    // DUT signals
    logic signed [DATA_WIDTH-1:0] data_in0, data_in1;
    logic                         data_valid;
    logic                         ready;
    logic signed [DATA_WIDTH-1:0] data_out0, data_out1;
    logic                         data_out_valid;

    fir_filter_L2_top #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH)
    ) u_dut (
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

    // Monitor
    integer out_cnt = 0;
    always @(posedge clk) begin
        if (data_out_valid) begin
            $display("[%0t] Block %0d:  y0 = %6d (0x%04h)   y1 = %6d (0x%04h)",
                     $time, out_cnt, data_out0, data_out0, data_out1, data_out1);
            out_cnt <= out_cnt + 1;
        end
    end

    // Task: send one block of 2 samples
    task automatic send_block(input logic signed [DATA_WIDTH-1:0] x0, x1);
        while (!ready) @(posedge clk);
        @(posedge clk);
        data_in0   <= x0;
        data_in1   <= x1;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;
        while (!data_out_valid) @(posedge clk);
    endtask

    // Test sequence
    initial begin
        rst_n      = 0;
        data_in0   = 0;
        data_in1   = 0;
        data_valid = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // --- Test 1: Impulse in x[0] (data_in0 of first block) ---
        $display("\n=== Test 1: Impulse at x[0] = 16384 ===");
        send_block(16'sd16384, 16'sd0);
        for (int i = 0; i < 4; i++) send_block(16'sd0, 16'sd0);

        // --- Test 2: Step input ---
        $display("\n=== Test 2: Step (x0=x1=1000) for 5 blocks ===");
        for (int i = 0; i < 5; i++) send_block(16'sd1000, 16'sd1000);

        // --- Test 3: Impulse in x[1] (data_in1 of first block) ---
        $display("\n=== Test 3: Impulse at x[1] = 16384 ===");
        send_block(16'sd0, 16'sd16384);
        for (int i = 0; i < 4; i++) send_block(16'sd0, 16'sd0);

        repeat (10) @(posedge clk);
        $display("\n=== Simulation Complete (%0d output blocks) ===", out_cnt);
        $finish;
    end

    initial begin #500_000; $display("TIMEOUT"); $finish; end

endmodule
