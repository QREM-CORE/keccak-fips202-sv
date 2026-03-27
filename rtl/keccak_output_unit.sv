/*
 * Module Name: keccak_output_unit
 * Author: Kiet Le
 * Description:
 * - Implements the "Squeeze" phase of the sponge construction.
 * - Extracts data from the State Array in chunks of 'DWIDTH' (e.g., 256 bits).
 * - Linearizes the 3D State Array (Lane[x][y]) into a bitstream for output.
 * - Manages Flow Control:
 * 1. Fixed-Length (SHA3-256/512): Asserts 'last_o' when the digest size is reached.
 * 2. Variable-Length (SHAKE128/256): Runs indefinitely until externally stopped.
 * 3. Rate Boundaries: Detects when the Rate block is exhausted via 'squeeze_perm_needed_o'
 * to trigger the FSM to permute the state again (for multi-block XOF output).
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module keccak_output_unit (
    input  logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    input  wire  [MODE_SEL_WIDTH-1:0]       keccak_mode_i,
    input  wire  [RATE_WIDTH-1:0]           rate_i,
    input  wire  [BYTE_ABSORB_WIDTH-1:0]    bytes_squeezed_i,      // Counter from FSM
    input  wire  [XOF_LEN_WIDTH-1:0]        xof_len_i,             // Target XOF bytes requested
    input  wire                             is_xof_fixed_len_i,    // Flag for fixed-length XOF (0 = continuous)
    input  wire  [XOF_LEN_WIDTH-1:0]        total_bytes_squeezed_i,// Total bytes sent so far out of XOF target

    output logic [BYTE_ABSORB_WIDTH-1:0]    bytes_squeezed_o,      // Next counter value
    output logic                            squeeze_perm_needed_o, // Flag: Rate is empty!
    output logic [DWIDTH-1:0]               data_o,                // 256 Bits
    output logic [DWIDTH/8-1:0]             keep_o,                // Valid bytes
    output logic                            last_o                 // End of Hash
);
    // ==========================================================
    // 1. CALCULATE NEXT COUNTER VALUE
    // ==========================================================
    // Simply increment by the bus width (32 bytes).
    // The FSM is responsible for resetting this to 0 when permutation happens.
    assign bytes_squeezed_o = bytes_squeezed_i + (DWIDTH / 8);

    // ==========================================================
    // 2. FLATTEN STATE ARRAY AND CAST TO WORD-ALIGNED ARRAY
    // ==========================================================
    localparam int NUM_OUTPUT_WORDS = 1600 / DWIDTH;
    logic [1599:0] state_linear;
    logic [NUM_OUTPUT_WORDS-1:0][DWIDTH-1:0] state_words;

    always_comb begin
        // 1. Flatten 3D to 1D
        for (int y = 0; y < 5; y++) begin
            for (int x = 0; x < 5; x++) begin
                // Calculate linear lane index: i = 5*y + x
                state_linear[(x + 5*y) * 64 +: 64] = state_array_i[x][y];
            end
        end
        // 2. Cast 1D array into Word-Aligned Boundaries
        for (int i = 0; i < NUM_OUTPUT_WORDS; i++) begin
            state_words[i] = state_linear[i * DWIDTH +: DWIDTH];
        end
    end

    // ==========================================================
    // 3. EXTRACT OUTPUT WORD (High-Fmax Multiplexer)
    // ==========================================================
    // Instead of a dynamic bit-slice, select exactly which word block to output.
    int current_word_idx;
    assign current_word_idx = bytes_squeezed_i / (DWIDTH / 8);

    always_comb begin
        data_o = state_words[current_word_idx];
    end

    // ==========================================================
    // 4. VALID BYTE CALCULATION (KEEP SIGNAL)
    // ==========================================================
    logic [RATE_WIDTH-1:0] bytes_remaining_in_rate;
    // Note: rate_i is bits, convert to bytes.
    assign bytes_remaining_in_rate = (rate_i >> 3) - bytes_squeezed_i;

    logic [XOF_LEN_WIDTH-1:0] bytes_remaining_req;
    assign bytes_remaining_req = (is_xof_fixed_len_i && xof_len_i > total_bytes_squeezed_i) ? (xof_len_i - total_bytes_squeezed_i) : 0;

    logic [XOF_LEN_WIDTH-1:0] limit_bytes;
    always_comb begin
        if (is_xof_fixed_len_i && (keccak_mode_i == SHAKE128 || keccak_mode_i == SHAKE256)) begin
            // We have an XOF mode with a specific length
            if (bytes_remaining_in_rate < bytes_remaining_req) begin
                limit_bytes = bytes_remaining_in_rate;
            end else begin
                limit_bytes = bytes_remaining_req;
            end
        end else begin
            limit_bytes = bytes_remaining_in_rate;
        end
    end

    always_comb begin
        // If we have more than 32 bytes left in the limit, keep all 32.
        if (limit_bytes >= (DWIDTH/8)) begin
            keep_o = '1; // All ones
        end else begin
            // We hit the end of the rate block or XOF limit. Mask the valid bytes.
            // Example: 5 bytes left -> keep_o = 00...0011111
            keep_o = (1 << limit_bytes) - 1;
        end
    end

    // ==========================================================
    // 5. SHAKE PERMUTATION TRIGGER
    // ==========================================================
    // If the remaining bytes <= what we are about to output, we are draining the block.
    assign squeeze_perm_needed_o = (bytes_remaining_in_rate <= (DWIDTH/8));

    // ==========================================================
    // 6. LAST SIGNAL LOGIC
    // ==========================================================
    always_comb begin
        case (keccak_mode_i)
            // Fixed Length Hashes: Done when we output the specific size.
            // Note: We compare against bytes_squeezed_o (the NEXT value)
            // to assert 'last' during the final transfer.
            SHA3_256: last_o = (bytes_squeezed_o >= 32);
            SHA3_512: last_o = (bytes_squeezed_o >= 64);

            // XOF (SHAKE): Infinite. Rely on external stop signal or fixed len limit
            default: begin
                if (is_xof_fixed_len_i) begin
                    logic [XOF_LEN_WIDTH-1:0] output_bytes_this_cycle;
                    output_bytes_this_cycle = (limit_bytes > (DWIDTH/8)) ? (DWIDTH/8) : limit_bytes;
                    if (total_bytes_squeezed_i + output_bytes_this_cycle >= xof_len_i) begin
                        last_o = 1'b1;
                    end else begin
                        last_o = 1'b0;
                    end
                end else begin
                    last_o = 1'b0;
                end
            end
        endcase
    end

endmodule

`default_nettype wire
