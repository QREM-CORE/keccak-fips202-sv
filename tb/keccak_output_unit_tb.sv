// ==========================================================
// Testbench for Keccak Squeeze Unit
// ==========================================================
`timescale 1ns/1ps

import keccak_pkg::*;

module keccak_output_unit_tb ();

    // ==========================================================
    // Parameters & Constants
    // ==========================================================
    localparam int RATE_SHA3_256 = 1088;    // 136 Bytes
    localparam int RATE_SHA3_512 = 576;     // 72  Bytes
    localparam int RATE_SHAKE128 = 1344;    // 168 Bytes

    // DUT Signals
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_i;
    logic [MODE_SEL_WIDTH-1:0]      keccak_mode_i;
    logic [RATE_WIDTH-1:0]          rate_i;
    logic [BYTE_ABSORB_WIDTH-1:0]   bytes_squeezed_i;
    logic [XOF_LEN_WIDTH-1:0]       xof_len_i;
    logic                           is_xof_fixed_len_i;
    logic [XOF_LEN_WIDTH-1:0]       total_bytes_squeezed_i;

    logic [BYTE_ABSORB_WIDTH-1:0]   bytes_squeezed_o;
    logic                           squeeze_perm_needed_o;
    logic [DWIDTH-1:0]              data_o;
    logic [DWIDTH/8-1:0]            keep_o;
    logic                           last_o;

    // Instance
    keccak_output_unit dut (
        .state_array_i          (state_i),
        .keccak_mode_i          (keccak_mode_i),
        .rate_i                 (rate_i),
        .bytes_squeezed_i       (bytes_squeezed_i),
        .xof_len_i              (xof_len_i),
        .is_xof_fixed_len_i     (is_xof_fixed_len_i),
        .total_bytes_squeezed_i (total_bytes_squeezed_i),

        .bytes_squeezed_o       (bytes_squeezed_o),
        .squeeze_perm_needed_o  (squeeze_perm_needed_o),
        .data_o                 (data_o),
        .keep_o                 (keep_o),
        .last_o                 (last_o)
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
    // Helper Task: Fill State with Linear Pattern
    // ==========================================================
    // Fills the state such that Byte 0 = 0x00, Byte 1 = 0x01...
    // This makes verifying window slicing very easy.
    task automatic init_state_linear();
        int x, y, i;
        logic [7:0] val;
        val = 0;
        for (y = 0; y < 5; y++) begin
            for (x = 0; x < 5; x++) begin
                for (i = 0; i < 8; i++) begin
                    // Byte ordering: Little Endian in the lane
                    state_i[x][y][i*8 +: 8] = val;
                    val++;
                end
            end
        end
    endtask

    // ==========================================================
    // Helper Task: Verify Results
    // ==========================================================
    task automatic check_results(
        input string test_name,
        input logic [DWIDTH-1:0]              exp_data,
        input logic [DWIDTH/8-1:0]            exp_keep,
        input logic                           exp_last,
        input logic                           exp_perm_needed
    );
        int error_count = 0;

        $display("----------------------------------------------------------------");
        $display("[%s] Checking Results...", test_name);

        // 1. Check Data
        if (data_o !== exp_data) begin
            $error("  [FAIL] Data Mismatch.");
            $display("    Expected: 0x%h", exp_data);
            $display("    Got:      0x%h", data_o);
            error_count++;
        end else begin
            $display("  [PASS] Data Matches.");
            $display("    Expected: 0x%h", exp_data);
            $display("    Got:      0x%h", data_o);
        end

        // 2. Check Keep Mask
        if (keep_o !== exp_keep) begin
            $error("  [FAIL] Keep Mask Mismatch.");
            $display("    Expected: 0x%h", exp_keep);
            $display("    Got:      0x%h", keep_o);
            error_count++;
        end else begin
            $display("  [PASS] Keep Mask Matches.");
            $display("    Expected: 0x%h", exp_keep);
            $display("    Got:      0x%h", keep_o);
        end

        // 3. Check Last Flag
        if (last_o !== exp_last) begin
            $error("  [FAIL] Last Flag Mismatch.");
            $display("    Expected: %b", exp_last);
            $display("    Got:      %b", last_o);
            error_count++;
        end else begin
            $display("  [PASS] Last Flag Matches.");
            $display("    Expected: %b", exp_last);
            $display("    Got:      %b", last_o);
        end

        // 4. Check Permutation Trigger
        if (squeeze_perm_needed_o !== exp_perm_needed) begin
            $error("  [FAIL] Perm Needed Mismatch.");
            $display("    Expected: %b", exp_perm_needed);
            $display("    Got:      %b", squeeze_perm_needed_o);
            error_count++;
        end else begin
            $display("  [PASS] Perm Needed Matches.");
            $display("    Expected: %b", exp_perm_needed);
            $display("    Got:      %b", squeeze_perm_needed_o);
        end

        if (error_count == 0) begin
            $display("[%s] ALL CHECKS PASSED.", test_name);
        end else begin
            $display("[%s] CHECKS FAILED with %0d errors.", test_name, error_count);
        end
        $display("----------------------------------------------------------------\n");
    endtask

    // ==========================================================
    // Main Test Procedure
    // ==========================================================
    logic [DWIDTH-1:0] exp_data_build;
    int i;

    initial begin
        $display("\n--- Starting Squeeze Unit Testbench ---\n");

        // Initialize State with 00, 01, 02... pattern
        init_state_linear();

        print_state_fips(state_i);

        // ----------------------------------------------------------
        // TC1: SHA3-256 (32 Bytes total) - Beat 1 of 4
        // Expected: Full 8 bytes output, LAST is LOW.
        // ----------------------------------------------------------
        $display("TC1: SHA3-256 Output Beat 1/4 (8 Bytes)");
        keccak_mode_i    = SHA3_256;
        rate_i           = RATE_SHA3_256;
        bytes_squeezed_i = 0;
        xof_len_i        = 0;
        is_xof_fixed_len_i = 0;
        total_bytes_squeezed_i = 0;
        #1;

        exp_data_build = '0;
        for(i=0; i<8; i++) exp_data_build[i*8 +: 8] = i[7:0];

        check_results("TC1", exp_data_build, 8'hFF, 1'b0, 1'b0);

        // ----------------------------------------------------------
        // TC2: SHA3-512 (64 Bytes total) - Beat 1 of 8
        // Expected: Full 8 bytes, LAST is LOW (needs 56 more).
        // ----------------------------------------------------------
        $display("\nTC2: SHA3-512 Beat 1/8");
        keccak_mode_i    = SHA3_512;
        rate_i           = RATE_SHA3_512; // 576 bits = 72 bytes
        bytes_squeezed_i = 0;
        #1;

        // Same data expectation as TC1 (Bytes 0-7)
        check_results("TC2", exp_data_build, 8'hFF, 1'b0, 1'b0);

        // ----------------------------------------------------------
        // TC3: SHA3-512 - Beat 8 of 8
        // Expected: Full 8 bytes, LAST is HIGH.
        // ----------------------------------------------------------
        $display("\nTC3: SHA3-512 Beat 8/8");
        bytes_squeezed_i = 56; // Offset by 56 bytes
        #1;

        // Expected Data: Bytes 56 to 63 (0x38 to 0x3F)
        for(i=0; i<8; i++) exp_data_build[i*8 +: 8] = (i+56);

        check_results("TC3", exp_data_build, 8'hFF, 1'b1, 1'b0);

        // ----------------------------------------------------------
        // TC4: Perfection + Permutation Trigger (SHA3-512 Boundary)
        // Rate = 72 bytes. Wait, if rate is 72, at offset 64, there are 8 left.
        // Expected: Keep mask 0xFF, Permutation Trigger HIGH.
        // ----------------------------------------------------------
        $display("\nTC4: Partial Keep + Permutation Trigger");
        keccak_mode_i    = SHA3_512;
        bytes_squeezed_i = 64;
        #1;

        // Expected Data: Bytes 64 to 71 (0x40 to 0x47)
        for(i=0; i<8; i++) exp_data_build[i*8 +: 8] = (i+64);

        // Keep Mask: All 8 bits set -> 8'hFF
        check_results("TC4", exp_data_build, 8'hFF, 1'b1, 1'b1);

        // ----------------------------------------------------------
        // TC5: SHAKE128 Infinite Stream
        // Mode = SHAKE128. Last should NEVER be high.
        // ----------------------------------------------------------
        $display("\nTC5: SHAKE128 Infinite (Last = 0)");
        keccak_mode_i    = SHAKE128;
        rate_i           = RATE_SHAKE128;
        bytes_squeezed_i = 0;
        #1;

        // Verify LAST is 0
        if (last_o !== 1'b0) begin
            $error("TC5 FAIL: SHAKE should not assert last_o");
        end else begin
            $display("TC5 PASS.");
        end

        // ----------------------------------------------------------
        // TC6: SHAKE128 Bounded Stream (End of Hash)
        // Requested XOF len is 34. Total bytes squeezed is 32.
        // This beat will squeeze the final 2 bytes.
        // Expected: Keep mask 0x03 (2 bytes), Last is HIGH.
        // ----------------------------------------------------------
        $display("\nTC6: SHAKE128 Bounded Length Reached");
        keccak_mode_i          = SHAKE128;
        rate_i                 = RATE_SHAKE128;
        bytes_squeezed_i       = 32;
        xof_len_i              = 34; // user requested 34 bytes
        is_xof_fixed_len_i     = 1;
        total_bytes_squeezed_i = 32; // we have output 32 so far
        #1;

        for(i=0; i<8; i++) exp_data_build[i*8 +: 8] = (i+32);
        check_results("TC6", exp_data_build, 8'h03, 1'b1, 1'b0);

        // ----------------------------------------------------------
        // TC7: SHAKE128 Bounded Stream (Not the End)
        // Requested XOF len is 68. Total bytes squeezed is 32.
        // This beat will output a full 8 bytes (total 40).
        // Expected: Keep mask 0xFF, Last is LOW.
        // ----------------------------------------------------------
        $display("\nTC7: SHAKE128 Bounded Length Not Reached");
        keccak_mode_i          = SHAKE128;
        rate_i                 = RATE_SHAKE128;
        bytes_squeezed_i       = 32;
        xof_len_i              = 68;
        is_xof_fixed_len_i     = 1;
        total_bytes_squeezed_i = 32;
        #1;

        for(i=0; i<8; i++) exp_data_build[i*8 +: 8] = (i+32);
        check_results("TC7", exp_data_build, 8'hFF, 1'b0, 1'b0);

        $display("\n--- Testbench Complete ---");
        $finish;
    end

endmodule
