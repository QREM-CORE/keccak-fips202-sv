/*
 * Module Name: keccak_absorb_unit
 * Author: Kiet Le
 * Description:
 * - Performs the XOR absorption phase of the Keccak sponge construction.
 * - Accepts a variable-width message chunk (up to 64 bits) and absorbs it
 * into the current State Array at the offset specified by 'bytes_absorbed_i'.
 * - With DWIDTH=64, all FIPS 202 rates are evenly divisible by 8 bytes,
 * so rate-boundary straddling is structurally impossible and no carry-over
 * logic is needed.
 * - Supports byte-granular validity via 'keep_i' masking.
 * - Also handles FIPS 202 suffix and 10*1 padding injection via pad_en_i.
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

// Compute state array after absorption
module keccak_absorb_unit (
    input   wire  [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    input   wire  [RATE_WIDTH-1:0]          rate_i,
    input   wire  [BYTE_ABSORB_WIDTH-1:0]   bytes_absorbed_i,
    input   wire  [DWIDTH-1:0]              msg_i,
    input   wire  [KEEP_WIDTH-1:0]          keep_i,
    input   wire                            pad_en_i,
    input   wire  [SUFFIX_WIDTH-1:0]        suffix_i,

    output  logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o,
    output  logic [BYTE_ABSORB_WIDTH-1:0]   bytes_absorbed_o
);
    localparam int INPUT_LANE_NUM = DWIDTH/LANE_SIZE;
    localparam int BYTES_PER_LANE = LANE_SIZE/BYTE_SIZE;
    localparam int TOTAL_BYTES = DWIDTH/BYTE_SIZE;
    localparam int INPUT_BYTES_NUM = DWIDTH/8;

    // Physical Limit: The absolute max rate defined by the spec (SHAKE128)
    // 1344 bits / 64 = 21 lanes. Indices 0 to 20 are valid.
    localparam int MAX_POSSIBLE_LANES = 21;

    // ==========================================================
    // 1. MASK INPUT DATA
    // ==========================================================
    // Zero out invalid bytes in msg_i
    logic [DWIDTH-1:0] msg_masked;
    always_comb begin
        for (int b = 0; b < (DWIDTH/8); b++) begin
            // Byte-wise masking
            msg_masked[b*8 +: 8] = keep_i[b] ? msg_i[b*BYTE_SIZE +: BYTE_SIZE] : 8'h00;
        end
    end

    // ==========================================================
    // 2. CALCULATE SPACE AND VALID COUNTS
    // ==========================================================
    logic [RATE_WIDTH-1:0] rate_bytes;
    assign rate_bytes = rate_i >> 3; // Convert bits to bytes

    logic [$clog2(KEEP_WIDTH + 1)-1:0] valid_byte_count;
    assign valid_byte_count = $countones(keep_i);

    // ==========================================================
    // 3. PROCESS ABSORB (No Carry Over with 64-bit DWIDTH)
    // ==========================================================
    always_comb begin
        bytes_absorbed_o = bytes_absorbed_i + valid_byte_count;
    end

    // ==========================================================
    // 4. SPLIT LANES
    // ==========================================================
    // Split the msg_masked into four 64-bit lanes
    wire [LANE_SIZE-1:0] split_lanes [INPUT_LANE_NUM];
    genvar i;
    generate
        for (i = 0; i<INPUT_LANE_NUM; i=i+1) begin : g_split_loop
            assign split_lanes[i] = msg_masked[i*LANE_SIZE +: LANE_SIZE];
        end
    endgenerate

    // ==========================================================
    // 5. XOR INTO STATE (SHARED ABSORB & PADDING RESOURCE)
    // ==========================================================
    logic [4:0] rate_lane_limit;
    assign rate_lane_limit = rate_i[RATE_WIDTH-1:6]; // rate_i / 64

    int start_lane_idx;

    // Padder Coordinates
    int head_lane_idx;
    int head_byte_offset;
    logic [63:0] head_pad_val;
    int tail_lane_idx;
    logic [63:0] tail_pad_val;

    assign head_lane_idx    = int'(bytes_absorbed_i >> 3);
    assign head_byte_offset = int'(bytes_absorbed_i[2:0]);
    assign head_pad_val     = 64'(suffix_i) << (head_byte_offset * 8);

    assign tail_lane_idx    = int'((rate_i >> 6) - 1);
    assign tail_pad_val     = 64'h8000_0000_0000_0000;

    // Single 1600-bit XOR operand plane multiplexed across Absorb and Padding
    logic [63:0] xor_plane [25];

    always_comb begin
        // Zero all operands
        for (int i = 0; i < 25; i++) begin
            xor_plane[i] = '0;
        end

        if (pad_en_i) begin
            // Padding Phase (Reuses the XOR plane)
            // Can merge if head == tail!
            xor_plane[head_lane_idx] |= head_pad_val;
            xor_plane[tail_lane_idx] |= tail_pad_val;
        end else begin
            // Normal Absorb Phase
            start_lane_idx = int'(bytes_absorbed_i >> 3);

            for (int i = 0; i < INPUT_LANE_NUM; i = i + 1) begin
                automatic int current_lane_idx = start_lane_idx + i;
                if (current_lane_idx < rate_lane_limit && current_lane_idx < MAX_POSSIBLE_LANES) begin
                    xor_plane[current_lane_idx] = split_lanes[i];
                end
            end
        end

        // Single monolithic 1600-bit XOR execution
        for (int i = 0; i < 25; i++) begin
            automatic int x = i % COL_SIZE;
            automatic int y = i / COL_SIZE;
            state_array_o[x][y] = state_array_i[x][y] ^ xor_plane[i];
        end
    end

endmodule

`default_nettype wire
