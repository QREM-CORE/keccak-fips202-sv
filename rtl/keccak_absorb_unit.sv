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
import qrem_global_pkg::*;

// Compute state array after absorption
module keccak_absorb_unit #(
    parameter int KEEP_WIDTH = DWIDTH/8
) (
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
    logic [$clog2(MAX_POSSIBLE_LANES)-1:0] rate_lane_limit;
    assign rate_lane_limit = rate_i[RATE_WIDTH-1:$clog2(LANE_SIZE)]; // rate_i / 64

    logic [$clog2(ROW_SIZE*COL_SIZE)-1:0] start_lane_idx;
    assign start_lane_idx = bytes_absorbed_i >> $clog2(BYTES_PER_LANE);

    // Padder Coordinates
    logic [$clog2(ROW_SIZE*COL_SIZE)-1:0] head_lane_idx;
    logic [$clog2(BYTES_PER_LANE)-1:0] head_byte_offset;
    logic [LANE_SIZE-1:0] head_pad_val;
    logic [$clog2(ROW_SIZE*COL_SIZE)-1:0] tail_lane_idx;
    logic [LANE_SIZE-1:0] tail_pad_val;

    assign head_lane_idx    = bytes_absorbed_i >> $clog2(BYTES_PER_LANE);
    assign head_byte_offset = bytes_absorbed_i[$clog2(BYTES_PER_LANE)-1:0];
    assign head_pad_val     = (64'(suffix_i)) << {head_byte_offset, 3'b000};

    assign tail_lane_idx    = (rate_i >> $clog2(LANE_SIZE)) - 1;
    assign tail_pad_val     = {1'b1, {(LANE_SIZE-1){1'b0}}};

    // Single 1600-bit XOR operand plane multiplexed across Absorb and Padding
    logic [63:0] xor_plane [25];

    // Construct the XOR operand plane
    always_comb begin
        // Default to zero
        for (int i = 0; i < 25; i++) xor_plane[i] = '0;

        if (pad_en_i) begin
            // Padding Phase
            // Use explicit checks for head/tail to avoid variable indexing in a complex way
            for (int i = 0; i < 25; i++) begin
                if (i == head_lane_idx) xor_plane[i] |= head_pad_val;
                if (i == tail_lane_idx) xor_plane[i] |= tail_pad_val;
            end
        end else begin
            // Normal Absorb Phase
            // INPUT_LANE_NUM is 1 (DWIDTH=64, LANE_SIZE=64)
            // Match the single input lane to its target offset
            for (int i = 0; i < 25; i++) begin
                if (i == start_lane_idx) begin
                    if (i < rate_lane_limit && i < MAX_POSSIBLE_LANES) begin
                        xor_plane[i] = split_lanes[0];
                    end
                end
            end
        end
    end

    // Single monolithic 1600-bit XOR execution via generate
    genvar x_idx, y_idx;
    generate
        for (y_idx = 0; y_idx < 5; y_idx = y_idx + 1) begin : g_xor_y
            for (x_idx = 0; x_idx < 5; x_idx = x_idx + 1) begin : g_xor_x
                assign state_array_o[x_idx][y_idx] = state_array_i[x_idx][y_idx] ^ xor_plane[x_idx + 5*y_idx];
            end
        end
    endgenerate

endmodule

`default_nettype wire
