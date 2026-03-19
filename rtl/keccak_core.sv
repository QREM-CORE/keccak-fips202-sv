/*
 * Module Name: keccak_core
 * Author: Kiet Le
 * Description:
 * - Fully compliant FIPS 202 Keccak Permutation Core.
 * - Supports SHA3-256, SHA3-512, SHAKE128, and SHAKE256 modes via 'keccak_mode_i'.
 * - Implements standard AXI4-Stream Sink/Source interfaces for data IO.
 * - Features a Multi-Cycle Iterative Architecture (Theta, Rho, Pi, Chi, Iota) for high frequency.
 * - Handles arbitrary message lengths including correct '10*1' padding logic.
 * - Supports infinite output generation (XOF) for SHAKE modes with external 'stop_i' control.
 *
 * Performance & Latency:
 * - Architecture: Iterative decomposition (1 Keccak Round = 5 Clock Cycles).
 * - Permutation Latency: 120 clock cycles per block (24 rounds * 5 cycles/round).
 * - Squeeze Output: Combinational (Data is valid immediately upon entering Squeeze state).
 *
 * Interface Notes:
 * - Configuration (mode/rate) is latched only on the rising edge of 'start_i'.
 * - 't_ready_o' acts as backpressure; upstream must hold data if low.
 *
 * Usage Contract:
 * - start_i must be asserted for one cycle when IDLE.
 * - Input data must follow AXI4-Stream semantics.
 * - stop_i is only sampled during SQUEEZE.
 * - keccak_mode_i must remain stable after start_i.
 */

`default_nettype none
`timescale 1ns / 1ps

import keccak_pkg::*;

