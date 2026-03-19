/*
 * Module Name: keccak_step_unit
 * Author: Kiet Le
 * Description:
 * - Acts as the primary Combinational Logic block (ALU) for the Keccak Core.
 * - Instantiates all five Keccak permutation step mappings in parallel:
 * 1. Theta (θ): Parity computation and mixing.
 * 2. Rho (ρ): Bitwise rotation.
 * 3. Pi (π): Lane permutation (transpose).
 * 4. Chi (χ): Non-linear combination (S-box equivalent).
 * 5. Iota (ι): Round constant addition (asymmetry injection).
 * - Uses a multiplexer ('step_sel_i') to select the result of the active step
 * to be registered by the FSM in the next cycle.
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module keccak_step_unit (
    input   logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    // Current round index (0-23)
    input   wire  [ROUND_INDEX_SIZE-1:0]                      round_index_i,
    // Step Selector
    input   wire  [STEP_SEL_WIDTH-1:0]                        step_sel_i,

    output  logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o
);
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0]   theta_out,
                                                        rho_out,
                                                        pi_out,
                                                        chi_out,
                                                        iota_out;

    // ==========================================================
    // OPERAND ISOLATION LOGIC (Power Optimization)
    // ==========================================================
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] theta_in, chi_in, iota_in;

    assign theta_in = (step_sel_i == THETA_STEP) ? state_array_i : '0;
    assign chi_in   = (step_sel_i == CHI_STEP)   ? state_array_i : '0;
    assign iota_in  = (step_sel_i == IOTA_STEP)  ? state_array_i : '0;

    // Instantiate Step Mapping Modules
    theta_step u_theta (.state_array_i(theta_in),      .state_array_o(theta_out));
    rho_step   u_rho   (.state_array_i(state_array_i), .state_array_o(rho_out));
    pi_step    u_pi    (.state_array_i(state_array_i), .state_array_o(pi_out));
    chi_step   u_chi   (.state_array_i(chi_in),        .state_array_o(chi_out));
    iota_step  u_iota  (.state_array_i(iota_in),
                        .round_index_i(round_index_i),
                        .state_array_o(iota_out));

    // Multiplexor for step mappings
    always_comb begin
        case(step_sel_i)
            THETA_STEP          : state_array_o = theta_out;
            RHO_STEP            : state_array_o = rho_out;
            PI_STEP             : state_array_o = pi_out;
            CHI_STEP            : state_array_o = chi_out;
            IOTA_STEP           : state_array_o = iota_out;
            IDLE_STEP           : state_array_o = 'b0;
            default             : state_array_o = 'b0;
        endcase
    end

endmodule

`default_nettype wire
