/*
 * Module Name: keccak_step_unit
 * Author: Kiet Le
 * Description:
 * - Acts as the primary Combinational Logic block (ALU) for the Keccak Core.
 * - Chains all five Keccak permutation step mappings in series to execute
 *   one complete round per clock cycle:
 *     θ (Theta) → ρ (Rho) → π (Pi) → χ (Chi) → ι (Iota)
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module keccak_step_unit (
    input   logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_i,
    input   wire                                              perm_en_i,
    // Current pre-fetched round constant
    input   wire  [LANE_SIZE-1:0]                             round_constant_i,

    output  logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array_o
);
    // Intermediate wires between chained steps
    logic [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0]   theta_out,
                                                        rho_out,
                                                        pi_out,
                                                        chi_out,
                                                        iota_out;

    // ==========================================================
    // COMBINATIONAL CASCADE: θ → ρ → π → χ → ι
    // ==========================================================
    // NOTE: state_in_gated removed to save logic levels.
    // Combinatorial logic will toggle but register is clock-gated.

    theta_step u_theta (.state_array_i(state_array_i), .state_array_o(theta_out));
    rho_step   u_rho   (.state_array_i(theta_out),     .state_array_o(rho_out));
    pi_step    u_pi    (.state_array_i(rho_out),        .state_array_o(pi_out));
    chi_step   u_chi   (.state_array_i(pi_out),         .state_array_o(chi_out));
    iota_step  u_iota  (.state_array_i(chi_out),
                        .round_constant_i(round_constant_i),
                        .state_array_o(iota_out));

    assign state_array_o = iota_out;

endmodule

`default_nettype wire
