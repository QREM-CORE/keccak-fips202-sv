/*
 * Module Name: keccak_core
 * Author: Kiet Le
 * Description:
 * - Fully compliant FIPS 202 Keccak Permutation Core.
 * - Supports SHA3-256, SHA3-512, SHAKE128, and SHAKE256 modes via 'keccak_mode_i'.
 * - Implements standard AXI4-Stream Sink/Source interfaces for data IO.
 * - Features a 1-Cycle Round Architecture: all five step mappings (θ, ρ, π, χ, ι)
 *   execute combinationally in a single clock cycle per round.
 * - Handles arbitrary message lengths including correct '10*1' padding logic.
 * - Supports infinite output generation (XOF) and hardware-bounded length limits for SHAKE modes.
 *
 * Performance & Latency:
 * - Architecture: 1-Cycle Round (1 Keccak Round = 1 Clock Cycle).
 * - Permutation Latency: 24 clock cycles per block (24 rounds * 1 cycle/round).
 * - Critical Path: Theta (~5 gate levels) + Chi (~2 gate levels) = ~7 gate levels / ~3 LUT levels.
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
    input   wire  [XOF_LEN_WIDTH-1:0]       xof_len_i,     // 0 = Infinite/Continuous Mode, else specific byte length
    input   wire                            stop_i,

    input  wire  [DWIDTH-1:0]               s_axis_tdata,
    input  wire                             s_axis_tvalid,
    input  wire                             s_axis_tlast,
    input  wire  [KEEP_WIDTH-1:0]           s_axis_tkeep,
    output wire                             s_axis_tready,

    output wire  [DWIDTH-1:0]               m_axis_tdata,
    output wire                             m_axis_tvalid,
    output wire                             m_axis_tlast,
    output wire  [KEEP_WIDTH-1:0]           m_axis_tkeep,
    input  wire                             m_axis_tready
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
    assign t_data_i       = s_axis_tdata;
    assign t_valid_i      = s_axis_tvalid;
    assign t_last_i       = s_axis_tlast;
    assign t_keep_i       = s_axis_tkeep;
    assign s_axis_tready  = t_ready_o;

    // Assignments: Source (Internal -> Output to Interface)
    assign m_axis_tdata   = t_data_o;
    assign m_axis_tvalid  = t_valid_o;
    assign m_axis_tlast   = t_last_o;
    assign m_axis_tkeep   = t_keep_o;
    assign t_ready_i      = m_axis_tready;


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
        STATE_PERMUTE,
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
    reg [LANE_SIZE-1:0]             round_constant_r;

    // Keccak Parameter Setup Registers
    reg [RATE_WIDTH-1:0]            rate; // Rate in BITS (e.g., 1088 for SHA3-256)
    reg [BYTE_ABSORB_WIDTH-1:0]     max_bytes_absorbed_r; // Phase 2: Registered LTP opt
    reg [SUFFIX_WIDTH-1:0]          suffix;

    // Keccak Mode Register
    reg [MODE_SEL_WIDTH-1:0]        current_mode;
    reg [XOF_LEN_WIDTH-1:0]         target_xof_len;
    reg                             is_xof_fixed_len;

    // Absorb Phase Registers
    reg                             absorb_done; // Absorb stage fully complete flag
    reg     [BYTE_ABSORB_WIDTH-1:0] bytes_absorbed; // # of bytes absorbed in the current rate block

    reg                             msg_received;   // Full message has been received

    // Squeeze Signals
    logic   [BYTE_ABSORB_WIDTH-1:0]    bytes_squeezed;
    reg     [XOF_LEN_WIDTH-1:0]        xof_remaining_r; // Phase 3: Down-counter
    logic   [5:0]                   bytes_in_this_beat; // Popcount of m_axis_tkeep

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
    logic update_total_squeezed_en;

    // 1D. Module Wires and Registers
    // ----------------------------------------------------------

    // Keccak Parameter Unit (KPU) Module Wires
    wire [MODE_SEL_WIDTH-1:0]       KPU_MODE_I;

    wire [RATE_WIDTH-1:0]           KPU_RATE_O;
    wire [SUFFIX_WIDTH-1:0]         KPU_SUFFIX_O;

    // Keccak Step Unit (KSU) Module Wires
    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KSU_STATE_ARRAY_I;
    wire                            KSU_PERM_EN_I;
    wire [LANE_SIZE-1:0]            KSU_ROUND_CONST_I;

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

    // Suffix Padder Unit (Collapsed into KAU)

    // Squeeze Output Unit (KOU) Module Wires
    wire [ROW_SIZE-1:0][COL_SIZE-1:0][LANE_SIZE-1:0] KOU_STATE_ARRAY_I;
    wire [MODE_SEL_WIDTH-1:0]       KOU_MODE_I;
    wire [RATE_WIDTH-1:0]           KOU_RATE_I;
    wire [BYTE_ABSORB_WIDTH-1:0]    KOU_BYTES_SQUEEZED_I;
    wire [XOF_LEN_WIDTH-1:0]        KOU_XOF_LEN_I;
    wire                            KOU_IS_XOF_FIXED_LEN_I;
    wire [XOF_LEN_WIDTH-1:0]        KOU_TOTAL_BYTES_SQUEEZED_I;

    wire [BYTE_ABSORB_WIDTH-1:0]    KOU_BYTES_SQUEEZED_O;
    wire                            KOU_PERM_NEEDED_O;
    wire [DWIDTH-1:0]               KOU_DATA_O;
    wire [KEEP_WIDTH-1:0]           KOU_KEEP_O;
    wire [3:0]                      KOU_BYTE_COUNT_O; // Phase 2: Direct count pass
    wire                            KOU_LAST_O;

    // 1E. Wire Assignments
    // ----------------------------------------------------------

    // Phase 2 Optimization: Use registered max_bytes_absorbed to break configuration-to-logic
    // combinatorial path (LTP bottleneck).
    logic internal_ready;
    // We are ready if we aren't full and haven't finished message.
    assign internal_ready = (bytes_absorbed != max_bytes_absorbed_r) &&
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
    // Keccak Round Unit: Executes all 5 step mappings (θ→ρ→π→χ→ι) in 1 cycle.
    keccak_step_unit KSU (
        .state_array_i  (KSU_STATE_ARRAY_I),
        .perm_en_i      (KSU_PERM_EN_I),
        .round_constant_i(KSU_ROUND_CONST_I),

        .state_array_o  (KSU_STATE_ARRAY_O)
    );
    assign KSU_STATE_ARRAY_I    = state_array;
    assign KSU_PERM_EN_I        = (state == STATE_PERMUTE);
    assign KSU_ROUND_CONST_I    = round_constant_r;

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
        .bytes_absorbed_o   (KAU_BYTES_ABSORBED_O)
    );
    assign KAU_STATE_ARRAY_I    = state_array;
    assign KAU_RATE_I           = rate;
    assign KAU_BYTES_ABSORBED_I = bytes_absorbed;
    assign KAU_MSG_I            = t_data_i;
    assign KAU_KEEP_I           = t_keep_i;
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
        .xof_len_i              (KOU_XOF_LEN_I),
        .is_xof_fixed_len_i     (KOU_IS_XOF_FIXED_LEN_I),
        .xof_remaining_i        (xof_remaining_r),
        .max_bytes_absorbed_i   (max_bytes_absorbed_r),

        .bytes_squeezed_o       (KOU_BYTES_SQUEEZED_O),
        .squeeze_perm_needed_o  (KOU_PERM_NEEDED_O),
        .data_o                 (KOU_DATA_O),
        .keep_o                 (KOU_KEEP_O),
        .byte_count_o           (KOU_BYTE_COUNT_O),
        .last_o                 (KOU_LAST_O)
    );
    assign KOU_STATE_ARRAY_I          = state_array;
    assign KOU_MODE_I                 = current_mode;
    assign KOU_RATE_I                 = rate;
    assign KOU_BYTES_SQUEEZED_I       = bytes_squeezed;
    assign KOU_XOF_LEN_I              = target_xof_len;
    assign KOU_IS_XOF_FIXED_LEN_I     = is_xof_fixed_len;

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
                if (bytes_absorbed == max_bytes_absorbed_r) begin
                    next_state = STATE_PERMUTE;

                // PRIORITY 2: Message fully received, move on to padding stage
                end else if (msg_received) begin
                    next_state = STATE_SUFFIX_PADDING;

                // PRIORITY 3: Check if there is valid input and to process if so
                end else if (t_valid_i && internal_ready) begin
                    next_state = STATE_ABSORB;

                // PRIORITY 4: Message not yet fully received, waiting for t_valid
                end else begin
                    next_state = STATE_ABSORB;
                end
            end

            STATE_SUFFIX_PADDING : begin
                next_state = STATE_PERMUTE;
            end

            // ------------ PERMUTATION (1 Round Per Cycle) ------------
            STATE_PERMUTE : begin
                // Keccak-f[1600] requires 24 rounds (Indices 0 to 23)
                if (round_idx == 'd23) begin
                    if (absorb_done) begin
                        next_state = STATE_SQUEEZE;
                    end else begin
                        next_state = STATE_ABSORB;
                    end
                end else begin
                    next_state = STATE_PERMUTE;
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
                        next_state = STATE_PERMUTE;

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
        state_array_in_sel = KSU_SEL;

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
        init_wr_en          = 1'b0;

        // Absorb Wires
        absorb_wr_en        = 1'b0;
        msg_received_wr_en  = 1'b0;
        complete_absorb_en  = 1'b0;

        // Permutation
        perm_en             = 1'b0;
        rst_round_idx_en    = 1'b0;
        inc_round_idx_en    = 1'b0;

        // Squeeze Signals
        squeeze_wr_en            = 1'b0;
        update_total_squeezed_en = 1'b0;

        case(state)
            STATE_IDLE : begin
                if (start_i) begin
                    init_wr_en = 1'b1;
                end
            end

            STATE_ABSORB : begin
                t_ready_o = internal_ready;

                // PRIORITY 1: If current rate block is full, run permutation
                if (bytes_absorbed == max_bytes_absorbed_r) begin
                    perm_en = 1'b1;

                // PRIORITY 2: Message fully received, move on to padding stage
                end else if (msg_received) begin
                    // Need this extra register for edge case:
                    // - when message matches rate (msg_received)
                    complete_absorb_en = 1'b1;

                // PRIORITY 3: Check if there is valid input and to process if so
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

            // ------------ PERMUTATION (1 Round Per Cycle) ------------
            STATE_PERMUTE : begin
                state_array_wr_en   = 1'b1;
                state_array_in_sel  = KSU_SEL;

                // Keccak-f[1600] requires 24 rounds (Indices 0 to 23)
                if (round_idx == 'd23) begin
                    rst_round_idx_en = 1'b1;
                end else begin
                    inc_round_idx_en = 1'b1;
                end
            end
            // ---------------------------------------------------------

            STATE_SQUEEZE : begin
                t_data_o    = KOU_DATA_O;
                t_valid_o   = !stop_i;
                t_last_o    = KOU_LAST_O;
                t_keep_o    = KOU_KEEP_O;

                if (t_valid_o && t_ready_i) begin
                    // update_total_squeezed_en removed for Phase 3
                end

                if (stop_i) begin
                    init_wr_en = 1'b1;

                end else if (t_ready_i) begin
                    // A. Check Fixed Hash Done (SHA3-*)
                    if (KOU_LAST_O) begin

                    // B. Check Rate Empty -> Re-Permute (SHAKE)
                    end else if (KOU_PERM_NEEDED_O) begin
                        perm_en = 1'b1; // Reset counters
                        squeeze_wr_en = 1'b1; // Phase 3: Decrement XOF counter even on boundary

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

        // Phase 2 Optimization: Bypass redundant popcount loop by using
        // direct count from Output Unit (KOU).
        bytes_in_this_beat = {2'b00, KOU_BYTE_COUNT_O};
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

            // Squeeze Signals
            bytes_squeezed      <= 'b0;
            xof_remaining_r      <= 'b0;
        end else begin
            // --- Initialization & Reset ---
            if (init_wr_en) begin
                // 1. Setup Parameters
                current_mode     <= keccak_mode_i;
                target_xof_len   <= xof_len_i;
                is_xof_fixed_len <= (xof_len_i != 0);
                rate             <= KPU_RATE_O;
                max_bytes_absorbed_r <= KPU_RATE_O >> 3; // Phase 2: Register config-derived value
                suffix           <= KPU_SUFFIX_O;

                // 2. CRITICAL: Wipe the State Logic
                state_array      <= '0;  // Must be 0 before starting new Absorb
                bytes_absorbed   <= '0;
                bytes_squeezed   <= '0;
                xof_remaining_r  <= xof_len_i;
                msg_received     <= '0;

                // 3. Clear Internal Flags
                absorb_done      <= '0;

                round_idx        <= '0;
                round_constant_r <= KECCAK_ROUND_CONSTANTS[0];

            // Reset bytes absorbed after absorb permutation
            end else if (perm_en) begin
                bytes_absorbed  <= '0;
                bytes_squeezed  <= '0;
            end

            // --- State Array Update ---
            if (state_array_wr_en) begin
                if (state_array_in_sel == KSU_SEL) begin
                    state_array <= KSU_STATE_ARRAY_O;
                end else begin
                    state_array <= KAU_STATE_ARRAY_O;
                end
            end

            // --- Absorb Counters & Flags ---
            if (absorb_wr_en) begin
                bytes_absorbed  <= KAU_BYTES_ABSORBED_O;


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
                round_constant_r <= KECCAK_ROUND_CONSTANTS[0];
            end else if (inc_round_idx_en) begin
                round_idx <= round_idx + 'b1;
                round_constant_r <= KECCAK_ROUND_CONSTANTS[round_idx + 1];
            end

            // --- Squeeze Counters ---
            if (squeeze_wr_en) begin
                xof_remaining_r <= xof_remaining_r - {12'b0, KOU_BYTE_COUNT_O};
                if (!perm_en) begin
                    bytes_squeezed <= KOU_BYTES_SQUEEZED_O;
                end
            end
        end
    end
endmodule

`default_nettype wire
