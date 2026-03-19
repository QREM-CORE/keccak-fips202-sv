# Verilator Setup for WSL

This guide explains how to set up [Verilator](https://verilator.org/) locally on Windows Subsystem for Linux (WSL) to run the `keccak-fips202-sv` tests. The `Makefile` relies on Verilator >= 5.0 (specifically it uses the `--binary` flag).

Fortunately, the package manager on newer Ubuntu WSL instances (e.g., Ubuntu 24.04 Noble Numbat) provides Verilator version 5.0+.

## 1. Install Verilator and Dependencies

Open your WSL terminal and run the following command. It will update your package lists and install Verilator along with essential build tools (`g++` and `make`).

```bash
sudo apt-get update
sudo apt-get install -y verilator g++ make
```

Provide your WSL user password when prompted.

## 2. Verify Installation

Check that Verilator was installed successfully and is version **5.0** or newer:

```bash
verilator --version
```
*Expected output: `Verilator 5.020...` or similar.*

## 3. Run Simulations Locally

The `Makefile` is already configured for dual simulators. To run tests locally utilizing Verilator:

1. Navigate to the root of the repository:
   ```bash
   cd ~/repos/keccak-fips202-sv
   ```
2. Run all tests with Verilator:
   ```bash
   make run_all SIM=verilator
   ```

To run a specific testbench (e.g., `keccak_core_tb`):
```bash
make run_keccak_core_tb SIM=verilator
```

## Useful Flags used in the Project
- `--binary`: Compiles the Verilog directly into an executable (`obj_dir/V<top_module>`).
- `--trace`: Generates `.vcd` files for viewing waveforms in GTKWave. (Automatically added for standard tests).
