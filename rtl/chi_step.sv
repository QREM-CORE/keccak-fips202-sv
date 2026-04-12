/*
 * Module Name: chi_step
 * Author: Kiet Le
 * Description:
 * - Implements the χ (Chi) step mapping, the only non-linear layer in Keccak.
 * - Acts effectively as a parallel S-box applied to each row independently.
 * - Logic: Each bit is XORed with the logical AND of the inverted neighbor
 * and the neighbor's neighbor:
 * A'[x,y] = A[x,y] XOR ((NOT A[x+1,y]) AND A[x+2,y])
 * - Reference: FIPS 202 Section 3.2.4
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module chi_step (
    input   wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    output  logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o
);
    // Compute chi step: nonlinear transformation across each row
    // Formula: A′[x,y]=A[x,y]⊕((¬A[(x+1)mod5,y])∧A[(x+2)mod5,y])
    always_comb begin
        for (int y = 0; y<COL_SIZE; y = y + 1) begin
            for (int x = 0; x<ROW_SIZE; x = x + 1) begin
                automatic int XP1 = (x+1) % 5;
                automatic int XP2 = (x+2) % 5;
                state_array_o[x][y] = state_array_i[x][y] ^ (~state_array_i[XP1][y] & state_array_i[XP2][y]);
            end
        end
    end
endmodule

`default_nettype wire
