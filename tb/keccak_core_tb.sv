// =========================================================================
// Keccak Core Testbench - Reusable Verification Framework
// Supports: SHA3-256, SHA3-512, SHAKE128, SHAKE256
// Context: DWIDTH=256, Little Endian Byte Packing
// =========================================================================
`timescale 1ns/1ps

import keccak_pkg::*;

module keccak_core_tb;

    // =====================================================================
    // 1. TB Configuration & Signals
    // =====================================================================
    localparam CLK_PERIOD = 10;

    // Watchdog timeout to prevent infinite loops from consuming storage
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
    // AXI4-Stream Interface Instantiation
    // ---------------------------------------------------------------------
    // Sink Interface (Input to Core)
    axis_if #(.DWIDTH(DWIDTH)) s_axis();

    // Source Interface (Output from Core)
    axis_if #(.DWIDTH(DWIDTH)) m_axis();

    // Test Vector Structure
    typedef struct {
        string      name;
        keccak_mode mode;            // Enum: SHA3_256, etc.
        string      msg_hex_str;     // Input Message (e.g., "b1ca...")
        string      exp_md_hex_str;  // Expected Hash
        int         output_len_bits; // Length of output to check
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

        // Connect Sink Interface (Input to DUT)
        .s_axis         (s_axis.sink),

        // Connect Source Interface (Output from DUT)
        .m_axis         (m_axis.source)
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

        // Reset Sink Interface Signals (Driver side)
        s_axis.tvalid = 0;
        s_axis.tlast  = 0;
        s_axis.tkeep  = 0;
        s_axis.tdata  = 0;

        // Reset Source Interface Ready (Monitor side)
        m_axis.tready = 0;

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
    // 5. Driver Task: Drive Message
    // =====================================================================
    task automatic drive_msg(input string msg_str);
        logic [7:0] msg_bytes[];
        int total_bytes;
        int sent_bytes = 0;
        int k;

        // Convert string to bytes
        str_to_byte_array(msg_str, msg_bytes);
        total_bytes = msg_bytes.size();

        // 1. Synchronize to clock BEFORE driving anything
        @(posedge clk);

        // Handle empty message case (Len=0)
        if (total_bytes == 0) begin
            // Wait for handshake safely using negedge sampling
            forever begin
                @(negedge clk);
                if (s_axis.tready) break;
            end

            // Drive active payload at the same NegEdge
            s_axis.tvalid <= 1;
            s_axis.tlast  <= 1;
            s_axis.tkeep  <= '0;
            s_axis.tdata  <= '0;

            // Wait for the RTL to sample the data exactly ONCE.
            @(posedge clk);

            // Transaction complete, drop valid at the following NegEdge
            @(negedge clk);
            s_axis.tvalid <= 0;
            s_axis.tlast  <= 0;
            s_axis.tkeep  <= 0;
            return;
        end

        // Main loop for >0 bytes
        while (sent_bytes < total_bytes) begin
            int bytes_to_send;
            int bytes_remaining = total_bytes - sent_bytes;
            bytes_to_send = (bytes_remaining > BYTES_PER_BEAT) ? BYTES_PER_BEAT : bytes_remaining;

            // Wait for SLAVE to be ready BEFORE driving this beat
            forever begin
                @(negedge clk);
                if (s_axis.tready) break;
            end

            // Drive beat at the same NegEdge
            s_axis.tvalid <= 1;
            s_axis.tlast  <= (bytes_remaining <= BYTES_PER_BEAT) ? 1'b1 : 1'b0;
            s_axis.tkeep  <= '0;
            s_axis.tdata  <= '0;

            for (k = 0; k < bytes_to_send; k++) begin
                s_axis.tdata[k*8 +: 8] <= msg_bytes[sent_bytes + k];
                s_axis.tkeep[k]        <= 1'b1;
            end

            // Wait for the RTL to sample the data exactly ONCE.
            @(posedge clk);

            sent_bytes += bytes_to_send;
        end

        // Drop signals safely after all beats are done
        @(negedge clk);
        s_axis.tvalid <= 0;
        s_axis.tlast  <= 0;
        s_axis.tkeep  <= 0;
    endtask

    // =====================================================================
    // 6. Monitor Task: Check Response & Verify Signals
    // =====================================================================
    /**
     * Reconstructs the hash from the AXI4-Stream Source interface,
     * compares it against the NIST expected vector, logs the result,
     * AND verifies that output control signals (keep, last) are correct.
     */
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

        is_shake = (mode == SHAKE128 || mode == SHAKE256);
        bytes_total_expected = out_bits / 8;

        // 1. Determine Rate based on Mode
        case (mode)
            SHA3_256: rate_bytes = 136; // 1088 bits
            SHA3_512: rate_bytes = 72;  // 576 bits
            SHAKE128: rate_bytes = 168; // 1344 bits
            SHAKE256: rate_bytes = 136; // 1088 bits
            default:  rate_bytes = 136;
        endcase

        m_axis.tready = 1;
        $display("[%s] Monitor: Waiting for %0d bytes...", test_name, bytes_total_expected);

        forever begin
            @(posedge clk);

            // Use interface signals for monitoring
            if (m_axis.tvalid && m_axis.tready) begin

                // --- 1. SIGNAL VERIFICATION ---
                // A. Determine where we are inside the Keccak "Rate Block"
                // The DUT output pattern depends on the Rate, not on how many bytes the test requested.
                bytes_in_current_rate_block = bytes_squeezed_from_dut_total % rate_bytes;
                bytes_remaining_in_rate_block = rate_bytes - bytes_in_current_rate_block;

                // B. Calculate Expected Keep for THIS beat
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
                if (m_axis.tkeep !== exp_keep) begin
                    $error("[%s] SIGNAL ERROR: tkeep mismatch at DUT byte offset %0d",
                           test_name, bytes_squeezed_from_dut_total);
                    $display("\tExpected Keep: %b", exp_keep);
                    $display("\tGot Keep:      %b", m_axis.tkeep);
                end

                // D. Verify Last (Strict for SHA3 / Bounded SHAKE)
                if (!is_shake || (is_shake && xof_len_val > 0)) begin
                    // SHA3/Bounded XOF logic (Last asserts at extremely final beat)
                    int bytes_rem = bytes_total_expected - bytes_collected_so_far;
                    
                    int expected_bytes_this_beat2;
                    expected_bytes_this_beat2 = (DWIDTH/8);
                    if (bytes_remaining_in_rate_block < expected_bytes_this_beat2) 
                        expected_bytes_this_beat2 = bytes_remaining_in_rate_block;

                    if (bytes_rem <= expected_bytes_this_beat2) exp_last = 1; else exp_last = 0;
                    if (m_axis.tlast !== exp_last) $error("[%s] SIGNAL ERROR: tlast mismatch!", test_name);
                end else begin
                    // SHAKE logic (Last usually 0, dependent on implementation)
                    if (m_axis.tlast !== 0) $error("[%s] SIGNAL ERROR: SHAKE tlast should be 0!", test_name);
                end

                // --- 2. DATA COLLECTION ---
                current_word = m_axis.tdata;
                current_keep = m_axis.tkeep;

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

        m_axis.tready = 0;

        // --- Result Reconstruction ---
        for (i = 0; i < bytes_total_expected; i++) begin
            if (i < collected_bytes.size())
                res_str = {res_str, $sformatf("%02x", collected_bytes[i])};
            else
                res_str = {res_str, "XX"};
        end

        // --- Logging ---
        if (res_str.tolower() == exp_hex.tolower()) begin
            $display("    [PASS] %s", test_name);
        end else begin
            $error("    [FAIL] %s Data Mismatch", test_name);
            $display("    Expected: %s", exp_hex.tolower());
            $display("    Got:      %s", res_str.tolower());
        end
    endtask

    // =====================================================================
    // 7. Main Test Execution (With Safe Polling Watchdog)
    // =====================================================================
    task automatic run_test(
        string      name,
        keccak_mode mode,
        string      msg_hex_str,
        string      exp_md_hex_str,
        int         output_len_bits,
        int         xof_len_val
    );
        logic test_done; // Shared flag to kill the watchdog safely

        $display("----------------------------------------------------------");
        $display("STARTING: %s", name);

        reset_dut();
        test_done = 0;

        // Run Test Logic and Watchdog in parallel
        fork
            // Thread 1: The Test Logic
            begin
                // Setup signals before forking the driver/monitor
                @(posedge clk);
                start_i <= 1;
                keccak_mode_i <= mode;
                xof_len_i <= xof_len_val;
                @(posedge clk);
                start_i <= 0;

                // Run driver and monitor in parallel
                fork
                    drive_msg(msg_hex_str);
                    check_response(name, exp_md_hex_str, output_len_bits, mode, xof_len_val);
                join

                $display("    [INFO] Test execution finished normally.");
                test_done = 1; // Signal the watchdog to stop!
            end

            // Thread 2: Safe Polling Watchdog (Avoids Verilator disable fork bugs)
            begin
                int time_waited = 0;
                // Check every 1000ns to see if the test finished, up to the limit
                while (!test_done && time_waited < TIMEOUT_LIMIT) begin
                    #(1000);
                    time_waited += 1000;
                end

                // If the loop finished and test_done is STILL 0, we timed out
                if (!test_done) begin
                    $error("[FATAL] TIMEOUT detected for test: %s", name);
                    $fatal("       Simulation forced to stop this test case to save storage.");
                end
            end
        join

        #(CLK_PERIOD * 5);
    endtask

    initial begin

        // =====================================================================
        // 1. SHA3-256 (Rate = 1088 bits)
        // =====================================================================

        // Empty Message
        vectors.push_back(test_vector_t'{"SHA3-256 Empty", SHA3_256, "", "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a", 256});

        // Short Message (Single beat)
        vectors.push_back(test_vector_t'{"SHA3-256 Short", SHA3_256, "616263", "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532", 256});

        // Full Rate Message (Spans entire block i.e., 1088 bits)
        vectors.push_back(test_vector_t'{"SHA3-256 Full Rate", SHA3_256, "56ea14d7fcb0db748ff649aaa5d0afdc2357528a9aad6076d73b2805b53d89e73681abfad26bee6c0f3d20215295f354f538ae80990d2281be6de0f6919aa9eb048c26b524f4d91ca87b54c0c54aa9b54ad02171e8bf31e8d158a9f586e92ffce994ecce9a5185cc80364d50a6f7b94849a914242fcb73f33a86ecc83c3403630d20650ddb8cd9c4", "4beae3515ba35ec8cbd1d94567e22b0d7809c466abfbafe9610349597ba15b45", 256});

        // Long Message (Spans multiple blocks/permutations)
        vectors.push_back(test_vector_t'{"SHA3-256 Long", SHA3_256, "b1caa396771a09a1db9bc20543e988e359d47c2a616417bbca1b62cb02796a888fc6eeff5c0b5c3d5062fcb4256f6ae1782f492c1cf03610b4a1fb7b814c057878e1190b9835425c7a4a0e182ad1f91535ed2a35033a5d8c670e21c575ff43c194a58a82d4a1a44881dd61f9f8161fc6b998860cbe4975780be93b6f87980bad0a99aa2cb7556b478ca35d1f3746c33e2bb7c47af426641cc7bbb3425e2144820345e1d0ea5b7da2c3236a52906acdc3b4d34e474dd714c0c40bf006a3a1d889a632983814bbc4a14fe5f159aa89249e7c738b3b73666bac2a615a83fd21ae0a1ce7352ade7b278b587158fd2fabb217aa1fe31d0bda53272045598015a8ae4d8cec226fefa58daa05500906c4d85e7567", "cb5648a1d61c6c5bdacd96f81c9591debc3950dcf658145b8d996570ba881a05", 256});

        // =====================================================================
        // 2. SHA3-512 (Rate = 576 bits)
        // =====================================================================

        // Empty Message
        vectors.push_back(test_vector_t'{"SHA3-512 Empty", SHA3_512, "", "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26", 512});

        // Short Message
        vectors.push_back(test_vector_t'{"SHA3-512 Short", SHA3_512, "54746a7ba28b5f263d2496bd0080d83520cd2dc503", "d77048df60e20d03d336bfa634bc9931c2d3c1e1065d3a07f14ae01a085fe7e7fe6a89dc4c7880f1038938aa8fcd99d2a782d1bbe5eec790858173c7830c87a2", 512});

        // Long Message
        vectors.push_back(test_vector_t'{"SHA3-512 Long", SHA3_512, "22e1df25c30d6e7806cae35cd4317e5f94db028741a76838bfb7d5576fbccab001749a95897122c8d51bb49cfef854563e2b27d9013b28833f161d520856ca4b61c2641c4e184800300aede3518617c7be3a4e6655588f181e9641f8df7a6a42ead423003a8c4ae6be9d767af5623078bb116074638505c10540299219b0155f45b1c18a74548e4328de37a911140531deb6434c534af2449c1abe67e18030681a61240225f87ede15d519b7ce2500bccf33e1364e2fbe6a8a2fe6c15d73242610ed36b0740080812e8902ee531c88e0359020797cbdd1fb78848ae6b5105961d05cdddb8af5fef21b02db94c9810464b8d3ea5f047b94bf0d23931f12df37e102b603cd8e5f5ffa83488df257ddde110106262e0ef16d7ef213e7b49c69276d4d048f", "a6375ff04af0a18fb4c8175f671181b4cf79653a3d70847c6d99694b3f5d41601f1dbef809675c63cac4ec83153b1c78131a7b61024ce36244f320ab8740cb7e", 512});

        // =====================================================================
        // 3. SHAKE128 (XOF - Rate = 1344 bits)
        // =====================================================================

        // Empty Message
        vectors.push_back(test_vector_t'{"SHAKE128 Empty", SHAKE128, "", "7f9c2ba4e88f827d616045507605853e", 128});

        // Short Message
        vectors.push_back(test_vector_t'{"SHAKE128 Short", SHAKE128, "84f6cb3dc77b9bf856caf54e", "56538d52b26f967bb9405e0f54fdf6e2", 128});

        // Edge Case: Long squeeze that crosses the 168-byte rate boundary (200 bytes)
        // Verified against NIST: SHAKE128 Msg="cc" (1 byte)
        vectors.push_back(test_vector_t'{"SHAKE128 Boundary Cross", SHAKE128, "cc", "4dd4b0004a7d9e613a0f488b4846f804015f0f8ccdba5f7c16810bbc5a1c6fb254efc81969c5eb49e682babae02238a31fd2708e418d7b754e21e4b75b65e7d39b5b42d739066e7c63595daf26c3a6a2f7001ee636c7cb2a6c69b1ec7314a21ff24833eab61258327517b684928c7444380a6eacd60a6e9400da37a61050e4cd1fbdd05dde0901ea2f3f67567f7c9bf7aa53590f29c94cb4226e77c68e1600e4765bea40b3644b4d1e93eda6fb0380377c12d5bb9df4728099e88b55d820c7f827034d809e756831", 1600});

        // =====================================================================
        // 4. SHAKE256 (XOF - Rate = 1088 bits)
        // =====================================================================

        // Empty Message
        vectors.push_back(test_vector_t'{"SHAKE256 Empty", SHAKE256, "", "46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762f", 256});

        // Short Message
        vectors.push_back(test_vector_t'{"SHAKE256 Short", SHAKE256, "765db6ab3af389b8c775c8eb99fe72", "ccb6564a655c94d714f80b9f8de9e2610c4478778eac1b9256237dbf90e50581", 256});

        // Long Message
        vectors.push_back(test_vector_t'{"SHAKE256 Long", SHAKE256, "dc5a100fa16df1583c79722a0d72833d3bf22c109b8889dbd35213c6bfce205813edae3242695cfd9f59b9a1c203c1b72ef1a5423147cb990b5316a85266675894e2644c3f9578cebe451a09e58c53788fe77a9e850943f8a275f830354b0593a762bac55e984db3e0661eca3cb83f67a6fb348e6177f7dee2df40c4322602f094953905681be3954fe44c4c902c8f6bba565a788b38f13411ba76ce0f9f6756a2a2687424c5435a51e62df7a8934b6e141f74c6ccf539e3782d22b5955d3baf1ab2cf7b5c3f74ec2f9447344e937957fd7f0bdfec56d5d25f61cde18c0986e244ecf780d6307e313117256948d4230ebb9ea62bb302cfe80d7dfebabc4a51d7687967ed5b416a139e974c005fff507a96", "2bac5716803a9cda8f9e84365ab0a681327b5ba34fdedfb1c12e6e807f45284b", 256});

        // Execute all
        foreach(vectors[i]) begin
            // Run with XOF len 0 (infinite mode, relies on stop_i)
            run_test({vectors[i].name, " (Continuous)"}, vectors[i].mode, vectors[i].msg_hex_str, vectors[i].exp_md_hex_str, vectors[i].output_len_bits, 0);

            // If it's SHAKE, also test with bounded length!
            if (vectors[i].mode == SHAKE128 || vectors[i].mode == SHAKE256) begin
                run_test({vectors[i].name, " (Bounded)"}, vectors[i].mode, vectors[i].msg_hex_str, vectors[i].exp_md_hex_str, vectors[i].output_len_bits, vectors[i].output_len_bits / 8);
            end
        end

        $display("==========================================================");
        $display("TEST SUITE COMPLETE");
        $display("==========================================================");
        $finish;
    end

endmodule
