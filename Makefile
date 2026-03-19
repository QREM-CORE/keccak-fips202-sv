# =====================
# ModelSim Multi-TB Makefile
# =====================

# List of testbenches (example: TESTBENCHES = theta_step_tb rho_step_tb)
TESTBENCHES = theta_step_tb rho_step_tb pi_step_tb chi_step_tb iota_step_tb keccak_absorb_unit_tb keccak_output_unit_tb keccak_core_tb

# --- PATH DEFINITIONS ---
LIB_DIR     = lib/common_rtl
# Assuming the submodule has its own 'rtl' folder inside
LIB_SRCS    = $(wildcard $(LIB_DIR)/rtl/*.sv)

# --- SOURCE FILES ---
# Packages must be compiled first
PKG_SRCS    = rtl/keccak_pkg.sv

# Your local design files
DESIGN_SRCS = $(wildcard rtl/*.sv)
COMMON_SRCS = $(wildcard rtl/*.svh)

# Work library
WORK = work

# Default target
all: $(WORK)
	@if [ -z "$(strip $(TESTBENCHES))" ]; then \
		echo "No testbenches specified. Compiling RTL only..."; \
		vlog -work $(WORK) -sv +incdir+$(LIB_DIR)/rtl $(PKG_SRCS) $(LIB_SRCS); \
		vlog -work $(WORK) -sv +incdir+$(LIB_DIR)/rtl $(filter-out $(PKG_SRCS), $(DESIGN_SRCS)) $(COMMON_SRCS); \
	else \
		$(MAKE) run_all TESTBENCHES="$(TESTBENCHES)"; \
	fi


# Create ModelSim work library
$(WORK):
	vlib $(WORK)

# Run all testbenches
.PHONY: run_all clean run_%

run_all:
	@for tb in $(TESTBENCHES); do \
		$(MAKE) run_$$tb; \
	done

# Rule for each testbench
run_%: $(WORK)
	@if [ "$*" = "all" ]; then exit 0; fi
	@echo "=== Running $* ==="
# 1. Compile Packages & Common Lib (Interfaces)
	vlog -work $(WORK) -sv +incdir+$(LIB_DIR)/rtl $(PKG_SRCS) $(LIB_SRCS)
# 2. Compile Design & Testbench
	vlog -work $(WORK) -sv +incdir+$(LIB_DIR)/rtl $(filter-out $(PKG_SRCS), $(DESIGN_SRCS)) $(COMMON_SRCS) tb/$*.sv

# 3. Create Macro & Run
	@echo 'vcd file "$*.vcd"' > run_$*.macro
	@echo 'vcd add -r /$*/*' >> run_$*.macro
	@echo 'run -all' >> run_$*.macro
	@echo 'quit' >> run_$*.macro
	vsim -c -do run_$*.macro $(WORK).$*
	@rm -f run_$*.macro
# Add the new TB to the list
TESTBENCHES += keccak_core_heavy_tb

# Special rule for the "Heavy" TB (Running ALL, NO VCD)
# We override the standard run_% rule for this specific target to avoid huge VCDs
run_keccak_core_heavy_tb: $(WORK)
	@echo "=== Running Heavy Regression (No VCD) ==="
	vlog -work $(WORK) -sv +incdir+$(LIB_DIR)/rtl $(PKG_SRCS)
	vlog -work $(WORK) -sv +incdir+$(LIB_DIR)/rtl $(filter-out $(PKG_SRCS), $(DESIGN_SRCS)) $(COMMON_SRCS) tb/keccak_core_heavy_tb.sv
	@echo 'run -all' > run_heavy.macro
	@echo 'quit' >> run_heavy.macro
	vsim -c -do run_heavy.macro $(WORK).keccak_core_heavy_tb
	rm -f run_heavy.macro

# Special rule for Re-running a FAILURE (With VCD)
# Usage: make run_heavy_fail TEST_ID=123
run_heavy_fail: $(WORK)
	@echo "=== Debugging Test ID $(TEST_ID) ==="
	@echo 'vcd file "keccak_core_heavy_tb.vcd"' > run_fail.macro
	@echo 'vcd add -r /keccak_core_heavy_tb/*' >> run_fail.macro
	@echo 'run -all' >> run_fail.macro
	@echo 'quit' >> run_fail.macro
	vsim -c -do run_fail.macro $(WORK).keccak_core_heavy_tb +TEST_ID=$(TEST_ID)
	rm -f run_fail.macro

# Clean build files
clean:
	rm -rf $(WORK) *.vcd transcript vsim.wlf run_*.macro *.log
