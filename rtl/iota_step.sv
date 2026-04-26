/*
 * Module Name: iota_step
 * Author: Kiet Le
 * Description:
 * - Implements the ι (Iota) step mapping, responsible for breaking symmetry
 * between the 24 rounds of the permutation.
 * - Adds a 64-bit Round Constant (RC) to Lane(0,0) via XOR.
 * - Optimized Storage: Since the RC is sparse (only 7 specific bit positions
 * can ever be '1'), this module stores only those 7 bits per round
 * instead of full 64-bit constants, reducing area usage.
 * - Reference: FIPS 202 Section 3.2.5
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module iota_step (
    input  wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    input  wire [ROUND_INDEX_SIZE-1:0] round_index_i, // Current round index (0-23)
    output reg  [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o
);
    /* ============================================================
     * Step 1: Get Round Constant using input Round Index
     * ============================================================
     *
     * A keccak permutation has 24 rounds, so we have 24 different round constants.
     * The 64-bit round constant only has 7 possible non-zero bits at index positions:
     * (0, 1, 3, 7, 15, 31, 63) == 2^j - 1 for j=0..6
     * So we will only store the 7 bits that can be non-zero.
     *
     * The following array is as such:
     *  - Each row corresponds to each round 0..23
     *  - Each column corresponds to one of the 7 bit positions
     */
    localparam logic ROUNDCONSTANTS [MAX_ROUNDS][L_SIZE] = '{
       //  Bit-0    Bit-1    Bit-3    Bit-7    Bit-15    Bit 31    Bit-63
        '{ 1,       0,       0,       0,       0,        0,        0      }, // Round 0
        '{ 0,       1,       0,       1,       1,        0,        0      }, // Round 1
        '{ 0,       1,       1,       1,       1,        0,        1      }, // Round 2
        '{ 0,       0,       0,       0,       1,        1,        1      }, // Round 3
        '{ 1,       1,       1,       1,       1,        0,        0      }, // Round 4
        '{ 1,       0,       0,       0,       0,        1,        0      }, // Round 5
        '{ 1,       0,       0,       1,       1,        1,        1      }, // Round 6
        '{ 1,       0,       1,       0,       1,        0,        1      }, // Round 7
        '{ 0,       1,       1,       1,       0,        0,        0      }, // Round 8
        '{ 0,       0,       1,       1,       0,        0,        0      }, // Round 9
        '{ 1,       0,       1,       0,       1,        1,        0      }, // Round 10
        '{ 0,       1,       1,       0,       0,        1,        0      }, // Round 11
        '{ 1,       1,       1,       1,       1,        1,        0      }, // Round 12
        '{ 1,       1,       1,       1,       0,        0,        1      }, // Round 13
        '{ 1,       0,       1,       1,       1,        0,        1      }, // Round 14
        '{ 1,       1,       0,       0,       1,        0,        1      }, // Round 15
        '{ 0,       1,       0,       0,       1,        0,        1      }, // Round 16
        '{ 0,       0,       0,       1,       0,        0,        1      }, // Round 17
        '{ 0,       1,       1,       0,       1,        0,        0      }, // Round 18
        '{ 0,       1,       1,       0,       0,        1,        1      }, // Round 19
        '{ 1,       0,       0,       1,       1,        1,        1      }, // Round 20
        '{ 0,       0,       0,       1,       1,        0,        1      }, // Round 21
        '{ 1,       0,       0,       0,       0,        1,        0      }, // Round 22
        '{ 0,       0,       1,       0,       1,        1,        1      }  // Round 23
    };

    // Bit position mapping: 2^j - 1 for j = 0..6
    localparam int BITMAPPING [L_SIZE] = '{0, 1, 3, 7, 15, 31, 63};

    // ============================================================
    // Step 2: XOR corresponding round constants into lane (0,0)
    // ============================================================
    logic [LANE_SIZE-1:0] round_constant;

    always_comb begin
        // Default passthrough
        state_array_o = state_array_i;

        // Build 64-bit round constant
        case (round_index_i)
            'd 0 : round_constant = 64'h0000000000000001;
            'd 1 : round_constant = 64'h0000000000008082;
            'd 2 : round_constant = 64'h800000000000808a;
            'd 3 : round_constant = 64'h8000000080008000;
            'd 4 : round_constant = 64'h000000000000808b;
            'd 5 : round_constant = 64'h0000000080000001;
            'd 6 : round_constant = 64'h8000000080008081;
            'd 7 : round_constant = 64'h8000000000008009;
            'd 8 : round_constant = 64'h000000000000008a;
            'd 9 : round_constant = 64'h0000000000000088;
            'd10 : round_constant = 64'h0000000080008009;
            'd11 : round_constant = 64'h000000008000000a;
            'd12 : round_constant = 64'h000000008000808b;
            'd13 : round_constant = 64'h800000000000008b;
            'd14 : round_constant = 64'h8000000000008089;
            'd15 : round_constant = 64'h8000000000008003;
            'd16 : round_constant = 64'h8000000000008002;
            'd17 : round_constant = 64'h8000000000000080;
            'd18 : round_constant = 64'h000000000000800a;
            'd19 : round_constant = 64'h800000008000000a;
            'd20 : round_constant = 64'h8000000080008081;
            'd21 : round_constant = 64'h8000000000008080;
            'd22 : round_constant = 64'h0000000080000001;
            'd23 : round_constant = 64'h8000000080008008;
            default: round_constant = '0;
        endcase

        // Apply constant to lane (0,0) in single operation
        state_array_o[0][0] = state_array_i[0][0] ^ round_constant;
    end

endmodule

`default_nettype wire
