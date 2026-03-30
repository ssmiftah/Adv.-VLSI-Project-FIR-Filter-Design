// =============================================================================
// Testbench : fir_filter_pipelined_L3_tb
// Description : Verifies fir_filter_pipelined_L3_top and compares output against
//               the non-pipelined fir_filter_L3_top to confirm functional
//               equivalence (same outputs, just 1 extra cycle latency).
// =============================================================================
`timescale 1ns / 1ps

module fir_filter_pipelined_L3_tb;

    localparam integer NUM_TAPS    = 100;
    localparam integer DATA_WIDTH  = 16;
    localparam integer COEFF_WIDTH = 16;

    // Clock & reset
    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;   // 100 MHz

    // ----- Pipelined DUT signals -----
    logic signed [DATA_WIDTH-1:0] data_in0, data_in1, data_in2;
    logic                         data_valid;
    logic                         ready_pip;
    logic signed [DATA_WIDTH-1:0] pip_out0, pip_out1, pip_out2;
    logic                         pip_out_valid;

    fir_filter_pipelined_L3_top #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH)
    ) u_pipelined (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in0       (data_in0),
        .data_in1       (data_in1),
        .data_in2       (data_in2),
        .data_valid     (data_valid),
        .ready          (ready_pip),
        .data_out0      (pip_out0),
        .data_out1      (pip_out1),
        .data_out2      (pip_out2),
        .data_out_valid (pip_out_valid)
    );

    // ----- Non-pipelined reference DUT -----
    logic                         ready_ref;
    logic signed [DATA_WIDTH-1:0] ref_out0, ref_out1, ref_out2;
    logic                         ref_out_valid;

    fir_filter_L3_top #(
        .NUM_TAPS    (NUM_TAPS),
        .DATA_WIDTH  (DATA_WIDTH),
        .COEFF_WIDTH (COEFF_WIDTH)
    ) u_reference (
        .clk            (clk),
        .rst_n          (rst_n),
        .data_in0       (data_in0),
        .data_in1       (data_in1),
        .data_in2       (data_in2),
        .data_valid     (data_valid),
        .ready          (ready_ref),
        .data_out0      (ref_out0),
        .data_out1      (ref_out1),
        .data_out2      (ref_out2),
        .data_out_valid (ref_out_valid)
    );

    // ----- Monitor & comparison -----
    integer block_cnt = 0;
    integer mismatch  = 0;

    // Collect reference outputs in a queue for comparison
    logic signed [DATA_WIDTH-1:0] ref_q0 [$];
    logic signed [DATA_WIDTH-1:0] ref_q1 [$];
    logic signed [DATA_WIDTH-1:0] ref_q2 [$];

    always @(posedge clk) begin
        if (ref_out_valid) begin
            ref_q0.push_back(ref_out0);
            ref_q1.push_back(ref_out1);
            ref_q2.push_back(ref_out2);
        end
    end

    always @(posedge clk) begin
        if (pip_out_valid) begin
            $display("[%0t] Block %0d PIP:  y0=%6d  y1=%6d  y2=%6d",
                     $time, block_cnt, pip_out0, pip_out1, pip_out2);

            if (ref_q0.size() > 0) begin
                automatic logic signed [DATA_WIDTH-1:0] ry0 = ref_q0.pop_front();
                automatic logic signed [DATA_WIDTH-1:0] ry1 = ref_q1.pop_front();
                automatic logic signed [DATA_WIDTH-1:0] ry2 = ref_q2.pop_front();

                $display("             REF:  y0=%6d  y1=%6d  y2=%6d", ry0, ry1, ry2);

                if (pip_out0 !== ry0 || pip_out1 !== ry1 || pip_out2 !== ry2) begin
                    $display("  *** MISMATCH ***");
                    mismatch++;
                end else begin
                    $display("  MATCH");
                end
            end

            block_cnt++;
        end
    end

    // ----- Task: send one block, wait for BOTH DUTs to finish -----
    task automatic send_block(
        input logic signed [DATA_WIDTH-1:0] x0, x1, x2
    );
        // Wait until both DUTs are ready
        while (!ready_pip || !ready_ref) @(posedge clk);

        @(posedge clk);
        data_in0   <= x0;
        data_in1   <= x1;
        data_in2   <= x2;
        data_valid <= 1'b1;
        @(posedge clk);
        data_valid <= 1'b0;

        // Wait for the slower (pipelined) DUT to produce output
        while (!pip_out_valid) @(posedge clk);
    endtask

    // ----- Test sequence -----
    initial begin
        rst_n      = 0;
        data_in0   = 0;
        data_in1   = 0;
        data_in2   = 0;
        data_valid = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // --- Test 1: Impulse ---
        $display("\n=== Test 1: Impulse at x[0] = 16384 ===");
        send_block(16'sd16384, 16'sd0, 16'sd0);
        for (int i = 0; i < 4; i++) send_block(16'sd0, 16'sd0, 16'sd0);

        // --- Test 2: Step ---
        $display("\n=== Test 2: Step (all = 1000) for 5 blocks ===");
        for (int i = 0; i < 5; i++) send_block(16'sd1000, 16'sd1000, 16'sd1000);

        // --- Test 3: Alternating ---
        $display("\n=== Test 3: Alternating +8000 / -8000 ===");
        for (int i = 0; i < 4; i++)
            send_block(16'sd8000, -16'sd8000, 16'sd8000);

        // --- Summary ---
        repeat (10) @(posedge clk);
        $display("\n=== Simulation Complete ===");
        $display("Total blocks  : %0d", block_cnt);
        $display("Mismatches    : %0d", mismatch);
        if (mismatch == 0)
            $display("RESULT: PASS — pipelined output matches non-pipelined reference.");
        else
            $display("RESULT: FAIL — %0d mismatches detected!", mismatch);
        $finish;
    end

    initial begin #1_000_000; $display("TIMEOUT"); $finish; end

endmodule
