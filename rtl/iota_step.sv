/*
 * Module Name: iota_step
 * Author: Kiet Le
 * Description:
 * - Implements the ι (Iota) step mapping, responsible for breaking symmetry
 * between the 24 rounds of the permutation.
 * - Adds a 64-bit Round Constant (RC) to Lane(0,0) via XOR.
 * - Optimized: Receives the pre-fetched round constant directly to minimize critical path.
 * - Reference: FIPS 202 Section 3.2.5
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module iota_step (
    input  wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    input  wire [LANE_SIZE-1:0]                             round_constant_i, // Pre-fetched 64-bit RC
    output logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o
);
    always_comb begin
        // Default passthrough
        state_array_o = state_array_i;

        // Apply constant to lane (0,0) in single operation
        state_array_o[0][0] = state_array_i[0][0] ^ round_constant_i;
    end

endmodule

`default_nettype wire
