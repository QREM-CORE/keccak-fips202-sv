# Keccak/SHA3 (FIPS202) Hardware Accelerator (SystemVerilog)

![Language](https://img.shields.io/badge/Language-SystemVerilog-blue)
![Standard](https://img.shields.io/badge/Standard-FIPS%20202-green)
![Interface](https://img.shields.io/badge/Interface-AXI4--Stream-orange)
![Verification](https://img.shields.io/badge/Verification-SVA%20%26%20NIST-purple)
![License](https://img.shields.io/badge/License-MIT-lightgrey)

A high-frequency, fully synthesizable hardware implementation of the **Keccak Permutation** and **SHA-3/SHAKE** hashing algorithms.

This core utilizes a **Multi-Cycle Iterative Architecture**. To maximize operating frequency ($F_{max}$), the Keccak round function is decomposed into 5 distinct clock cycles ($\theta, \rho, \pi, \chi, \iota$). This reduces the combinatorial path depth significantly compared to single-cycle implementations, making it suitable for high-speed FPGA and ASIC targets.

## 🚀 Key Features

* **FIPS 202 Compliant:** Byte-exact implementation of SHA-3 and SHAKE standards. Verified against **3,592 NIST Test Vectors**.
* **Optimized PPA Profile:**
    * **Power:** Dynamic operand isolation gates internal permutation logic when inactive.
    * **Performance:** Word-aligned output multiplexing maps naturally to FPGA primitives, maximizing $F_{max}$.
    * **Area:** Padding logic shares the XOR-plane resources directly within the Absorb Unit.
* **Runtime Configurable:** Switch between 4 modes dynamically via input signals:
    * **Fixed-Length:** SHA3-256, SHA3-512
    * **Extendable-Output (XOF):** SHAKE128, SHAKE256
* **Standard Interface:** **AXI4-Stream** compliant Sink (Input) and Source (Output) with full backpressure support.
* **Robust Architecture:**
    * **Internal Padding:** Automatically handles the FIPS 202 `10*1` padding rule and Domain Separation Suffixes.
* **Production Ready:** Written with `default_nettype none` to prevent implicit wire hazards and supports explicit width casting.

## 📦 Installation & Cloning

Because this repository uses shared RTL libraries, you must clone recursively:

```bash
git clone --recursive git@github.com:QREM-CORE/keccak-core.git
# OR if you already cloned it:
git submodule update --init --recursive
```

## 📊 Supported Modes

| Mode | Security Strength | Rate (r) | Capacity (c) | Suffix |
| :--- | :--- | :--- | :--- | :--- |
| **SHA3-256** | 128-bit | 1088 bits | 512 bits | `01` |
| **SHA3-512** | 256-bit | 576 bits | 1024 bits | `01` |
| **SHAKE128** | 128-bit | 1344 bits | 256 bits | `1111` |
| **SHAKE256** | 256-bit | 1088 bits | 512 bits | `1111` |

## 🔄 Control Protocol

The core follows a strict **Start → Absorb → Permute → Squeeze** lifecycle.

1. **Initialization**
   * Assert `start_i` for one cycle while in `STATE_IDLE`
   * Internally:
     * Mode, rate, and suffix are latched
     * State array is wiped to zero
     * Absorb/squeeze counters are reset

2. **Absorption Phase**
   * Input data is streamed via AXI4-Stream sink
   * Backpressure is applied when permutations are running
   * `t_last_i` marks the final message fragment
   * Arbitrary message lengths are supported via `t_keep_i`

3. **Padding & Final Permutation**
   * FIPS 202 domain suffix and `10*1` padding are injected automatically
   * A final 24-round permutation is executed

4. **Squeeze Phase**
   * Output is streamed via AXI4-Stream source
   * For SHA3 modes, output terminates automatically
   * For SHAKE modes, output continues indefinitely until `stop_i` is asserted

⚠️ **Important:** `keccak_mode_i` must remain stable after `start_i` until the core returns to `STATE_IDLE`.

## 🛠️ Architecture Overview

### Structural Data Path
![Keccak Core Structural Diagram](docs/KECCAK_STRUCTURAL_DIAGRAM.jpg)

The architecture centers around a **1600-bit (200-byte) State Array** that circulates through processing units in a feedback loop:

* **Keccak Absorb Unit (KAU):** Manages the "Sponge" construction by XORing incoming AXI data streams into the state array. It handles partial-block buffering, rate-boundary crossings, and dynamically injects FIPS 202 domain suffixes and `10*1` padding using shared hardware resources.
* **Keccak Step Unit (KSU):** The computational heart of the core. It executes the 24 rounds of permutations ($\theta, \rho, \pi, \chi, \iota$) utilizing exact operand isolation for power efficiency.
* **Keccak Output Unit (KOU):** Truncates the state array to the desired rate (r) and linearizes the data onto the AXI4-Stream output bus using word-aligned indexing during the Squeeze phase.

### Finite State Machine (Control)
![Keccak Core FSM Diagram](docs/KECCAK_CORE_FSM.jpg)

The design is orchestrated by a centralized FSM with the following states:

* **IDLE**
  * Waits for `start_i`
  * Core is quiescent; AXI interfaces inactive

* **ABSORB**
  * Accepts AXI4-Stream input data
  * Handles partial words using `t_keep`
  * Supports carry-over when rate boundaries are crossed
  * Automatically schedules permutations when the rate is full

* **SUFFIX_PADDING**
  * Injects FIPS 202 domain separation suffix
  * Appends final `1` bit according to `10*1` padding rule

* **PERMUTATION PIPELINE**
  * Each Keccak round is decomposed into 5 FSM states:
    * `THETA → RHO → PI → CHI → IOTA`
  * A full permutation requires **24 rounds × 5 cycles = 120 cycles**

* **SQUEEZE**
  * Streams output blocks via AXI4-Stream
  * Automatically re-enters permutation when rate is exhausted
  * Terminates on:
    * Hash completion (SHA3)
    * External `stop_i` (SHAKE)

### Absorption with Rate Boundary Carry-Over

The absorb unit supports input fragments that cross rate boundaries without data loss.

* Partial input words are tracked using `t_keep`
* Excess bytes are buffered internally (`carry_over`)
* Carry-over data is automatically re-injected on the next absorb cycle
* No external re-alignment or padding is required from the user

This allows seamless hashing of arbitrarily-sized messages using wide AXI data paths.

## ⏱️ Performance Characteristics

* **Permutation latency:** 120 cycles per Keccak-f[1600]
* **Absorb throughput:** 256 bits per accepted AXI beat
* **Squeeze throughput:** 256 bits per cycle (subject to backpressure)
* **Critical path:** Single Keccak step (Θ, ρ, π, χ, or ι)

The multi-cycle round decomposition significantly reduces combinational depth,
enabling higher achievable clock frequencies compared to single-cycle designs.


## 🔌 Signal Description

### Parameters
* `DWIDTH`: Input/Output Data Width (Default: **256 bits**)

### Ports

| Signal Group | Name | Direction | Type | Description |
| :--- | :--- | :--- | :--- | :--- |
| **System** | `clk` | Input | Wire | System Clock (Rising Edge) |
| | `rst` | Input | Wire | Synchronous Active-High Reset |
| **Control** | `start_i` | Input | Wire | Pulse high to reset FSM and start new hash |
| | `keccak_mode_i` | Input | Wire | `00`: SHA3-256, `01`: SHA3-512, `10`: SHAKE128, `11`: SHAKE256 |
| | `stop_i` | Input | Wire | Stops output generation (Required for XOF modes) |
| **AXI Stream** | `s_axis` | Sink | Interface | **Sink Interface** (Input). Accepts Message Data. |
| | `m_axis` | Source | Interface | **Source Interface** (Output). Outputs Hash Data. |

### Interface Details (`axis_if`)

The `s_axis` and `m_axis` ports utilize the `axis_if` SystemVerilog interface (located in `lib/common_rtl`). This bundles the standard AXI4-Stream signals as follows:

| Interface Signal | Width | Function |
| :--- | :--- | :--- |
| `tdata` | `[DWIDTH-1:0]` | **Data Payload**. Contains the message chunk (Sink) or hash result (Source). |
| `tvalid` | `1` | **Valid**. Asserted by the source when `tdata` is valid. |
| `tready` | `1` | **Ready**. Asserted by the sink to indicate it can accept data (Backpressure). |
| `tlast` | `1` | **Last**. Asserted to mark the final chunk of a message packet. |
| `tkeep` | `[DWIDTH/8-1:0]` | **Keep**. Byte-enable mask indicating which bytes in `tdata` are valid. |

## ⚠️ Integration Notes

* **Latency & Backpressure:** The core deasserts `s_axis.tready` for 120 cycles during the permutation phase. Upstream buffers (FIFOs) must be sized to handle this pause if streaming continuously.
* **SHAKE Infinite Stream:** In XOF modes (SHAKE128/256), the `m_axis` output stream is **infinite**. You *must* assert `stop_i` or drop `m_axis.tready` to halt data generation.
* **Partial Bytes:** `s_axis.tkeep` is fully respected, allowing messages that are not 256-bit aligned.

## 💻 Simulation & Verification

This project utilizes a dual-verification strategy: **SystemVerilog Assertions (SVA)** for runtime protocol checking and **Python-generated NIST vectors** for standard compliance. Continuous Integration (CI) is handled via GitHub Actions to ensure build integrity on every Pull Request.

### 🛡️ NIST FIPS 202 Compliance

This core has been verified against the official **NIST Cryptographic Algorithm Validation Program (CAVP)** test vectors. A dedicated "Heavy" testbench (`keccak_core_heavy_tb.sv`) handles the automated regression of over 3,500 test vectors using a Two-Pass Python Runner to optimize disk usage.

#### Verification Results
| Standard | File Type | Count | Status |
| :--- | :--- | :--- | :--- |
| **SHA3** | `ShortMsg`, `LongMsg` | 100% | ✅ PASS |
| **SHAKE** | `ShortMsg`, `LongMsg`, `VariableOut` | 100% | ✅ PASS |
| **Total** | **All Vectors** | **3,592** | **PASS** |

### 1. Prerequisites (Linux/Ubuntu)
The simulation environment relies on **ModelSim (Intel FPGA Lite)**. Since ModelSim ASE is a 32-bit application, running it on modern 64-bit Linux distributions (like Ubuntu 20.04/22.04) requires specific 32-bit compatibility libraries and a kernel check patch.

---

**Install Dependencies:**
```bash
# 1. Add architecture and update
sudo dpkg --add-architecture i386
sudo apt-get update

# 2. Install core build tools
sudo apt-get install -y wget build-essential

# 3. Install required 32-bit libraries (Required for ModelSim ASE)
sudo apt-get install -y libc6:i386 libncurses5:i386 libstdc++6:i386 \
lib32ncurses6 libxft2 libxft2:i386 libxext6 libxext6:i386
```
**Patching ModelSim (Critical for Modern Linux):**
If ModelSim fails to launch or hangs, apply these patches to the `vco` script (located in `<install_dir>/modelsim_ase/vco`) to fix OS detection and force 32-bit mode:
```bash
# Fix Red Hat directory detection logic
sudo sed -i 's/linux_rh[[:digit:]]\+/linux/g' <path_to_modelsim>/vco

# Force 32-bit mode
sudo sed -i 's/MTI_VCO_MODE:-\"\"/MTI_VCO_MODE:-\"32\"/g' <path_to_modelsim>/vco
```
### 2. Running Simulations
The repository includes a Makefile that handles compiling, running, and waveform generation for multiple testbenches.

---

**Setup Environment:**
Ensure the path in `env.sh` points to your specific ModelSim installation (e.g., `/opt/intelFPGA_lite/...` or `/pkgcache/...`).
```bash
source env.sh
```

**Run All Tests:** This will execute the entire suite of unit tests and the full core integration test.
```bash
make
```

**Run Specific Test:** You can target individual modules (Unit Tests) using the run_<tb_name> target:
```bash
make run_theta_step_tb
make run_keccak_core_tb
make run_keccak_absorb_unit_tb
```
**Clean Artifacts:** Removes generated work libraries and .vcd waveform files.
```bash
make clean
```
**Viewing Waveforms:** Every simulation run automatically generates a corresponding Value Change Dump (.vcd) file (e.g., keccak_core_tb.vcd) which can be opened in GTKWave or ModelSim.

### 3. Running the Compliance Suite

This section describes how to execute the full **NIST FIPS 202 compliance regression**, consisting of vector generation followed by a two-pass simulation run.

---

#### Step 1: Generate NIST Test Vectors

Convert the official NIST `.rsp` files into a single consolidated `vectors.txt` file consumed by the heavy testbench.

```bash
cd verif/

# Parse ALL vectors (≈ 4,000 total; full compliance run)
python parse_nist_vectors.py --full test_vectors/SHA3/*.rsp test_vectors/SHAKE/*.rsp

# OR parse a reduced subset (default: 10 per file) for quick sanity checks
# python parse_nist_vectors.py test_vectors/SHA3/*.rsp test_vectors/SHAKE/*.rsp

cd ..
```

#### Step 2: Run Compliance Regression
Invoke the heavy regression runner:
```bash
python tb/run_heavy.py
```
The regression executes in **two passes**:

- **Fast Pass**
  Runs all test vectors with waveform generation disabled for maximum throughput.

- **Debug Pass (On Failure Only)**
  Automatically re-runs the failing test ID with VCD recording enabled and archives the waveform for inspection.


#### Outputs & Artifacts

- **Logs**
  Full simulation output is written to `regression.log`.

- **Failure Artifacts**
  Waveform dumps (`.vcd`) for failing vectors are stored in `failures/`.


## 📂 File Structure

The repository is organized into RTL source, testbenches, and verification scripts:

```text
.
├── docs/                        # Architecture Diagrams & FSM Specs
├── lib/
│   └── common_rtl/              # Shared Git Submodule (AXI Interfaces)
│       └── rtl/axis_if.sv
├── rtl/                         # SystemVerilog Source Code
│   ├── keccak_core.sv           # Top-level Module
│   ├── keccak_pkg.sv            # Global Parameters & Enums
│   ├── keccak_step_unit.sv      # Permutation Round Logic
│   ├── keccak_absorb_unit.sv    # Input Buffering & XOR Logic
│   ├── keccak_output_unit.sv    # Output Linearization & Squeeze
│   └── *_step.sv                # Individual Step Modules (Chi, Rho, etc.)
├── tb/                          # SystemVerilog Testbenches
│   ├── keccak_core_tb.sv        # Integration Testbench
│   ├── keccak_core_heavy_tb.sv  # NIST Compliance Regression
│   └── *_step_tb.sv             # Unit Testbenches for Sub-modules
├── verif/                       # NIST Compliance Suite & Python Testing
|   ├── python_testing/          # Step-mapping Golden Models (Python)
│   ├── parse_nist_vectors.py    # .rsp to vectors.txt parser
│   └── test_vectors/            # Official NIST CAVP Test Vectors
├── Makefile                     # Simulation & Build automation
└── README.md
```
