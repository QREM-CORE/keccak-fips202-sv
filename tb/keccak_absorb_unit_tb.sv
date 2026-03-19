// ==========================================================
// Testbench for Keccak Absorb Module
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
    logic [DWIDTH-1:0]            carry_over_o;
    logic                         has_carry_over_o;
    logic [KEEP_WIDTH-1:0]        carry_keep_o;

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
        .bytes_absorbed_o   (bytes_absorbed_o),
        .carry_over_o       (carry_over_o),
        .has_carry_over_o   (has_carry_over_o),
        .carry_keep_o       (carry_keep_o)
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
        input logic exp_has_carry,
        input logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] exp_state,
        input logic [DWIDTH-1:0] exp_carry_data = '0,    // Default to 0
        input logic [CARRY_KEEP_WIDTH-1:0] exp_carry_keep = '0 // Default to 0 (Added Checker)
    );
        int error_count = 0;

        // 1. Check Bytes Absorbed
        if (bytes_absorbed_o !== exp_bytes_abs) begin
            $error("[%s] FAIL: Bytes Absorbed mismatch. Expected: %0d, Got: %0d",
                   test_name, exp_bytes_abs, bytes_absorbed_o);
            error_count++;
        end

        // 2. Check Carry Flag
        if (has_carry_over_o !== exp_has_carry) begin
            $error("[%s] FAIL: Carry Flag mismatch. Expected: %0b, Got: %0b",
                   test_name, exp_has_carry, has_carry_over_o);
            error_count++;
        end

        // 3. Check Carry Data (Only if flag is high, or if we expect non-zero data)
        if (exp_has_carry && (carry_over_o !== exp_carry_data)) begin
             $error("[%s] FAIL: Carry Data mismatch.\n\tExpected: %h\n\tGot:      %h",
                   test_name, exp_carry_data, carry_over_o);
            error_count++;
        end

        // 4. Check Carry Keep
        // We check this if carry flag is high, or generally if we expect a non-zero value.
        if (carry_keep_o !== exp_carry_keep) begin
             $error("[%s] FAIL: Carry Keep mismatch.\n\tExpected: %h\n\tGot:      %h",
                   test_name, exp_carry_keep, carry_keep_o);
            error_count++;
        end

        // 5. Check State Lanes
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
        msg_i = {4{64'h1111_2222_3333_4444}}; // Fill 4 lanes with pattern
        keep_i = {32{1'b1}};                  // All 32 bytes valid

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h1111_2222_3333_4444;
        expected_state[1][0] = 64'h1111_2222_3333_4444;
        expected_state[2][0] = 64'h1111_2222_3333_4444;
        expected_state[3][0] = 64'h1111_2222_3333_4444;

        check_results("TC1", 32, 0, expected_state);
        // Visual check: Lanes (0,0), (1,0), (2,0), (3,0) should be filled.
        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 2: SHA3-256 Partial Masking
        // Absorbing 32 bytes, but keep_i only enables first 8 bytes (1 lane).
        // ----------------------------------------------------------
        $display("\nTC2: SHA3-256 Partial Mask (Only 8 bytes valid)");
        bytes_absorbed_i = 32; // Starting after previous block
        msg_i = {4{64'hDEAD_BEEF_DEAD_BEEF}};
        keep_i = { {24{1'b0}}, {8{1'b1}} }; // Top 24 bytes invalid, Bottom 8 valid

        #10;

        expected_state = '0;
        expected_state[4][0] = 64'hDEAD_BEEF_DEAD_BEEF;

        // Expected: 32 + 8 = 40 bytes absorbed.
        // Logic: Should fill Lane 4 (which is x=4, y=0) and ignore lanes 5,6,7.
        check_results("TC2", 40, 0, expected_state);
        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 3: SHA3-256 "The Straddle" (Carry Over)
        // Rate = 136 bytes. We are at 128 bytes. We input 32 bytes.
        // Only 8 bytes fit. 24 bytes must carry over.
        // ----------------------------------------------------------
        $display("\nTC3: SHA3-256 Straddle Boundary (Trigger Carry Over)");
        rate_i = RATE_SHA3_256; // 1088
        bytes_absorbed_i = 128; // 16 Lanes full (0-15). Next is Lane 16 (Last one).

        // Bottom 64 bits = AAAA..., Top 192 bits = BBBB...
        msg_i = { {3{64'hBBBB_BBBB_BBBB_BBBB}}, 64'hAAAA_AAAA_AAAA_AAAA };
        keep_i = {32{1'b1}};

        #10;

        expected_state = '0;
        expected_state[1][3] = 64'hAAAA_AAAA_AAAA_AAAA; // Lane 16

        check_results("TC3", 136, 1, expected_state,
                      {64'b0, 192'hBBBB_BBBB_BBBB_BBBB_BBBB_BBBB_BBBB_BBBB_BBBB_BBBB_BBBB_BBBB},
                      24'hFFFFFF);

        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 4: SHA3-512 Mode (Smaller Rate)
        // Rate = 72 bytes (9 Lanes).
        // Let's ensure logic respects the smaller rate limit.
        // ----------------------------------------------------------
        $display("\nTC4: SHA3-512 Boundary Check");
        rate_i = RATE_SHA3_512; // 576
        bytes_absorbed_i = 64; // 8 Lanes full. Lane 8 is the last one.
        msg_i = {4{64'hCCCC_CCCC_CCCC_CCCC}};
        keep_i = {32{1'b1}};

        #10;

        expected_state = '0;
        expected_state[3][1] = 64'hCCCC_CCCC_CCCC_CCCC;

        check_results("TC4", 72, 1, expected_state,
                      {64'b0, 192'hCCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC},
                      24'hFFFFFF);

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
        msg_i = {216'h0, 40'hAA_BB_CC_DD_EE};
        keep_i = 32'b00000000_00000000_00000000_00011111; // Bottom 5 bytes valid

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h0000_00AA_BBCC_DDEE;

        // Check: 5 bytes absorbed, Carry=0, Expected State, Expected Carry Data=0, Expected Keep=0
        check_results("TC5", 5, 0, expected_state, '0, '0);
        print_state_fips(state_out);

        // ----------------------------------------------------------
        // TEST CASE 6: SHAKE128 Max Rate Boundary
        // ----------------------------------------------------------
        $display("\nTC6: SHAKE128 Max Rate (Lane 20 valid, Lane 21 cap)");
        rate_i = RATE_SHAKE512; // 1344
        bytes_absorbed_i = 160;

        // Lane 3 (Top): BAD0...
        // Lane 2:       BAD0...
        // Lane 1:       CAFE...
        // Lane 0 (Bot): 9999... (This one gets absorbed)
        msg_i = { {2{64'hBAD0_BAD0_BAD0_BAD0}}, 64'hCAFE_F00D_CAFE_F00D, 64'h9999_8888_7777_6666 };
        keep_i = {32{1'b1}};

        #10;

        expected_state = '0;
        expected_state[0][4] = 64'h9999_8888_7777_6666;

        check_results("TC6", 168, 1, expected_state,
                      {64'b0, 64'hBAD0_BAD0_BAD0_BAD0, 64'hBAD0_BAD0_BAD0_BAD0,
                      64'hCAFE_F00D_CAFE_F00D}, 24'hFFFFFF);

        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 7: SHAKE256 (Sanity Check)
        // ----------------------------------------------------------
        $display("\nTC7: SHAKE256 (Sanity Check)");
        rate_i = RATE_SHAKE256; // 1088
        bytes_absorbed_i = 0;
        msg_i = {4{64'h1234_5678_9ABC_DEF0}};
        keep_i = {32{1'b1}};

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h1234_5678_9ABC_DEF0;
        expected_state[1][0] = 64'h1234_5678_9ABC_DEF0;
        expected_state[2][0] = 64'h1234_5678_9ABC_DEF0;
        expected_state[3][0] = 64'h1234_5678_9ABC_DEF0;

        check_results("TC7", 32, 0, expected_state);
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
        msg_i = {4{64'hEEEE_EEEE_EEEE_EEEE}};
        keep_i = {32{1'b1}};

        #10;

        expected_state = '0;
        // Start index = 24 / 8 = Lane 3 (Lane(3,0))
        expected_state[3][0] = 64'hEEEE_EEEE_EEEE_EEEE; // 24-31
        expected_state[4][0] = 64'hEEEE_EEEE_EEEE_EEEE; // 32-39
        expected_state[0][1] = 64'hEEEE_EEEE_EEEE_EEEE; // 40-47
        expected_state[1][1] = 64'hEEEE_EEEE_EEEE_EEEE; // 48-55

        // Expected: 24 + 32 = 56 bytes. No carry.
        check_results("TC8", 56, 0, expected_state, '0, '0);
        print_state_fips(state_out);


        // ----------------------------------------------------------
        // TEST CASE 9: The "8-Bytes Left" Edge Case
        // Rate 136. We are at 128 bytes (Lane 16 is empty).
        // Input: 32 bytes valid.
        // Expected: 8 Bytes absorbed (fills block). 24 Bytes carried.
        // ----------------------------------------------------------
        $display("\nTC9: The '8-Byte Left' Boundary (Max Aligned Carry)");
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 128;
        state_in = '0;

        // Input 32 bytes. 8 fit. 24 carry.
        // Lower 64-bits (0xDD..) should absorb. Upper 192 bits (0xCC..) should carry.
        msg_i = { {3{64'hCCCC_CCCC_CCCC_CCCC}}, 64'hDDDD_DDDD_DDDD_DDDD };
        keep_i = {32{1'b1}};

        #10;

        expected_state = '0;
        expected_state[1][3] = 64'hDDDD_DDDD_DDDD_DDDD; // Lane 16 filled

        // Carry: The top 3 words (0xCCCC...) shifted down to position 0.
        check_results("TC9", 136, 1, expected_state,
                      {64'b0, 192'hCCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC_CCCC},
                      24'hFFFFFF);


        // ----------------------------------------------------------
        // TEST CASE 10: Garbage Data Masking
        // Input has valid data in Byte 0, but GARBAGE in Bytes 1-31.
        // Expected: Only Byte 0 is XORed. Garbage is ignored.
        // ----------------------------------------------------------
        $display("\nTC10: Garbage Data Masking");
        rate_i = RATE_SHA3_256;
        bytes_absorbed_i = 0;
        state_in = '0;

        // Msg has valid 0xAA, but then 0xFF garbage
        msg_i = { {31{8'hFF}}, 8'hAA };
        keep_i = 32'b00000000_00000000_00000000_00000001; // Only 1st byte valid

        #10;

        expected_state = '0;
        expected_state[0][0] = 64'h0000_0000_0000_00AA; // Garbage 0xFFs must NOT appear here

        check_results("TC10", 1, 0, expected_state, '0, '0);
        print_state_fips(state_out);

        $display("\n--- Testbench Complete ---");
    end

endmodule
