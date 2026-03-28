// =========================================================================
// Keccak Core HEAVY Testbench
// -------------------------------------------------------------------------
// Description:
//   A high-volume verification framework designed to process large test
//   vector files (e.g., from NIST/FIPS compliance suites).
//   It supports selective test execution via the +TEST_ID argument,
//   allowing for targeted debugging of failures detected during
//   full regression runs.
//
// Key Features:
//   - Parses vectors from "verif/vectors.txt".
//   - Implements full AXI4-Stream protocol verification (Valid/Ready).
//   - Verifies Rate-Aware control signals (Keep/Last) for both SHA3 and SHAKE.
//   - Watchdog timer prevents simulation hangs on DUT failure.
// =========================================================================
`timescale 1ns/1ps

import keccak_pkg::*;

module keccak_core_heavy_tb;

    // =====================================================================
    // 1. TB Configuration & Signals
    // =====================================================================
    localparam CLK_PERIOD = 10;

    // Safety Timeout: 500us is sufficient for standard test vectors.
    localparam time TIMEOUT_LIMIT = 500_000;

    // Derived from Package
    localparam int BYTES_PER_BEAT = DWIDTH / 8;

    logic clk;
    logic rst;

    // DUT Control
    logic                               start_i;
    keccak_mode                         keccak_mode_i;
    logic [XOF_LEN_WIDTH-1:0]           xof_len_i;
    logic                               stop_i;

    // ---------------------------------------------------------------------
    // AXI4-Stream Interfaces
    // ---------------------------------------------------------------------
    // Instantiate the interface bundles.
    // NOTE: We use DWIDTH from keccak_pkg.

    // Sink Interface (Input to Core)
    logic [DWIDTH-1:0]      s_axis_tdata;
    logic                   s_axis_tvalid;
    logic                   s_axis_tlast;
    logic [KEEP_WIDTH-1:0]  s_axis_tkeep;
    logic                   s_axis_tready;

    // Source Interface (Output from Core)
    logic [DWIDTH-1:0]      m_axis_tdata;
    logic                   m_axis_tvalid;
    logic                   m_axis_tlast;
    logic [KEEP_WIDTH-1:0]  m_axis_tkeep;
    logic                   m_axis_tready;

    // Test Vector Definition
    typedef struct {
        int        id;
        string     name;
        keccak_mode mode;
        string     msg_hex_str;
        string     exp_md_hex_str;
        int        output_len_bits;
    } test_vector_t;

    test_vector_t vectors[$];

    // =====================================================================
    // 2. DUT Instantiation
    // =====================================================================
    keccak_core dut (
        .clk            (clk),
        .rst            (rst),
        .start_i        (start_i),
        .keccak_mode_i  (keccak_mode_i),
        .xof_len_i      (xof_len_i),
        .stop_i         (stop_i),

        // Connect Sink Interface using the 'sink' modport
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tlast   (s_axis_tlast),
        .s_axis_tkeep   (s_axis_tkeep),
        .s_axis_tready  (s_axis_tready),

        // Connect Source Interface using the 'source' modport
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tready  (m_axis_tready)
    );

    // =====================================================================
    // 3. Clock & Reset
    // =====================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    task automatic reset_dut();
        rst = 1;
        start_i = 0;
        stop_i = 0;
        xof_len_i = 0;

        // Reset Sink Interface Signals
        s_axis_tvalid = 0;
        s_axis_tlast  = 0;
        s_axis_tkeep  = 0;
        s_axis_tdata  = 0;

        // Reset Source Interface Backpressure
        m_axis_tready = 0;

        @(posedge clk);
        @(posedge clk);
        rst = 0;
        @(posedge clk);
    endtask

    // =====================================================================
    // 4. Helper Functions: Hex String <-> Byte Array
    // =====================================================================

    // Helper: Char to 4-bit val
    function automatic logic [3:0] hex_char_to_val(byte c);
        if (c >= "0" && c <= "9") return c - "0";
        if (c >= "a" && c <= "f") return c - "a" + 10;
        if (c >= "A" && c <= "F") return c - "A" + 10;
        return 0;
    endfunction

    // Convert string "b1ca" -> dynamic array {0xb1, 0xca}
    function automatic void str_to_byte_array(input string s, output logic [7:0] b_arr[]);
        int len = s.len();
        int byte_len = len / 2; // Assuming even length strings
        b_arr = new[byte_len];

        for (int i = 0; i < byte_len; i++) begin
            b_arr[i] = {hex_char_to_val(s[i*2]), hex_char_to_val(s[i*2+1])};
        end
    endfunction

    // =====================================================================
    // 5. File Parsing Logic
    // =====================================================================
    initial begin
        int fd;
        string line;
        test_vector_t tv;
        int code;
        int vector_count = 0;
        string raw_mode, raw_len, raw_msg, raw_digest;

        // Open the test vector file relative to project root
        fd = $fopen("verif/vectors.txt", "r");
        if (fd == 0) begin
            $error("FATAL: Could not open verif/vectors.txt");
            $finish;
        end

        while (!$feof(fd)) begin
            code = $fgets(line, fd);
            if (code <= 0) break;

            // Skip comments (//) or short empty lines
            if (line.len() < 5 || line.substr(0,1) == "//") continue;

            // Parse Format: MODE LENGTH MSG DIGEST
            if ($sscanf(line, "%s %s %s", raw_mode, raw_len, raw_msg) == 3) begin

                // 1. Mode Parsing
                if (raw_mode == "SHA3_256") tv.mode = SHA3_256;
                else if (raw_mode == "SHA3_512") tv.mode = SHA3_512;
                else if (raw_mode == "SHAKE128") tv.mode = SHAKE128;
                else if (raw_mode == "SHAKE256") tv.mode = SHAKE256;
                else continue; // Skip unknown modes

                // 2. Length Parsing
                tv.output_len_bits = raw_len.atoi();

                // 3. Message Parsing
                if (raw_msg == "EMPTY") tv.msg_hex_str = "";
                else tv.msg_hex_str = raw_msg;

                // 4. Digest Parsing
                void'($sscanf(line, "%*s %*s %*s %s", raw_digest));
                tv.exp_md_hex_str = raw_digest;

                // Metadata
                tv.id = vector_count;
                tv.name = $sformatf("Test_%0d_%s", vector_count, raw_mode);

                vectors.push_back(tv);
                vector_count++;
            end
        end
        $fclose(fd);
        $display("Loaded %0d vectors from verif/vectors.txt", vectors.size());
    end

    // =====================================================================
    // 6. Driver Task: Drive Message
    // =====================================================================
    task automatic drive_msg(input string msg_str);
        logic [7:0] msg_bytes[];
        int total_bytes;
        int sent_bytes = 0;
        int k;

        // Convert string to bytes
        str_to_byte_array(msg_str, msg_bytes);
        total_bytes = msg_bytes.size();

        // Handle empty message case (Len=0)
        if (total_bytes == 0) begin
            @(posedge clk);
            while (!s_axis_tready) @(posedge clk);
            s_axis_tvalid <= 1;
            s_axis_tlast  <= 1;
            s_axis_tkeep  <= '0;
            s_axis_tdata  <= '0;
            @(posedge clk);
            s_axis_tvalid <= 0;
            s_axis_tlast  <= 0;
            return;
        end

        // Loop until all bytes sent
        while (sent_bytes < total_bytes) begin

            // Wait for clock edge to sample signals
            @(posedge clk);

            // Flow Control: Drive if valid is low (idle) or ready is high (accepted)
            if (!s_axis_tvalid || s_axis_tready) begin
                s_axis_tvalid <= 1;
                s_axis_tdata  <= '0;
                s_axis_tkeep  <= '0;
                s_axis_tlast  <= 0;

                // Pack up to 32 bytes (BYTES_PER_BEAT) into tdata
                for (k = 0; k < BYTES_PER_BEAT; k++) begin
                    if ((sent_bytes + k) < total_bytes) begin
                        s_axis_tdata[k*8 +: 8] <= msg_bytes[sent_bytes + k];
                        s_axis_tkeep[k]        <= 1'b1;
                    end
                end

                sent_bytes += BYTES_PER_BEAT;

                // Assert T_LAST if this is the final chunk
                if (sent_bytes >= total_bytes) begin
                    s_axis_tlast <= 1'b1;
                end

            end
        end

        // Cleanup
        @(posedge clk);
        while (!s_axis_tready) @(posedge clk); // Wait for final handshake if pending
        s_axis_tvalid <= 0;
        s_axis_tlast  <= 0;
        s_axis_tkeep  <= 0;

        // Verify tready behavior post-transaction
        #(1);
        if (s_axis_tready === 1'bx) begin
             $error("[FAIL] s_axis_tready is X (unknown) after driving message!");
        end
    endtask

    // =====================================================================
    // 7. Monitor Task: Check Response & Verify Signals
    // =====================================================================
    task automatic check_response(
        input string      test_name,
        input string      exp_hex,
        input int         out_bits,
        input keccak_mode mode,
        input int         xof_len_val
    );
        logic [7:0] collected_bytes[$];
        logic [DWIDTH-1:0] current_word;
        logic [DWIDTH/8-1:0] current_keep;

        int bytes_total_expected;
        int bytes_collected_so_far = 0;

        // Rate Tracking Variables
        int rate_bytes;
        int bytes_squeezed_from_dut_total = 0; // Tracks TOTAL bytes DUT has sent
        int bytes_in_current_rate_block;
        int bytes_remaining_in_rate_block;

        int i;
        string res_str = "";
        bit is_shake;

        // Signal verification
        logic [DWIDTH/8-1:0]            exp_keep;
        logic                           exp_last;

        // Logging helpers
        string current_msg_str = "Unknown";
        int tid;

        is_shake = (mode == SHAKE128 || mode == SHAKE256);
        bytes_total_expected = out_bits / 8;

        // Extract Input Message for Logging on Failure
        if ($sscanf(test_name, "Test_%d_%*s", tid) == 1) begin
             current_msg_str = vectors[tid].msg_hex_str;
             if (current_msg_str == "") current_msg_str = "(Empty Message)";
        end

        // Determine Rate based on Mode
        case (mode)
            SHA3_256: rate_bytes = 136; // 1088 bits
            SHA3_512: rate_bytes = 72;  // 576 bits
            SHAKE128: rate_bytes = 168; // 1344 bits
            SHAKE256: rate_bytes = 136; // 1088 bits
            default:  rate_bytes = 136;
        endcase

        m_axis_tready = 1;

        forever begin
            @(posedge clk);

            if (m_axis_tvalid && m_axis_tready) begin

                // --- 1. SIGNAL VERIFICATION ---

                // A. Determine position inside Keccak "Rate Block"
                // The DUT output pattern depends on the Rate, not on requested bytes.
                bytes_in_current_rate_block = bytes_squeezed_from_dut_total % rate_bytes;
                bytes_remaining_in_rate_block = rate_bytes - bytes_in_current_rate_block;

                // B. Calculate Expected Keep
                exp_keep = '0;

                begin
                     // It is limited by the smallest of:
                     // 1. Up to bus width (32)
                     // 2. Remaining bytes in the Hash length (bytes_remaining_total)
                     // 3. Remaining bytes in the current rate block (bytes_remaining_in_rate_block)
                     int expected_bytes_this_beat;

                     expected_bytes_this_beat = (DWIDTH/8); // Start with full 32

                     // Apply Rate Limit
                     if (bytes_remaining_in_rate_block < expected_bytes_this_beat) begin
                         expected_bytes_this_beat = bytes_remaining_in_rate_block;
                     end

                     // Apply Total Hash Length Limit (Fixed length or Bounded SHAKE)
                     if (!is_shake || (is_shake && xof_len_val > 0)) begin
                         int bytes_remaining_total = bytes_total_expected - bytes_collected_so_far;
                         if (bytes_remaining_total < expected_bytes_this_beat) begin
                             expected_bytes_this_beat = bytes_remaining_total;
                         end
                     end

                     // Build exp_keep
                     for (int b=0; b < expected_bytes_this_beat; b++) exp_keep[b] = 1'b1;
                end

                // C. Verify Keep
                if (m_axis_tkeep !== exp_keep) begin
                    $error("[%s] SIGNAL ERROR: tkeep mismatch at DUT byte offset %0d",
                           test_name, bytes_squeezed_from_dut_total);
                    $display("\tExpected Keep: %b", exp_keep);
                    $display("\tGot Keep:      %b", m_axis_tkeep);
                end

                // D. Verify Last
                if (!is_shake || (is_shake && xof_len_val > 0)) begin
                    // SHA3/Bounded XOF logic (Last asserts at extremely final beat)
                    int bytes_rem = bytes_total_expected - bytes_collected_so_far;

                    int expected_bytes_this_beat2;
                    expected_bytes_this_beat2 = (DWIDTH/8);
                    if (bytes_remaining_in_rate_block < expected_bytes_this_beat2)
                        expected_bytes_this_beat2 = bytes_remaining_in_rate_block;

                    if (bytes_rem <= expected_bytes_this_beat2) exp_last = 1; else exp_last = 0;
                    if (m_axis_tlast !== exp_last) $error("[%s] SIGNAL ERROR: tlast mismatch!", test_name);
                end else begin
                    // SHAKE logic (Last usually 0, dependent on implementation)
                    if (m_axis_tlast !== 0) $error("[%s] SIGNAL ERROR: SHAKE tlast should be 0!", test_name);
                end

                // --- 2. DATA COLLECTION ---
                current_word = m_axis_tdata;
                current_keep = m_axis_tkeep;

                for (i = 0; i < (DWIDTH/8); i++) begin
                    if (current_keep[i]) begin
                        bytes_squeezed_from_dut_total++;

                        // Only store data if test requires more
                        if (collected_bytes.size() < bytes_total_expected) begin
                            collected_bytes.push_back(current_word[i*8 +: 8]);
                            bytes_collected_so_far++;
                        end
                    end
                end

                // --- 3. TERMINATION ---
                if (collected_bytes.size() >= bytes_total_expected) begin
                    if (is_shake && xof_len_val == 0) begin
                        stop_i = 1;
                        @(posedge clk);
                        stop_i = 0;
                    end
                    break;
                end
            end
        end

        m_axis_tready = 0;

        // --- Result Reconstruction ---
        for (i = 0; i < bytes_total_expected; i++) begin
            if (i < collected_bytes.size())
                res_str = {res_str, $sformatf("%02x", collected_bytes[i])};
            else
                res_str = {res_str, "XX"};
        end

        // --- Logging ---
        if (res_str.tolower() == exp_hex.tolower()) begin
             // Success: Silent for heavy regressions
        end else begin
            $error("    [FAIL] %s", test_name);
            $display("    --------------------------------------------------");
            $display("    Input Msg: %s", current_msg_str);
            $display("    Expected:  %s", exp_hex.tolower());
            $display("    Got:       %s", res_str.tolower());
            $display("    --------------------------------------------------");
        end
    endtask

    // =====================================================================
    // 8. Main Execution
    // =====================================================================
    task automatic run_test(test_vector_t tv);
        reset_dut();

        // Fork the Test Logic vs The Watchdog Timer
        fork : test_watchdog_guard
            // Thread 1: The Test Logic
            begin
                // Setup signals before forking the driver/monitor
                @(posedge clk);
                start_i = 1;
                keccak_mode_i = tv.mode;
                xof_len_i = (tv.mode == SHAKE128 || tv.mode == SHAKE256) ? (tv.output_len_bits / 8) : 0;
                @(posedge clk);
                start_i = 0;

                // Run driver and monitor in parallel
                fork
                    drive_msg(tv.msg_hex_str);
                    check_response(tv.name, tv.exp_md_hex_str, tv.output_len_bits, tv.mode, (tv.mode == SHAKE128 || tv.mode == SHAKE256) ? (tv.output_len_bits / 8) : 0);
                join

                // Silent success indicator
            end

            // Thread 2: The Timeout Watchdog
            begin
                #(TIMEOUT_LIMIT);
                $error("[FATAL] TIMEOUT ID:%0d", tv.id); // Print ID for parser
                $error("       Simulation forced to stop this test case to save storage.");
            end
        join_any

        // Disable pending threads
        disable fork;

        #(CLK_PERIOD * 5);
    endtask

    initial begin
        int target_id = -1;

        // Allow file parsing to complete
        #1;

        // Check for Single Test Override (+TEST_ID=x)
        if ($value$plusargs("TEST_ID=%d", target_id)) begin
            $display("Running Single Test Mode: ID %0d", target_id);
            if (target_id >= 0 && target_id < vectors.size()) begin
                run_test(vectors[target_id]);
            end else begin
                $error("Invalid TEST_ID specified.");
            end
        end else begin
            // Default: Run All Tests
            $display("Running All Tests...");
            foreach(vectors[i]) begin
                run_test(vectors[i]);
            end
        end

        $display("TEST SUITE COMPLETE");
        $finish;
    end

endmodule
