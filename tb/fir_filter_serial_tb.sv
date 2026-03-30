// =============================================================================
// Testbench : fir_filter_serial_tb
// Description : Verifies fir_filter_serial_top with impulse, step, and
//               negative impulse tests.
// =============================================================================
`timescale 1ns / 1ps

module fir_filter_serial_tb;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam integer NUM_TAPS    = 100;
    localparam integer DATA_WIDTH  = 16;
    localparam integer COEFF_WIDTH = 16;

    // =========================================================================
    // Clock & reset
    // =========================================================================
    logic clk;
    logic rst_n;

    initial clk = 0;
    always #5 clk = ~clk;   // 100 MHz

    // =========================================================================
    // DUT signals
    // =========================================================================
    logic signed [DATA_WIDTH-1:0]  data_in;
    logic                          data_valid;
    logic                          ready;
    logic signed [DATA_WIDTH-1:0]  data_out;
    logic                          data_out_valid;

    // =========================================================================
    // DUT: Serial FIR filter top (filter + ROM connected internally)
    // =========================================================================
    fir_filter_serial_top #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH)
    ) u_dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in        (data_in),
        .data_valid     (data_valid),
        .ready          (ready),
        .data_out       (data_out),
        .data_out_valid (data_out_valid)
    );

    // =========================================================================
    // Monitoring
    // =========================================================================
    integer output_count;

    initial output_count = 0;
    always @(posedge clk) begin
        if (data_out_valid) begin
            $display("[%0t] Output[%0d] = %0d (0x%04h)",
                     $time, output_count, data_out, data_out);
            output_count <= output_count + 1;
        end
    end

    // =========================================================================
    // Task: send one sample and wait for the filter to finish
    // =========================================================================
    task automatic send_sample(input logic signed [DATA_WIDTH-1:0] sample);
        // Wait until the filter is ready
        while (!ready) @(posedge clk);

        @(posedge clk);
        data_in    <= sample;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        // Wait for output
        while (!data_out_valid) @(posedge clk);
    endtask

    // =========================================================================
    // Test sequence
    // =========================================================================
    initial begin
        // --- Initialise ---
        rst_n      = 1'b0;
        data_in    = '0;
        data_valid = 1'b0;

        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // =====================================================================
        // Test 1: Impulse response
        //   Send x[0] = max positive value (scaled to ~1.0 in Q1.15 = 16384),
        //   followed by zeros.  The output sequence should reproduce the
        //   filter coefficients (scaled by the input).
        // =====================================================================
        $display("\n=== Test 1: Impulse Response ===");
        $display("Sending impulse (x=16384, then zeros)...\n");

        send_sample(16'sd16384);   // ~0.5 in Q1.15

        // Send a few zeros to see the impulse ring through
        for (int i = 0; i < 4; i++) begin
            send_sample(16'sd0);
        end

        // =====================================================================
        // Test 2: DC (step) input
        //   Send a constant value.  After NUM_TAPS samples, the output should
        //   converge to: input * sum(h[k]).  For a normalised lowpass filter
        //   with DC gain = 1, the output should approach the input value.
        // =====================================================================
        $display("\n=== Test 2: Step Response ===");
        $display("Sending constant value (x=1000) for 5 samples...\n");

        for (int i = 0; i < 5; i++) begin
            send_sample(16'sd1000);
        end

        // =====================================================================
        // Test 3: Negative impulse
        // =====================================================================
        $display("\n=== Test 3: Negative Impulse ===");
        $display("Sending impulse (x=-16384, then zero)...\n");

        send_sample(-16'sd16384);
        send_sample(16'sd0);

        // =====================================================================
        // Done
        // =====================================================================
        repeat (10) @(posedge clk);
        $display("\n=== Simulation Complete ===");
        $display("Total outputs: %0d", output_count);
        $finish;
    end

    // Timeout watchdog
    initial begin
        #500_000;
        $display("ERROR: Simulation timeout!");
        $finish;
    end

endmodule
// =============================================================================
