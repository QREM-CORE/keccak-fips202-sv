# =========================================================
# Keccak Local Makefile (Inherits from build-tools)
# =========================================================

# 1. Override default includes for Keccak specifically
INCDIRS = +incdir+rtl +incdir+lib/common_rtl/rtl

# 2. Import the central build system
include build-tools/common.mk

# 3. Filter out the heavy testbench from the default run_all list.
# We do this AFTER the include so it overrides common.mk's definition.
TESTBENCHES := $(filter-out keccak_core_heavy_tb, $(patsubst tb/%.sv,%,$(wildcard tb/*_tb.sv)))

# =====================
# HEAVY REGRESSION TARGETS
# =====================

# Special rule for the "Heavy" TB (Running ALL, NO VCD)
# Overrides standard run_% to avoid huge VCD files
run_keccak_core_heavy_tb: build.f
	@echo "=== Running Heavy Regression (No VCD) with $(SIM) ==="
ifeq ($(SIM), verilator)
	# Compile WITHOUT --trace to maximize speed and save disk space
	verilator --binary -j 0 --timing -Wall -Wno-fatal $(INCDIRS) --top-module keccak_core_heavy_tb -f build.f tb/keccak_core_heavy_tb.sv
	bash -c "set -o pipefail; ./obj_dir/Vkeccak_core_heavy_tb 2>&1 | tee keccak_core_heavy_tb.log"
else
	vlib work
	vlog -work work -sv $(INCDIRS) -f build.f tb/keccak_core_heavy_tb.sv
	@echo 'run -all' > run_heavy.macro
	@echo 'quit' >> run_heavy.macro
	vsim -c -do run_heavy.macro work.keccak_core_heavy_tb -l keccak_core_heavy_tb.log
	@rm -f run_heavy.macro
endif

# Special rule for Re-running a FAILURE (With VCD)
# Usage: make run_heavy_fail TEST_ID=123 SIM=verilator
run_heavy_fail: build.f
	@echo "=== Debugging Test ID $(TEST_ID) with $(SIM) ==="
ifeq ($(SIM), verilator)
	# Compile WITH --trace (using VERILATOR_FLAGS from common.mk) and pass +TEST_ID
	verilator $(VERILATOR_FLAGS) $(INCDIRS) --top-module keccak_core_heavy_tb -f build.f tb/keccak_core_heavy_tb.sv
	bash -c "set -o pipefail; ./obj_dir/Vkeccak_core_heavy_tb +TEST_ID=$(TEST_ID) 2>&1 | tee keccak_core_heavy_tb_fail_$(TEST_ID).log"
else
	vlib work
	vlog -work work -sv $(INCDIRS) -f build.f tb/keccak_core_heavy_tb.sv
	@echo 'vcd file "keccak_core_heavy_tb.vcd"' > run_fail.macro
	@echo 'vcd add -r /keccak_core_heavy_tb/*' >> run_fail.macro
	@echo 'run -all' >> run_fail.macro
	@echo 'quit' >> run_fail.macro
	vsim -c -do run_fail.macro work.keccak_core_heavy_tb +TEST_ID=$(TEST_ID) -l keccak_core_heavy_tb_fail_$(TEST_ID).log
	@rm -f run_fail.macro
endif
