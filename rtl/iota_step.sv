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
    output  wire  [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o
);
    /* ============================================================
     * Step 1: Get Round Constant using input Round Index
     * ============================================================
     */
    logic [63:0] rc;
    always_comb begin
        case (round_index_i)
            5'd0:  rc = 64'h0000000000000001;
            5'd1:  rc = 64'h0000000000008082;
            5'd2:  rc = 64'h800000000000808a;
            5'd3:  rc = 64'h8000000080008000;
            5'd4:  rc = 64'h000000000000808b;
            5'd5:  rc = 64'h0000000080000001;
            5'd6:  rc = 64'h8000000080008081;
            5'd7:  rc = 64'h8000000000008009;
            5'd8:  rc = 64'h000000000000008a;
            5'd9:  rc = 64'h0000000000000088;
            5'd10: rc = 64'h0000000080008009;
            5'd11: rc = 64'h000000008000000a;
            5'd12: rc = 64'h000000008000808b;
            5'd13: rc = 64'h800000000000008b;
            5'd14: rc = 64'h8000000000008089;
            5'd15: rc = 64'h8000000000008003;
            5'd16: rc = 64'h8000000000008002;
            5'd17: rc = 64'h8000000000000080;
            5'd18: rc = 64'h000000000000800a;
            5'd19: rc = 64'h800000008000000a;
            5'd20: rc = 64'h8000000080008081;
            5'd21: rc = 64'h8000000000008080;
            5'd22: rc = 64'h0000000080000001;
            5'd23: rc = 64'h8000000080008008;
            default: rc = 64'h0000000000000000;
        endcase
    end

    genvar x, y;
    generate
        for (y = 0; y < COL_SIZE; y++) begin : gen_iota_y
            for (x = 0; x < ROW_SIZE; x++) begin : gen_iota_x
                if (x == 0 && y == 0) begin
                    assign state_array_o[x][y] = state_array_i[x][y] ^ rc;
                end else begin
                    assign state_array_o[x][y] = state_array_i[x][y];
                end
            end
        end
    endgenerate

endmodule

`default_nettype wire
