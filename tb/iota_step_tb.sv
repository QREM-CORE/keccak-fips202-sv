// ==========================================================
// Testbench for Keccak Iota Step (Full State Version)
// Author: Kiet Le
// ==========================================================
`timescale 1ns/1ps

import keccak_pkg::*;

module iota_step_tb();

    // DUT signals
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_i;
    logic [LANE_SIZE-1:0]                             rc_i;
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_o;

    // Instantiate DUT
    iota_step dut (
        .state_array_i    (state_i),
        .round_constant_i (rc_i),
        .state_array_o    (state_o)
    );

    // ==========================================================
    // Task: Initialize State with unique pattern
    // ==========================================================
    task automatic init_state();
        int x, y;
        for (x = 0; x < 5; x++) begin
            for (y = 0; y < 5; y++) begin
                state_i[x][y] = {56'h0, x[3:0], y[3:0]};
            end
        end
    endtask

    // ==========================================================
    // Task: Check Result
    // ==========================================================
    task automatic check_result(
        input int round_idx,
        input logic [LANE_SIZE-1:0] expected_rc
    );
        int x, y;
        int err_count = 0;
        logic [LANE_SIZE-1:0] exp_lane00;

        $display("---------------------------------------------------");
        $display("Checking Round %0d...", round_idx);

        // 1. Check Lane (0,0) Modification
        exp_lane00 = state_i[0][0] ^ expected_rc;

        if (state_o[0][0] !== exp_lane00) begin
            $error("FAIL: Lane (0,0) Mismatch!");
            $display("  Input:    0x%016h", state_i[0][0]);
            $display("  Exp RC:   0x%016h", expected_rc);
            $display("  Expected: 0x%016h", exp_lane00);
            $display("  Got:      0x%016h", state_o[0][0]);
            err_count++;
        end else begin
            $display("PASS: Lane (0,0) correctly XORed with RC.");
        end

        // 2. Check Pass-Through (All other lanes)
        for (x = 0; x < 5; x++) begin
            for (y = 0; y < 5; y++) begin
                // Skip (0,0)
                if (x == 0 && y == 0) continue;

                if (state_o[x][y] !== state_i[x][y]) begin
                    $error("FAIL: Pass-through mismatch at Lane(%0d,%0d)", x, y);
                    $display("  Input: 0x%016h", state_i[x][y]);
                    $display("  Got:   0x%016h", state_o[x][y]);
                    err_count++;
                end
            end
        end

        if (err_count == 0) $display("PASS: All lanes verified.");
        $display("---------------------------------------------------\n");
    endtask

    // ==========================================================
    // Main Test Procedure
    // ==========================================================
    initial begin
        $display("\n--- Starting Iota Step Testbench ---\n");

        // ================================
        // Test 1: Round 0
        // ================================
        init_state(); // Fill with pattern
        state_i[0][0] = 64'h0; // Clear lane 0 for easy reading
        rc_i = KECCAK_ROUND_CONSTANTS[0];
        #1;
        check_result(0, rc_i);

        // ================================
        // Test 2: Round 1 (With Data)
        // ================================
        init_state();
        state_i[0][0] = 64'hAAAAAAAAAAAAAAAA; // Test XOR logic
        rc_i = KECCAK_ROUND_CONSTANTS[1];
        #1;
        check_result(1, rc_i);

        // ================================
        // Test 3: Round 23 (Max Constant)
        // ================================
        init_state();
        state_i[0][0] = 64'h0;
        rc_i = KECCAK_ROUND_CONSTANTS[23];
        #1;
        check_result(23, rc_i);

        $display("DONE: Iota Step verification successful.");
        $finish;
    end

endmodule
