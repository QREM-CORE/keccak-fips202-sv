# --- Packages (Must be compiled first) ---
rtl/keccak_pkg.sv


# --- Keccak Step Modules ---
rtl/chi_step.sv
rtl/iota_step.sv
rtl/pi_step.sv
rtl/rho_step.sv
rtl/theta_step.sv

# --- Keccak Top-Level Modules ---
rtl/keccak_step_unit.sv
rtl/keccak_absorb_unit.sv
rtl/keccak_output_unit.sv
rtl/keccak_param_unit.sv

# --- Keccak Core Top Module ---
rtl/keccak_core.sv
