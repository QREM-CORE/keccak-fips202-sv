# =========================================================
# Keccak Dual-Simulator Makefile (ModelSim + Verilator)
# =========================================================

# --- PATH & FILE DEFINITIONS ---
# Includes for your packages and headers
INCDIRS = +incdir+rtl +incdir+lib/common_rtl/rtl

# 1. Dynamically read RTL files from the filelist (rtl.f)
# Preserves exact order from rtl.f.
# NOTE: Make sure your packages (e.g., keccak_pkg.sv) are at the TOP of rtl.f!
RTL_FILES = $(shell grep -v '^\#' rtl.f | grep -v '^$$')

# 2. Discover testbenches, but FILTER OUT the heavy testbench
# This ensures 'make' or 'make run_all' skips the heavy simulation
ALL_TBS = $(patsubst tb/%.sv,%,$(wildcard tb/*_tb.sv))
TESTBENCHES = $(filter-out keccak_core_heavy_tb, $(ALL_TBS))

# Simulator selection (default to vsim if not specified)
# Usage: make run_all SIM=verilator
SIM ?= vsim

# --- VERILATOR FLAGS ---
# --binary: Build an executable (requires Verilator v5.0+)
# --timing: Support delay statements (#1ns) in SV
VERILATOR_FLAGS = --binary -j 0 --timing -Wall -Wno-fatal
# Note: --trace is added dynamically below for targets that need VCDs

# =====================
# STANDARD TARGETS
# =====================

# Default target
all: run_all

.PHONY: run_all clean run_% run_keccak_core_heavy_tb run_heavy_fail

# Loop through all testbenches
run_all:
	@for tb in $(TESTBENCHES); do \
		$(MAKE) run_$$tb SIM=$(SIM); \
	done

# Standard rule for each testbench (Generates VCD)
run_%:
	@echo "=== Running $* with $(SIM) ==="
ifeq ($(SIM), verilator)
	# Compile WITH tracing for standard TBs
	verilator $(VERILATOR_FLAGS) --trace $(INCDIRS) --top-module $* -f rtl.f tb/$*.sv
	./obj_dir/V$*
else
	vlib work
	vlog -work work -sv $(INCDIRS) -f rtl.f tb/$*.sv
	@echo 'vcd file "$*.vcd"' > run_$*.macro
	@echo 'vcd add -r /$*/*' >> run_$*.macro
	@echo 'run -all' >> run_$*.macro
	@echo 'quit' >> run_$*.macro
	vsim -c -do run_$*.macro work.$*
	@rm -f run_$*.macro
endif

# =====================
# HEAVY REGRESSION TARGETS
# =====================

# Special rule for the "Heavy" TB (Running ALL, NO VCD)
# Overrides standard run_% to avoid huge VCD files
run_keccak_core_heavy_tb:
	@echo "=== Running Heavy Regression (No VCD) with $(SIM) ==="
ifeq ($(SIM), verilator)
	# Compile WITHOUT --trace to maximize speed and save disk space
	verilator $(VERILATOR_FLAGS) $(INCDIRS) --top-module keccak_core_heavy_tb -f rtl.f tb/keccak_core_heavy_tb.sv
	./obj_dir/Vkeccak_core_heavy_tb
else
	vlib work
	vlog -work work -sv $(INCDIRS) -f rtl.f tb/keccak_core_heavy_tb.sv
	@echo 'run -all' > run_heavy.macro
	@echo 'quit' >> run_heavy.macro
	vsim -c -do run_heavy.macro work.keccak_core_heavy_tb
	@rm -f run_heavy.macro
endif

# Special rule for Re-running a FAILURE (With VCD)
# Usage: make run_heavy_fail TEST_ID=123 SIM=verilator
run_heavy_fail:
	@echo "=== Debugging Test ID $(TEST_ID) with $(SIM) ==="
ifeq ($(SIM), verilator)
	# Compile WITH --trace and pass +TEST_ID to the executable
	verilator $(VERILATOR_FLAGS) --trace $(INCDIRS) --top-module keccak_core_heavy_tb -f rtl.f tb/keccak_core_heavy_tb.sv
	./obj_dir/Vkeccak_core_heavy_tb +TEST_ID=$(TEST_ID)
else
	vlib work
	vlog -work work -sv $(INCDIRS) -f rtl.f tb/keccak_core_heavy_tb.sv
	@echo 'vcd file "keccak_core_heavy_tb.vcd"' > run_fail.macro
	@echo 'vcd add -r /keccak_core_heavy_tb/*' >> run_fail.macro
	@echo 'run -all' >> run_fail.macro
	@echo 'quit' >> run_fail.macro
	vsim -c -do run_fail.macro work.keccak_core_heavy_tb +TEST_ID=$(TEST_ID)
	@rm -f run_fail.macro
endif

# =====================
# CLEANUP
# =====================
clean:
	rm -rf work *.vcd transcript vsim.wlf run_*.macro *.log obj_dir