module keccak_core (
    input   wire                            clk,
    input   wire                            rst,

    input   wire                            start_i,
    input   keccak_mode                     keccak_mode_i,
    input   wire                            stop_i,

    // AXI4-Stream Interface - Sink (Input)
    axis_if.sink                            s_axis,

    // AXI4-Stream Interface - Source (Output)
    axis_if.source                          m_axis
);
    // Dataflow Summary:
    // AXI Sink -> Absorb (KAU) -> State Array
    // Padding (SPU) -> Permutation (KSU)
    // State Array -> Squeeze (KOU) -> AXI Source

    // ==========================================================
    // 0. INTERFACE BRIDGE / ADAPTER
    // ==========================================================

    // Sink Internal Signals
    logic [DWIDTH-1:0]      t_data_i;
    logic                   t_valid_i;
    logic                   t_last_i;
    logic [KEEP_WIDTH-1:0]  t_keep_i;
    logic                   t_ready_o;

    // Source Internal Signals
    logic [DWIDTH-1:0]      t_data_o;
    logic                   t_valid_o;
    logic                   t_last_o;
    logic [KEEP_WIDTH-1:0]  t_keep_o;
    logic                   t_ready_i;

    // Assignments: Sink (Input from Interface -> Internal)
    assign t_data_i       = s_axis.tdata;
    assign t_valid_i      = s_axis.tvalid;
    assign t_last_i       = s_axis.tlast;
    assign t_keep_i       = s_axis.tkeep;
    assign s_axis.tready  = t_ready_o; // Output to Interface

    // Assignments: Source (Internal -> Output to Interface)
    assign m_axis.tdata   = t_data_o;
    assign m_axis.tvalid  = t_valid_o;
    assign m_axis.tlast   = t_last_o;
    assign m_axis.tkeep   = t_keep_o;
    assign t_ready_i      = m_axis.tready; // Input from Interface

    // ==========================================================
    // 1. KECCAK LOGIC, WIRES, REGISTERS AND ENUMS
    // ==========================================================

    // 1A. Enum Instantiations
    // ----------------------------------------------------------

    // FSM States
    typedef enum {
        STATE_IDLE,
        STATE_ABSORB,
        STATE_SUFFIX_PADDING,
        STATE_THETA,
        STATE_RHO,
        STATE_PI,
        STATE_CHI,
        STATE_IOTA,
        STATE_SQUEEZE
    } state_t;
    state_t state, next_state;

    // State Array Write Selector Options
    typedef enum {
        KSU_SEL,
        ABSORB_SEL,
        PADDING_SEL
    } sa_in_sel_t;
    sa_in_sel_t state_array_in_sel;

    // 1B. Registers
    // ----------------------------------------------------------

    // 1600-bit State Array using to hold the state of keccak core.
    // See FIPS202 Section 3.1.1 for more information on state array.
    reg [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] state_array;

    // KSU Permutation Registers
    reg [ROUND_INDEX_SIZE-1:0]      round_idx;
    reg [STEP_SEL_WIDTH-1:0]        step_sel;

    // Keccak Parameter Setup Registers
    reg [RATE_WIDTH-1:0]            rate; // Rate in BITS (e.g., 1088 for SHA3-256)
    reg [SUFFIX_WIDTH-1:0]          suffix;

    // Keccak Mode Register
    reg [MODE_SEL_WIDTH-1:0]        current_mode;

    // Absorb Phase Registers
    reg                             absorb_done; // Absorb stage fully complete flag
    reg     [BYTE_ABSORB_WIDTH-1:0] bytes_absorbed; // # of bytes absorbed in the current rate block
    reg     [DWIDTH-1:0]            carry_over;     // Partial AXI beat that crosses rate boundary and must be
                                                    // re-absorbed in the next cycle
    reg                             has_carry_over; // Carry over flag
    reg     [KEEP_WIDTH-1:0]        carry_keep;
    reg                             msg_received;   // Full message has been received

    // Squeeze Signals
    logic   [BYTE_ABSORB_WIDTH-1:0] bytes_squeezed;

    // 1C. Enable Wires
    // ----------------------------------------------------------

    // Misc. FSM Enables
    logic state_array_wr_en;
    logic init_wr_en;
    logic rst_round_idx_en;
    logic inc_round_idx_en;

    // Absorb Enable Wires
    logic absorb_wr_en;
    logic msg_received_wr_en;
    logic complete_absorb_en;

    // Permutation Enable
    logic perm_en;

    // Squeeze Enable
    logic squeeze_wr_en;

    // 1D. Module Wires and Registers
    // ----------------------------------------------------------

    // Keccak Parameter Unit (KPU) Module Wires
    wire [MODE_SEL_WIDTH-1:0]       KPU_MODE_I;

    wire [RATE_WIDTH-1:0]           KPU_RATE_O;
    wire [SUFFIX_WIDTH-1:0]         KPU_SUFFIX_O;

    // Keccak Step Unit (KSU) Module Wires
    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KSU_STATE_ARRAY_I;
    wire [ROUND_INDEX_SIZE-1:0]     KSU_ROUND_INDEX_I;
    wire [STEP_SEL_WIDTH-1:0]       KSU_STEP_SEL_I;

    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KSU_STATE_ARRAY_O;

    // Keccak Absorb Unit (KAU) Module Wires
    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KAU_STATE_ARRAY_I;
    wire [RATE_WIDTH-1:0]           KAU_RATE_I;
    wire [BYTE_ABSORB_WIDTH-1:0]    KAU_BYTES_ABSORBED_I;
    wire [DWIDTH-1:0]               KAU_MSG_I;
    wire [KEEP_WIDTH-1:0]           KAU_KEEP_I;
    wire                            KAU_PAD_EN_I;
    wire [SUFFIX_WIDTH-1:0]         KAU_SUFFIX_I;

    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KAU_STATE_ARRAY_O;
    wire [BYTE_ABSORB_WIDTH-1:0]    KAU_BYTES_ABSORBED_O;
    wire                            KAU_HAS_CARRY_OVER_O;
    wire [KEEP_WIDTH-1:0]           KAU_CARRY_KEEP_O;
    wire [DWIDTH-1:0]               KAU_CARRY_OVER_O;

    // Suffix Padder Unit (Collapsed into KAU)

    // Squeeze Output Unit (KOU) Module Wires
    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KOU_STATE_ARRAY_I;
    wire [MODE_SEL_WIDTH-1:0]       KOU_MODE_I;
    wire [RATE_WIDTH-1:0]           KOU_RATE_I;
    wire [BYTE_ABSORB_WIDTH-1:0]    KOU_BYTES_SQUEEZED_I;

    wire [BYTE_ABSORB_WIDTH-1:0]    KOU_BYTES_SQUEEZED_O;
    wire                            KOU_PERM_NEEDED_O;
    wire [DWIDTH-1:0]               KOU_DATA_O;
    wire [KEEP_WIDTH-1:0]           KOU_KEEP_O;
    wire                            KOU_LAST_O;

    // 1E. Wire Assignments
    // ----------------------------------------------------------

    // Max Byte Absorb Value
    logic [RATE_WIDTH-1:0] max_bytes_absorbed;
    assign max_bytes_absorbed   = rate >> 3;

    // Calculate Ready
    // We are ready if we aren't full, aren't processing overflow, and aren't done.
    logic internal_ready;
    assign internal_ready = (bytes_absorbed != max_bytes_absorbed) &&
                            (!has_carry_over) &&
                            (!msg_received);

    // ==========================================================
    // 2. HELPER MODULE INSTANTIATIONS
    // ==========================================================

    // 2A. KECCAK PARAMETER UNIT (KPU)
    // ----------------------------------------------------------
    // Module to get sha3 parameters during initializtion
    keccak_param_unit KPU (
        .keccak_mode_i  (KPU_MODE_I),

        .rate_o         (KPU_RATE_O),
        .suffix_o       (KPU_SUFFIX_O)
    );
    assign KPU_MODE_I = keccak_mode_i;

    // 2B. KECCAK STEP UNIT (KSU)
    // ----------------------------------------------------------
    // Keccak Step Mapping Operations Module
    keccak_step_unit KSU (
        .state_array_i  (KSU_STATE_ARRAY_I),
        .round_index_i  (KSU_ROUND_INDEX_I),
        .step_sel_i     (KSU_STEP_SEL_I),

        .state_array_o  (KSU_STATE_ARRAY_O)
    );
    assign KSU_STATE_ARRAY_I    = state_array;
    assign KSU_ROUND_INDEX_I    = round_idx;
    assign KSU_STEP_SEL_I       = step_sel;

    // 2C. KECCAK ABSORB UNIT (KAU) (Now handles Optional Padding)
    // ----------------------------------------------------------
    // Module to handle absorbing of input message and padding
    keccak_absorb_unit KAU (
        .state_array_i      (KAU_STATE_ARRAY_I),
        .rate_i             (KAU_RATE_I),
        .bytes_absorbed_i   (KAU_BYTES_ABSORBED_I),
        .msg_i              (KAU_MSG_I),
        .keep_i             (KAU_KEEP_I),
        .pad_en_i           (KAU_PAD_EN_I),
        .suffix_i           (KAU_SUFFIX_I),

        .state_array_o      (KAU_STATE_ARRAY_O),
        .bytes_absorbed_o   (KAU_BYTES_ABSORBED_O),
        .has_carry_over_o   (KAU_HAS_CARRY_OVER_O),
        .carry_keep_o       (KAU_CARRY_KEEP_O),
        .carry_over_o       (KAU_CARRY_OVER_O)
    );
    assign KAU_STATE_ARRAY_I    = state_array;
    assign KAU_RATE_I           = rate;
    assign KAU_BYTES_ABSORBED_I = bytes_absorbed;
    assign KAU_MSG_I            = has_carry_over ? { 64'b0, carry_over} : t_data_i;
    assign KAU_KEEP_I           = has_carry_over ? {  8'b0, carry_keep} : t_keep_i;
    assign KAU_PAD_EN_I         = (state == STATE_SUFFIX_PADDING);
    assign KAU_SUFFIX_I         = suffix;

    // 2D. SUFFIX PADDER UNIT (SPU)
    // ----------------------------------------------------------
    // Collapsed and merged into KAU logic to save Area payload!

    // 2E. SQUEEZE OUTPUT UNIT (KOU)
    // ----------------------------------------------------------
    keccak_output_unit KOU (
        .state_array_i          (KOU_STATE_ARRAY_I),
        .keccak_mode_i          (KOU_MODE_I),
        .rate_i                 (KOU_RATE_I),
        .bytes_squeezed_i       (KOU_BYTES_SQUEEZED_I),

        .bytes_squeezed_o       (KOU_BYTES_SQUEEZED_O),
        .squeeze_perm_needed_o  (KOU_PERM_NEEDED_O),
        .data_o                 (KOU_DATA_O),
        .keep_o                 (KOU_KEEP_O),
        .last_o                 (KOU_LAST_O)
    );
    assign KOU_STATE_ARRAY_I    = state_array;
    assign KOU_MODE_I           = current_mode;
    assign KOU_RATE_I           = rate;
    assign KOU_BYTES_SQUEEZED_I = bytes_squeezed;

    // ==========================================================
    // 3. 3-PROCESS CONTROL FSM
    // ==========================================================

    // 3A. FSM Control Process 1: State Register (Sequential)
    // ----------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STATE_IDLE;
        end else begin
            state <= next_state;
        end
    end

    // 3B. FSM Control Process 2: Next State Decoder (Combinational)
    // ----------------------------------------------------------
    always_comb begin
        next_state = state;

        case(state)
            STATE_IDLE : begin
                if (start_i) begin
                    next_state = STATE_ABSORB;
                end else begin
                    next_state = STATE_IDLE;
                end
            end

            STATE_ABSORB : begin
                // PRIORITY 1: If current rate block is full, run permutation
                if (bytes_absorbed == max_bytes_absorbed) begin
                    next_state = STATE_THETA;

                // PRIORITY 2: Check if there is a unhandled carry over
                end else if (has_carry_over) begin
                    next_state = STATE_ABSORB;

                // PRIORITY 3: Message fully received, move on to padding stage
                end else if (msg_received) begin
                    next_state = STATE_SUFFIX_PADDING;

                // PRIORITY 4: Check if there is valid input and to process if so
                end else if (t_valid_i && internal_ready) begin
                    next_state = STATE_ABSORB;

                // PRIORITY 5: Message not yet fully received, waiting for t_valid
                end else begin
                    next_state = STATE_ABSORB;
                end
            end

            STATE_SUFFIX_PADDING : begin
                next_state = STATE_THETA;
            end

            // ------------ PERMUTATION STEP MAPPING STATES ------------
            STATE_THETA : begin
                next_state = STATE_RHO;
            end

            STATE_RHO : begin
                next_state = STATE_PI;
            end

            STATE_PI : begin
                next_state = STATE_CHI;
            end

            STATE_CHI : begin
                next_state = STATE_IOTA;
            end

            STATE_IOTA : begin
                // Keccak-f[1600] requires 24 rounds (Indices 0 to 23)
                if (round_idx == 'd23) begin
                    if (absorb_done) begin
                        next_state = STATE_SQUEEZE;
                    end else begin
                        next_state = STATE_ABSORB;
                    end
                end else begin
                    next_state = STATE_THETA;
                end
            end
            // ---------------------------------------------------------

            STATE_SQUEEZE : begin
                // PRIORITY 1: External Stop
                if (stop_i) begin
                    next_state = STATE_IDLE;

                // PRIORITY 2: Output Data
                end else if (t_ready_i) begin
                    // A. Check Fixed Hash Done (SHA3-*)
                    if (KOU_LAST_O) begin
                        next_state = STATE_IDLE;

                    // B. Check Rate Empty -> Re-Permute (SHAKE)
                    end else if (KOU_PERM_NEEDED_O) begin
                        next_state = STATE_THETA;

                    // C. Continue Squeezing
                    end else begin
                        next_state = STATE_SQUEEZE;
                    end

                // PRIORITY 3: Receiver not ready? WAIT here.
                end else begin
                    next_state = STATE_SQUEEZE;
                end
            end

            default : begin
                next_state = STATE_IDLE;
            end
        endcase
    end

    // 3C. FSM Control Process 3: Action Decoder (Combinational)
    // ----------------------------------------------------------
    always_comb begin
        // Defaults:

        // ----- Outputs -----
        // AXI4-Stream Signals - Sink
        t_ready_o   = '0;
        // AXI4-Stream Signals - Source
        t_data_o    = '0;
        t_valid_o   = '0;
        t_last_o    = '0;
        t_keep_o    = '0;

        // ----- Internal Control Signals -----
        state_array_wr_en   = 1'b0;
        step_sel            = IDLE_STEP;
        init_wr_en          = 1'b0;

        // Absorb Wires
        absorb_wr_en        = 1'b0;
        msg_received_wr_en  = 1'b0;
        complete_absorb_en  = 1'b0;

        // Step Mapping
        perm_en             = 1'b0;
        rst_round_idx_en    = 1'b0;
        inc_round_idx_en    = 1'b0;

        // Squeeze Signals
        squeeze_wr_en       = 1'b0;

        case(state)
            STATE_IDLE : begin
                if (start_i) begin
                    init_wr_en = 1'b1;
                end
            end

            STATE_ABSORB : begin
                t_ready_o = internal_ready;

                // PRIORITY 1: If current rate block is full, run permutation
                if (bytes_absorbed == max_bytes_absorbed) begin
                    perm_en = 1'b1;

                // PRIORITY 2: Check if there is a unhandled carry over
                end else if (has_carry_over) begin
                    absorb_wr_en = 1'b1;
                    state_array_wr_en = 1'b1;
                    state_array_in_sel = ABSORB_SEL;

                // PRIORITY 3: Message fully received, move on to padding stage
                end else if (msg_received) begin
                    // Need this extra register for edge case:
                    // - when message matches rate (msg_received, no carry over)
                    complete_absorb_en = 1'b1;

                // PRIORITY 4: Check if there is valid input and to process if so
                end else if (t_valid_i && internal_ready) begin
                    absorb_wr_en = 1'b1;
                    state_array_wr_en = 1'b1;
                    state_array_in_sel = ABSORB_SEL;
                    if (t_last_i) begin
                        msg_received_wr_en = 1'b1;
                    end
                end
            end

            STATE_SUFFIX_PADDING : begin
                state_array_wr_en   = 1'b1;
                state_array_in_sel  = PADDING_SEL;
                perm_en             = 1'b1;
            end

            // ------------ PERMUTATION STEP MAPPING STATES ------------
            STATE_THETA : begin
                state_array_wr_en   = 1'b1;
                step_sel            = THETA_STEP;
                state_array_in_sel  = KSU_SEL;
            end

            STATE_RHO : begin
                state_array_wr_en   = 1'b1;
                step_sel            = RHO_STEP;
                state_array_in_sel  = KSU_SEL;
            end

            STATE_PI : begin
                state_array_wr_en   = 1'b1;
                step_sel            = PI_STEP;
                state_array_in_sel  = KSU_SEL;
            end

            STATE_CHI : begin
                state_array_wr_en   = 1'b1;
                step_sel            = CHI_STEP;
                state_array_in_sel  = KSU_SEL;
            end

            STATE_IOTA : begin
                // Keccak-f[1600] requires 24 rounds (Indices 0 to 23)
                if (round_idx == 'd23) begin
                    rst_round_idx_en = 1'b1;
                end else begin
                    inc_round_idx_en = 1'b1;
                end

                state_array_wr_en   = 1'b1;
                step_sel            = IOTA_STEP;
                state_array_in_sel  = KSU_SEL;
            end
            // ---------------------------------------------------------

            STATE_SQUEEZE : begin
                t_data_o    = KOU_DATA_O;
                t_valid_o   = !stop_i;
                t_last_o    = KOU_LAST_O;
                t_keep_o    = KOU_KEEP_O;

                if (stop_i) begin
                    init_wr_en = 1'b1;

                end else if (t_ready_i) begin
                    // A. Check Fixed Hash Done (SHA3-*)
                    if (KOU_LAST_O) begin
                        init_wr_en = 1'b1;

                    // B. Check Rate Empty -> Re-Permute (SHAKE)
                    end else if (KOU_PERM_NEEDED_O) begin
                        perm_en = 1'b1; // Reset counters

                    // C. Continue Squeezing
                    end else begin
                        squeeze_wr_en = 1'b1;
                    end
                end
            end
            default : begin
                // Defaults
                t_ready_o   = '0;
                t_data_o    = '0;
                t_valid_o   = '0;
                t_last_o    = '0;
                t_keep_o    = '0;
            end
        endcase
    end

    // ==========================================================
    // 4. KECCAK DATAPATH UPDATING
    // ==========================================================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state_array         <= 'b0;
            round_idx           <= 'b0;
            msg_received        <= 'b0;

            // Absorb Signals
            absorb_done         <= 'b0;
            bytes_absorbed      <= 'b0;
            carry_over          <= 'b0;
            has_carry_over      <= 'b0;
            carry_keep          <= 'b0;

            // Squeeze Signals
            bytes_squeezed      <= 'b0;
        end else begin
            // --- Initialization & Reset ---
            if (init_wr_en) begin
                // 1. Setup Parameters
                current_mode    <= keccak_mode_i;
                rate            <= KPU_RATE_O;
                suffix          <= KPU_SUFFIX_O;

                // 2. CRITICAL: Wipe the State Logic
                state_array     <= '0;  // Must be 0 before starting new Absorb
                bytes_absorbed  <= '0;
                bytes_squeezed  <= '0;
                msg_received    <= '0;

                // 3. Clear Internal Flags
                absorb_done     <= '0;
                has_carry_over  <= '0;
                carry_over      <= '0;
                carry_keep      <= '0;
                round_idx       <= '0;

            // Reset bytes absorbed after absorb permutation
            end else if (perm_en) begin
                bytes_absorbed  <= '0;
                bytes_squeezed  <= '0;
            end

            // --- State Array Update ---
            if (state_array_wr_en) begin
                case (state_array_in_sel)
                    KSU_SEL : begin
                        state_array <= KSU_STATE_ARRAY_O;
                    end
                    ABSORB_SEL : begin
                        state_array <= KAU_STATE_ARRAY_O;
                    end
                    PADDING_SEL : begin
                        state_array <= KAU_STATE_ARRAY_O;
                    end
                    default : begin
                        state_array <= state_array;
                    end
                endcase
            end

            // --- Absorb Counters & Flags ---
            if (absorb_wr_en) begin
                bytes_absorbed  <= KAU_BYTES_ABSORBED_O;

                if (KAU_HAS_CARRY_OVER_O) begin
                    has_carry_over  <= 1'b1;
                    carry_over      <= KAU_CARRY_OVER_O;
                    carry_keep      <= KAU_CARRY_KEEP_O;
                end else begin
                    has_carry_over  <= 1'b0;
                end
            end
            // Set flag for absorb completion
            if (complete_absorb_en) begin
                absorb_done <= 1'b1;
            end
            // If source has completed full message transfer
            if (msg_received_wr_en) begin
                msg_received <= 1'b1;
            end

            // --- Permutation Round Control ---
            if (rst_round_idx_en) begin
                round_idx <= 'b0;
            end else if (inc_round_idx_en) begin
                round_idx <= round_idx + 'b1;
            end

            // --- Squeeze Counters ---
            if (squeeze_wr_en) begin
                bytes_squeezed <= KOU_BYTES_SQUEEZED_O;
            end
        end
    end

    // ==========================================================
    // 5. ASSERTIONS (Safety & Protocol Checks)
    // ==========================================================
    // synthesis translate_off

    // 5A. Internal Logic Safety
    // ----------------------------------------------------------

    // ASSERTION 1: Bytes Absorbed Overflow Protection
    // Critical: If this fires, your counter logic is broken.
    property p_bytes_absorbed_overflow;
        @(posedge clk) disable iff (rst)
        (RATE_WIDTH'(bytes_absorbed) <= (rate >> 3));
    endproperty
    assert property (p_bytes_absorbed_overflow)
        else $error("FATAL: bytes_absorbed exceeded maximum rate!");

    // ASSERTION 2: FSM State Validity
    // Ensures the FSM never enters an unknown state (X/Z)
    always @(posedge clk) begin
        if (!rst && $isunknown(state))
            $fatal("FATAL: FSM is in an unknown state!");
    end

    // ASSERTION 3: Mode Stability
    // The Keccak mode should NOT change while the core is busy (not IDLE).
    property p_mode_stable;
        @(posedge clk) disable iff (rst)
        (state != STATE_IDLE) |-> $stable(current_mode);
    endproperty
    assert property (p_mode_stable)
        else $error("ERROR: current_mode changed while core was active!");

    // 5B. AXI4-Stream Protocol Compliance (Sink/Input)
    // ----------------------------------------------------------

    // ASSERTION 4: AXI Valid-Ready Stability (The "Handshake Rule")
    // Once Valid is asserted, Data/Keep/Last must NOT change until Ready goes high.
    property p_axi_sink_stability;
        @(posedge clk) disable iff (rst)
        ($past(t_valid_i) && !$past(t_ready_o)) |-> (
            $stable(t_valid_i) &&
            $stable(t_data_i) &&
            $stable(t_keep_i) &&
            $stable(t_last_i)
        );
    endproperty
    assert property (p_axi_sink_stability)
        else $error("VIOLATION: AXI Sink violated Valid stability rule!");

    // ASSERTION 5: No Data Loss during Backpressure (Sink)
    // Ensure we do not enable writes/absorption if we are telling the master to wait.
    property p_backpressure_safety;
        @(posedge clk) disable iff (rst)
        (!t_ready_o) |-> (!absorb_wr_en);
    endproperty
    assert property (p_backpressure_safety)
        else $error("VIOLATION: Accepted data while Ready was LOW (Backpressure failure)!");

    // 5C. AXI4-Stream Protocol Compliance (Source/Output)
    // ----------------------------------------------------------

    // (Valid stability assertion removed for strict Verilator compatibility)

    // ----------------------------------------------------------
    // 5D. Keccak Specific Rules
    // ----------------------------------------------------------

    // ASSERTION 7: Squeeze Counter Overflow
    // Should never squeeze more bytes than the rate allows before re-permuting.
    property p_squeeze_overflow;
        @(posedge clk) disable iff (rst)
        (RATE_WIDTH'(bytes_squeezed) <= (rate >> 3));
    endproperty
    assert property (p_squeeze_overflow)
        else $error("FATAL: Squeeze counter exceeded rate!");

    // synthesis translate_on

endmodule

`default_nettype wire
