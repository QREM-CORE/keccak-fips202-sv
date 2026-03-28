// ==========================================================
// Testbench for Keccak Absorb Module (64-bit DWIDTH)
// ==========================================================
`timescale 1ns/1ps

import keccak_pkg::*;

module keccak_absorb_unit_tb ();

    //Parameters & Constants
    localparam int RATE_SHA3_256 = 1088;    // 136 Bytes (17 Lanes)
    localparam int RATE_SHA3_512 = 576;     // 72  Bytes (9 Lanes)
    localparam int RATE_SHAKE256 = 1088;    // 136 Bytes (17 Lanes)
    localparam int RATE_SHAKE512 = 1344;    // 168 Bytes (21 Lanes)

    // DUT signals
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_in;
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_out;

    logic [RATE_WIDTH-1:0]        rate_i;
    logic [BYTE_ABSORB_WIDTH-1:0] bytes_absorbed_i;
    logic [DWIDTH-1:0]            msg_i;
    logic [KEEP_WIDTH-1:0]        keep_i;
    logic [BYTE_ABSORB_WIDTH-1:0] bytes_absorbed_o;

    // Instance
    keccak_absorb_unit dut (
        .state_array_i      (state_in),
        .rate_i             (rate_i),
        .bytes_absorbed_i   (bytes_absorbed_i),
        .msg_i              (msg_i),
        .keep_i             (keep_i),
        .pad_en_i           (1'b0),
        .suffix_i           (8'h00),
        .state_array_o      (state_out),
        .bytes_absorbed_o   (bytes_absorbed_o)
    );

    // ==========================================================
    // Helper Task: Print State
    // ==========================================================
    task automatic print_state_fips(
        input logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state
    );
        int y, x;
        $display("Keccak state (FIPS 202 coordinates):\n");
        for (y = COL_SIZE-1; y >= 0; y--) begin
            $write("y=%0d: ", y);
            for (x = 0; x < ROW_SIZE; x++) begin
                $write("0x%016h  ", state[x][y]);
            end
            $display("");
        end
        $display($sformatf("%s%s",  "     x=0                 x=1                 ",
                                    "x=2                 x=3                 x=4\n"));
    endtask

    // ==========================================================
    // Helper Task: Verify Expected Results
    // ==========================================================
    task automatic check_results(
        input string test_name,
        input int exp_bytes_abs,
        input logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] exp_state
    );
        int error_count = 0;

        // 1. Check Bytes Absorbed
        if (bytes_absorbed_o !== exp_bytes_abs) begin
            $error("[%s] FAIL: Bytes Absorbed mismatch. Expected: %0d, Got: %0d",
                   test_name, exp_bytes_abs, bytes_absorbed_o);
            error_count++;
        end

        // 2. Check State Lanes
        for (int x = 0; x < ROW_SIZE; x++) begin
            for (int y = 0; y < COL_SIZE; y++) begin
                if (state_out[x][y] !== exp_state[x][y]) begin
                    $error("[%s] FAIL: State mismatch at [x=%0d][y=%0d].\n\tExpected: 0x%016h\n\tGot:      0x%016h",
                           test_name, x, y, exp_state[x][y], state_out[x][y]);
                    error_count++;
                end
            end
        end

        // Pass Message
        if (error_count == 0) begin
            $display("[%s] PASS: All checks match.", test_name);
        end
    endtask


    // ==========================================================
    // Main Test Procedure
    // ==========================================================

    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] expected_state;

    initial begin
        $display("\n--- Starting Keccak Absorb Testbench ---\n");

        // Initialize
        state_in = '0;
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 0;
        msg_i = '0;
        keep_i = '0;
        #10;

        // ----------------------------------------------------------
        // TEST CASE 1: SHA3-256 Clean Start
        // ----------------------------------------------------------
        $display("TC1: SHA3-256 Start (0 bytes absorbed)");
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 0;
        msg_i = 64'h1111_2222_3333_4444; // Fill 1 lane with pattern
        keep_i = 8'b1111_1111;           // All 8 bytes valid

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h1111_2222_3333_4444;

        check_results("TC1", 8, expected_state);
        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 2: SHA3-256 Partial Masking
        // Absorbing 8 bytes max, but keep_i only enables 4 bytes.
        // ----------------------------------------------------------
        $display("\nTC2: SHA3-256 Partial Mask (Only 4 bytes valid)");
        bytes_absorbed_i = 8; // Starting after previous block (Lane 1 starts here)
        msg_i = 64'hDEAD_BEEF_DEAD_BEEF;
        keep_i = 8'b0000_1111; // Bottom 4 bytes valid

        #10;

        expected_state = '0;
        expected_state[1][0] = 64'h0000_0000_DEAD_BEEF;

        // Expected: 8 + 4 = 12 bytes absorbed.
        check_results("TC2", 12, expected_state);
        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 3: SHA3-256 Boundary Reached (No Carry Over possible for DWIDTH=64)
        // Rate = 136 bytes. We are at 128 bytes. We input 8 bytes.
        // It fits exactly. State reaches 136 bytes.
        // ----------------------------------------------------------
        $display("\nTC3: SHA3-256 Boundary Reached (No Carry)");
        rate_i = RATE_SHA3_256; // 136 bytes
        bytes_absorbed_i = 128; // Lane 16 (the 17th lane) is empty.

        msg_i = 64'hAAAA_AAAA_BBBB_BBBB;
        keep_i = 8'b1111_1111; // 8 bytes valid

        #10;

        expected_state = '0;
        expected_state[1][3] = 64'hAAAA_AAAA_BBBB_BBBB; // Lane 16 (16 % 5 = 1, 16 / 5 = 3)

        check_results("TC3", 136, expected_state);

        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 4: SHA3-512 Mode (Smaller Rate)
        // Rate = 72 bytes (9 Lanes). Use boundary condition.
        // ----------------------------------------------------------
        $display("\nTC4: SHA3-512 Boundary Check");
        rate_i = RATE_SHA3_512; // 72 bytes
        bytes_absorbed_i = 64; // Lane 8 (the 9th lane) is empty.
        msg_i = 64'hCCCC_CCCC_CCCC_CCCC;
        keep_i = 8'b1111_1111; // Provide full 8 bytes.

        #10;

        expected_state = '0;
        expected_state[3][1] = 64'hCCCC_CCCC_CCCC_CCCC;

        // Fits exactly 8 bytes (since space is 72 - 64 = 8).
        check_results("TC4", 72, expected_state);

        print_state_fips(state_out);

        // ----------------------------------------------------------
        // TEST CASE 5: Partial Lane (5 bytes)
        // Absorbing 5 bytes (partial lane)
        // ----------------------------------------------------------
        $display("\nTC5: Partial Lane (5 bytes)");
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 0;
        state_in = '0;

        // Input: 0xAA, 0xBB, 0xCC, 0xDD, 0xEE (where EE is the LSB/Byte 0)
        msg_i = 64'h0000_00AA_BBCC_DDEE;
        keep_i = 8'b0001_1111; // Bottom 5 bytes valid

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h0000_00AA_BBCC_DDEE;

        // Check: 5 bytes absorbed, Carry=0, Expected State, Expected Carry Data=0, Expected Keep=0
        check_results("TC5", 5, expected_state);
        print_state_fips(state_out);

        // ----------------------------------------------------------
        // TEST CASE 6: SHAKE128 Max Rate Boundary
        // ----------------------------------------------------------
        $display("\nTC6: SHAKE128 Max Rate Edge Case");
        rate_i = RATE_SHAKE512; // 168 bytes
        bytes_absorbed_i = 160;

        // Lane 20 (21st Lane) gets absorbed.
        msg_i = 64'h9999_8888_7777_6666;
        keep_i = 8'b1111_1111;

        #10;

        expected_state = '0;
        expected_state[0][4] = 64'h9999_8888_7777_6666; // Lane 20 is x=0, y=4.

        // It fits exactly 168-160 = 8 bytes. No carry.
        check_results("TC6", 168, expected_state);

        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 7: SHAKE256 (Sanity Check)
        // ----------------------------------------------------------
        $display("\nTC7: SHAKE256 (Sanity Check)");
        rate_i = RATE_SHAKE256; // 136 bytes
        bytes_absorbed_i = 0;
        msg_i = 64'h1234_5678_9ABC_DEF0;
        keep_i = 8'b1111_1111;

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h1234_5678_9ABC_DEF0;

        check_results("TC7", 8, expected_state);
        print_state_fips(state_out);

        // ==========================================================
        // NEW TEST CASES FOR DYNAMIC CARRY
        // ==========================================================

        // ----------------------------------------------------------
        // TEST CASE 8: SHA3-256 "Drifting Boundary"
        // Cycle is mid-block. We have space.
        // ----------------------------------------------------------
        $display("\nTC8: SHA3-256 Dynamic (No Carry, Mid-Block)");
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 24;
        state_in = '0;
        msg_i = 64'hEEEE_EEEE_EEEE_EEEE;
        keep_i = 8'b1111_1111;

        #10;

        expected_state = '0;
        // Start index = 24 / 8 = Lane 3 (Lane(3,0))
        expected_state[3][0] = 64'hEEEE_EEEE_EEEE_EEEE; // 24-31

        // Expected: 24 + 8 = 32 bytes. No carry.
        check_results("TC8", 32, expected_state);
        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 9: Removed since misaligned Straddle is impossible
        // with DWIDTH=64 and AXI bus guarantees dense tkeep.
        // ----------------------------------------------------------


        // ----------------------------------------------------------
        // TEST CASE 10: Garbage Data Masking
        // Input has valid data in Byte 0, but GARBAGE in Bytes 1-7.
        // Expected: Only Byte 0 is XORed. Garbage is ignored.
        // ----------------------------------------------------------
        $display("\nTC10: Garbage Data Masking");
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 0;
        state_in = '0;

        // Msg has valid 0xAA, but then 0xFF garbage
        msg_i = { {7{8'hFF}}, 8'hAA };
        keep_i = 8'b0000_0001; // Only 1st byte valid

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h0000_0000_0000_00AA; // Garbage 0xFFs must NOT appear here

        check_results("TC10", 1, expected_state);
        print_state_fips(state_out);

        $display("\n--- Testbench Complete ---");
        $finish;
    end

endmodule
