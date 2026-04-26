/*
 * Module Name: iota_step
 * Author: Kiet Le
 * Description:
 * - Implements the ι (Iota) step mapping, responsible for breaking symmetry
 * between the 24 rounds of the permutation.
 * - Adds a 64-bit Round Constant (RC) to Lane(0,0) via XOR.
 * - Synthesis Optimized: Uses an explicit case statement for round constants
 * to ensure clean ROM/Mux mapping in sv2v/Yosys flows.
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
    /*
     * A keccak permutation has 24 rounds, so we have 24 different round constants.
     * The 64-bit round constants are defined in FIPS 202 Table 5.
     */
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
